import SwiftUI
import PhotosUI

/// 布阵图导入：框住布局卡 6×5 区域 → 逐格 OCR → 点格子手动纠错 → 保存/套用到本局。
/// 套用后我方（或队友）25 枚棋子身份直接写入实时棋盘，推演从第一手就精确。
struct LayoutImportView: View {
    @EnvironmentObject var records: RecordStore
    @EnvironmentObject var session: GameSession
    @Environment(\.dismiss) private var dismiss

    @State private var pickerItem: PhotosPickerItem?
    @State private var cg: CGImage?
    @State private var tl: CGPoint = CGPoint(x: 0.14, y: 0.13)   // 6×5 区域左上（归一化）
    @State private var br: CGPoint = CGPoint(x: 0.86, y: 0.87)   // 右下
    @State private var cells: [Rank?] = Array(repeating: nil, count: 30)
    @State private var ocrRunning = false
    @State private var seat: Seat = .me
    @State private var title = ""
    @State private var editingCell: Int?

    /// 行营格下标（lr,lc → (lr-1)*5+(lc-1)：(2,2)(2,4)(3,3)(4,2)(4,4)）
    private static let campSet: Set<Int> = [6, 8, 12, 16, 18]

    private var filledCount: Int { cells.compactMap { $0 }.count }

    /// 构成校验：与标准 25 枚配置比对
    private var compositionWarnings: [String] {
        var counts: [Rank: Int] = [:]
        for r in cells.compactMap({ $0 }) { counts[r, default: 0] += 1 }
        var out: [String] = []
        for r in Rank.allCases {
            let got = counts[r] ?? 0
            if got != r.initialCount { out.append("\(r.rawValue)×\(got)(应\(r.initialCount))") }
        }
        return out
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 14) {
                    if let cg {
                        imageEditor(imageSize: CGSize(width: cg.width, height: cg.height))
                    } else {
                        placeholder
                    }
                    controls
                    gridEditor
                }
                .padding(14)
                .padding(.bottom, 30)
            }
            .navigationTitle("布阵图导入")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("关闭") { dismiss() }
                }
            }
            .onAppear(perform: loadLatest)
            .onChange(of: pickerItem) { item in
                guard let item else { return }
                Task {
                    if let data = try? await item.loadTransferable(type: Data.self),
                       let img = UIImage(data: data)?.cgImage {
                        cg = img
                        cells = Array(repeating: nil, count: 30)
                    }
                }
            }
            .sheet(item: $editingCell) { idx in
                cellPicker(idx)
                    .presentationDetents([.medium])
            }
        }
    }

    // MARK: 图片编辑器
    private func imageEditor(imageSize: CGSize) -> some View {
        GeometryReader { geo in
            let fit = CalibrationView.fitRect(imageSize: imageSize, in: geo.size)
            ZStack {
                Image(uiImage: UIImage(cgImage: cg!))
                    .resizable()
                    .scaledToFit()
                    .frame(width: fit.width, height: fit.height)
                    .position(x: fit.midX, y: fit.midY)
                Canvas { ctx, _ in
                    drawGrid(fit: fit, imageSize: imageSize, context: &ctx)
                }
                handleView(fit: fit, imageSize: imageSize, isTopLeft: true)
                handleView(fit: fit, imageSize: imageSize, isTopLeft: false)
            }
        }
        .frame(height: 420)
    }

    private var placeholder: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 14).fill(Color(hex: "#101218"))
            VStack(spacing: 8) {
                Image(systemName: "photo.badge.arrow.down").font(.largeTitle).foregroundColor(.secondary)
                Text("选一张布局卡截图（我方或队友）")
                Text("把两个黄点框住 6×5 棋子区，再点识别")
            }
            .font(.footnote)
            .foregroundColor(.secondary)
        }
        .frame(height: 300)
    }

    private func handleView(fit: CGRect, imageSize: CGSize, isTopLeft: Bool) -> some View {
        let p = isTopLeft ? tl : br
        return Circle()
            .fill(Color.yellow)
            .frame(width: 22, height: 22)
            .overlay(Circle().strokeBorder(.black.opacity(0.4), lineWidth: 1))
            .position(x: fit.minX + p.x * fit.width, y: fit.minY + p.y * fit.height)
            .gesture(
                DragGesture(minimumDistance: 1).onChanged { v in
                    var q = v.location
                    q.x = min(0.985, max(0.015, (q.x - fit.minX) / fit.width))
                    q.y = min(0.985, max(0.015, (q.y - fit.minY) / fit.height))
                    if isTopLeft { tl = q } else { br = q }
                }
            )
    }

    private func drawGrid(fit: CGRect, imageSize: CGSize, context: inout GraphicsContext) {
        for i in 0..<30 {
            let rect = Self.cellRect(i, tl: tl, br: br, imageSize: imageSize)
            let drect = CGRect(
                x: fit.minX + rect.minX / imageSize.width * fit.width,
                y: fit.minY + rect.minY / imageSize.height * fit.height,
                width: rect.width / imageSize.width * fit.width,
                height: rect.height / imageSize.height * fit.height)
            context.stroke(Path(roundedRect: drect, cornerRadius: 3),
                           with: .color(.white.opacity(0.5)), lineWidth: 0.7)
            if Self.campSet.contains(i) {
                context.draw(Text("○").font(.system(size: 11)).foregroundColor(.white.opacity(0.6)),
                             at: CGPoint(x: drect.midX, y: drect.midY))
            } else if let r = cells[i] {
                context.draw(Text(r.short).font(.system(size: 13, weight: .bold)).foregroundColor(.yellow),
                             at: CGPoint(x: drect.midX, y: drect.midY))
            }
        }
    }

    // MARK: 控制
    private var controls: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                PhotosPicker(selection: $pickerItem, matching: .images) {
                    Label("选布局图", systemImage: "photo.on.rectangle")
                }
                .buttonStyle(.bordered)
                Button {
                    runOCR()
                } label: {
                    Label(ocrRunning ? "识别中…" : "识别 25 格", systemImage: "text.viewfinder")
                }
                .buttonStyle(.borderedProminent)
                .disabled(cg == nil || ocrRunning)
            }
            .font(.footnote)
            Text("两个黄点对准布局卡 6×5 棋子区的左上、右下角；识别错的直接点下方格子改。布局卡方向与对局一致：上=前排，左=左手侧。")
                .font(.caption2).foregroundColor(.secondary)

            Picker("归属", selection: $seat) {
                Text("我方布阵").tag(Seat.me)
                Text("队友布阵").tag(Seat.teammate)
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            TextField("标题（可选，默认按日期）", text: $title)
                .textFieldStyle(.roundedBorder)

            if !compositionWarnings.isEmpty {
                Text("构成与标准配置不符：\(compositionWarnings.joined(separator: "、")) —— 请检查对应格子")
                    .font(.caption2).foregroundColor(.orange)
            }

            HStack(spacing: 10) {
                Button {
                    save(apply: false)
                } label: {
                    Label("保存到棋谱库", systemImage: "tray.and.arrow.down")
                }
                .buttonStyle(.bordered)
                Button {
                    save(apply: true)
                } label: {
                    Label("保存并套用到本局", systemImage: "square.and.arrow.down.on.square")
                }
                .buttonStyle(.borderedProminent)
                .disabled(filledCount == 0)
            }
            .font(.footnote)
        }
    }

    // MARK: 网格纠错
    private var gridEditor: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("识别结果（点格子纠错；○=行营）").font(.headline)
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: 5), spacing: 6) {
                ForEach(0..<30, id: \.self) { i in
                    Button { editingCell = i } label: { cellView(i) }
                }
            }
            Text("已填 \(filledCount)/25")
                .font(.caption2).foregroundColor(.secondary)
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 12).fill(Color(hex: "#101218")))
    }

    @ViewBuilder
    private func cellView(_ i: Int) -> some View {
        let isCamp = Self.campSet.contains(i)
        ZStack {
            RoundedRectangle(cornerRadius: 8)
                .fill(isCamp ? Color.gray.opacity(0.15)
                      : (cells[i] == nil ? Color.orange.opacity(0.12) : Color.blue.opacity(0.14)))
                .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.white.opacity(0.15)))
            if isCamp {
                Text("○").font(.system(size: 16)).foregroundColor(.secondary)
            } else if let r = cells[i] {
                Text(r.short).font(.system(size: 18, weight: .bold)).foregroundColor(.white)
            } else {
                Text("?").font(.system(size: 16, weight: .bold)).foregroundColor(.orange)
            }
        }
        .frame(height: 44)
    }

    private func cellPicker(_ idx: Int) -> some View {
        NavigationStack {
            List {
                Button("清空此格", role: .destructive) {
                    cells[idx] = nil
                    editingCell = nil
                }
                ForEach(Rank.allCases, id: \.self) { r in
                    Button {
                        cells[idx] = r
                        editingCell = nil
                    } label: {
                        HStack {
                            Text(r.short).bold()
                            Text(r.rawValue).foregroundColor(.secondary)
                            Spacer()
                            if cells[idx] == r {
                                Image(systemName: "checkmark").foregroundColor(.blue)
                            }
                        }
                    }
                }
            }
            .navigationTitle("第\(idx / 5 + 1)排 第\(idx % 5 + 1)列")
            .navigationBarTitleDisplayMode(.inline)
        }
    }

    // MARK: 逻辑
    private func loadLatest() {
        session.currentFrame { img in
            if let img { cg = img }
        }
    }

    private func runOCR() {
        guard let cg, !ocrRunning else { return }
        ocrRunning = true
        let img = cg
        let t = tl, b = br
        Task.detached(priority: .userInitiated) {
            var result = Array(repeating: Rank?.none, count: 30)
            for i in 0..<30 where !LayoutImportView.campSet.contains(i) {
                let rect = LayoutImportView.cellRect(i, tl: t, br: b,
                                                     imageSize: CGSize(width: img.width, height: img.height))
                if let up = ImageStat.upscaled(img, rect: rect, scale: 3, minSide: 96),
                   let r = OCREngine.shared.recognizeLayoutCellSync(in: up) {
                    result[i] = r
                }
            }
            await MainActor.run {
                cells = result
                ocrRunning = false
            }
        }
    }

    private func save(apply: Bool) {
        var rec = GameRecord(
            title: title.isEmpty ? "\(seat.label)布阵 \(Date().formatted(.dateTime.month().day()))" : title,
            kind: .layout,
            rawText: "")
        rec.grid = cells.map { $0?.rawValue ?? "" }
        rec.gridSeat = seat.rawValue
        records.add(rec)
        if apply { session.applyLayout(rec) }
        dismiss()
    }

    /// 网格下标 → 图像像素区域
    static func cellRect(_ i: Int, tl: CGPoint, br: CGPoint, imageSize: CGSize) -> CGRect {
        let lr = i / 5, lc = i % 5
        let w = (br.x - tl.x) / 5, h = (br.y - tl.y) / 6
        let cx = tl.x + (CGFloat(lc) + 0.5) * w
        let cy = tl.y + (CGFloat(lr) + 0.5) * h
        let half = min(w, h) * 0.36
        return CGRect(x: (cx - half) * imageSize.width, y: (cy - half) * imageSize.height,
                      width: half * 2 * imageSize.width, height: half * 2 * imageSize.height)
    }
}
