import Foundation
import Network

/// 主 App 本地帧接收服务: 录屏扩展通过 127.0.0.1 把屏幕帧推到这里。
/// 传输协议 (自定义二进制): [4B 大端 jpeg 长度][4B 大端 seq][jpeg 字节]
/// loopback 通信不触发 iOS 本地网络权限弹窗, 免费签名即可用。
enum FrameServer {
    static let port: UInt16 = 18080

    private static var listener: NWListener?
    private static let lock = NSLock()
    private static var pending = Data()

    static func start() {
        guard listener == nil else { return }
        let params = NWParameters.tcp
        params.allowLocalEndpointReuse = true
        guard let p = NWEndpoint.Port(rawValue: port),
              let l = try? NWListener(using: params, on: p) else { return }
        l.newConnectionHandler = { conn in
            conn.start(queue: DispatchQueue.global(qos: .utility))
            receiveLoop(conn)
        }
        l.stateUpdateHandler = { _ in }
        l.start(queue: DispatchQueue.global(qos: .utility))
        listener = l
    }

    private static func receiveLoop(_ conn: NWConnection) {
        conn.receive(minimumIncompleteLength: 1, maximumLength: 262144) { data, _, complete, error in
            if let d = data, !d.isEmpty {
                lock.lock()
                pending.append(d)
                let frames = drainPending()
                lock.unlock()
                for (jpeg, seq) in frames {
                    let meta = FrameStore.Meta(
                        seq: seq,
                        time: Date().timeIntervalSince1970,
                        width: 0, height: 0)
                    FrameStore.store(jpeg: jpeg, meta: meta)
                }
            }
            if complete || error != nil {
                lock.lock()
                pending.removeAll()
                lock.unlock()
                conn.cancel()
                return
            }
            receiveLoop(conn)
        }
    }

    /// 从 pending 中按帧协议切出所有完整帧
    private static func drainPending() -> [(jpeg: Data, seq: Int)] {
        var out: [(Data, Int)] = []
        while pending.count >= 8 {
            let len = u32(pending, 0)
            if len == 0 || len > 8_000_000 {
                pending.removeAll()
                break
            }
            guard pending.count >= 8 + Int(len) else { break }
            let seq = Int(u32(pending, 4))
            let jpeg = pending.subdata(in: 8..<(8 + Int(len)))
            pending.removeSubrange(0..<(8 + Int(len)))
            out.append((jpeg, seq))
        }
        return out
    }

    private static func u32(_ d: Data, _ off: Int) -> UInt32 {
        let b = [UInt8](d.subdata(in: off..<(off + 4)))
        return (UInt32(b[0]) << 24) | (UInt32(b[1]) << 16) | (UInt32(b[2]) << 8) | UInt32(b[3])
    }
}
