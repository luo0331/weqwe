import SwiftUI
import PhotosUI

/// 布阵图导入（对齐模拟器最终版）：
/// - 我方 / 队友 两个独立入口，各自记住自己的截图、对齐框和标注
/// - 拖黄点对齐 → 智能识别（字模库优先，Vision OCR 兜底）→ 点格子纠错
/// - 保存到棋谱库 / 确认布阵（同步到实时盘面）
/// - 手动标注会自动学习该字的字模（字模库越用越准）
struct LayoutImportView: View {
    @EnvironmentObject var records: RecordStore
    @EnvironmentObject var session: GameSession

    @State private var pickerItem: PhotosPickerItem?
    @State private var activeSeat: Seat = .me
    @State private var imgs: [Seat: CGImage] = [:]
    @State private var tls: [Seat: CGPoint] = [.me: CGPoint(x: 0.10, y: 0.08), .teammate: CGPoint(x: 0.10, y: 0.08)]
    @State private var brs: [Seat: CGPoint] = [.me: CGPoint(x: 0.90, y: 0.92), .teammate: CGPoint(x: 0.90, y: 0.92)]
    @State private var cellsBySeat: [Seat: [Rank?]] = [.me: Array(repeating: nil, count: 30),
                                                       .teammate: Array(repeating: nil, count: 30)]
    @State private var ocrRunning = false
    @State private var title = ""
    @State private var editingCell: Int?
    @State private var selCell: Int = -1
    @State private var status = ""

    private static let campSet: Set<Int> = [6, 8, 12, 16, 18]

    private var activeCells: [Rank?] {
        cellsBySeat[activeSeat] ?? Array(repeating: nil, count: 30)
    }
    private var filledCount: Int { activeCells.filter { $0 != nil }.count }
    private var currentImage: CGImage? { imgs[activeSeat] }
    private var currentTL: CGPoint { tls[activeSeat] ?? CGPoint(x: 0.10, y: 0.08) }
    private var currentBR: CGPoint { brs[activeSeat] ?? CGPoint(x: 0.90, y: 0.92) }

    private var compositionWarnings: [String] {
        var counts: [Rank: Int] = [:]
        for r in activeCells.compactMap({ $0 }) { counts[r, default: 0] += 1 }
        var out: [String] = []
        for r in Rank.allCases {
            let got = counts[r] ?? 0
            if got != r.initialCount { out.append("\(r.rawValue)×\(got)(应\(r.initialCount))") }
        }
        return out
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 14) {
                Text("布阵导入（我方 / 队友 是两个独立入口）")
                    .font(.headline)
                    .frame(maxWidth: .infinity, alignment: .leading)
                entryButtons
                controls
                if currentImage != nil {
                    imageEditor(imageSize: CGSize(width: currentImage!.width, height: currentImage!.height))
                } else {
                    placeholder
                }
                gridEditor
                mePreviewCard
            }
            .padding(14)
        }
        .onChange(of: pickerItem) { item in
            guard let item else { return }
            Task {
                if let data = try? await item.loadTransferable(type: Data.self),
                   let img = UIImage(data: data)?.cgImage {
                    imgs[activeSeat] = img
                    tls[activeSeat] = CGPoint(x: 0.10, y: 0.08)
                    brs[activeSeat] = CGPoint(x: 0.90, y: 0.92)
                    cellsBySeat[activeSeat] = Array(repeating: nil, count: 30)
                    selCell = -1
                    status = "已载入 \(activeSeat == .me ? "我方" : "队友")截图：拖两个黄点对齐 6×5 区域"
                }
            }
        }
        .sheet(item: $editingCell) { idx in
            cellPicker(idx)
                .presentationDetents([.medium])
        }
    }

    // MARK: 入口按钮（双入口独立会话）
    private var entryButtons: some View {
        HStack(spacing: 10) {
            entryButton(.me, label: "🟥 我方布阵")
            entryButton(.teammate, label: "🟦 队友布阵")
        }
    }

    private func entryButton(_ seat: Seat, label: String) -> some View {
        let cnt = (cellsBySeat[seat]?.filter { $0 != nil }.count) ?? 0
        let isOn = activeSeat == seat
        return Button {
            activeSeat = seat
            selCell = -1
            status = "当前编辑：\(seat == .me ? "我方" : "队友")布阵"
        } label: {
            VStack(spacing: 4) {
                Text(label).font(.system(size: 15, weight: .bold))
                Text("\(cnt)/25").font(.caption2).foregroundColor(.secondary)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 10)
        }
        .buttonStyle(.bordered)
        .tint(seat == .me ? .red : .blue)
        .opacity(isOn ? 1 : 0.45)
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(isOn ? Color.yellow : .clear, lineWidth: 2))
    }

    private var placeholder: some View {
        ZStack {
            let panelBG = Color(red: 0.063, green: 0.071, blue: 0.094)
            RoundedRectangle(cornerRadius: 14).fill(panelBG)
            VStack(spacing: 8) {
                Image(systemName: "photo.badge.arrow.down").font(.largeTitle).foregroundColor(.secondary)
                Text("「\(activeSeat == .me ? "我方" : "队友")布阵」：选一张布局卡截图")
                Text("拖两个黄点框住 6×5 棋子区")
            }
            .font(.footnote)
            .foregroundColor(.secondary)
        }
        .frame(height: 300)
    }

    private var controls: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                PhotosPicker(selection: $pickerItem, matching: .images) {
                    Label(currentImage == nil ? "选择布局截图" : "重新选图", systemImage: "photo.on.rectangle")
                }
                .buttonStyle(.borderedProminent)
                Button {
                    runOCR()
                } label: {
                    Label(ocrRunning ? "识别中…" : "🔍 智能识别", systemImage: "text.viewfinder")
                }
                .buttonStyle(.borderedProminent)
                .disabled(ocrRunning)
            }
            .font(.footnote)

            Text("点截图上的格子 → 弹出选盘标注（自动学习字模）；或点下方预览的格子修改")
                .font(.caption2).foregroundColor(.secondary)

            Text("字模库：\(GlyphStore.learnedCount)/12 种已学习 —— 学全 12 种后，识别基本全自动")
                .font(.caption2).foregroundColor(GlyphStore.learnedCount >= 12 ? .green : .orange)

            TextField("标题（可选，默认按日期）", text: $title)
                .textFieldStyle(.roundedBorder)

            if !compositionWarnings.isEmpty {
                Text("构成与标准配置不符：\(compositionWarnings.joined(separator: "、")) —— 请检查对应格子")
                    .font(.caption2).foregroundColor(.orange)
            }

            HStack(spacing: 8) {
                Button {
                    saveToLibrary()
                } label: {
                    Label("保存到棋谱库", systemImage: "tray.and.arrow.down")
                }
                .buttonStyle(.bordered)
                Button {
                    confirmLayout()
                } label: {
                    Label("✓ 确认布阵（同步实时）", systemImage: "square.and.arrow.down.on.square")
                }
                .buttonStyle(.borderedProminent)
            }
            .font(.footnote)

            if !status.isEmpty {
                Text(status).font(.caption).foregroundColor(.secondary)
            }
        }
    }

    // MARK: 截图编辑器（拖手柄对齐 + 点格子标注）
    private func imageEditor(imageSize: CGSize) -> some View {
        GeometryReader { geo in
            let fit = CalibrationView.fitRect(imageSize: imageSize, in: geo.size)
            ZStack {
                Image(uiImage: UIImage(cgImage: currentImage!))
                    .resizable()
                    .scaledToFit()
                    .frame(width: fit.width, height: fit.height)
                    .position(x: fit.midX, y: fit.midY)
                gridOverlayView(fit: fit, imageSize: imageSize)
                handleView(fit: fit, imageSize: imageSize, isTopLeft: true)
                handleView(fit: fit, imageSize: imageSize, isTopLeft: false)
                rankStrip
            }
        }
        .frame(height: 430)
    }

    private func gridOverlayView(fit: CGRect, imageSize: CGSize) -> some View {
        let cc = cellsBySeat[activeSeat] ?? Array(repeating: nil, count: 30)
        return Canvas { ctx, _ in
            for i in 0..<30 {
                let r = Self.cellRect(i, tl: currentTL, br: currentBR, imageSize: imageSize, inset: 0.5)
                let drect = CGRect(
                    x: fit.minX + r.minX / imageSize.width * fit.width,
                    y: fit.minY + r.minY / imageSize.height * fit.height,
                    width: r.width / imageSize.width * fit.width,
                    height: r.height / imageSize.height * fit.height)
                ctx.stroke(Path(roundedRect: drect, cornerRadius: 3),
                           with: .color(.white.opacity(0.5)), lineWidth: 0.8)
                if Self.campSet.contains(i) {
                    ctx.stroke(Path(ellipseIn: CGRect(x: drect.midX-10, y: drect.midY-10, width: 20, height: 20)),
                               with: .color(.green.opacity(0.6)), lineWidth: 2)
                } else if let r2 = cc[i] {
                    ctx.draw(Text(r2.short).font(.system(size: 15, weight: .bold)).foregroundColor(.yellow),
                             at: CGPoint(x: drect.midX, y: drect.midY))
                }
            }
        }
        .allowsHitTesting(false)
    }

    private var rankStrip: some View {
        Group {
            if selCell >= 0 {
                VStack(spacing: 6) {
                    Text("标注 · 第\((selCell/5)+1)排 第\((selCell%5)+1)列")
                        .font(.caption).foregroundColor(.secondary)
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 5), count: 4), spacing: 5) {
                        ForEach(Rank.allCases, id: \.self) { r in
                            Button {
                                setCell(selCell, r)
                                learnCellGlyph(idx: selCell, rank: r)
                                selCell = -1
                            } label: {
                                Text("\(r.short) \(r.rawValue)")
                                    .font(.caption).fontWeight(.semibold)
                                    .frame(maxWidth: .infinity)
                                    .padding(.vertical, 6)
                                    .background(Color.blue.opacity(0.12), in: RoundedRectangle(cornerRadius: 7))
                            }
                            .buttonStyle(.plain)
                        }
                        Button("清空") {
                            setCell(selCell, nil)
                            selCell = -1
                        }
                        .font(.caption)
                        .frame(maxWidth: .infinity)
                    }
                }
                .padding(10)
                .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 12))
            }
        }
    }

    private func setCell(_ idx: Int, _ rank: Rank?) {
        var arr = activeCells
        arr[idx] = rank
        cellsBySeat[activeSeat] = arr
    }

    private func handleView(fit: CGRect, imageSize: CGSize, isTopLeft: Bool) -> some View {
        let p = isTopLeft ? currentTL : currentBR
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
                    if isTopLeft { tls[activeSeat] = q } else { brs[activeSeat] = q }
                }
            )
    }

    private func drawGridOverlay(fit: CGRect, imageSize: CGSize, context: inout GraphicsContext) {
        let cc = cellsBySeat[activeSeat] ?? Array(repeating: nil, count: 30)
        for i in 0..<30 {
            let r = Self.cellRect(i, tl: currentTL, br: currentBR, imageSize: imageSize, inset: 0.5)
            let drect = CGRect(
                x: fit.minX + r.minX / imageSize.width * fit.width,
                y: fit.minY + r.minY / imageSize.height * fit.height,
                width: r.width / imageSize.width * fit.width,
                height: r.height / imageSize.height * fit.height)
            context.stroke(Path(roundedRect: drect, cornerRadius: 3),
                           with: .color(.white.opacity(0.5)), lineWidth: 0.8)
            if Self.campSet.contains(i) {
                context.stroke(Path(ellipseIn: CGRect(x: drect.midX-10, y: drect.midY-10, width: 20, height: 20)),
                               with: .color(.green.opacity(0.6)), lineWidth: 2)
            } else if let r2 = cc[i] {
                context.draw(Text(r2.short).font(.system(size: 15, weight: .bold)).foregroundColor(.yellow),
                             at: CGPoint(x: drect.midX, y: drect.midY))
            }
        }
    }

    // MARK: 棋盘预览网格（点格子修改）
    private var gridEditor: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("布阵预览（点格子修改）").font(.headline)
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: 5), spacing: 6) {
                ForEach(0..<30, id: \.self) { i in
                    Button { editingCell = i } label: { cellView(i) }
                }
            }
            Text("已标注 \(filledCount)/25 —— ○=行营；未标注格留空，不影响确认")
                .font(.caption2).foregroundColor(.secondary)
        }
        .padding(12)
        .background(Color(red: 0.063, green: 0.071, blue: 0.094))
        .cornerRadius(12)
    }

    // MARK: 棋盘预览（我方 · 只读展示，始终可见）
    private var mePreviewCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("棋盘预览（我方 · 只读展示）").font(.headline)
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: 5), spacing: 6) {
                ForEach(0..<30, id: \.self) { i in previewCell(i) }
            }
            Text("○=行营；确认布阵后，实时与画中画按此推演")
                .font(.caption2).foregroundColor(.secondary)
        }
        .padding(12)
        .background(Color(red: 0.063, green: 0.071, blue: 0.094))
        .cornerRadius(12)
    }

    private func previewCell(_ i: Int) -> some View {
        let isCamp = Self.campSet.contains(i)
        let r = cellsBySeat[.me]?[i]
        return ZStack {
            RoundedRectangle(cornerRadius: 8)
                .fill(Color.green.opacity(0.10))
                .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.white.opacity(0.12)))
            if isCamp {
                Circle().stroke(Color.green.opacity(0.7), lineWidth: 2).frame(width: 22, height: 22)
            } else if let rr = r {
                Text(rr.short).font(.system(size: 17, weight: .bold)).foregroundColor(.yellow)
            } else {
                Text("?").font(.system(size: 15, weight: .bold)).foregroundColor(.white.opacity(0.35))
            }
        }
        .frame(height: 44)
    }

    private func cellView(_ i: Int) -> some View {
        let isCamp = Self.campSet.contains(i)
        let r = activeCells[i]
        return ZStack {
            RoundedRectangle(cornerRadius: 8)
                .fill(isCamp ? Color.gray.opacity(0.15)
                      : (r == nil ? Color.orange.opacity(0.12) : Color.blue.opacity(0.14)))
                .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.white.opacity(0.15)))
            if isCamp {
                Text("○").font(.system(size: 16)).foregroundColor(.secondary)
            } else if let rr = r {
                Text(rr.short).font(.system(size: 19, weight: .bold)).foregroundColor(.white)
            } else {
                Text("?").font(.system(size: 15, weight: .bold)).foregroundColor(.orange)
            }
        }
        .frame(height: 44)
    }

    private func cellPicker(_ idx: Int) -> some View {
        NavigationStack {
            List {
                Button("清空此格", role: .destructive) {
                    setCell(idx, nil)
                    editingCell = nil
                }
                ForEach(Rank.allCases, id: \.self) { r in
                    Button {
                        setCell(idx, r)
                        learnCellGlyph(idx: idx, rank: r) // 手动标注自动学习字模
                        editingCell = nil
                    } label: {
                        HStack {
                            Text(r.short).bold()
                            Text(r.rawValue).foregroundColor(.secondary)
                            Spacer()
                            if activeCells[idx] == r {
                                Image(systemName: "checkmark").foregroundColor(.blue)
                            }
                        }
                    }
                }
            }
            .navigationTitle("第\((idx/5)+1)排 第\((idx%5)+1)列")
            .navigationBarTitleDisplayMode(.inline)
        }
    }

    // MARK: 逻辑
    private func learnCellGlyph(idx: Int, rank: Rank) {
        guard let cg = currentImage else { return }
        let rect = Self.cellRect(idx, tl: currentTL, br: currentBR,
                                 imageSize: CGSize(width: cg.width, height: cg.height), inset: 0.30)
        if let crop = ImageStat.upscaled(cg, rect: rect, scale: 3, minSide: 96),
           let bits = GlyphStore.hashBits(of: crop) {
            GlyphStore.learn(bits, rank: rank)
        }
    }

    private func runOCR() {
        guard let cg = currentImage, !ocrRunning else {
            if currentImage == nil { status = "请先点「选择布局截图」选一张布局卡截图" }
            return
        }
        ocrRunning = true
        let img = cg
        let t = currentTL, b = currentBR
        Task.detached(priority: .userInitiated) {
            var result = Array(repeating: Rank?.none, count: 30)
            var byGlyph = 0
            var byVision = 0
            for i in 0..<30 where !LayoutImportView.campSet.contains(i) {
                let rect = LayoutImportView.cellRect(i, tl: t, br: b,
                                                     imageSize: CGSize(width: img.width, height: img.height), inset: 0.30)
                // 1) 字模优先（学过的字，离线极准）
                if GlyphStore.learnedCount > 0,
                   let crop = ImageStat.upscaled(img, rect: rect, scale: 3, minSide: 96),
                   let bits = GlyphStore.hashBits(of: crop),
                   let r = GlyphStore.match(bits) {
                    result[i] = r; byGlyph += 1
                    continue
                }
                // 2) Vision OCR（正向/旋转各试一次）
                if let up = ImageStat.upscaled(img, rect: rect, scale: 3, minSide: 128) {
                    if let r = OCREngine.shared.recognizeLayoutCellSync(in: up) {
                        result[i] = r; byVision += 1
                    } else if let up2 = ImageStat.upscaled(img, rect: rect, scale: 3, minSide: 128, rotate180: true),
                              let r2 = OCREngine.shared.recognizeLayoutCellSync(in: up2) {
                        result[i] = r2; byVision += 1
                    }
                }
            }
            let gCount = byGlyph, vCount = byVision
            await MainActor.run {
                var res = result
                // 智能补全：恰好剩 1 个未识别格、构成恰好只缺 1 枚某棋子 → 直接补上并学习字模
                let unknown = res.indices.filter { res[$0] == nil }
                if unknown.count == 1 {
                    var counts: [Rank: Int] = [:]
                    for r in res.compactMap({ $0 }) { counts[r, default: 0] += 1 }
                    let missing = Rank.allCases.filter { (counts[$0] ?? 0) < $0.initialCount }
                    if missing.count == 1, (counts[missing[0]] ?? 0) == missing[0].initialCount - 1 {
                        res[unknown[0]] = missing[0]
                        learnCellGlyph(idx: unknown[0], rank: missing[0])
                        cellsBySeat[activeSeat] = res
                        ocrRunning = false
                        status = "识别完成：25/25（自动补全 1 枚\(missing[0].rawValue)，字模已学习）"
                        return
                    }
                }
                cellsBySeat[activeSeat] = res
                ocrRunning = false
                status = "识别完成：\(res.compactMap { $0 }.count)/25（字模 \(gCount) + Vision \(vCount)）—— 错的点格子改"
            }
        }
    }

    private func saveToLibrary() {
        let filled = filledCount
        guard filled > 0 else { status = "没有可保存的标注"; return }
        let d = Date()
        let df = DateFormatter()
        df.dateFormat = "M/d HH:mm"
        let rec = GameRecord(
            title: title.isEmpty ? "\(activeSeat == .me ? "我方" : "队友")布阵 \(df.string(from: d))" : title,
            kind: .layout,
            rawText: "",
            grid: activeCells.map { $0?.rawValue ?? "" },
            gridSeat: activeSeat.rawValue)
        records.add(rec)
        status = "已保存到棋谱库：\(rec.title)"
    }

    private func confirmLayout() {
        let filled = filledCount
        guard filled > 0 else { status = "先标注至少一枚棋子"; return }
        let d = Date()
        let df = DateFormatter()
        df.dateFormat = "M/d HH:mm"
        let rec = GameRecord(
            title: title.isEmpty ? "\(activeSeat == .me ? "我方" : "队友")布阵 \(df.string(from: d))" : title,
            kind: .layout,
            rawText: "",
            grid: activeCells.map { $0?.rawValue ?? "" },
            gridSeat: activeSeat.rawValue)
        records.add(rec)          // 自动存档
        session.applyLayout(rec)  // 同步到实时盘面
        status = "✓ 已确认并同步到实时盘面（\(filled) 枚）"
    }

    /// 格子下标 → 源图像素区域（inset 控制裁剪相对格子的收紧程度）
    static func cellRect(_ i: Int, tl: CGPoint, br: CGPoint, imageSize: CGSize, inset: CGFloat = 0.36) -> CGRect {
        let w = (br.x - tl.x) * imageSize.width / 5
        let h = (br.y - tl.y) * imageSize.height / 6
        let cx = tl.x * imageSize.width + (CGFloat(i % 5) + 0.5) * w
        let cy = tl.y * imageSize.height + (CGFloat(i / 5) + 0.5) * h
        let half = min(w, h) * inset
        return CGRect(x: cx - half, y: cy - half, width: half * 2, height: half * 2)
    }
}
