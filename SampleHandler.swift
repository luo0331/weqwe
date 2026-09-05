import ReplayKit
import CoreImage
import CoreMedia
import ImageIO

/// 录屏采集扩展：接收系统屏幕帧 → 降采样 → JPEG → 写入 App Group，供主 App 轮询分析。
class SampleHandler: RPBroadcastSampleHandler {

    private let ciContext = CIContext()
    private var lastPTS = CMTime.invalid
    private var seq = 0
    private var interval: Double = 0.34
    private var quality: Double = 0.6
    private var maxDim: CGFloat = 1600
    private var paramsAt = Date.distantPast

    override func broadcastStarted(withSetupInfo setupInfo: [String: NSObject]?) {
        seq = FrameStore.defaults?.integer(forKey: FrameStore.seqKey) ?? 0
        refreshParams(force: true)
    }

    override func broadcastFinished() {
        finishBroadcast(with: nil)
    }

    override func broadcastSampleBuffer(_ sampleBuffer: CMSampleBuffer, with sampleBufferType: RPSampleBufferType) {
        guard sampleBufferType == .video,
              CMSampleBufferDataIsReady(sampleBuffer),
              let pb = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        if lastPTS.isValid, CMTimeSubtract(pts, lastPTS).seconds < interval { return }
        lastPTS = pts
        refreshParams(force: false)

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
        let meta = FrameStore.Meta(seq: seq,
                                   time: Date().timeIntervalSince1970,
                                   width: cg.width, height: cg.height)
        FrameStore.writeFrame(jpeg: data as Data, meta: meta)
    }

    private func refreshParams(force: Bool) {
        guard force || Date().timeIntervalSince(paramsAt) > 5 else { return }
        paramsAt = Date()
        interval = FrameStore.captureInterval
        quality = FrameStore.captureQuality
        maxDim = FrameStore.captureMaxDim
    }
}
