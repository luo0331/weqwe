import Foundation
import CoreGraphics

/// 单帧 → 129 节点占用/归属识别 + 状态稳定化（连续 2 帧一致才提交变化）。
/// 所有可变状态只允许在 FrameAnalyzer 的串行队列上访问。
final class VisionPipeline {

    struct Reading: Identifiable, Hashable {
        let id: Int
        let occupied: Bool
        let metric: Double
        let owner: Seat?
        let hue: Double?
        let hueScore: Double
    }

    struct Analysis {
        var readings: [Reading]
        var diff: FrameDiff?
        static let skipped = Analysis(readings: [], diff: nil)
        var isSkipped: Bool { readings.isEmpty && diff == nil }
    }

    // MARK: - 可调参数
    var corners: Corners
    var threshold: Double
    var hueTolerance: Double = 0.24
    var hueRefs: [Seat: Double] = [:]

    // MARK: - 稳定化状态
    private var committed: [Int: NodeSnapshot] = [:]
    private var pending: [Int: (snap: NodeSnapshot, hits: Int)] = [:]
    private(set) var baselineTaken = false

    init(corners: Corners = .default, threshold: Double = 0.075) {
        self.corners = corners
        self.threshold = threshold
    }

    // MARK: 节点采样区域
    func nodePoint(_ id: Int, imageSize: CGSize) -> CGPoint {
        guard let n = BoardLayout.nodeByID[id] else { return .zero }
        return corners.pixelPoint(row: n.row, col: n.col, size: imageSize)
    }

    func spacing(_ imageSize: CGSize) -> CGFloat {
        let c = corners.pixelCorners(size: imageSize)
        let dx = hypot(c.tr.x - c.tl.x, c.tr.y - c.tl.y) / CGFloat(BoardLayout.grid - 1)
        let dy = hypot(c.bl.x - c.tl.x, c.bl.y - c.tl.y) / CGFloat(BoardLayout.grid - 1)
        return max(4, min(dx, dy))
    }

    func cropRect(_ id: Int, imageSize: CGSize, ratio: CGFloat = 0.34) -> CGRect {
        let p = nodePoint(id, imageSize: imageSize)
        let half = spacing(imageSize) * ratio
        return CGRect(x: p.x - half, y: p.y - half, width: half * 2, height: half * 2)
    }

    // MARK: 单节点读数
    private func readNode(_ node: BoardNode, image: CGImage, size: CGSize) -> (Reading, CGRect)? {
        let rect = cropRect(node.id, imageSize: size)
        guard let patch = ImageStat.sample(image, rect: rect) else { return nil }
        let metric = ImageStat.occupancyMetric(patch)
        // 滞回：已占用节点需要更低阈值才判空，避免闪烁
        let occupied: Bool
        if let cur = committed[node.id], cur.occupied {
            occupied = metric >= threshold * 0.72
        } else {
            occupied = metric >= threshold
        }
        var owner: Seat? = nil
        var score = 0.0
        if occupied {
            if let h = patch.hue, !hueRefs.isEmpty {
                var best: (Seat, Double)? = nil
                for (s, ref) in hueRefs {
                    let d = ImageStat.hueDist(h, ref)
                    if best == nil || d < best!.1 { best = (s, d) }
                }
                if let b = best, b.1 <= hueTolerance {
                    owner = b.0
                    score = 1 - b.1 / hueTolerance
                }
            }
            if owner == nil && node.seat != .center { owner = node.seat } // 色相不可靠时退回阵地归属
        }
        return (Reading(id: node.id, occupied: occupied, metric: metric, owner: owner, hue: patch.hue, hueScore: score), rect)
    }

    // MARK: 基准帧（本局开始：四家布阵完毕）
    func takeBaseline(_ image: CGImage) -> [Int: NodeSnapshot] {
        let size = CGSize(width: image.width, height: image.height)
        learnHues(image: image, size: size)
        var snap: [Int: NodeSnapshot] = [:]
        committed.removeAll()
        pending.removeAll()
        for n in BoardLayout.nodes {
            guard let (r, _) = readNode(n, image: image, size: size) else { continue }
            let s = NodeSnapshot(occupied: r.occupied, owner: r.owner)
            committed[n.id] = s
            snap[n.id] = s
        }
        baselineTaken = true
        return snap
    }

    /// 从当前帧学习四家配色（用各阵地内节点，中央节点不参与）
    @discardableResult
    func learnHues(image: CGImage, size: CGSize? = nil) -> Bool {
        let sz = size ?? CGSize(width: image.width, height: image.height)
        var hues: [Seat: [Double]] = [:]
        for n in BoardLayout.nodes where n.seat != .center {
            guard n.kind != .camp else { continue }
            guard let (r, _) = readNodeRaw(n, imageSize: sz), r.occupied, let h = r.hue else { continue }
            hues[n.seat, default: []].append(h)
        }
        guard Seat.allCases.filter({ $0 != .center }).allSatisfy({ (hues[$0]?.count ?? 0) >= 8 }) else { return false }
        for (s, hs) in hues {
            let sorted = hs.sorted()
            hueRefs[s] = sorted[sorted.count / 2]
        }
        return true
    }

    /// 不带稳定化/提交的裸读数（配色学习用）
    private func readNodeRaw(_ node: BoardNode, imageSize: CGSize) -> (Reading, CGRect)? {
        let rect = cropRect(node.id, imageSize: imageSize)
        guard let patch = ImageStat.sample(image, rect: rect) else { return nil }
        let metric = ImageStat.occupancyMetric(patch)
        let occupied = metric >= threshold
        return (Reading(id: node.id, occupied: occupied, metric: metric, owner: occupied ? node.seat : nil, hue: patch.hue, hueScore: 0), rect)
    }

    // MARK: 常规分析
    func analyze(_ image: CGImage, allowCommit: Bool) -> Analysis {
        let size = CGSize(width: image.width, height: image.height)
        var readings: [Reading] = []
        var changes: [NodeChange] = []
        for n in BoardLayout.nodes {
            guard let (r, _) = readNode(n, image: image, size: size) else { continue }
            readings.append(r)
            guard allowCommit, baselineTaken else { continue }
            let snap = NodeSnapshot(occupied: r.occupied, owner: r.owner)
            let cur = committed[n.id] ?? .empty
            if snap == cur {
                pending.removeValue(forKey: n.id)
                continue
            }
            var p = pending[n.id] ?? (snap, 0)
            if p.snap == snap { p.hits += 1 } else { p = (snap, 1) }
            pending[n.id] = p
            if p.hits >= 2 {
                committed[n.id] = snap
                pending.removeValue(forKey: n.id)
                changes.append(NodeChange(id: n.id, from: cur, to: snap))
            }
        }
        let diff = changes.isEmpty ? nil : FrameDiff(changes: changes, time: Date().timeIntervalSince1970)
        return Analysis(readings: readings, diff: diff)
    }

    func reset() {
        committed.removeAll()
        pending.removeAll()
        baselineTaken = false
        hueRefs.removeAll()
    }
}

/// 把 VisionPipeline 串行化，供主线程调用；回调跳回主线程。
final class FrameAnalyzer {
    private let queue = DispatchQueue(label: "sqjq.analysis", qos: .userInitiated)
    private let pipeline: VisionPipeline
    private var busy = false
    fileprivate var lastImage: CGImage?

    init(pipeline: VisionPipeline) { self.pipeline = pipeline }

    func updateCorners(_ c: Corners) { queue.async { self.pipeline.corners = c } }
    func updateThreshold(_ t: Double) { queue.async { self.pipeline.threshold = t } }
    func reset() { queue.async { self.pipeline.reset() } }

    func currentImage(_ completion: @escaping (CGImage?) -> Void) {
        queue.async {
            let img = self.lastImage
            Task { @MainActor in completion(img) }
        }
    }

    func takeBaseline(_ cg: CGImage, completion: @escaping ([Int: NodeSnapshot]) -> Void) {
        queue.async {
            let snap = self.pipeline.takeBaseline(cg)
            self.lastImage = cg
            Task { @MainActor in completion(snap) }
        }
    }

    func learnHues(from cg: CGImage, completion: @escaping (Bool) -> Void) {
        queue.async {
            let ok = self.pipeline.learnHues(image: cg)
            Task { @MainActor in completion(ok) }
        }
    }

    /// 诊断/校准用：只读不提交
    func diagnose(_ cg: CGImage, completion: @escaping ([VisionPipeline.Reading]) -> Void) {
        queue.async {
            let a = self.pipeline.analyze(cg, allowCommit: false)
            Task { @MainActor in completion(a.readings) }
        }
    }

    func ingest(_ cg: CGImage, allowCommit: Bool, completion: @escaping (VisionPipeline.Analysis) -> Void) {
        queue.async {
            if self.busy {
                Task { @MainActor in completion(.skipped) }
                return
            }
            self.busy = true
            let a = self.pipeline.analyze(cg, allowCommit: allowCommit)
            self.busy = false
            self.lastImage = cg
            Task { @MainActor in completion(a) }
        }
    }
}

extension CGImage {
    static func createEmpty() -> CGImage {
        let ctx = CGContext(data: nil, width: 4, height: 4, bitsPerComponent: 8, bytesPerRow: 16,
                            space: CGColorSpaceCreateDeviceRGB(),
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        return ctx.makeImage()!
    }
}
