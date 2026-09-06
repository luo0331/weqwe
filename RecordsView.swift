import SwiftUI
import PhotosUI

/// 棋谱库：OCR 导入 → 编辑 → 统计；布阵棋谱可套用为本局我方/队友身份。
struct RecordsView: View {
    @EnvironmentObject var records: RecordStore
    @EnvironmentObject var session: GameSession
    @State private var pickerItems: [PhotosPickerItem] = []
    @State private var importing = false
    @State private var importProgressText = ""
    @State private var ocrText = ""
    @State private var showEditor = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 14) {
                    LayoutImportView()
                    recordsSection
                }
                .padding(.horizontal, 12)
                .padding(.bottom, 30)
            }
            .navigationTitle("棋谱库")
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    PhotosPicker(selection: $pickerItems, matching: .images) {
                        Label("截图导入", systemImage: "plus.viewfinder")
                    }
                }
            }
            .overlay {
                if importing {
                    VStack(spacing: 10) {
                        ProgressView()
                        Text(importProgressText).font(.caption)
                    }
                    .padding(24)
                    .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 14))
                }
            }
            .onChange(of: pickerItems) { items in
                Task { await runImport(items) }
            }
            .sheet(isPresented: $showEditor) {
                RecordEditorSheet(initial: nil, initialText: ocrText)
            }
        }
    }

    /// 棋谱列表（卡片式，嵌入页面底部）
    private var recordsSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("棋谱列表（\(records.records.count)）").font(.headline)
            if records.records.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "doc.text.magnifyingglass").font(.largeTitle).foregroundColor(.secondary)
                    Text("还没有棋谱").bold()
                    Text("布阵导入「确认布阵」后自动存入棋谱；右上角可导入复盘截图做 OCR 统计。")
                        .font(.caption).foregroundColor(.secondary)
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity)
                .padding(20)
            } else {
                ForEach(records.records) { r in
                    NavigationLink {
                        RecordDetailView(record: r)
                    } label: {
                        row(r)
                    }
                    .contextMenu {
                        Button {
                            session.applyLayout(r)
                        } label: {
                            Label("引用到本局", systemImage: "bolt.fill")
                        }
                        Button(role: .destructive) {
                            deleteRecord(r)
                        } label: {
                            Label("删除", systemImage: "trash")
                        }
                    }
                }
            }
        }
        .padding(12)
        .background(Color(red: 0.063, green: 0.071, blue: 0.094))
        .cornerRadius(12)
    }

    private func deleteRecord(_ r: GameRecord) {
        if let idx = records.records.firstIndex(where: { $0.id == r.id }) {
            records.remove(at: idx)
        }
    }

    private func row(_ r: GameRecord) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(r.title.isEmpty ? "未命名棋谱" : r.title).bold()
                Text(r.kind.rawValue)
                    .font(.caption2)
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(Color.blue.opacity(0.15), in: Capsule())
                Spacer()
            }
            Text(r.createdAt.formatted(date: .abbreviated, time: .shortened))
                .font(.caption2).foregroundColor(.secondary)
            summary(r).font(.caption).foregroundColor(.secondary)
        }
    }

    @ViewBuilder
    private func summary(_ r: GameRecord) -> some View {
        if r.kind == .layout {
            let n = RecordStore.parseLayout(r.rawText).count
            Text("布阵条目 \(n) 条")
        } else {
            let p = r.parsedRanks
            if p.isEmpty {
                Text("未识别到棋子信息")
            } else {
                Text(p.sorted { ($0.key.strength ?? -1) > ($1.key.strength ?? -1) }
                    .map { "\($0.key.short)×\($0.value)" }.joined(separator: " "))
            }
        }
    }

    @MainActor
    private func runImport(_ items: [PhotosPickerItem]) async {
        guard !items.isEmpty, !importing else { return }
        importing = true
        var texts: [String] = []
        for (i, item) in items.enumerated() {
            importProgressText = "OCR 识别中 \(i + 1)/\(items.count)…"
            guard let data = try? await item.loadTransferable(type: Data.self),
                  let ui = UIImage(data: data), let cg = ui.cgImage else { continue }
            let lines = await Task.detached(priority: .userInitiated) {
                OCREngine.shared.recognizePageSync(in: cg)
            }.value
            if !lines.isEmpty {
                texts.append("—— 截图 \(i + 1) ——")
                texts.append(contentsOf: lines)
            }
        }
        importing = false
        pickerItems = []
        ocrText = texts.joined(separator: "\n")
        if ocrText.isEmpty {
            session.toast = "未识别出文字，可截图更清晰后重试，或手动录入"
        }
        showEditor = !ocrText.isEmpty
    }
}

/// 新建/编辑棋谱
struct RecordEditorSheet: View {
    @EnvironmentObject var records: RecordStore
    @EnvironmentObject var session: GameSession
    @Environment(\.dismiss) private var dismiss
    var initial: GameRecord?
    var initialText: String

    @State private var title = ""
    @State private var kind: GameRecord.Kind = .battleLog
    @State private var text = ""
    @State private var loaded = false

    var body: some View {
        NavigationStack {
            Form {
                Section("基本信息") {
                    TextField("标题（如：0905 对局 vs 左右家）", text: $title)
                    Picker("类型", selection: $kind) {
                        ForEach(GameRecord.Kind.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                    }
                }
                Section("OCR / 手输内容") {
                    TextEditor(text: $text)
                        .frame(minHeight: 200)
                        .font(.callout.monospaced())
                }
                Section("识别预览") {
                    if kind == .layout {
                        let entries = RecordStore.parseLayout(text)
                        if entries.isEmpty {
                            Text("未解析出布阵条目。格式：每行 “我 3-2 军长”（行1~6=前排→后排，列1~5=该玩家左手→右手；队友写 “友 3-2 军长”）。")
                                .font(.caption).foregroundColor(.secondary)
                        } else {
                            ForEach(Array(entries.enumerated()), id: \.offset) { _, e in
                                Text("\(e.seat.label) 第\(e.lr)排 第\(e.lc)列 → \(e.rank.rawValue)")
                                    .font(.caption)
                            }
                        }
                    } else {
                        let p = RecordStore.parse(text)
                        if p.isEmpty {
                            Text("未识别到棋子").font(.caption).foregroundColor(.secondary)
                        } else {
                            Text(p.sorted { ($0.key.strength ?? -1) > ($1.key.strength ?? -1) }
                                .map { "\($0.key.rawValue)×\($0.value)" }.joined(separator: "  "))
                                .font(.caption)
                        }
                    }
                }
            }
            .navigationTitle(initial == nil ? "新建棋谱" : "编辑棋谱")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") {
                        if var r = initial {
                            r.title = title
                            r.kind = kind
                            r.rawText = text
                            records.update(r)
                        } else {
                            records.add(GameRecord(title: title, kind: kind, rawText: text))
                        }
                        dismiss()
                    }
                }
            }
            .onAppear {
                guard !loaded else { return }
                loaded = true
                if let initial {
                    title = initial.title
                    kind = initial.kind
                    text = initial.rawText
                } else {
                    text = initialText
                }
            }
        }
    }
}

/// 棋谱详情：编辑 / 套用布阵
struct RecordDetailView: View {
    @EnvironmentObject var records: RecordStore
    @EnvironmentObject var session: GameSession
    let record: GameRecord
    @State private var showEditor = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    Text(record.kind.rawValue)
                        .font(.caption)
                        .padding(.horizontal, 8).padding(.vertical, 3)
                        .background(Color.blue.opacity(0.15), in: Capsule())
                    Spacer()
                    Text(record.createdAt.formatted(date: .long, time: .shortened))
                        .font(.caption).foregroundColor(.secondary)
                }
                if record.kind == .layout {
                    Button {
                        session.applyLayout(record)
                    } label: {
                        Label("套用为本局我方/队友身份", systemImage: "square.and.arrow.down.on.square")
                    }
                    .buttonStyle(.borderedProminent)
                    Text("套用后，开局即可精确推演“吃掉这枚棋子的敌方棋子大小”。请在开始本局之前套用。")
                        .font(.caption2).foregroundColor(.secondary)
                }
                Text("原文").font(.headline)
                Text(record.rawText.isEmpty ? "（空）" : record.rawText)
                    .font(.callout.monospaced())
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(10)
                    .background(Color(hex: "#101218"))
                    .clipShape(RoundedRectangle(cornerRadius: 10))
                Button("编辑内容") { showEditor = true }
                    .buttonStyle(.bordered)
            }
            .padding(16)
        }
        .navigationTitle(record.title.isEmpty ? "棋谱" : record.title)
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $showEditor) {
            RecordEditorSheet(initial: record, initialText: record.rawText)
        }
    }
}
