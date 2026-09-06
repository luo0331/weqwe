import Foundation
import AVFoundation
import AVKit
import CoreMedia
import CoreVideo
import UIKit

struct PiPNode {
    let x: CGFloat // 0~1 棋盘归一化坐标
    let y: CGFloat
    let seat: Seat
    let rank: Rank?
}

struct PiPState {
    var summaries: [Seat: InferenceEngine.EnemySummary] = [:]
    var notes: [String] = []
    var nodes: [PiPNode] = []
    var updatedAt: Date?
    var roundActive = false
    var inferenceLeft: String = ""
    var inferenceRight: String = ""
}

/// 悬浮窗：自定义 PiP（AVSampleBufferDisplayLayer）。
/// iOS 不允许第三方 App 在其他 App 上层叠加窗口，PiP 是唯一合规途径：
/// 把实时数据渲染成视频帧，通过画中画小窗浮在微信上面，边看边下。
/// 每 1 秒定时渲染"敌方牌情"数据卡，保证小窗永远有画面（修复黑屏）。
@MainActor
final class PiPManager: NSObject, ObservableObject {
    @Published var isActive = false
    @Published var canPiP = false

    let displayLayer = AVSampleBufferDisplayLayer()
    private var controller: AVPictureInPictureController?
    private var audioPlayer: AVAudioPlayer?
    private var renderTimer: DispatchSourceTimer?
    private var lastRender = Date.distantPast
    private let size = CGSize(width: 720, height: 960)

    /// 由 GameSession 注入：随时取当前数据快照
    var stateProvider: (() -> PiPState)?

    func setup() {
        canPiP = AVPictureInPictureController.isPictureInPictureSupported()
        guard canPiP else { return }
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .default, options: [.mixWithOthers])
        try? AVAudioSession.sharedInstance().setActive(true)
        audioPlayer = Self.silentPlayer()
        audioPlayer?.numberOfLoops = -1
        audioPlayer?.volume = 0.01
        audioPlayer?.play()
        let src = AVPictureInPictureController.ContentSource(
            sampleBufferDisplayLayer: displayLayer, playbackDelegate: self)
        let c = AVPictureInPictureController(contentSource: src)
        c.canStartPictureInPictureAutomaticallyFromInline = true
        c.delegate = self
        controller = c

        // 定时渲染（1fps）：无论是否在对局，小窗始终显示最新牌情
        let t = DispatchSource.makeTimerSource(queue: .main)
        t.schedule(deadline: .now() + 1, repeating: 1.0)
        t.setEventHandler { [weak self] in
            Task { @MainActor [weak self] in
                guard let self, let sp = self.stateProvider else { return }
                self.render(state: sp())
            }
        }
        t.resume()
        renderTimer = t
    }

    func start() {
        // 首帧渲染前 isPictureInPicturePossible 可能为 false，直接尝试启动
        controller?.startPictureInPicture()
        render(state: stateProvider?() ?? PiPState())
    }

    func stop() {
        controller?.stopPictureInPicture()
    }

    // MARK: 渲染
    func render(state: PiPState) {
        guard controller != nil else { return }
        let now = Date()
        guard now.timeIntervalSince(lastRender) >= 0.4 else { return }
        lastRender = now
        guard let pb = Self.makeBuffer(size: size) else { return }
        Self.draw(state: state, into: pb, size: size)
        enqueue(pb)
    }

    private func enqueue(_ pb: CVPixelBuffer) {
        var fmt: CMVideoFormatDescription?
        guard CMVideoFormatDescriptionCreateForImageBuffer(
            allocator: kCFAllocatorDefault, imageBuffer: pb, formatDescriptionOut: &fmt) == noErr,
              let fmt else { return }
        var timing = CMSampleTimingInfo(
            duration: CMTime(value: 1, timescale: 10),
            presentationTimeStamp: CMClockGetTime(CMClockGetHostTimeClock()),
            decodeTimeStamp: .invalid)
        var sb: CMSampleBuffer?
        guard CMSampleBufferCreateForImageBuffer(
            allocator: kCFAllocatorDefault, imageBuffer: pb, dataReady: true,
            makeDataReadyCallback: nil, refcon: nil, formatDescription: fmt,
            sampleTiming: &timing, sampleBufferOut: &sb) == noErr, let sb else { return }
        if displayLayer.status == .failed { displayLayer.flush() }
        displayLayer.enqueue(sb)
    }

    private nonisolated static func makeBuffer(size: CGSize) -> CVPixelBuffer? {
        var pb: CVPixelBuffer?
        let attrs: [CFString: Any] = [
            kCVPixelBufferCGImageCompatibilityKey: true,
            kCVPixelBufferCGBitmapContextCompatibilityKey: true
        ]
        guard CVPixelBufferCreate(kCFAllocatorDefault, Int(size.width), Int(size.height),
                                  kCVPixelFormatType_32BGRA, attrs as CFDictionary, &pb) == kCVReturnSuccess
        else { return nil }
        return pb
    }

    // MARK: 绘制"敌方牌情"数据卡（参考用户提供样式）
    private nonisolated static func draw(state: PiPState, into pb: CVPixelBuffer, size: CGSize) {
        CVPixelBufferLockBaseAddress(pb, [])
        defer { CVPixelBufferUnlockBaseAddress(pb, []) }
        guard let base = CVPixelBufferGetBaseAddress(pb) else { return }
        guard let ctx = CGContext(
            data: base, width: Int(size.width), height: Int(size.height),
            bitsPerComponent: 8, bytesPerRow: CVPixelBufferGetBytesPerRow(pb),
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        ) else { return }

        UIGraphicsPushContext(ctx)
        defer { UIGraphicsPopContext() }

        UIColor(red: 0.043, green: 0.051, blue: 0.071, alpha: 1).setFill()
        UIRectFill(CGRect(origin: .zero, size: size))

        drawText("敌方牌情", at: CGPoint(x: 34, y: 30),
                 font: .systemFont(ofSize: 44, weight: .bold), color: .white)
        let timeStr = state.updatedAt.map { "更新 " + DateFormatter.shortTime.string(from: $0) } ?? "待机中"
        let ts = timeStr as NSString
        let tw = ts.size(withAttributes: [.font: UIFont.systemFont(ofSize: 26)]).width
        drawText(timeStr, at: CGPoint(x: size.width - tw - 34, y: 46),
                 font: .systemFont(ofSize: 26), color: UIColor(white: 0.6, alpha: 1))

        let pad: CGFloat = 30
        let colW = (size.width - pad * 2 - 20) / 2

        drawText("敌方剩余棋子", at: CGPoint(x: pad, y: 104),
                 font: .systemFont(ofSize: 30, weight: .semibold), color: UIColor(white: 0.72, alpha: 1))
        for (i, seat) in [Seat.leftEnemy, .rightEnemy].enumerated() {
            let x = pad + CGFloat(i) * (colW + 20)
            drawEnemyColumn(seat: seat, summary: state.summaries[seat], roundActive: state.roundActive,
                            rect: CGRect(x: x, y: 148, width: colW, height: 424))
        }

        drawText("最新敌方大小判断", at: CGPoint(x: pad, y: 600),
                 font: .systemFont(ofSize: 30, weight: .semibold), color: UIColor(white: 0.72, alpha: 1))
        drawInferenceBox(seat: .leftEnemy, text: state.inferenceLeft,
                         rect: CGRect(x: pad, y: 646, width: colW, height: 250))
        drawInferenceBox(seat: .rightEnemy, text: state.inferenceRight,
                         rect: CGRect(x: pad + colW + 20, y: 646, width: colW, height: 250))
    }

    private nonisolated static func drawEnemyColumn(seat: Seat, summary: InferenceEngine.EnemySummary?, roundActive: Bool, rect: CGRect) {
        UIColor(white: 1, alpha: 0.04).setFill()
        UIBezierPath(roundedRect: rect, cornerRadius: 18).fill()
        let border = UIBezierPath(roundedRect: rect, cornerRadius: 18)
        (UIColor(hex: seat.colorHex) ?? .gray).withAlphaComponent(0.9).setStroke()
        border.lineWidth = 3
        border.stroke()

        drawText("敌方·\(seat.short)", at: CGPoint(x: rect.minX + 20, y: rect.minY + 14),
                 font: .systemFont(ofSize: 32, weight: .bold),
                 color: UIColor(hex: seat.colorHex) ?? .white)
        let alive = roundActive ? (summary?.aliveTotal ?? 25) : 25
        let aliveStr = "剩\(alive)/25" as NSString
        let aw = aliveStr.size(withAttributes: [.font: UIFont.systemFont(ofSize: 30, weight: .bold)]).width
        drawText(aliveStr as String, at: CGPoint(x: rect.maxX - aw - 20, y: rect.minY + 18),
                 font: .systemFont(ofSize: 30, weight: .bold), color: .white)

        // 与参考图一致的顺序
        let order: [Rank] = [.司令, .军长, .师长, .旅长, .团长, .营长, .连长, .排长, .工兵, .炸弹, .地雷, .军旗]
        let highlight: Set<Rank> = [.司令, .军长, .工兵, .炸弹]
        let chipW = (rect.width - 40 - 10) / 2
        let chipH: CGFloat = 46
        var cy = rect.minY + 66
        for row in 0..<6 {
            for col in 0..<2 {
                let idx = row * 2 + col
                guard idx < order.count else { break }
                let r = order[idx]
                let dead = summary?.deadKnown[r] ?? 0
                let remaining = max(0, r.initialCount - dead)
                let crect = CGRect(x: rect.minX + 20 + CGFloat(col) * (chipW + 10), y: cy,
                                   width: chipW, height: chipH)
                UIColor(white: 1, alpha: highlight.contains(r) ? 0.13 : 0.06).setFill()
                UIBezierPath(roundedRect: crect, cornerRadius: 8).fill()
                drawText("\(r.rawValue)\(remaining)",
                         at: CGPoint(x: crect.minX + 12, y: crect.midY - 17),
                         font: .systemFont(ofSize: 26, weight: .semibold),
                         color: highlight.contains(r) ? UIColor.systemYellow : UIColor(white: 0.85, alpha: 1))
            }
            cy += chipH + 10
        }
    }

    private nonisolated static func drawInferenceBox(seat: Seat, text: String, rect: CGRect) {
        UIColor(white: 1, alpha: 0.04).setFill()
        UIBezierPath(roundedRect: rect, cornerRadius: 16).fill()
        let border = UIBezierPath(roundedRect: rect, cornerRadius: 16)
        (UIColor(hex: seat.colorHex) ?? .gray).withAlphaComponent(0.8).setStroke()
        border.lineWidth = 2
        border.stroke()

        (UIColor(hex: seat.colorHex) ?? .gray).setFill()
        UIBezierPath(ovalIn: CGRect(x: rect.minX + 18, y: rect.minY + 22, width: 14, height: 14)).fill()
        drawText("敌方·\(seat.short)", at: CGPoint(x: rect.minX + 44, y: rect.minY + 12),
                 font: .systemFont(ofSize: 30, weight: .bold),
                 color: UIColor(hex: seat.colorHex) ?? .white)

        let body = text.isEmpty ? "待吃子触发后判断…" : text
        let attrs: [NSAttributedString.Key: Any] = [
            .font: UIFont.systemFont(ofSize: 27, weight: .medium),
            .foregroundColor: text.isEmpty ? UIColor(white: 0.5, alpha: 1) : UIColor.systemYellow
        ]
        (body as NSString).draw(in: CGRect(x: rect.minX + 20, y: rect.minY + 58,
                                           width: rect.width - 40, height: rect.height - 72),
                                withAttributes: attrs)
    }

    private nonisolated static func drawText(_ text: String, at point: CGPoint, font: UIFont, color: UIColor) {
        let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color]
        (text as NSString).draw(at: point, withAttributes: attrs)
    }

    /// 生成 1 秒静音 wav，维持后台播放保活（PiP 需要）
    static func silentPlayer() -> AVAudioPlayer? {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("silence.wav")
        if !FileManager.default.fileExists(atPath: url.path) {
            var data = Data()
            func le32(_ v: UInt32) { data.append(contentsOf: [UInt8(v & 255), UInt8((v >> 8) & 255), UInt8((v >> 16) & 255), UInt8((v >> 24) & 255)]) }
            func le16(_ v: UInt16) { data.append(contentsOf: [UInt8(v & 255), UInt8((v >> 8) & 255)]) }
            let rate: UInt32 = 8000
            let samples: UInt32 = 8000
            data.append(contentsOf: Array("RIFF".utf8))
            le32(36 + samples * 2)
            data.append(contentsOf: Array("WAVE".utf8))
            data.append(contentsOf: Array("fmt ".utf8))
            le32(16); le16(1); le16(1); le32(rate); le32(rate * 2); le16(2); le16(16)
            data.append(contentsOf: Array("data".utf8))
            le32(samples * 2)
            data.append(contentsOf: [UInt8](repeating: 0, count: Int(samples) * 2))
            try? data.write(to: url)
        }
        return try? AVAudioPlayer(contentsOf: url)
    }
}

extension PiPManager: AVPictureInPictureControllerDelegate {
    func pictureInPictureControllerDidStartPictureInPicture(_ pictureInPictureController: AVPictureInPictureController) {
        isActive = true
    }

    func pictureInPictureControllerDidStopPictureInPicture(_ pictureInPictureController: AVPictureInPictureController) {
        isActive = false
    }
}

extension PiPManager: AVPictureInPictureSampleBufferPlaybackDelegate {
    func pictureInPictureController(_ pictureInPictureController: AVPictureInPictureController, setPlaying playing: Bool) {}

    func pictureInPictureControllerTimeRangeForPlayback(_ pictureInPictureController: AVPictureInPictureController) -> CMTimeRange {
        CMTimeRange(start: .negativeInfinity, duration: .positiveInfinity)
    }

    func pictureInPictureControllerIsPlaybackPaused(_ pictureInPictureController: AVPictureInPictureController) -> Bool {
        false
    }

    func pictureInPictureController(_ pictureInPictureController: AVPictureInPictureController, skipByInterval skipInterval: CMTime, completion completionHandler: @escaping () -> Void) {
        completionHandler()
    }

    func pictureInPictureController(_ pictureInPictureController: AVPictureInPictureController, didTransitionToRenderSize newRenderSize: CMVideoDimensions) {}

    nonisolated var byPlayerContainerView: UIView? { nil }

    nonisolated var pictureInPictureControllerByPlayerContainerView: UIView? { nil }
}

extension UIColor {
    convenience init?(hex: String) {
        var s = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.hasPrefix("#") { s.removeFirst() }
        guard s.count == 6, let v = UInt32(s, radix: 16) else { return nil }
        self.init(red: CGFloat((v >> 16) & 255) / 255,
                  green: CGFloat((v >> 8) & 255) / 255,
                  blue: CGFloat(v & 255) / 255, alpha: 1)
    }
}
