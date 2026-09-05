import Foundation
import CoreGraphics
import ImageIO

/// 录屏帧接收缓存 (主 App 进程内)。
/// 免费签名无 App Group 权限, 扩展改走 loopback 网络把帧推给 FrameServer,
/// 由 FrameServer 写入这里; GameSession 轮询 readLatestFrame。
enum FrameStore {
    struct Meta: Codable {
        var seq: Int
        var time: Double
        var width: Int
        var height: Int
    }

    private static let lock = NSLock()
    private static var latestJPEG: Data?
    private static var latestMeta: Meta?
    private static var seenSeq = -1

    /// FrameServer 收到新帧时调用 (后台线程)
    static func store(jpeg: Data, meta: Meta) {
        lock.lock()
        latestJPEG = jpeg
        latestMeta = meta
        lock.unlock()
    }

    /// 主 App 调用: 有新帧时返回
    static func readLatestFrame() -> (image: CGImage, meta: Meta)? {
        lock.lock()
        guard let meta = latestMeta, meta.seq != seenSeq, let jpeg = latestJPEG else {
            lock.unlock()
            return nil
        }
        latestJPEG = nil
        lock.unlock()
        guard let src = CGImageSourceCreateWithData(jpeg as CFData, nil),
              let img = CGImageSourceCreateImageAtIndex(src, 0, nil) else {
            return nil
        }
        seenSeq = meta.seq
        return (img, meta)
    }

    static func resetSeq() {
        lock.lock()
        latestJPEG = nil
        latestMeta = nil
        seenSeq = -1
        lock.unlock()
    }
}
