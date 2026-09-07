import SwiftUI
import ReplayKit

/// 系统广播选择器：点击后弹出"开始录制"面板，选择本 App 的采集扩展。
struct BroadcastPickerView: UIViewRepresentable {
    var preferredExtension: String = "com.sqjq.tracker.extension"

    func makeUIView(context: Context) -> RPSystemBroadcastPickerView {
        let v = RPSystemBroadcastPickerView(frame: CGRect(x: 0, y: 0, width: 220, height: 56))
        v.preferredExtension = preferredExtension
        return v
    }

    func updateUIView(_ uiView: RPSystemBroadcastPickerView, context: Context) {}
}

/// 承载 PiP 显示层的宿主视图（层必须挂在视图树上，画中画才能接管）。
final class PiPLayerView: UIView {
    var attached: CALayer? {
        didSet {
            oldValue?.removeFromSuperlayer()
            if let attached { layer.addSublayer(attached) }
        }
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        attached?.frame = bounds
        CATransaction.commit()
    }
}

struct PiPLayerHost: UIViewRepresentable {
    let layer: CALayer

    func makeUIView(context: Context) -> PiPLayerView {
        let v = PiPLayerView()
        v.backgroundColor = .clear
        v.isUserInteractionEnabled = false
        v.attached = layer
        return v
    }

    func updateUIView(_ uiView: PiPLayerView, context: Context) {
        if uiView.attached !== layer { uiView.attached = layer }
    }
}
