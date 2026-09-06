import SwiftUI
import AVFoundation

struct SettingsView: View {
    @EnvironmentObject var session: GameSession

    var body: some View {
        NavigationStack {
            Form {
                captureSection
                recognizeSection
                glyphSection
                pipSection
                dataSection
                disclaimerSection
            }
            .navigationTitle("设置")
        }
    }

    // MARK: 字模库
    private var glyphSection: some View {
        Section {
            HStack {
                Text("已学习字模")
                Spacer()
                Text("\(GlyphStore.learnedCount)/12 种").foregroundColor(.secondary)
            }
            if !GlyphStore.learnedShorts.isEmpty {
                Text("已学: " + GlyphStore.learnedShorts.joined(separator: " "))
                    .font(.caption).foregroundColor(.secondary)
            }
            Button {
                GlyphStore.clear()
            } label: {
                Text("清空字模库").foregroundColor(.red)
            }
        } header: {
            Text("字模库")
        } footer: {
            Text("怎么训练：在「棋谱 → 布阵导入」里手动点选标注的格子，会自动学习该字的图案。第一次把 12 种字各标注一遍（约 1 分钟），之后导入截图即可自动识别、越用越准。换游戏皮肤/字体后清空重学。")
        }
    }

    // MARK: 采集
    private var captureSection: some View {
        Section {
            HStack {
                Label(statusLabel, systemImage: statusIcon)
                Spacer()
                if session.isCapturing {
                    Button("停止") {
                        session.stopWatching()
                        session.stopCamera()
                    }
                    .buttonStyle(.bordered)
                }
            }
            #if !LITE
            // 系统广播选择器（开始录屏采集）
            VStack(alignment: .leading, spacing: 6) {
                Text("录屏采集（推荐）").font(.subheadline.bold())
                Text("点击下方按钮 → 系统弹出“屏幕录制”面板 → 选择“记牌器采集” → 开始录制，然后切到微信对局。停止录制用系统顶部的红色条。")
                    .font(.caption2).foregroundColor(.secondary)
                BroadcastPickerView()
                    .frame(height: 50)
            }
            #else
            VStack(alignment: .leading, spacing: 6) {
                Text("录屏采集（本版本不可用）").font(.subheadline.bold())
                Text("精简版（免费自签）无法使用录屏广播采集，需要开发者账号签名版的完整包。当前可测试：相机取景、棋盘校准诊断（用相册截图）、棋谱 OCR。")
                    .font(.caption2).foregroundColor(.orange)
            }
            #endif
            VStack(alignment: .leading, spacing: 6) {
                Text("相机取景（辅助）").font(.subheadline.bold())
                Text("用于拍摄另一块屏幕（平板/电脑）上的棋盘。")
                    .font(.caption2).foregroundColor(.secondary)
                HStack {
                    if session.phase == .camera {
                        Button("停止相机", role: .destructive) { session.stopCamera() }
                    } else {
                        Button("启动相机") { session.startCamera() }
                    }
                    Spacer()
                }
                .buttonStyle(.bordered)
                if session.phase == .camera {
                    CameraPreview(session: session.camera.session)
                        .frame(height: 200)
                        .clipShape(RoundedRectangle(cornerRadius: 10))
                }
            }
            VStack(alignment: .leading, spacing: 8) {
                sliderRow("采样间隔", value: $session.frameInterval, range: 0.2...1.0, step: 0.05, format: "%.2f 秒/帧")
                sliderRow("JPEG 质量", value: $session.jpegQuality, range: 0.3...0.9, step: 0.05, format: "%.2f")
                sliderRow("分辨率上限", value: $session.maxDim, range: 1000...2000, step: 100, format: "%.0f px")
            }
        } header: {
            Text("画面采集")
        }
    }

    private var statusLabel: String {
        switch session.phase {
        case .watching: return "录屏采集中"
        case .camera: return "相机取景中"
        case .idle: return "未采集"
        }
    }

    private var statusIcon: String {
        session.isCapturing ? "dot.radiowaves.left.and.right" : "slash.circle"
    }

    private func sliderRow(_ label: String, value: Binding<Double>, range: ClosedRange<Double>, step: Double, format: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(label).font(.footnote)
                Spacer()
                Text(String(format: format, value.wrappedValue))
                    .font(.caption.monospacedDigit()).foregroundColor(.secondary)
            }
            Slider(value: value, in: range, step: step)
        }
    }

    // MARK: 识别
    private var recognizeSection: some View {
        Section {
            NavigationLink {
                CalibrationView()
            } label: {
                Label(“棋盘校准与诊断”, systemImage: “viewfinder”)
            }
            Toggle(“OCR 自动识别我方棋子”, isOn: $session.ocrEnabled)
            Button {
                GlyphStore.clear()
            } label: {
                Label(“清空字模库（\(GlyphStore.learnedCount)/12）”, systemImage: “trash”)
            }
            Button {
                session.relearnHues()
            } label: {
                Label(“重新学习四家配色”, systemImage: “paintpalette”)
            }
        } header: {
            Text(“识别”)
        } footer: {
            Text(“首次使用必须校准。字模训练：布阵导入里手动标注的格子会自动学习字模，学全 12 种后导入截图即可自动识别。”)
        }
    }

    // MARK: 悬浮窗
    private var pipSection: some View {
        Section {
            HStack {
                Label(session.pip.isActive ? "悬浮窗显示中" : (session.pip.canPiP ? "未启动" : "设备不支持"),
                      systemImage: "pip.enter")
                Spacer()
                if session.pip.isActive {
                    Button("关闭") { session.pip.stop() }
                } else {
                    Button("启动") { session.pip.start() }
                        .disabled(!session.pip.canPiP)
                }
            }
            .buttonStyle(.bordered)
        } header: {
            Text("画中画悬浮窗")
        } footer: {
            Text("启动后切到微信，画中画小窗会浮在游戏上方，实时显示两家剩余与推演结果——即“边看边下”。建议先“开始本局”再启动。若小窗黑屏，等第一帧数据渲染后会自动出现。")
        }
    }

    // MARK: 数据
    private var dataSection: some View {
        Section {
            Button {
                session.beginRound()
            } label: {
                Label("开始本局（抓基准帧）", systemImage: "flag.checkered")
            }
            Button {
                session.resetAll()
            } label: {
                Label("清空本局数据", systemImage: "trash")
            }
            ShareLink(item: exportText) {
                Label("导出事件日志", systemImage: "square.and.arrow.up")
            }
        } header: {
            Text("本局")
        }
    }

    private var exportText: String {
        var s = "四国记牌器 事件日志\n"
        for e in session.events { s += e.text + "\n" }
        return s
    }

    // MARK: 声明
    private var disclaimerSection: some View {
        Section {
            Text("本工具仅识别屏幕上公开可见的信息（棋子有无、胜负结果、我方明子），不读取任何游戏隐藏数据。四国军棋高手本就依靠记忆与推理完成同样的“记子/判断”，本工具是这一过程的自动化笔记。请注意：实时辅助工具可能违反游戏平台用户协议，请仅用于个人学习研究，风险自担。")
                .font(.caption2).foregroundColor(.secondary)
        } header: {
            Text("声明")
        }
    }
}

struct CameraPreview: UIViewRepresentable {
    let session: AVCaptureSession

    func makeUIView(context: Context) -> UIView {
        let v = UIView()
        let l = AVCaptureVideoPreviewLayer(session: session)
        l.videoGravity = .resizeAspectFill
        l.frame = UIScreen.main.bounds
        v.layer.addSublayer(l)
        return v
    }

    func updateUIView(_ uiView: UIView, context: Context) {}
}
