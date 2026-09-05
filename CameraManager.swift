import Foundation
import AVFoundation
import CoreImage

/// 相机取景（辅助模式：拍摄另一块屏幕/实体棋盘）。
final class CameraManager: NSObject, ObservableObject, AVCaptureVideoDataOutputSampleBufferDelegate {
    let session = AVCaptureSession()
    private let output = AVCaptureVideoDataOutput()
    private let ciContext = CIContext()
    private var lastEmit = Date.distantPast
    var onFrame: ((CGImage) -> Void)?

    func start() {
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            if !self.session.inputs.isEmpty {
                self.session.startRunning()
                return
            }
            self.session.sessionPreset = .hd1920x1080
            guard let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back),
                  let input = try? AVCaptureDeviceInput(device: device),
                  self.session.canAddInput(input) else { return }
            self.session.addInput(input)
            self.output.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
            self.output.alwaysDiscardsLateVideoFrames = true
            self.output.setSampleBufferDelegate(self, queue: DispatchQueue(label: "sqjq.camera.out", qos: .userInitiated))
            if self.session.canAddOutput(self.output) { self.session.addOutput(self.output) }
            self.session.startRunning()
        }
    }

    func stop() {
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            self?.session.stopRunning()
        }
    }

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        let now = Date()
        guard now.timeIntervalSince(lastEmit) > 0.6 else { return }
        lastEmit = now
        guard let pb = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        let ci = CIImage(cvPixelBuffer: pb).oriented(.right)
        guard let cg = ciContext.createCGImage(ci, from: ci.extent) else { return }
        Task { @MainActor in self.onFrame?(cg) }
    }
}
