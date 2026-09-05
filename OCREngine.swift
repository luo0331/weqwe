import Foundation
import Vision
import CoreGraphics

/// 中文 OCR：节点棋子识别（我方/队友明子）+ 棋谱整页识别。
final class OCREngine {
    static let shared = OCREngine()
    private let queue = DispatchQueue(label: "sqjq.ocr", qos: .utility)

    /// 识别单节点小图上的棋子名（异步）
    func recognizeRank(in cg: CGImage, completion: @escaping (Rank?) -> Void) {
        queue.async {
            completion(self.recognizeRankSync(in: cg))
        }
    }

    func recognizeRankSync(in cg: CGImage) -> Rank? {
        let texts = recognizeTextSync(in: cg, maxCandidates: 5)
        for t in texts {
            if let r = Rank.match(text: t) { return r }
        }
        return nil
    }

    /// 整页文本识别（棋谱导入用）
    func recognizePageSync(in cg: CGImage) -> [String] {
        recognizeTextSync(in: cg, maxCandidates: 1)
    }

    private func recognizeTextSync(in cg: CGImage, maxCandidates: Int) -> [String] {
        var out: [String] = []
        let request = VNRecognizeTextRequest { req, _ in
            guard let obs = req.results as? [VNRecognizedTextObservation] else { return }
            for o in obs {
                guard let top = o.topCandidates(maxCandidates).first else { continue }
                out.append(top.string)
            }
        }
        request.recognitionLevel = .accurate
        request.recognitionLanguages = ["zh-Hans", "zh-Hant"]
        request.usesLanguageCorrection = false
        let handler = VNImageRequestHandler(cgImage: cg, options: [:])
        do { try handler.perform([request]) } catch { return [] }
        return out
    }
}
