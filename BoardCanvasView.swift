import SwiftUI

/// 示意棋盘画布：129 节点占用/归属/身份可视化，点击节点查看与修正。
struct BoardCanvasView: View {
    @EnvironmentObject var session: GameSession
    @State private var selected: Int? = nil

    var body: some View {
        GeometryReader { geo in
            let side = min(geo.size.width, geo.size.height)
            let rect = CGRect(x: (geo.size.width - side) / 2 + 8,
                              y: (geo.size.height - side) / 2 + 8,
                              width: side - 16, height: side - 16)
            Canvas { ctx, _ in
                drawZones(in: rect, context: &ctx)
                drawNodes(in: rect, context: &ctx)
            }
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0).onEnded { v in
                    selected = nearestNode(to: v.location, in: rect)
                }
            )
        }
        .sheet(item: $selected) { id in
            NodeDetailSheet(nodeID: id)
                .presentationDetents([.medium, .large])
        }
    }

    private func point(of n: BoardNode, in rect: CGRect) -> CGPoint {
        CGPoint(x: rect.minX + CGFloat(n.col) / 16 * rect.width,
                y: rect.minY + CGFloat(n.row) / 16 * rect.height)
    }

    private func nearestNode(to p: CGPoint, in rect: CGRect) -> Int? {
        var best: (Int, CGFloat)? = nil
        for n in BoardLayout.nodes {
            let d = hypot(point(of: n, in: rect).x - p.x, point(of: n, in: rect).y - p.y)
            if best == nil || d < best!.1 { best = (n.id, d) }
        }
        guard let b = best, b.1 < 26 else { return nil }
        return b.0
    }

    private func drawZones(in rect: CGRect, context: inout GraphicsContext) {
        for seat in [Seat.teammate, .leftEnemy, .rightEnemy, .me] {
            let nodes = BoardLayout.nodes.filter { $0.seat == seat }
            let xs = nodes.map { point(of: $0, in: rect).x }
            let ys = nodes.map { point(of: $0, in: rect).y }
            let zone = CGRect(x: xs.min()! - 14, y: ys.min()! - 14,
                              width: xs.max()! - xs.min()! + 28, height: ys.max()! - ys.min()! + 28)
            context.fill(Path(roundedRect: zone, cornerRadius: 10),
                         with: .color(Color(hex: seat.colorHex)?.opacity(0.08) ?? .gray.opacity(0.08)))
        }
    }

    private func drawNodes(in rect: CGRect, context: inout GraphicsContext) {
        for n in BoardLayout.nodes {
            let p = point(of: n, in: rect)
            let snap = session.nodeStates[n.id]
            let identity = session.engineSnapshot.identity[n.id]

            // 底座
            switch n.kind {
            case .camp:
                context.stroke(Circle().path(in: CGRect(x: p.x - 9, y: p.y - 9, width: 18, height: 18)),
                               with: .color(.white.opacity(0.25)), lineWidth: 1)
            case .hq:
                context.stroke(Rectangle().path(in: CGRect(x: p.x - 9, y: p.y - 9, width: 18, height: 18)),
                               with: .color(.white.opacity(0.3)), lineWidth: 1)
            default:
                context.fill(Circle().path(in: CGRect(x: p.x - 2.5, y: p.y - 2.5, width: 5, height: 5)),
                             with: .color(.white.opacity(0.18)))
            }

            if let s = snap, s.occupied {
                let color = Color(hex: s.owner?.colorHex ?? n.seat.colorHex) ?? .gray
                let r: CGFloat = 10.5
                context.fill(Circle().path(in: CGRect(x: p.x - r, y: p.y - r, width: r * 2, height: r * 2)),
                             with: .color(color.opacity(0.9)))
                if let id = identity {
                    context.draw(Text(id.short).font(.system(size: 9, weight: .black)).foregroundColor(.white),
                                 at: p)
                }
            }
            if selected == n.id {
                context.stroke(Circle().path(in: CGRect(x: p.x - 14, y: p.y - 14, width: 28, height: 28)),
                               with: .color(.white), lineWidth: 1.5)
            }
        }
    }
}

extension Int: Identifiable {
    public var id: Int { self }
}

/// 节点详情与人工修正
struct NodeDetailSheet: View {
    @EnvironmentObject var session: GameSession
    @Environment(\.dismiss) private var dismiss
    let nodeID: Int

    private var node: BoardNode? { BoardLayout.nodeByID[nodeID] }
    private var snap: NodeSnapshot? { session.nodeStates[nodeID] }
    private var identity: Rank? { session.engineSnapshot.identity[nodeID] }
    private var enemyPiece: InferenceEngine.Piece? {
        session.engineSnapshot.piece(atNode: nodeID)
    }

    var body: some View {
        NavigationStack {
            List {
                if let node {
                    Section("位置") {
                        LabeledRow("编号", BoardLayout.nodeLabel(nodeID))
                        LabeledRow("阵地", node.seat.label)
                        LabeledRow("类型", node.kind.label)
                        LabeledRow("状态", (snap?.occupied ?? false) ? "有子" : "空")
                    }
                }
                if node?.seat.isAlly == true {
                    Section("棋子身份（我方/队友明子）") {
                        Picker("身份", selection: Binding(
                            get: { identity },
                            set: { session.setNodeRank(nodeID, $0) }
                        )) {
                            Text("未知").tag(Rank?.none)
                            ForEach(Rank.allCases, id: \.self) { r in
                                Text(r.rawValue).tag(Rank?.some(r))
                            }
                        }
                        if identity == nil {
                            Text("无法识别时可手动选择；OCR 会持续尝试自动识别。")
                                .font(.caption).foregroundColor(.secondary)
                        }
                    }
                }
                if let p = enemyPiece {
                    Section("敌方推演") {
                        if let d = p.definite {
                            LabeledRow("判定", d.rawValue + "（确定）")
                        } else {
                            VStack(alignment: .leading, spacing: 6) {
                                Text("候选身份")
                                    .font(.caption).foregroundColor(.secondary)
                                ForEach(candidateRows(p), id: \.0) { row in
                                    HStack {
                                        Text(row.0)
                                        Spacer()
                                        Text("\(Int(row.1 * 100))%").monospacedDigit()
                                    }
                                    .font(.callout)
                                }
                            }
                        }
                        LabeledRow("是否移动过", p.moved ? "是（排除地雷/军旗）" : "否")
                        Button("标记该子阵亡", role: .destructive) {
                            session.markDeath(owner: p.seat, node: nodeID)
                            dismiss()
                        }
                    }
                }
                Section {
                    Button("标记 \(BoardLayout.nodeLabel(nodeID)) 的棋子阵亡", role: .destructive) {
                        session.markDeath(owner: snap?.owner ?? node?.seat ?? .me, node: nodeID)
                        dismiss()
                    }
                    Button("清除身份标记") {
                        session.setNodeRank(nodeID, nil)
                        dismiss()
                    }
                }
            }
            .navigationTitle("节点详情")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { dismiss() }
                }
            }
        }
    }

    private func candidateRows(_ p: InferenceEngine.Piece) -> [(String, Double)] {
        guard let s = session.engineSnapshot.summary(for: p.seat) else { return [] }
        let allowed = p.candidates
        let rows = allowed.map { r -> (String, Double) in
            let w = Double(max(1, r.initialCount - (s.deadKnown[r] ?? 0)))
            return (r.rawValue, w)
        }
        let total = rows.reduce(0.0) { $0 + $1.1 }
        guard total > 0 else { return [] }
        return rows.sorted { $0.1 > $1.1 }.map { ($0.0, $0.1 / total) }
    }
}

struct LabeledRow: View {
    let label: String
    let value: String
    init(_ label: String, _ value: String) {
        self.label = label
        self.value = value
    }
    var body: some View {
        HStack {
            Text(label).foregroundColor(.secondary)
            Spacer()
            Text(value).bold()
        }
    }
}
