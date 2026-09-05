import Foundation
import CoreGraphics
import ImageIO

/// 录屏扩展与主 App 之间的帧通道（App Group 共享容器）。
/// 扩展负责写：latest.jpg（原子写）+ meta.json + UserDefaults seq。
/// 主 App 轮询 seq，变化则读帧。此文件同时编译进两个 target。
enum FrameStore {
    static let appGroupId = "group.com.sqjq.tracker"
    static let seqKey = "capture.seq"
    static let intervalKey = "capture.interval"
    static let qualityKey = "capture.quality"
    static let maxDimKey = "capture.maxDim"

    struct Meta: Codable {
        var seq: Int
        var time: Double
        var width: Int
        var height: Int
    }

    static var containerURL: URL? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroupId)
    }

    private static var baseDir: URL {
        containerURL ?? FileManager.default.temporaryDirectory
    }

    static var frameURL: URL { baseDir.appendingPathComponent("live_frame.jpg") }
    static var metaURL: URL { baseDir.appendingPathComponent("live_frame.json") }

    static var defaults: UserDefaults? { UserDefaults(suiteName: appGroupId) }

    /// 录屏扩展调用
    static func writeFrame(jpeg: Data, meta: Meta) {
        let dir = baseDir
        let tmp = dir.appendingPathComponent("live_frame.tmp.jpg")
        try? jpeg.write(to: tmp, options: .atomic)
        try? FileManager.default.removeItem(at: frameURL)
        try? FileManager.default.moveItem(at: tmp, to: frameURL)
        if let d = try? JSONEncoder().encode(meta) {
            try? d.write(to: metaURL, options: .atomic)
        }
        defaults?.set(meta.seq, forKey: seqKey)
    }

    private static var cachedSeq = -1

    /// 主 App 调用：有新帧时返回
    static func readLatestFrame() -> (image: CGImage, meta: Meta)? {
        guard let seq = defaults?.object(forKey: seqKey) as? Int else { return nil }
        guard seq != cachedSeq else { return nil }
        guard let meta = loadMeta(), meta.seq == seq,
              let src = CGImageSourceCreateWithURL(frameURL as CFURL, nil),
              let img = CGImageSourceCreateImageAtIndex(src, 0, nil) else {
            cachedSeq = seq // 避免反复读取坏帧
            return nil
        }
        cachedSeq = seq
        return (img, meta)
    }

    static func loadMeta() -> Meta? {
        guard let d = try? Data(contentsOf: metaURL) else { return nil }
        return try? JSONDecoder().decode(Meta.self, from: d)
    }

    static func resetSeq() {
        defaults?.set(-1, forKey: seqKey)
        cachedSeq = -1
        try? FileManager.default.removeItem(at: frameURL)
        try? FileManager.default.removeItem(at: metaURL)
    }

    /// 采集参数（扩展每帧读取，主 App 设置页可实时改）
    static var captureInterval: Double {
        let v = defaults?.double(forKey: intervalKey) ?? 0
        return v > 0.05 ? v : 0.34
    }
    static var captureQuality: Double {
        let v = defaults?.double(forKey: qualityKey) ?? 0
        return v > 0.05 ? v : 0.6
    }
    static var captureMaxDim: CGFloat {
        let v = defaults?.double(forKey: maxDimKey) ?? 0
        return v > 400 ? CGFloat(v) : 1600
    }
}
