import Foundation
import ReplayKit
import CoreImage
import CoreMedia
import ImageIO
import Network

/// 录屏采集扩展：接收系统屏幕帧 → 降采样 → JPEG → 通过 127.0.0.1 推给主 App。
/// (免费签名无 App Group 权限, 用 loopback 网络传帧替代)
class SampleHandler: RPBroadcastSampleHandler {

    private let ciContext = CIContext()
    private var lastPTS = CMTime.invalid
    private var seq = 0
    private let interval: Double = 0.34
    private let quality: Double = 0.6
    private let maxDim: CGFloat = 1600
    private var conn: NWConnection?

    override func broadcastStarted(withSetupInfo setupInfo: [String: NSObject]?) {
        seq = 0
        connect()
    }

    override func broadcastFinished() {
        conn?.cancel()
        conn = nil
    }

    private func connect() {
        let c = NWConnection(host: "127.0.0.1", port: 18080, using: .tcp)
        c.stateUpdateHandler = { _ in }
        c.start(queue: DispatchQueue.global(qos: .utility))
        conn = c
    }

    override func processSampleBuffer(_ sampleBuffer: CMSampleBuffer, with sampleBufferType: RPSampleBufferType) {
        guard sampleBufferType == .video,
              CMSampleBufferDataIsReady(sampleBuffer),
              let pb = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        if lastPTS.isValid, CMTimeSubtract(pts, lastPTS).seconds < interval { return }
        lastPTS = pts

        var ci = CIImage(cvPixelBuffer: pb)
        let scale = min(1, maxDim / max(ci.extent.width, ci.extent.height))
        if scale < 1 {
            ci = ci.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        }
        guard let cg = ciContext.createCGImage(ci, from: ci.extent) else { return }

        let data = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(data, "public.jpeg" as CFString, 1, nil) else { return }
        let opts: [CFString: Any] = [kCGImageDestinationLossyCompressionQuality: quality]
        CGImageDestinationAddImage(dest, cg, opts as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { return }

        seq += 1
        send(jpeg: data as Data, seq: seq)
    }

    /// 帧协议: [4B 大端 jpeg 长度][4B 大端 seq][jpeg]
    private func send(jpeg: Data, seq: Int) {
        guard let c = conn, c.state == .ready else { return }
        let n = UInt32(jpeg.count)
        let s = UInt32(seq)
        var head: [UInt8] = [
            UInt8((n >> 24) & 255), UInt8((n >> 16) & 255), UInt8((n >> 8) & 255), UInt8(n & 255),
            UInt8((s >> 24) & 255), UInt8((s >> 16) & 255), UInt8((s >> 8) & 255), UInt8(s & 255),
        ]
        c.send(content: Data(head) + jpeg, completion: .contentProcessed { _ in })
    }
}
