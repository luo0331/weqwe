import SwiftUI

/// 实时仪表盘：状态、敌我剩余、示意棋盘、推演结果、事件流。
struct DashboardView: View {
    @EnvironmentObject var session: GameSession

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 14) {
                    statusCard
                    enemyCard(.leftEnemy)
                    enemyCard(.rightEnemy)
                    boardCard
                    notesCard
                    eventCard
                }
                .padding(.horizontal, 14)
                .padding(.bottom, 120)
            }
            .background(Color.black)
            .navigationTitle("四国记牌器")
            .navigationBarTitleDisplayMode(.inline)
        }
    }

    // MARK: 状态与控制
    private var statusCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Circle()
                    .fill(statusColor)
                    .frame(width: 10, height: 10)
                Text(statusText).font(.subheadline.bold())
                Spacer()
                if let t = session.lastFrameAt {
                    Text("帧 \(DateFormatter.shortTime.string(from: t))")
                        .font(.caption2).foregroundColor(.secondary)
                }
            }
            HStack(spacing: 10) {
                if session.roundActive {
                    Button(role: .destructive) { session.endRound() } label: {
                        Label("结束本局", systemImage: "stop.circle")
                    }
                    .buttonStyle(.bordered)
                } else {
                    Button { session.beginRound() } label: {
                        Label(session.awaitingBaseline ? "等待基准帧…" : "开始本局", systemImage: "play.circle")
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(session.awaitingBaseline)
                }
                Button { session.undoLastEvent() } label: {
                    Label("撤销", systemImage: "arrow.uturn.backward")
                }
                .buttonStyle(.bordered)
                .disabled(session.events.isEmpty)
                Spacer()
                NavigationLink {
                    CalibrationView()
                } label: {
                    Label("校准", systemImage: "viewfinder")
                }
                .buttonStyle(.bordered)
            }
            .font(.footnote)
            if !session.isCapturing {
                Text("尚未采集：请到「设置」启动录屏采集（推荐）或相机取景。")
                    .font(.caption).foregroundColor(.orange)
            }
            if session.roundActive {
                Text("已开始记录。切到微信四国军棋对局，本工具会在后台自动跟踪。")
                    .font(.caption2).foregroundColor(.secondary)
            }
        }
        .padding(14)
        .background(cardBG)
    }

    private var statusColor: Color {
        if session.roundActive { return .green }
        if session.awaitingBaseline { return .yellow }
        if session.isCapturing { return .blue }
        return .gray
    }

    private var statusText: String {
        if session.roundActive { return "监控中 · 本局记录中" }
        if session.awaitingBaseline { return "等待基准帧（布阵界面）" }
        if session.isCapturing { return "采集中 · 未开始记录" }
        return "未采集"
    }

    // MARK: 敌方剩余卡片
    private func enemyCard(_ seat: Seat) -> some View {
        let s = session.engineSnapshot.summary(for: seat)
        let pieces = session.engineSnapshot.pieces
            .filter { $0.alive && $0.seat == seat }
            .sorted { a, b in
                let ad = a.definite != nil ? 0 : 1
                let bd = b.definite != nil ? 0 : 1
                if ad != bd { return ad < bd }
                return a.originNode < b.originNode
            }
        return VStack(alignment: .leading, spacing: 10) {
            HStack {
                Circle().fill(Color(hex: seat.colorHex) ?? .gray).frame(width: 10, height: 10)
                Text(seat.label).font(.headline)
                Spacer()
                Text("剩 \(session.roundActive ? (s?.aliveTotal ?? 25) : 25)/25")
                    .font(.title3.bold().monospacedDigit())
                    .foregroundColor(Color(hex: seat.colorHex))
            }
            estimateBar(s)
            HStack(spacing: 6) {
                let known = s?.deadKnown ?? [:]
                if known.isEmpty && (s?.deadUnknown ?? 0) == 0 {
                    Text("无损失").font(.caption).foregroundColor(.secondary)
                }
                ForEach(known.sorted { ($0.key.strength ?? -1) > ($1.key.strength ?? -1) }, id: \.key) { pair in
                    Text("\(pair.key.rawValue)×\(pair.value)")
                        .font(.caption2)
                        .padding(.horizontal, 7).padding(.vertical, 3)
                        .background(Color.red.opacity(0.16), in: Capsule())
                }
                if let u = s?.deadUnknown, u > 0 {
                    Text("未知×\(u)")
                        .font(.caption2)
                        .padding(.horizontal, 7).padding(.vertical, 3)
                        .background(Color.gray.opacity(0.2), in: Capsule())
                }
            }
            if !pieces.isEmpty {
                VStack(spacing: 4) {
                    ForEach(pieces.prefix(4)) { p in
                        HStack(spacing: 8) {
                            Text(p.label).font(.caption2.monospaced()).foregroundColor(.secondary)
                            if let d = p.definite {
                                Text(d.rawValue).font(.caption.bold())
                            } else {
                                Text(candidatesText(p)).font(.caption).foregroundColor(.orange)
                            }
                            Spacer()
                        }
                    }
                    if pieces.count > 4 {
                        Text("… 共 \(pieces.count) 枚存活，详见棋盘点按")
                            .font(.caption2).foregroundColor(.secondary)
                    }
                }
            }
        }
        .padding(14)
        .background(cardBG)
    }

    private func estimateBar(_ s: InferenceEngine.EnemySummary?) -> some View {
        GeometryReader { geo in
            let total = s?.estimate.values.reduce(0, +) ?? 0
            HStack(spacing: 2) {
                if total > 0, let s {
                    ForEach(Rank.allCases.sorted(by: >), id: \.self) { r in
                        if let v = s.estimate[r], v > 0.01 {
                            RoundedRectangle(cornerRadius: 3)
                                .fill((Color(hex: s.seat.colorHex) ?? .gray)
                                    .opacity(0.35 + 0.6 * Double(r.strength ?? 1) / 9))
                                .frame(width: max(3, geo.size.width * v / total))
                        }
                    }
                }
            }
        }
        .frame(height: 14)
    }

    private func candidatesText(_ p: InferenceEngine.Piece) -> String {
        let cs = p.candidates.sorted(by: >)
        if cs.isEmpty { return "?" }
        let lo = cs.last!, hi = cs.first!
        if cs.count <= 3 { return cs.map(\.short).joined(separator: "/") }
        return "\(lo.rawValue)~\(hi.rawValue)"
    }

    // MARK: 棋盘 / 推演 / 事件
    private var boardCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("实时盘面").font(.headline)
            BoardCanvasView()
                .frame(height: 400)
                .background(Color(hex: "#101218"))
                .clipShape(RoundedRectangle(cornerRadius: 12))
            Text("点任意节点可查看推演详情或手动修正")
                .font(.caption2).foregroundColor(.secondary)
        }
        .padding(14)
        .background(cardBG)
    }

    private var notesCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("敌方推演结果").font(.headline)
            if session.engineSnapshot.inconsistent {
                Label("检测到数据矛盾（可能是误识别），请检查最近事件或手动修正。", systemImage: "exclamationmark.triangle")
                    .font(.caption).foregroundColor(.orange)
            }
            if session.engineSnapshot.notes.isEmpty {
                Text("暂无推演。敌方吃子后这里会自动给出该子的身份候选与概率。")
                    .font(.caption).foregroundColor(.secondary)
            }
            ForEach(Array(session.engineSnapshot.notes.enumerated()), id: \.offset) { _, n in
                Text(n).font(.footnote)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(cardBG)
    }

    private var eventCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("事件日志").font(.headline)
            if session.events.isEmpty {
                Text("暂无事件").font(.caption).foregroundColor(.secondary)
            }
            ForEach(session.events.suffix(30)) { e in
                Text(e.text).font(.caption.monospaced())
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(cardBG)
    }

    private var cardBG: some View {
        RoundedRectangle(cornerRadius: 14)
            .fill(Color(hex: "#15171E") ?? Color.gray)
            .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(Color.white.opacity(0.06)))
    }
}
