import Foundation

/// 棋谱记录（OCR 导入，可增删）。battleLog 用于统计参考，layout 可套用为本局我方/队友身份。
struct GameRecord: Identifiable, Codable, Equatable {
    enum Kind: String, Codable, CaseIterable {
        case battleLog = "对局记录"
        case layout = "布阵棋谱"
    }

    var id: UUID = UUID()
    var createdAt: Date = Date()
    var title: String = ""
    var kind: Kind = .battleLog
    var rawText: String = ""
    /// 布阵网格：30 格，index = (行-1)*5 + (列-1)，值为 Rank.rawValue 或 ""（行=前排→后排，列=左手→右手）
    var grid: [String]? = nil
    /// 布阵归属："me" / "teammate"
    var gridSeat: String? = nil

    var parsedRanks: [Rank: Int] { RecordStore.parse(rawText) }

    /// 布阵条目：优先用结构化网格，否则回退文本解析
    func layoutEntries() -> [RecordStore.LayoutEntry] {
        if let grid, grid.count == 30 {
            let seat = Seat(rawValue: gridSeat ?? Seat.me.rawValue) ?? .me
            var out: [RecordStore.LayoutEntry] = []
            for (i, s) in grid.enumerated() where !s.isEmpty {
                if let r = Rank(rawValue: s) {
                    out.append(RecordStore.LayoutEntry(seat: seat, lr: i / 5 + 1, lc: i % 5 + 1, rank: r))
                }
            }
            return out
        }
        return RecordStore.parseLayout(rawText)
    }
}

@MainActor
final class RecordStore: ObservableObject {
    @Published private(set) var records: [GameRecord] = []

    private static var fileURL: URL {
        let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        return dir.appendingPathComponent("game_records.json")
    }

    init() { load() }

    func add(_ r: GameRecord) {
        records.insert(r, at: 0)
        save()
    }

    func remove(at offsets: IndexSet) {
        records.remove(atOffsets: offsets)
        save()
    }

    func update(_ r: GameRecord) {
        guard let i = records.firstIndex(where: { $0.id == r.id }) else { return }
        records[i] = r
        save()
    }

    private func load() {
        guard let d = try? Data(contentsOf: Self.fileURL),
              let list = try? JSONDecoder().decode([GameRecord].self, from: d) else { return }
        records = list
    }

    private func save() {
        guard let d = try? JSONEncoder().encode(records) else { return }
        try? d.write(to: Self.fileURL, options: .atomic)
    }

    // MARK: - 解析

    /// 从 OCR 文本统计棋子：支持 “师长 2”“炸弹×2”“工兵” 等写法
    nonisolated static func parse(_ text: String) -> [Rank: Int] {
        var out: [Rank: Int] = [:]
        let ns = text as NSString
        for r in Rank.allCases {
            let pattern = NSRegularExpression.escapedPattern(for: r.rawValue)
                + "\\s*[×xX*]?\\s*([0-9]{1,2})?"
            guard let re = try? NSRegularExpression(pattern: pattern) else { continue }
            for m in re.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
                var count = 1
                if m.numberOfRanges > 1, m.range(at: 1).location != NSNotFound {
                    count = Int(ns.substring(with: m.range(at: 1))) ?? 1
                    if count < 1 { count = 1 }
                    if count > 9 { count = 9 }
                }
                out[r, default: 0] += count
            }
        }
        return out
    }

    struct LayoutEntry: Equatable {
        let seat: Seat
        let lr: Int   // 1~6 前排→后排
        let lc: Int   // 1~5 左手→右手
        let rank: Rank
    }

    /// 布阵条目：每行 “我 3-2 军长” / “友 4,1 工兵” / “3 2 师长”（默认我方）
    nonisolated static func parseLayout(_ text: String) -> [LayoutEntry] {
        let pattern = #"\s*(我|友|队友|左|右)?\s*([1-6])\s*[-,，.、/]\s*([1-5])\s*[:：,，]?\s*(司令|军长|师长|旅长|团长|营长|连长|排长|工兵|炸弹|地雷|军旗)"#
        guard let re = try? NSRegularExpression(pattern: pattern) else { return [] }
        let ns = text as NSString
        var out: [LayoutEntry] = []
        for m in re.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            let seatWord = m.range(at: 1).location != NSNotFound ? ns.substring(with: m.range(at: 1)) : ""
            let seat: Seat
            switch seatWord {
            case "友", "队友": seat = .teammate
            case "左": seat = .leftEnemy
            case "右": seat = .rightEnemy
            default: seat = .me
            }
            guard let lr = Int(ns.substring(with: m.range(at: 2))),
                  let lc = Int(ns.substring(with: m.range(at: 3))),
                  let rank = Rank(rawValue: ns.substring(with: m.range(at: 4))) else { continue }
            out.append(LayoutEntry(seat: seat, lr: lr, lc: lc, rank: rank))
        }
        return out
    }
}
