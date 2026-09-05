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
}

/// 悬浮窗：自定义 PiP（AVSampleBufferDisplayLayer）。
/// iOS 不允许第三方 App 在其他 App 上层叠加窗口，PiP 是唯一合规途径：
/// 把实时数据渲染成视频帧，通过画中画小窗浮在微信上面，边看边下。
final class PiPManager: NSObject, ObservableObject {
    @Published var isActive = false
    @Published var canPiP = false

    let displayLayer = AVSampleBufferDisplayLayer()
    private var controller: AVPictureInPictureController?
    private var audioPlayer: AVAudioPlayer?
    private var lastRender = Date.distantPast
    private let size = CGSize(width: 720, height: 1280)

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
    }

    func start() {
        // 首帧渲染前 isPictureInPicturePossible 可能为 false，直接尝试启动
        controller?.startPictureInPicture()
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

    private static func makeBuffer(size: CGSize) -> CVPixelBuffer? {
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

    // MARK: 绘制实时数据卡
    static func draw(state: PiPState, into pb: CVPixelBuffer, size: CGSize) {
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

        UIColor(red: 0.05, green: 0.05, blue: 0.07, alpha: 1).setFill()
        UIRectFill(CGRect(origin: .zero, size: size))

        drawText("四国记牌器", at: CGPoint(x: 36, y: 34), font: .systemFont(ofSize: 48, weight: .bold), color: .white)
        let timeStr = state.updatedAt.map { "更新 " + DateFormatter.shortTime.string(from: $0) } ?? "等待画面…"
        drawText(timeStr, at: CGPoint(x: 36, y: 100), font: .systemFont(ofSize: 30), color: UIColor(white: 0.65, alpha: 1))

        var y: CGFloat = 170
        for seat in [Seat.leftEnemy, .rightEnemy] {
            y = drawEnemyCard(seat: seat, summary: state.summaries[seat], top: y, width: size.width - 72)
        }

        // 迷你棋盘
        let mapRect = CGRect(x: 44, y: y + 10, width: size.width - 88, height: 470)
        UIColor(white: 1, alpha: 0.05).setFill()
        UIBezierPath(roundedRect: mapRect, cornerRadius: 20).fill()
        for n in state.nodes {
            let p = CGPoint(x: mapRect.minX + n.x * mapRect.width,
                            y: mapRect.minY + n.y * mapRect.height)
            let r: CGFloat = n.rank != nil ? 15 : 11
            let color = UIColor(hex: n.seat.colorHex) ?? .gray
            color.setFill()
            UIBezierPath(ovalIn: CGRect(x: p.x - r, y: p.y - r, width: r * 2, height: r * 2)).fill()
            if let rank = n.rank, n.seat.isAlly {
                drawText(rank.short, at: CGPoint(x: p.x - 13, y: p.y - 17), font: .systemFont(ofSize: 26, weight: .semibold), color: .white)
            }
        }

        // 推演摘要
        var ny = size.height - 230
        drawText("推演", at: CGPoint(x: 40, y: ny - 46), font: .systemFont(ofSize: 32, weight: .semibold), color: UIColor(white: 0.75, alpha: 1))
        for line in state.notes.prefix(4) {
            if ny > size.height - 30 { break }
            drawText(line, at: CGPoint(x: 40, y: ny), font: .systemFont(ofSize: 28), color: UIColor(white: 0.88, alpha: 1))
            ny += 44
        }
    }

    private static func drawEnemyCard(seat: Seat, summary: InferenceEngine.EnemySummary?, top: CGFloat, width: CGFloat) -> CGFloat {
        let rect = CGRect(x: 36, y: top, width: width, height: 190)
        UIColor(white: 1, alpha: 0.07).setFill()
        UIBezierPath(roundedRect: rect, cornerRadius: 22).fill()
        let alive = summary?.aliveTotal ?? 0
        drawText("\(seat.label) 剩 \(alive)/25",
                 at: CGPoint(x: rect.minX + 26, y: rect.minY + 18),
                 font: .systemFont(ofSize: 42, weight: .bold),
                 color: UIColor(hex: seat.colorHex) ?? .white)
        // 构成期望条
        if let s = summary {
            var x = rect.minX + 26
            let barY = rect.minY + 90
            let total = s.estimate.values.reduce(0, +)
            if total > 0 {
                for r in Rank.allCases.sorted(by: >) {
                    guard let v = s.estimate[r], v > 0.01 else { continue }
                    let w = CGFloat(v / total) * (width - 52)
                    let color = UIColor(hex: seat.colorHex)?.withAlphaComponent(0.35 + 0.6 * Double(r.strength ?? 1) / 9.0) ?? .gray
                    color.setFill()
                    UIBezierPath(roundedRect: CGRect(x: x, y: barY, width: max(2, w - 2), height: 34), cornerRadius: 6).fill()
                    x += w
                }
            }
            var legend = "亡: "
            let known = s.deadKnown.sorted { ($0.key.strength ?? -1) > ($1.key.strength ?? -1) }
            for (r, c) in known { legend += "\(r.short)×\(c) " }
            if s.deadUnknown > 0 { legend += "未知×\(s.deadUnknown)" }
            if legend == "亡: " { legend = "亡: 无" }
            drawText(legend, at: CGPoint(x: rect.minX + 26, y: barY + 48), font: .systemFont(ofSize: 28), color: UIColor(white: 0.7, alpha: 1))
        }
        return top + 210
    }

    private static func drawText(_ text: String, at point: CGPoint, font: UIFont, color: UIColor) {
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

    func pictureInPictureControllerTimeRange(_ pictureInPictureController: AVPictureInPictureController) -> CMTimeRange {
        CMTimeRange(start: .negativeInfinity, duration: .positiveInfinity)
    }

    func pictureInPictureControllerIsPlaybackPaused(_ pictureInPictureController: AVPictureInPictureController) -> Bool {
        false
    }

    func pictureInPictureController(_ pictureInPictureController: AVPictureInPictureController, skipByInterval skipInterval: CMTime, completion completionHandler: @escaping () -> Void) {
        completionHandler()
    }

    func pictureInPictureController(_ pictureInPictureController: AVPictureInPictureController, didTransitionToRenderSize newRenderSize: CMVideoDimensions) {}
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
