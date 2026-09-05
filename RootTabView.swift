import SwiftUI

extension Color {
    init?(hex: String) {
        guard let ui = UIColor(hex: hex) else { return nil }
        self.init(uiColor: ui)
    }
}

struct RootTabView: View {
    @EnvironmentObject var session: GameSession

    var body: some View {
        ZStack(alignment: .bottom) {
            // PiP 显示层宿主：必须挂在视图树上，画中画才能接管（几乎不可见）
            PiPLayerHost(layer: session.pip.displayLayer)
                .frame(width: 180, height: 100)
                .opacity(0.02)
                .allowsHitTesting(false)
                .offset(y: -60)
            TabView {
                DashboardView()
                    .tabItem { Label("实时", systemImage: "bolt.shield") }
                RecordsView()
                    .tabItem { Label("棋谱", systemImage: "doc.text.magnifyingglass") }
                SettingsView()
                    .tabItem { Label("设置", systemImage: "gearshape") }
            }
            FloatingBallView()
                .padding(.bottom, 90)
            toastOverlay
        }
    }

    @ViewBuilder
    private var toastOverlay: some View {
        if let t = session.toast {
            Text(t)
                .font(.footnote)
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                .background(.ultraThinMaterial, in: Capsule())
                .padding(.bottom, 150)
                .task {
                    try? await Task.sleep(nanoseconds: 2_600_000_000)
                    if session.toast == t { session.toast = nil }
                }
        }
    }
}

/// 应用内悬浮球：随时查看两家剩余数量与最新推演。
/// 切到微信后请使用“画中画悬浮窗”（设置页启动）。
struct FloatingBallView: View {
    @EnvironmentObject var session: GameSession
    @State private var base = CGSize(width: 130, height: -40)
    @State private var drag: CGSize = .zero
    @State private var expanded = false

    private var leftAlive: Int { session.engineSnapshot.summary(for: .leftEnemy)?.aliveTotal ?? 25 }
    private var rightAlive: Int { session.engineSnapshot.summary(for: .rightEnemy)?.aliveTotal ?? 25 }

    var body: some View {
        VStack(spacing: 8) {
            if expanded { panel }
            ball
        }
    }

    private var ball: some View {
        ZStack {
            Circle()
                .fill(LinearGradient(colors: [Color(hex: "#2A2E3A") ?? Color.gray, Color(hex: "#12141A") ?? Color.gray], startPoint: .top, endPoint: .bottom))
                .overlay(Circle().strokeBorder(Color.white.opacity(0.18), lineWidth: 1))
                .shadow(radius: 6)
            VStack(spacing: 0) {
                Text("左\(leftAlive)")
                    .foregroundColor(Color(hex: Seat.leftEnemy.colorHex) ?? .green)
                Text("右\(rightAlive)")
                    .foregroundColor(Color(hex: Seat.rightEnemy.colorHex) ?? .orange)
            }
            .font(.system(size: 13, weight: .bold, design: .rounded))
        }
        .frame(width: 58, height: 58)
        .offset(x: base.width + drag.width, y: base.height + drag.height)
        .gesture(
            DragGesture()
                .onChanged { v in drag = v.translation }
                .onEnded { v in
                    base = CGSize(width: base.width + v.translation.width, height: base.height + v.translation.height)
                    drag = .zero
                    if abs(v.translation.width) < 6 && abs(v.translation.height) < 6 {
                        withAnimation(.spring(response: 0.3)) { expanded.toggle() }
                    }
                }
        )
    }

    private var panel: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach([Seat.leftEnemy, .rightEnemy], id: \.self) { seat in
                if let s = session.engineSnapshot.summary(for: seat) {
                    HStack(spacing: 6) {
                        Circle().fill(Color(hex: seat.colorHex) ?? .gray).frame(width: 8, height: 8)
                        Text("\(seat.label) 剩 \(s.aliveTotal)")
                            .font(.caption.bold())
                        Text("未知亡 \(s.deadUnknown)")
                            .font(.caption2)
                            .foregroundColor(.secondary)
                    }
                }
            }
            ForEach(Array(session.engineSnapshot.notes.prefix(3).enumerated()), id: \.offset) { _, n in
                Text(n)
                    .font(.caption2)
                    .foregroundColor(.secondary)
                    .lineLimit(2)
            }
        }
        .padding(12)
        .frame(width: 230, alignment: .leading)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 14))
        .offset(x: base.width + drag.width, y: base.height + drag.height - 20)
    }
}
