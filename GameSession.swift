import Foundation
import SwiftUI
import CoreGraphics

/// 全局会话编排：采集帧 → 识别 → 事件配对 → 推演 → UI/悬浮窗。
@MainActor
final class GameSession: ObservableObject {
    enum Phase: Equatable { case idle, watching, camera }

    // MARK: 设置（持久化）
    @Published var corners: Corners {
        didSet { persistCorners(); analyzer.updateCorners(corners) }
    }
    @Published var threshold: Double {
        didSet { UserDefaults.standard.set(threshold, forKey: "cfg.threshold"); analyzer.updateThreshold(threshold) }
    }
    @Published var frameInterval: Double {
        didSet { applyCaptureSettings() }
    }
    @Published var jpegQuality: Double {
        didSet { applyCaptureSettings() }
    }
    @Published var maxDim: Double {
        didSet { applyCaptureSettings() }
    }
    @Published var ocrEnabled: Bool {
        didSet { UserDefaults.standard.set(ocrEnabled, forKey: "cfg.ocr") }
    }
    @Published var autoPiP: Bool {
        didSet { UserDefaults.standard.set(autoPiP, forKey: "cfg.autoPiP") }
    }
    /// 棋谱布阵预载（我方/队友身份）
    @Published var layoutPreload: [Int: Rank] = [:]

    // MARK: 运行状态
    @Published private(set) var phase: Phase = .idle
    @Published private(set) var roundActive = false
    @Published private(set) var awaitingBaseline = false
    @Published private(set) var nodeStates: [Int: NodeSnapshot] = [:]
    @Published private(set) var engineSnapshot = InferenceEngine.Snapshot.empty
    @Published private(set) var events: [GameEvent] = []
    @Published private(set) var lastFrameAt: Date?
    @Published private(set) var diagnosticReadings: [VisionPipeline.Reading] = []
    @Published var toast: String?

    let engine = InferenceEngine()
    let pip = PiPManager()
    let camera = CameraManager()
    private let pipeline = VisionPipeline()
    private lazy var analyzer = FrameAnalyzer(pipeline: pipeline)
    private var pollTimer: DispatchSourceTimer?
    private var idleTimer: DispatchSourceTimer?
    private var baseline: [Int: NodeSnapshot] = [:]
    private var lastOCRAt = Date.distantPast
    private var ocrCursor = 0

    var isCapturing: Bool { phase != .idle }

    // MARK: - 初始化
    init() {
        let d = UserDefaults.standard
        if let c = d.data(forKey: "cfg.corners"), let cc = try? JSONDecoder().decode(Corners.self, from: c) {
            corners = cc
        } else {
            corners = .default
        }
        threshold = d.object(forKey: "cfg.threshold") as? Double ?? 0.075
        frameInterval = d.object(forKey: "cfg.interval") as? Double ?? 0.34
        jpegQuality = d.object(forKey: "cfg.quality") as? Double ?? 0.6
        maxDim = d.object(forKey: "cfg.maxDim") as? Double ?? 1600
        ocrEnabled = d.object(forKey: "cfg.ocr") as? Bool ?? true
        autoPiP = d.object(forKey: "cfg.autoPiP") as? Bool ?? true
        analyzer.updateCorners(corners)
        analyzer.updateThreshold(threshold)
        applyCaptureSettings()
        pip.setup()
        FrameServer.start()
        startIdlePolling()
    }

    /// 待机轮询（1s）：App 启动即常驻，无论用户何时/从哪里开启录屏，帧到来都能接住。
    /// 这样"进游戏后才从控制中心开录屏"也成立，无需来回切 App。
    private func startIdlePolling() {
        guard idleTimer == nil else { return }
        let t = DispatchSource.makeTimerSource(queue: DispatchQueue.global(qos: .userInitiated))
        t.schedule(deadline: .now() + 1, repeating: 1.0)
        t.setEventHandler { [weak self] in
            guard let (img, _) = FrameStore.readLatestFrame() else { return }
            Task { @MainActor [weak self] in self?.ingest(img) }
        }
        t.resume()
        idleTimer = t
    }

    private func persistCorners() {
        if let data = try? JSONEncoder().encode(corners) {
            UserDefaults.standard.set(data, forKey: "cfg.corners")
        }
    }

    private func applyCaptureSettings() {
        let d = UserDefaults.standard
        d.set(frameInterval, forKey: "cfg.interval")
        d.set(jpegQuality, forKey: "cfg.quality")
        d.set(maxDim, forKey: "cfg.maxDim")
    }

    // MARK: - 采集
    func startWatching() {
        stopCameraInternal()
        idleTimer?.cancel()
        idleTimer = nil
        FrameStore.resetSeq()
        FrameServer.start()
        phase = .watching
        let t = DispatchSource.makeTimerSource(queue: DispatchQueue.global(qos: .userInitiated))
        t.schedule(deadline: .now() + 0.4, repeating: 0.25)
        t.setEventHandler { [weak self] in
            guard let (img, _) = FrameStore.readLatestFrame() else { return }
            Task { @MainActor [weak self] in self?.ingest(img) }
        }
        t.resume()
        pollTimer = t
        toast = "录屏采集中——请切到游戏界面"
    }

    func stopWatching() {
        pollTimer?.cancel()
        pollTimer = nil
        if phase == .watching { phase = .idle }
        startIdlePolling()
    }

    func startCamera() {
        stopWatching()
        phase = .camera
        camera.onFrame = { [weak self] cg in
            Task { @MainActor [weak self] in self?.ingest(cg) }
        }
        camera.start()
        toast = "相机取景中——对准另一块屏幕上的棋盘"
    }

    func stopCamera() {
        camera.stop()
        if phase == .camera { phase = .idle }
    }

    private func stopCameraInternal() { camera.stop() }
    private func stopWatchingInternal() { pollTimer?.cancel(); pollTimer = nil }

    // MARK: - 帧入口
    func ingest(_ cg: CGImage) {
        lastFrameAt = Date()
        if awaitingBaseline {
            awaitingBaseline = false
            analyzer.takeBaseline(cg) { [weak self] snap in
                guard let self else { return }
                self.baseline = snap
                self.nodeStates = snap
                self.roundActive = true
                let count = snap.values.filter(\.occupied).count
                self.events.append(GameEvent(kind: .note("本局基准已建立：盘面 \(count) 枚棋子，四家配色已学习")))
                self.rebuild()
            }
            return
        }
        analyzer.ingest(cg, allowCommit: roundActive) { [weak self] a in
            guard let self, !a.isSkipped else { return }
            if let diff = a.diff, !diff.isEmpty {
                for c in diff.changes { self.nodeStates[c.id] = c.to }
                let evts = self.pair(diff)
                self.events.append(contentsOf: evts)
                if self.events.count > 400 { self.events.removeFirst(self.events.count - 400) }
                self.rebuild()
                self.scheduleOCR()
            } else {
                self.renderPiP()
            }
        }
    }

    // MARK: - 事件配对
    private func latticeDist(_ a: Int, _ b: Int) -> Double {
        guard let x = BoardLayout.nodeByID[a], let y = BoardLayout.nodeByID[b] else { return 99 }
        return Double(abs(x.row - y.row) + abs(x.col - y.col))
    }

    private func pair(_ diff: FrameDiff) -> [GameEvent] {
        var evts: [GameEvent] = []
        let changes = diff.changes
        let empties = changes.filter { !$0.to.occupied }
        let gains = changes.filter { $0.to.occupied }
        var usedGain = Set<Int>()
        var usedEmpty = Set<Int>()

        // 1) 占位战斗：某节点被另一色占领（攻方吃掉守方）
        for (gi, g) in gains.enumerated() {
            guard let newOwner = g.to.owner, let oldOwner = g.from.owner, oldOwner != newOwner else { continue }
            var best: (idx: Int, d: Double)? = nil
            for (ei, e) in empties.enumerated() where !usedEmpty.contains(ei) && e.from.owner == newOwner {
                let d = latticeDist(e.id, g.id)
                if best == nil || d < best!.d { best = (ei, d) }
            }
            if let b = best { usedEmpty.insert(b.idx) }
            evts.append(GameEvent(time: diff.time, kind: .battle(
                attackerFrom: best.map { empties[$0.idx].id },
                defenderNode: g.id,
                attacker: newOwner, defender: oldOwner, outcome: .attackerWins)))
            usedGain.insert(gi)
        }
        // 2) 同归于尽：两个不同阵营节点同时清空
        var remaining = empties.indices.filter { !usedEmpty.contains($0) }
        var i = 0
        while i < remaining.count {
            var j = i + 1
            var found = false
            while j < remaining.count {
                let a = empties[remaining[i]], b = empties[remaining[j]]
                if let oa = a.from.owner, let ob = b.from.owner, oa != ob {
                    evts.append(GameEvent(time: diff.time, kind: .battle(
                        attackerFrom: a.id, defenderNode: b.id,
                        attacker: oa, defender: ob, outcome: .bothDie)))
                    usedEmpty.insert(remaining[i]); usedEmpty.insert(remaining[j])
                    remaining.remove(at: j); remaining.remove(at: i)
                    found = true
                    break
                }
                j += 1
            }
            if !found { i += 1 }
        }
        // 3) 移动：剩余空位与新增占位同色就近配对
        for (gi, g) in gains.enumerated() where !usedGain.contains(gi) {
            guard let o = g.to.owner, !g.from.occupied else { continue }
            var best: (idx: Int, d: Double)? = nil
            for ei in remaining where !usedEmpty.contains(ei) && empties[ei].from.owner == o {
                let d = latticeDist(empties[ei].id, g.id)
                if best == nil || d < best!.d { best = (ei, d) }
            }
            if let b = best, b.d <= 5 {
                usedEmpty.insert(b.idx)
                remaining.removeAll { $0 == b.idx }
                evts.append(GameEvent(time: diff.time, kind: .move(from: empties[b.idx].id, to: g.id, owner: o)))
                usedGain.insert(gi)
            }
        }
        // 4) 孤立清空 → 阵亡
        for ei in remaining where !usedEmpty.contains(ei) {
            let e = empties[ei]
            if let o = e.from.owner {
                evts.append(GameEvent(time: diff.time, kind: .loss(owner: o, node: e.id)))
            }
        }
        // 5) 无法解释的占位出现
        for (gi, g) in gains.enumerated() where !usedGain.contains(gi) {
            evts.append(GameEvent(time: diff.time, kind: .note(
                "\(BoardLayout.nodeLabel(g.id)) 出现棋子但找不到来源（漏检/误判，可长按棋盘点修正）")))
        }
        return evts
    }

    // MARK: - 推演
    private func rebuild() {
        engine.rebuild(baseline: baseline, events: events, layoutPreload: layoutPreload)
        engineSnapshot = engine.snapshot
        renderPiP()
    }

    func beginRound() {
        guard isCapturing else {
            toast = "请先在“设置”里启动录屏采集或相机，再开始本局"
            return
        }
        events.removeAll()
        baseline = [:]
        nodeStates = [:]
        engineSnapshot = .empty
        roundActive = false
        awaitingBaseline = true
        toast = "等待基准帧：请把游戏切到完整布阵界面"
    }

    func endRound() {
        roundActive = false
        awaitingBaseline = false
    }

    func resetAll() {
        endRound()
        events.removeAll()
        baseline = [:]
        nodeStates = [:]
        engineSnapshot = .empty
        layoutPreload = [:]
        analyzer.reset()
        toast = "已清空本局数据"
    }

    func undoLastEvent() {
        guard !events.isEmpty else { return }
        events.removeLast()
        rebuild()
    }

    // MARK: - 人工修正
    func setNodeRank(_ node: Int, _ rank: Rank?) {
        events.append(GameEvent(kind: .manualRank(node: node, rank: rank)))
        rebuild()
    }

    func markDeath(owner: Seat, node: Int) {
        events.append(GameEvent(kind: .loss(owner: owner, node: node)))
        rebuild()
    }

    // MARK: - OCR 我方/队友明子
    private func cropRect(for id: Int, imageSize: CGSize) -> CGRect {
        guard let n = BoardLayout.nodeByID[id] else { return .zero }
        let c = corners.pixelCorners(size: imageSize)
        let dx = hypot(c.tr.x - c.tl.x, c.tr.y - c.tl.y) / CGFloat(BoardLayout.grid - 1)
        let dy = hypot(c.bl.x - c.tl.x, c.bl.y - c.tl.y) / CGFloat(BoardLayout.grid - 1)
        let half = max(4, min(dx, dy)) * 0.34
        let p = corners.pixelPoint(row: n.row, col: n.col, size: imageSize)
        return CGRect(x: p.x - half, y: p.y - half, width: half * 2, height: half * 2)
    }

    private func scheduleOCR() {
        guard ocrEnabled, roundActive, Date().timeIntervalSince(lastOCRAt) >= 0.7 else { return }
        let candidates = BoardLayout.nodes.filter {
            $0.seat.isAlly
                && nodeStates[$0.id]?.occupied == true
                && engineSnapshot.identity[$0.id] == nil
        }
        guard !candidates.isEmpty else { return }
        let node = candidates[ocrCursor % candidates.count]
        ocrCursor += 1
        lastOCRAt = Date()
        analyzer.currentImage { [weak self] img in
            guard let self, let img else { return }
            let rect = self.cropRect(for: node.id, imageSize: CGSize(width: img.width, height: img.height))
            guard let up = ImageStat.upscaled(img, rect: rect, scale: 3, minSide: 120) else { return }
            OCREngine.shared.recognizeRank(in: up) { rank in
                Task { @MainActor [weak self] in
                    guard let self, let rank else { return }
                    guard self.roundActive,
                          self.nodeStates[node.id]?.occupied == true,
                          self.engineSnapshot.identity[node.id] != rank else { return }
                    self.events.append(GameEvent(kind: .manualRank(node: node.id, rank: rank)))
                    self.rebuild()
                }
            }
        }
    }

    // MARK: - 校准 / 诊断
    func currentFrame(_ completion: @escaping (CGImage?) -> Void) {
        analyzer.currentImage(completion)
    }

    func diagnose(_ img: CGImage) {
        analyzer.diagnose(img) { [weak self] readings in
            self?.diagnosticReadings = readings
        }
    }

    func relearnHues() {
        analyzer.currentImage { [weak self] img in
            guard let self else { return }
            guard let img else {
                self.toast = "没有可用画面，请先启动采集"
                return
            }
            self.analyzer.learnHues(from: img) { ok in
                self.toast = ok ? "四家配色已重新学习" : "学习失败：请保证四家棋子都在盘面上"
            }
        }
    }

    // MARK: - 棋谱布阵
    func applyLayout(_ record: GameRecord) {
        var pre: [Int: Rank] = [:]
        for e in record.layoutEntries() {
            if let id = BoardLayout.nodeID(seat: e.seat, localRow: e.lr, localCol: e.lc) {
                pre[id] = e.rank
            }
        }
        guard !pre.isEmpty else {
            toast = "未能从该棋谱解析出布阵条目"
            return
        }
        layoutPreload = pre
        rebuild()
        toast = "已套用布阵棋谱（\(pre.count) 枚我方/队友身份）"
    }

    // MARK: - 悬浮窗
    private func renderPiP() {
        var nodes: [PiPNode] = []
        for n in BoardLayout.nodes {
            guard let s = nodeStates[n.id], s.occupied else { continue }
            nodes.append(PiPNode(x: CGFloat(n.col) / 16, y: CGFloat(n.row) / 16,
                                 seat: s.owner ?? n.seat, rank: engineSnapshot.identity[n.id]))
        }
        pip.render(state: PiPState(summaries: engineSnapshot.summaries,
                                   notes: engineSnapshot.notes,
                                   nodes: nodes,
                                   updatedAt: lastFrameAt))
    }
}
