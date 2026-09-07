import SwiftUI
import PhotosUI

/// 棋盘校准：对齐棋盘外框四角 → 129 节点全部自动映射；可调占用阈值并即时诊断。
struct CalibrationView: View {
    @EnvironmentObject var session: GameSession
    @State private var cg: CGImage?
    @State private var corners: Corners = .default
    @State private var showGrid = true
    @State private var pickerItem: PhotosPickerItem?
    @State private var diagSummary: String?

    var body: some View {
        VStack(spacing: 12) {
            if let cg {
                editor(imageSize: CGSize(width: cg.width, height: cg.height))
            } else {
                ZStack {
                    RoundedRectangle(cornerRadius: 14).fill(Color(hex: "#101218") ?? Color.gray)
                    Text("先抓取最新画面，或从相册选一张游戏截图")
                        .foregroundColor(.secondary)
                }
                .frame(height: 320)
            }
            controls
        }
        .padding(14)
        .navigationTitle("棋盘校准")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            corners = session.corners
            loadLatest()
        }
        .onChange(of: pickerItem) { item in
            guard let item else { return }
            Task {
                if let data = try? await item.loadTransferable(type: Data.self),
                   let img = UIImage(data: data)?.cgImage {
                    cg = img
                    diagSummary = nil
                }
            }
        }
    }

    // MARK: 编辑器
    private func editor(imageSize: CGSize) -> some View {
        GeometryReader { geo in
            let fit = Self.fitRect(imageSize: imageSize, in: geo.size)
            ZStack {
                Image(uiImage: UIImage(cgImage: cg!))
                    .resizable()
                    .scaledToFit()
                    .frame(width: fit.width, height: fit.height)
                    .position(x: fit.midX, y: fit.midY)
                if showGrid {
                    Canvas { ctx, _ in
                        for n in BoardLayout.nodes {
                            let p = displayPoint(row: n.row, col: n.col, fit: fit)
                            let color = Color(hex: n.seat.colorHex) ?? .gray
                            ctx.fill(Circle().path(in: CGRect(x: p.x - 3, y: p.y - 3, width: 6, height: 6)),
                                     with: .color(color.opacity(0.85)))
                            ctx.stroke(Circle().path(in: CGRect(x: p.x - 6, y: p.y - 6, width: 12, height: 12)),
                                       with: .color(.white.opacity(0.15)), lineWidth: 0.5)
                        }
                        // 外框
                        var path = Path()
                        path.move(to: displayPoint(row: 0, col: 0, fit: fit))
                        path.addLine(to: displayPoint(row: 0, col: 16, fit: fit))
                        path.addLine(to: displayPoint(row: 16, col: 16, fit: fit))
                        path.addLine(to: displayPoint(row: 16, col: 0, fit: fit))
                        path.closeSubpath()
                        ctx.stroke(path, with: .color(.yellow.opacity(0.6)), lineWidth: 1)
                    }
                }
                handles(fit: fit)
            }
        }
        .frame(height: 380)
    }

    private func handles(fit: CGRect) -> some View {
        ForEach(0..<4, id: \.self) { i in
            Circle()
                .fill(Color.yellow)
                .frame(width: 20, height: 20)
                .overlay(Circle().strokeBorder(.black.opacity(0.4), lineWidth: 1))
                .position(handlePoint(i, fit: fit))
                .gesture(
                    DragGesture(minimumDistance: 1)
                        .onChanged { v in
                            var p = v.location
                            p.x = (p.x - fit.minX) / fit.width
                            p.y = (p.y - fit.minY) / fit.height
                            p.x = min(0.98, max(0.02, p.x))
                            p.y = min(0.98, max(0.02, p.y))
                            setCorner(i, p)
                        }
                )
        }
    }

    private func handlePoint(_ i: Int, fit: CGRect) -> CGPoint {
        let c: CGPoint
        switch i {
        case 0: c = corners.tl
        case 1: c = corners.tr
        case 2: c = corners.bl
        default: c = corners.br
        }
        return CGPoint(x: fit.minX + c.x * fit.width, y: fit.minY + c.y * fit.height)
    }

    private func setCorner(_ i: Int, _ p: CGPoint) {
        switch i {
        case 0: corners.tl = p
        case 1: corners.tr = p
        case 2: corners.bl = p
        default: corners.br = p
        }
    }

    private func displayPoint(row: Int, col: Int, fit: CGRect) -> CGPoint {
        let u = CGFloat(col) / 16, v = CGFloat(row) / 16
        let top = CGPoint(x: corners.tl.x + (corners.tr.x - corners.tl.x) * u,
                          y: corners.tl.y + (corners.tr.y - corners.tl.y) * u)
        let bot = CGPoint(x: corners.bl.x + (corners.br.x - corners.bl.x) * u,
                          y: corners.bl.y + (corners.br.y - corners.bl.y) * u)
        let n = CGPoint(x: top.x + (bot.x - top.x) * v, y: top.y + (bot.y - top.y) * v)
        return CGPoint(x: fit.minX + n.x * fit.width, y: fit.minY + n.y * fit.height)
    }

    static func fitRect(imageSize: CGSize, in size: CGSize) -> CGRect {
        guard imageSize.width > 0, imageSize.height > 0 else { return CGRect(origin: .zero, size: size) }
        let scale = min(size.width / imageSize.width, size.height / imageSize.height)
        let w = imageSize.width * scale, h = imageSize.height * scale
        return CGRect(x: (size.width - w) / 2, y: (size.height - h) / 2, width: w, height: h)
    }

    // MARK: 控制
    private var controls: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 10) {
                    Button { loadLatest() } label: { Label("抓取最新画面", systemImage: "camera.on.rectangle") }
                        .buttonStyle(.bordered)
                    PhotosPicker(selection: $pickerItem, matching: .images) {
                        Label("相册截图", systemImage: "photo.on.rectangle")
                    }
                    .buttonStyle(.bordered)
                    Toggle("网格", isOn: $showGrid).toggleStyle(.button)
                }
                .font(.footnote)

                Text("提示：抓取的是「当前整个手机屏幕」。推荐：游戏中横屏时按 电源+音量上 截一张图 → 回这里点「相册截图」选它。若用「抓取最新画面」，请保持录屏开启且刚从游戏切回来。")
                    .font(.caption2).foregroundColor(.secondary)

                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text("占用灵敏度阈值").font(.footnote)
                        Spacer()
                        Text(String(format: "%.3f", session.threshold))
                            .font(.caption.monospacedDigit()).foregroundColor(.secondary)
                    }
                    Slider(value: $session.threshold, in: 0.04...0.16, step: 0.005)
                    Text("调大→更不容易把空点当棋子；调小→更容易认出浅色棋子。以“诊断”结果全对为准。")
                        .font(.caption2).foregroundColor(.secondary)
                }

                HStack(spacing: 10) {
                    Button {
                        guard let cg else { return }
                        session.diagnose(cg)
                        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { summarizeDiag() }
                    } label: { Label("运行诊断", systemImage: "stethoscope") }
                        .buttonStyle(.bordered)
                    Button {
                        session.corners = corners
                        session.toast = "校准已保存"
                    } label: { Label("保存校准", systemImage: "checkmark.circle") }
                        .buttonStyle(.borderedProminent)
                }
                .font(.footnote)

                if let s = diagSummary {
                    Text(s).font(.caption).foregroundColor(.secondary)
                }
                if !session.diagnosticReadings.isEmpty {
                    Text("提示：四家阵地内应各有 25 个“有子”节点、5 个行营为空；若某个阵地数量明显不对，请微调四角或阈值后重试。")
                        .font(.caption2).foregroundColor(.secondary)
                }
            }
        }
    }

    private func summarizeDiag() {
        let rs = session.diagnosticReadings
        guard !rs.isEmpty else {
            diagSummary = "诊断失败：未取到读数"
            return
        }
        var bySeat: [Seat: Int] = [:]
        for r in rs where r.occupied {
            let seat = BoardLayout.nodeByID[r.id]?.seat ?? .center
            bySeat[seat, default: 0] += 1
        }
        var s = "占用统计："
        for seat in [Seat.me, .teammate, .leftEnemy, .rightEnemy, .center] {
            s += "\(seat.label) \(bySeat[seat] ?? 0) "
        }
        diagSummary = s
    }

    private func loadLatest() {
        session.currentFrame { img in
            if let img {
                cg = img
                diagSummary = nil
            } else {
                session.toast = "暂无画面：请先启动录屏采集，或用相册截图校准"
            }
        }
    }
}
