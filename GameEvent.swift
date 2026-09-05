import Foundation
import CoreGraphics

/// 某一时刻某节点的可见状态（由识别层产出并提交）
struct NodeSnapshot: Codable, Equatable, Hashable {
    var occupied: Bool
    var owner: Seat?

    static let empty = NodeSnapshot(occupied: false, owner: nil)
}

/// 节点状态变化
struct NodeChange: Codable, Equatable, Hashable {
    let id: Int
    let from: NodeSnapshot
    let to: NodeSnapshot
}

/// 一帧内提交的所有变化
struct FrameDiff: Codable, Equatable {
    var changes: [NodeChange]
    var time: TimeInterval

    var isEmpty: Bool { changes.isEmpty }
}

enum BattleOutcome: String, Codable {
    case attackerWins // 攻方吃掉守方
    case defenderWins // 守方存活，攻方阵亡（攻方原节点孤立清空）
    case bothDie      // 同归于尽（两个节点同时清空）
}

enum GameEventKind: Codable, Equatable, Hashable {
    case move(from: Int, to: Int, owner: Seat)
    case battle(attackerFrom: Int?, defenderNode: Int, attacker: Seat, defender: Seat, outcome: BattleOutcome)
    case loss(owner: Seat, node: Int)                 // 该节点棋子阵亡且无法确定战斗位置（进攻阵亡）
    case manualRank(node: Int, rank: Rank?)           // 手动/OCR 设定我方或队友棋子身份
    case note(String)                                  // 系统提示/人工备注
}

struct GameEvent: Codable, Identifiable, Equatable, Hashable {
    let id: UUID
    let time: TimeInterval
    let kind: GameEventKind

    init(time: TimeInterval = Date().timeIntervalSince1970, kind: GameEventKind) {
        self.id = UUID()
        self.time = time
        self.kind = kind
    }

    var text: String {
        let t = DateFormatter.shortTime.string(from: Date(timeIntervalSince1970: time))
        switch kind {
        case .move(let f, let to, let o):
            return "\(t)  \(o.label) \(BoardLayout.nodeLabel(f)) → \(BoardLayout.nodeLabel(to))"
        case .battle(let af, let dn, let a, let d, let o):
            let from = af.map { BoardLayout.nodeLabel($0) } ?? "?"
            switch o {
            case .attackerWins: return "\(t)  ⚔ \(a.label)(\(from)) 吃掉 \(d.label)@\(BoardLayout.nodeLabel(dn))"
            case .defenderWins: return "\(t)  ⚔ \(a.label)(\(from)) 进攻 \(d.label) 阵亡"
            case .bothDie: return "\(t)  ⚔ \(a.label)(\(from)) 与 \(d.label)@\(BoardLayout.nodeLabel(dn)) 同归于尽"
            }
        case .loss(let o, let n):
            return "\(t)  ✝ \(o.label) \(BoardLayout.nodeLabel(n)) 阵亡"
        case .manualRank(let n, let r):
            return "\(t)  ✎ \(BoardLayout.nodeLabel(n)) 标记为 \(r?.rawValue ?? "未知")"
        case .note(let s):
            return "\(t)  ⓘ \(s)"
        }
    }
}

extension DateFormatter {
    static let shortTime: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        return f
    }()
}
