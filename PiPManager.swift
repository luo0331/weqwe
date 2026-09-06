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
    var verdictLeft: String = ""       // 大字结论：≥师长 / 工兵 / 炸弹 / 撞雷…
    var verdictRight: String = ""
    var verdictLeftDetail: String = ""  // 候选明细（" / " 分隔）
    var verdictRightDetail: String = ""
}

/// 悬浮窗：自定义 PiP（AVSampleBufferDisplayLayer）。
/// iOS 不允许第三方 App 在其他 App 上层叠加窗口，PiP 是唯一合规途径。
/// 每 1 秒定时渲染；窗口小 → 简洁大字版，窗口放大 → 12 格明细版（自适应）。
@MainActor
final class PiPManager: NSObject, ObservableObject {
    @Published var isActive = false
    @Published var canPiP = false

    let displayLayer = AVSampleBufferDisplayLayer()
    private var controller: AVPictureInPictureController?
    private var audioPlayer: AVAudioPlayer?
    private var renderTimer: DispatchSourceTimer?
    private var lastRender = Date.distantPast
    private var compactMode = true
    private let size = CGSize(width: 1280, height: 720)

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
        Self.draw(state: state, into: pb, size: size, compact: compactMode)
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

    // MARK: 绘制（横屏 16:9）
    private nonisolated static func draw(state: PiPState, into pb: CVPixelBuffer, size: CGSize, compact: Bool) {
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

        if compact {
            drawCompact(state: state, size: size)
        } else {
            drawDetail(state: state, size: size)
        }
    }

    /// 简洁大字版：小窗时可读性优先（各等级存活数红色数字 + 判断结论特大字）
    private nonisolated static func drawCompact(state: PiPState, size: CGSize) {
        let pad: CGFloat = 20, gap: CGFloat = 16
        let half = (size.width - pad*2 - gap) / 2
        for (i, seat) in [Seat.leftEnemy, .rightEnemy].enumerated() {
            let x0 = pad + CGFloat(i) * (half + gap)
            let s = state.summaries[seat]

            drawText("敌方·\(seat.short)", at: CGPoint(x: x0 + 6, y: 8),
                     font: .systemFont(ofSize: 38, weight: .bold),
                     color: UIColor(hex: seat.colorHex) ?? .white)

            // 12 格：每级存活数（阵亡变暗归零，数字红色）
            let order: [Rank] = [.司令, .军长, .师长, .旅长, .团长, .营长, .连长, .排长, .工兵, .炸弹, .地雷, .军旗]
            let chipW = (half - 24) / 3
            let chipH: CGFloat = 390.0 / 4.0
            let f = UIFont.systemFont(ofSize: 44, weight: .bold)
            for idx in 0..<12 {
                let r = order[idx]
                let row = idx / 3
                let col = idx % 3
                let cx0 = x0 + CGFloat(col) * (chipW + 12)
                let cy0 = 56 + CGFloat(row) * (chipH + 10)
                let crect = CGRect(x: cx0, y: cy0, width: chipW, height: chipH)
                let dead = s?.deadKnown[r] ?? 0
                let remaining = max(0, r.initialCount - dead)
                let dim = remaining == 0

                let bgColor = dim ? UIColor(white: 1, alpha: 0.04) : UIColor(white: 1, alpha: 0.10)
                bgColor.setFill()
                let chipRect = UIBezierPath(roundedRect: crect, cornerRadius: 10)
                chipRect.fill()

                let charColor = dim ? UIColor(white: 0.35, alpha: 1) : UIColor(white: 0.95, alpha: 1)
                let numColor = dim ? UIColor(white: 0.35, alpha: 1) : UIColor(red: 1.0, green: 0.27, blue: 0.27, alpha: 1)
                let charText: String = r.short
                let numText: String = String(remaining)
                let charAttrs: [NSAttributedString.Key: Any] = [.font: f, .foregroundColor: charColor]
                let numAttrs: [NSAttributedString.Key: Any] = [.font: f, .foregroundColor: numColor]

                let charNS = charText as NSString
                let numNS = numText as NSString
                let cw2 = charNS.size(withAttributes: charAttrs).width
                let nw2 = numNS.size(withAttributes: numAttrs).width
                let startX = crect.midX - (cw2 + nw2) / 2
                let drawY = crect.midY - 28
                charNS.draw(at: CGPoint(x: startX, y: drawY), withAttributes: charAttrs)
                numNS.draw(at: CGPoint(x: startX + cw2, y: drawY), withAttributes: numAttrs)
            }

            // 判断框（结论特大字 + 候选彩色块）
            let jrect = CGRect(x: x0, y: 466, width: half, height: 234)
            UIColor(white: 1, alpha: 0.04).setFill()
            UIBezierPath(roundedRect: jrect, cornerRadius: 12).fill()
            let border = UIBezierPath(roundedRect: jrect, cornerRadius: 12)
            (UIColor(hex: seat.colorHex) ?? .gray).withAlphaComponent(0.8).setStroke()
            border.lineWidth = 2
            border.stroke()
            (UIColor(hex: seat.colorHex) ?? .gray).setFill()
            UIBezierPath(ovalIn: CGRect(x: jrect.minX + 14, y: jrect.minY + 18, width: 12, height: 12)).fill()
            drawText("判断·\(seat.short)", at: CGPoint(x: jrect.minX + 34, y: jrect.minY + 10),
                     font: .systemFont(ofSize: 24, weight: .bold),
                     color: UIColor(hex: seat.colorHex) ?? .white)

            let verdict = seat == .leftEnemy ? state.verdictLeft : state.verdictRight
            let verdictText = verdict.isEmpty ? "待触发" : verdict
            let vAttrs: [NSAttributedString.Key: Any] = [
                .font: UIFont.systemFont(ofSize: 62, weight: .bold),
                .foregroundColor: verdict.isEmpty ? UIColor(white: 0.35, alpha: 1) : UIColor.systemYellow
            ]
            let vs = verdictText as NSString
            let vsz = vs.size(withAttributes: vAttrs)
            vs.draw(at: CGPoint(x: jrect.midX - vsz.width / 2, y: jrect.minY + 44), withAttributes: vAttrs)

            let vDetail = seat == .leftEnemy ? state.verdictLeftDetail : state.verdictRightDetail
            if !verdict.isEmpty, !vDetail.isEmpty {
                let cFont = UIFont.systemFont(ofSize: 22, weight: .semibold)
                var cx = jrect.minX + 18; var cy = jrect.minY + 128
                for c in vDetail.split(separator: " / ").map(String.init) {
                    let bigRank = ["司令", "军长", "师长", "旅长", "炸弹", "工兵"].contains(c)
                    let cstr = c as NSString
                    let cw = cstr.size(withAttributes: [.font: cFont]).width + 16
                    if cx + cw > jrect.maxX - 14 { cx = jrect.minX + 18; cy += 34 }
                    UIColor(white: 1, alpha: bigRank ? 0.15 : 0.07).setFill()
                    UIBezierPath(roundedRect: CGRect(x: cx, y: cy, width: cw, height: 30), cornerRadius: 7).fill()
                    cstr.draw(at: CGPoint(x: cx + 8, y: cy + 2),
                              withAttributes: [.font: cFont, .foregroundColor: bigRank ? UIColor.systemYellow : UIColor(white: 0.86, alpha: 1)])
                    cx += cw
                }
            }
        }
    }

    /// 详细版：放大画中画时显示 12 格明细 + 判断条
    private nonisolated static func drawDetail(state: PiPState, size: CGSize) {
        drawText("敌方牌情 · 明细", at: CGPoint(x: 30, y: 14),
                 font: .systemFont(ofSize: 34, weight: .bold), color: .white)
        let timeStr = state.updatedAt.map { "更新 " + DateFormatter.shortTime.string(from: $0) } ?? ""
        let ts = timeStr as NSString
        let tw = ts.size(withAttributes: [.font: UIFont.systemFont(ofSize: 22)]).width
        drawText(timeStr, at: CGPoint(x: size.width - tw - 30, y: 24),
                 font: .systemFont(ofSize: 22), color: UIColor(white: 0.6, alpha: 1))

        let pad: CGFloat = 30, gap: CGFloat = 20
        let colW = (size.width - pad*2 - gap) / 2
        let top: CGFloat = 64
        let colH: CGFloat = 456

        drawEnemyChipsColumn(seat: .leftEnemy, summary: state.summaries[.leftEnemy], roundActive: state.roundActive,
                             rect: CGRect(x: pad, y: top, width: colW, height: colH))
        drawEnemyChipsColumn(seat: .rightEnemy, summary: state.summaries[.rightEnemy], roundActive: state.roundActive,
                             rect: CGRect(x: pad + colW + gap, y: top, width: colW, height: colH))

        let stripY = top + colH + 14
        let stripH = size.height - stripY - 24
        drawJudgeStrip(seat: .leftEnemy, vd: state.verdictLeft, detail: state.verdictLeftDetail,
                       rect: CGRect(x: pad, y: stripY, width: colW, height: stripH))
        drawJudgeStrip(seat: .rightEnemy, vd: state.verdictRight, detail: state.verdictRightDetail,
                       rect: CGRect(x: pad + colW + gap, y: stripY, width: colW, height: stripH))
    }

    /// 单敌剩余棋子明细：12 格芯片（3×4），阵亡变灰归零（数字红色）
    private nonisolated static func drawEnemyChipsColumn(seat: Seat, summary: InferenceEngine.EnemySummary?, roundActive: Bool, rect: CGRect) {
        UIColor(white: 1, alpha: 0.04).setFill()
        UIBezierPath(roundedRect: rect, cornerRadius: 14).fill()
        let border = UIBezierPath(roundedRect: rect, cornerRadius: 14)
        (UIColor(hex: seat.colorHex) ?? .gray).withAlphaComponent(0.9).setStroke()
        border.lineWidth = 3
        border.stroke()

        drawText("敌方·\(seat.short)", at: CGPoint(x: rect.minX + 16, y: rect.minY + 10),
                 font: .systemFont(ofSize: 30, weight: .bold),
                 color: UIColor(hex: seat.colorHex) ?? .white)
        let alive = (!roundActive) ? 25 : (summary?.aliveTotal ?? 25)
        let aliveStr = "\(alive)/25" as NSString
        let aw = aliveStr.size(withAttributes: [.font: UIFont.systemFont(ofSize: 26, weight: .bold)]).width
        drawText(aliveStr as String, at: CGPoint(x: rect.maxX - aw - 16, y: rect.minY + 12),
                 font: .systemFont(ofSize: 26, weight: .bold), color: .white)

        let order: [Rank] = [.司令, .军长, .师长, .旅长, .团长, .营长, .连长, .排长, .工兵, .炸弹, .地雷, .军旗]
        let chipW = (rect.width - 32 - 20) / 3
        let chipY0 = rect.minY + 50
        let chipH = (rect.height - 50 - 24) / 4
        let f = UIFont.systemFont(ofSize: 30, weight: .bold)
        for idx in 0..<12 {
            let r = order[idx]
            let row = idx / 3
            let col = idx % 3
            let cx0 = rect.minX + 16 + CGFloat(col) * (chipW + 10)
            let cy0 = chipY0 + CGFloat(row) * (chipH + 8)
            let crect = CGRect(x: cx0, y: cy0, width: chipW, height: chipH)
            let dead = summary?.deadKnown[r] ?? 0
            let remaining = max(0, r.initialCount - dead)
            let dim = remaining == 0

            let bgColor = dim ? UIColor(white: 1, alpha: 0.04) : UIColor(white: 1, alpha: 0.10)
            bgColor.setFill()
            let chipRect = UIBezierPath(roundedRect: crect, cornerRadius: 9)
            chipRect.fill()

            let charColor = dim ? UIColor(white: 0.35, alpha: 1) : UIColor(white: 0.95, alpha: 1)
            let numColor = dim ? UIColor(white: 0.35, alpha: 1) : UIColor(red: 1.0, green: 0.27, blue: 0.27, alpha: 1)
            let charText: String = r.short
            let numText: String = String(remaining)
            let charAttrs: [NSAttributedString.Key: Any] = [.font: f, .foregroundColor: charColor]
            let numAttrs: [NSAttributedString.Key: Any] = [.font: f, .foregroundColor: numColor]

            let charNS = charText as NSString
            let numNS = numText as NSString
            let cw2 = charNS.size(withAttributes: charAttrs).width
            let nw2 = numNS.size(withAttributes: numAttrs).width
            let startX = crect.midX - (cw2 + nw2) / 2
            let drawY = crect.midY - 18
            charNS.draw(at: CGPoint(x: startX, y: drawY), withAttributes: charAttrs)
            numNS.draw(at: CGPoint(x: startX + cw2, y: drawY), withAttributes: numAttrs)
        }
    }

    /// 底部判断条（详细版）：结论大字居中 + 候选彩色块
    private nonisolated static func drawJudgeStrip(seat: Seat, vd: String, detail: String, rect: CGRect) {
        UIColor(white: 1, alpha: 0.04).setFill()
        UIBezierPath(roundedRect: rect, cornerRadius: 12).fill()
        let border = UIBezierPath(roundedRect: rect, cornerRadius: 12)
        (UIColor(hex: seat.colorHex) ?? .gray).withAlphaComponent(0.8).setStroke()
        border.lineWidth = 2
        border.stroke()

        (UIColor(hex: seat.colorHex) ?? .gray).setFill()
        UIBezierPath(ovalIn: CGRect(x: rect.minX + 14, y: rect.minY + 16, width: 12, height: 12)).fill()
        drawText("判断·\(seat.short)", at: CGPoint(x: rect.minX + 34, y: rect.minY + 8),
                 font: .systemFont(ofSize: 23, weight: .bold),
                 color: UIColor(hex: seat.colorHex) ?? .white)

        let vdEmpty = vd.isEmpty
        let vFont = UIFont.systemFont(ofSize: 44, weight: .bold)
        let vColor = vdEmpty ? UIColor(white: 0.45, alpha: 1) : UIColor.systemYellow
        let vs = (vdEmpty ? "待吃子触发后判断…" : vd) as NSString
        let vsz = vs.size(withAttributes: [.font: vFont])
        vs.draw(at: CGPoint(x: max(rect.minX + 12, rect.midX - vsz.width / 2), y: rect.minY + 44),
                withAttributes: [.font: vFont, .foregroundColor: vColor])

        if !vdEmpty {
            let cFont = UIFont.systemFont(ofSize: 20, weight: .semibold)
            var cx = rect.minX + 16; var cy = rect.minY + 106
            for c in detail.split(separator: " / ").map(String.init) {
                let bigRank = ["司令", "军长", "师长", "旅长", "炸弹", "工兵"].contains(c)
                let cstr = c as NSString
                let cw = cstr.size(withAttributes: [.font: cFont]).width + 14
                if cx + cw > rect.maxX - 12 { cx = rect.minX + 16; cy += 32 }
                UIColor(white: 1, alpha: bigRank ? 0.15 : 0.07).setFill()
                UIBezierPath(roundedRect: CGRect(x: cx, y: cy, width: cw, height: 26), cornerRadius: 6).fill()
                cstr.draw(at: CGPoint(x: cx + 7, y: cy + 2),
                          withAttributes: [.font: cFont, .foregroundColor: bigRank ? UIColor.systemYellow : UIColor(white: 0.85, alpha: 1)])
                cx += cw
            }
        }
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

    func pictureInPictureController(_ pictureInPictureController: AVPictureInPictureController, didTransitionToRenderSize newRenderSize: CMVideoDimensions) {
        // 窗口小 → 简洁大字版；窗口放大 → 详细明细版
        compactMode = newRenderSize.width < 640
    }

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
