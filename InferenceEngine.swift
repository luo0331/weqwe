import Foundation

/// 推演引擎：为左/右敌家的每个存活棋子维护候选身份集合，
/// 依据吃子/阵亡/移动事件做约束传播，并给出剩余构成估算。
/// 每次事件后整体重放（事件量小，开销可忽略），天然支持修正与撤销。
final class InferenceEngine {

    struct Piece: Identifiable, Codable, Hashable {
        let id: Int
        let seat: Seat
        var originNode: Int
        var node: Int?
        var alive = true
        var candidates: Set<Rank>
        var definite: Rank? = nil
        var moved = false

        var label: String { "\(seat.short)#\(originNode)" }
    }

    struct EnemySummary: Codable, Equatable {
        var seat: Seat
        var aliveTotal: Int = 0
        var aliveUnknown: Int = 0
        var deadKnown: [Rank: Int] = [:]
        var deadUnknown: Int = 0
        var estimate: [Rank: Double] = [:]   // 存活构成期望
    }

    struct Snapshot: Codable, Equatable {
        var pieces: [Piece] = []
        var summaries: [Seat: EnemySummary] = [:]
        var notes: [String] = []
        var identity: [Int: Rank] = [:]      // 我方/队友节点 → 已知身份
        var allyDead: [Rank: Int] = [:]
        var inconsistent = false

        static let empty = Snapshot()

        func piece(atNode node: Int) -> Piece? {
            pieces.first { $0.alive && $0.node == node }
        }

        func summary(for seat: Seat) -> EnemySummary? { summaries[seat] }
    }

    private(set) var snapshot: Snapshot = .empty

    // MARK: - 重放入口

    func rebuild(baseline: [Int: NodeSnapshot], events: [GameEvent], layoutPreload: [Int: Rank]) {
        var snap = Snapshot()
        var nodeRank: [Int: Rank] = layoutPreload
        var deadKnown: [Seat: [Rank: Int]] = [.leftEnemy: [:], .rightEnemy: [:]]
        var deadUnknown: [Seat: Int] = [.leftEnemy: 0, .rightEnemy: 0]
        var pieces: [Piece] = []
        var nextPieceID = 1
        var notes: [String] = []
        var inconsistent = false

        // 1. 从基准帧创建敌方棋子实例
        for (id, s) in baseline {
            guard s.occupied, let owner = s.owner, owner.isEnemy else { continue }
            pieces.append(Piece(id: nextPieceID, seat: owner, originNode: id, node: id,
                                candidates: Set(Rank.allCases)))
            nextPieceID += 1
        }

        @inline(__always)
        func pieceAt(_ seat: Seat, _ node: Int) -> Piece? {
            pieces.first { $0.alive && $0.seat == seat && $0.node == node }
        }

        @inline(__always)
        func kill(_ p: Piece, definiteRank: Rank?) {
            guard let idx = pieces.firstIndex(where: { $0.id == p.id }) else { return }
            pieces[idx].alive = false
            pieces[idx].node = nil
            if let r = definiteRank ?? pieces[idx].definite {
                deadKnown[pieces[idx].seat, default: [:]][r, default: 0] += 1
            } else {
                deadUnknown[pieces[idx].seat, default: 0] += 1
            }
        }

        @inline(__always)
        func constrainEnemy(_ p: Piece, to allowed: Set<Rank>, why: String) {
            guard let idx = pieces.firstIndex(where: { $0.id == p.id }) else { return }
            var next = pieces[idx]
            let before = next.candidates
            next.candidates.formIntersection(allowed)
            if next.candidates.isEmpty {
                inconsistent = true
                next.candidates = before // 保底，等待人工修正
                pieces[idx] = next
                return
            }
            if next.candidates != before {
                if next.candidates.count == 1, let r = next.candidates.first {
                    next.definite = r
                    notes.append("\(next.label) 判定→\(r.rawValue)（\(why)）")
                } else {
                    notes.append("\(next.label) \(why) → 候选 {\(next.candidates.sorted().map(\.short).joined(separator: "/"))}")
                }
            }
            pieces[idx] = next
        }

        // 2. 逐事件重放
        for ev in events {
            switch ev.kind {
            case .manualRank(let node, let rank):
                if let r = rank { nodeRank[node] = r } else { nodeRank[node] = nil }

            case .move(let from, let to, let owner):
                if owner.isEnemy {
                    if let p = pieceAt(owner, from) {
                        guard let i = pieces.firstIndex(where: { $0.id == p.id }) else { continue }
                        pieces[i].node = to
                        pieces[i].moved = true
                        pieces[i].candidates.subtract([.地雷, .军旗])
                        if pieces[i].candidates.count == 1 { pieces[i].definite = pieces[i].candidates.first }
                    }
                } else {
                    if let r = nodeRank[from] { nodeRank[to] = r }
                    nodeRank[from] = nil
                }

            case .loss(let owner, let node):
                if owner.isEnemy {
                    if let p = pieceAt(owner, node) { kill(p, definiteRank: nil) }
                } else {
                    let r = nodeRank[node]
                    if let r { snap.allyDead[r, default: 0] += 1 }
                    nodeRank[node] = nil
                    notes.append("\(owner.label) \(BoardLayout.nodeLabel(node)) 损失（身份\(r.map { $0.rawValue } ?? "未知")）")
                }

            case .battle(let af, let dn, let attacker, let defender, let outcome):
                let aRank: Rank? = attacker.isAlly ? (af.flatMap { nodeRank[$0] }) : pieceAt(attacker, af ?? -1)?.definite
                let dRank: Rank? = defender.isAlly ? nodeRank[dn] : pieceAt(defender, dn)?.definite

                switch (attacker.isEnemy, outcome) {
                // ---- 敌攻我/友 ----
                case (true, .attackerWins):
                    if let p = pieceAt(attacker, af ?? -1) {
                        guard let i = pieces.firstIndex(where: { $0.id == p.id }) else { break }
                        pieces[i].node = dn
                        pieces[i].moved = true
                        var allowed = pieces[i].candidates
                        if let d = dRank, d != .炸弹, let s = d.strength {
                            if d == .地雷 {
                                allowed.formIntersection([.工兵])
                            } else {
                                allowed = allowed.filter { r in (r.strength ?? -99) > s }
                                notes.append("\(pieces[i].label) 吃掉我方\(d.rawValue) ⇒ ≥\(d.rawValue)")
                            }
                        }
                        constrainEnemy(pieces[i], to: allowed, why: dRank != nil ? "吃\(dRank!.rawValue)" : "吃子")
                    }
                    if defender.isAlly {
                        if let d = dRank { snap.allyDead[d, default: 0] += 1 }
                        nodeRank[dn] = nil
                    }

                case (true, .defenderWins):
                    if let p = pieceAt(attacker, af ?? -1) {
                        var allowed = p.candidates
                        if let d = dRank {
                            if d == .地雷 {
                                allowed.subtract([.工兵, .炸弹])
                                notes.append("\(p.label) 撞雷阵亡 ⇒ 非工兵/炸弹")
                            } else if d == .炸弹 {
                                notes.append("\(p.label) 撞炸阵亡")
                            } else if let s = d.strength {
                                allowed = allowed.filter { r in (r.strength ?? 99) < s }
                                notes.append("\(p.label) 攻\(d.rawValue)阵亡 ⇒ <\(d.rawValue)")
                            }
                        } else {
                            allowed.subtract([.炸弹]) // 对方存活 ⇒ 它不是炸弹
                        }
                        constrainEnemy(p, to: allowed, why: "进攻阵亡")
                        kill(p, definiteRank: nil)
                    }
                    if attacker.isAlly {
                        if let a = aRank { snap.allyDead[a, default: 0] += 1 }
                        if let af { nodeRank[af] = nil }
                    }

                case (true, .bothDie):
                    if let p = pieceAt(attacker, af ?? -1) {
                        if let d = dRank, d != .炸弹, d != .地雷 {
                            constrainEnemy(p, to: [.炸弹], why: "与\(d.rawValue)同尽")
                            notes.append("\(p.label) 判定→炸弹（与\(d.rawValue)同归于尽）")
                        } else if dRank == nil {
                            notes.append("\(p.label) 与未知子同尽（可能互为炸弹）")
                        }
                        kill(p, definiteRank: nil)
                    }
                    if defender.isAlly {
                        if let d = dRank { snap.allyDead[d, default: 0] += 1 }
                        nodeRank[dn] = nil
                    }

                // ---- 我/友攻敌 ----
                case (false, .attackerWins):
                    if defender.isEnemy {
                        if let p = pieceAt(defender, dn) { kill(p, definiteRank: nil) }
                        notes.append("我方吃掉 \(defender.label)@\(BoardLayout.nodeLabel(dn))（敌方身份未暴露）")
                    }
                    if attacker.isAlly, let af {
                        if let r = nodeRank[af] { nodeRank[dn] = r }
                        nodeRank[af] = nil
                    }

                case (false, .defenderWins):
                    if defender.isEnemy, let p = pieceAt(defender, dn) {
                        var allowed = p.candidates
                        if let a = aRank, a != .炸弹, let s = a.strength {
                            allowed = allowed.filter { r in (r.strength ?? 99) > s }
                            if a == .工兵 { allowed.subtract([.地雷]) }
                            notes.append("\(p.label) 吃掉我方\(a.rawValue) ⇒ ≥\(a.rawValue)")
                        }
                        allowed.subtract([.炸弹]) // 守方存活 ⇒ 必非炸弹
                        constrainEnemy(p, to: allowed, why: aRank != nil ? "胜\(aRank!.rawValue)" : "防守成功")
                    }
                    if attacker.isAlly {
                        if let a = aRank { snap.allyDead[a, default: 0] += 1 }
                        if let af { nodeRank[af] = nil }
                    }

                case (false, .bothDie):
                    if defender.isEnemy, let p = pieceAt(defender, dn) {
                        if let a = aRank, a != .炸弹 {
                            constrainEnemy(p, to: [.炸弹], why: "与我方\(a.rawValue)同尽")
                            notes.append("\(p.label) 判定→炸弹（与我方\(a.rawValue)同归于尽）")
                        }
                        kill(p, definiteRank: nil)
                    }
                    if attacker.isAlly {
                        if let a = aRank { snap.allyDead[a, default: 0] += 1 }
                        if let af { nodeRank[af] = nil }
                    }
                }

            case .note(let s):
                notes.append(s)
            }
        }

        // 3. 构成容量剪枝（迭代至不动点）
        for seat in [Seat.leftEnemy, .rightEnemy] {
            var changed = true
            var guardCounter = 0
            while changed && guardCounter < 8 {
                changed = false
                guardCounter += 1
                var definiteAlive: [Rank: Int] = [:]
                for p in pieces where p.alive && p.seat == seat {
                    if let r = p.definite { definiteAlive[r, default: 0] += 1 }
                }
                for p in pieces where p.alive && p.seat == seat {
                    var allowed = p.candidates
                    for r in p.candidates {
                        // 容量 = 初始 - 已确认阵亡 - 其他棋子已判定为该等级（排除自身）
                        let others = (definiteAlive[r] ?? 0) - (p.definite == r ? 1 : 0)
                        let cap = r.initialCount - (deadKnown[seat]?[r] ?? 0) - others
                        if cap <= 0 { allowed.remove(r) }
                    }
                    if allowed.isEmpty { inconsistent = true; continue }
                    if allowed != p.candidates {
                        if let i = pieces.firstIndex(where: { $0.id == p.id }) {
                            pieces[i].candidates = allowed
                            if allowed.count == 1 { pieces[i].definite = allowed.first }
                        }
                        changed = true
                    }
                }
            }
        }

        // 4. 汇总
        for seat in [Seat.leftEnemy, .rightEnemy] {
            var sum = EnemySummary(seat: seat)
            for p in pieces where p.alive && p.seat == seat {
                sum.aliveTotal += 1
                if p.definite == nil { sum.aliveUnknown += 1 }
            }
            sum.deadKnown = deadKnown[seat] ?? [:]
            sum.deadUnknown = deadUnknown[seat] ?? 0
            var capacity: [Rank: Int] = [:]
            var definiteAlive: [Rank: Int] = [:]
            for r in Rank.allCases {
                definiteAlive[r] = pieces.filter { $0.alive && $0.seat == seat && $0.definite == r }.count
                capacity[r] = max(0, r.initialCount - (sum.deadKnown[r] ?? 0) - (definiteAlive[r] ?? 0))
            }
            for p in pieces where p.alive && p.seat == seat && p.definite == nil {
                let allowed = p.candidates.filter { (capacity[$0] ?? 0) > 0 }
                let totalW = allowed.reduce(0.0) { $0 + Double(max(1, capacity[$1] ?? 1)) }
                guard totalW > 0 else { continue }
                for r in allowed {
                    sum.estimate[r, default: 0] += Double(capacity[r] ?? 1) / totalW
                }
            }
            snap.summaries[seat] = sum
        }

        snap.pieces = pieces.sorted { ($0.seat.rawValue, $0.originNode) < ($1.seat.rawValue, $1.originNode) }
        snap.identity = nodeRank
        snap.notes = Array(notes.reversed().prefix(14))
        snap.inconsistent = inconsistent
        snapshot = snap
    }
}
