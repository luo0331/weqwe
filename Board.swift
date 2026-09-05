import Foundation
import CoreGraphics

/// 座位：2V2 中我方在下，队友在上（对家），左右两家为敌方。
enum Seat: String, Codable, CaseIterable, Hashable {
    case me = "me"
    case teammate = "teammate"
    case leftEnemy = "left"
    case rightEnemy = "right"
    case center = "center"

    var label: String {
        switch self {
        case .me: return "我方"
        case .teammate: return "队友"
        case .leftEnemy: return "左敌"
        case .rightEnemy: return "右敌"
        case .center: return "中路"
        }
    }

    var short: String {
        switch self {
        case .me: return "我"
        case .teammate: return "友"
        case .leftEnemy: return "左"
        case .rightEnemy: return "右"
        case .center: return "中"
        }
    }

    var isEnemy: Bool { self == .leftEnemy || self == .rightEnemy }
    var isAlly: Bool { self == .me || self == .teammate }

    /// UI 主色
    var colorHex: String {
        switch self {
        case .me: return "#E8574C"
        case .teammate: return "#3D8CE8"
        case .leftEnemy: return "#3FA65C"
        case .rightEnemy: return "#C8922E"
        case .center: return "#8A8A96"
        }
    }
}

enum NodeKind: String, Codable, Hashable {
    case station // 兵站
    case camp    // 行营（开局为空，安全点）
    case hq      // 大本营
    case center  // 中央线路节点

    var label: String {
        switch self {
        case .station: return "兵站"
        case .camp: return "行营"
        case .hq: return "大本营"
        case .center: return "中路"
        }
    }
}

struct BoardNode: Identifiable, Codable, Hashable {
    let id: Int
    let seat: Seat   // 所属阵地（中央节点 seat == .center）
    let kind: NodeKind
    let row: Int     // 0...16，自上而下
    let col: Int     // 0...16，自左而右
}

/// 标准四国军棋棋盘：17×17 晶格。
/// 四家阵地各 6×5（共 120 节点）+ 中央 9 节点（行/列 ∈ {6,8,10}），共 129。
/// 校准只需把整个棋盘外框四角对准即可完成全部节点映射。
enum BoardLayout {
    static let grid = 17

    static let nodes: [BoardNode] = {
        var list: [BoardNode] = []
        var nextID = 0
        func add(_ seat: Seat, _ kind: NodeKind, _ row: Int, _ col: Int) {
            list.append(BoardNode(id: nextID, seat: seat, kind: kind, row: row, col: col))
            nextID += 1
        }
        func kindAt(lr: Int, lc: Int) -> NodeKind {
            let camps: Set<Int> = [22, 24, 33, 42, 44] // lr*10+lc
            if lr == 6 && (lc == 2 || lc == 4) { return .hq }
            if camps.contains(lr * 10 + lc) { return .camp }
            return .station
        }
        // 我方（下）：正面朝上，前排 row=11；其左手为屏幕左
        for lr in 1...6 { for lc in 1...5 { add(.me, kindAt(lr: lr, lc: lc), 10 + lr, 5 + lc) } }
        // 队友（上）：正面朝下，前排 row=5；其左手为屏幕右
        for lr in 1...6 { for lc in 1...5 { add(.teammate, kindAt(lr: lr, lc: lc), 6 - lr, 11 - lc) } }
        // 左敌（屏幕左，朝右）：前排 col=5；其左手为屏幕上
        for lr in 1...6 { for lc in 1...5 { add(.leftEnemy, kindAt(lr: lr, lc: lc), 5 + lc, 6 - lr) } }
        // 右敌（屏幕右，朝左）：前排 col=11；其左手为屏幕下
        for lr in 1...6 { for lc in 1...5 { add(.rightEnemy, kindAt(lr: lr, lc: lc), 11 - lc, 10 + lr) } }
        // 中央 9 节点
        for r in [6, 8, 10] { for c in [6, 8, 10] { add(.center, .center, r, c) } }
        return list
    }()

    static let nodeByID: [Int: BoardNode] = Dictionary(uniqueKeysWithValues: nodes.map { ($0.id, $0) })

    /// 晶格归一化坐标（0~1，左上原点）
    static func position(of node: BoardNode) -> CGPoint {
        CGPoint(x: CGFloat(node.col) / CGFloat(grid - 1), y: CGFloat(node.row) / CGFloat(grid - 1))
    }

    static func node(atRow r: Int, col c: Int) -> BoardNode? {
        nodeByID.values.first { $0.row == r && $0.col == c }
    }

    /// 阵地内局部坐标（lr: 1~6 前排→后排, lc: 1~5 该玩家左手→右手）→ 节点
    static func nodeID(seat: Seat, localRow lr: Int, localCol lc: Int) -> Int? {
        guard lr >= 1, lr <= 6, lc >= 1, lc <= 5 else { return nil }
        let row: Int, col: Int
        switch seat {
        case .me: (row, col) = (10 + lr, 5 + lc)
        case .teammate: (row, col) = (6 - lr, 11 - lc)
        case .leftEnemy: (row, col) = (5 + lc, 6 - lr)
        case .rightEnemy: (row, col) = (11 - lc, 10 + lr)
        case .center: return nil
        }
        return nodes.first { $0.row == row && $0.col == col }?.id
    }

    static func nodeLabel(_ id: Int) -> String {
        guard let n = nodeByID[id] else { return "#\(id)" }
        return "\(n.seat.short)\(id)"
    }
}

/// 棋盘四角（归一化 0~1，屏幕左上原点）：
/// tl=左上, tr=右上, bl=左下, br=右下 —— 对应晶格 (0,0),(0,16),(16,0),(16,16)。
struct Corners: Codable, Equatable {
    var tl: CGPoint
    var tr: CGPoint
    var bl: CGPoint
    var br: CGPoint

    static let `default` = Corners(
        tl: CGPoint(x: 0.18, y: 0.16),
        tr: CGPoint(x: 0.82, y: 0.16),
        bl: CGPoint(x: 0.18, y: 0.84),
        br: CGPoint(x: 0.82, y: 0.84)
    )

    var isValid: Bool {
        [tl, tr, bl, br].allSatisfy { $0.x.isFinite && $0.y.isFinite }
    }

    /// 归一化角点 → 像素坐标（乘以图像宽高）
    func pixelCorners(size: CGSize) -> (tl: CGPoint, tr: CGPoint, bl: CGPoint, br: CGPoint) {
        ( CGPoint(x: tl.x * size.width, y: tl.y * size.height),
          CGPoint(x: tr.x * size.width, y: tr.y * size.height),
          CGPoint(x: bl.x * size.width, y: bl.y * size.height),
          CGPoint(x: br.x * size.width, y: br.y * size.height) )
    }

    /// 晶格 (row,col) → 图像像素点（平行四边形仿射）
    func pixelPoint(row: Int, col: Int, size: CGSize) -> CGPoint {
        let c = pixelCorners(size: size)
        let u = CGFloat(col) / CGFloat(BoardLayout.grid - 1)
        let v = CGFloat(row) / CGFloat(BoardLayout.grid - 1)
        let top = CGPoint(x: c.tl.x + (c.tr.x - c.tl.x) * u, y: c.tl.y + (c.tr.y - c.tl.y) * u)
        let bot = CGPoint(x: c.bl.x + (c.br.x - c.bl.x) * u, y: c.bl.y + (c.br.y - c.bl.y) * u)
        return CGPoint(x: top.x + (bot.x - top.x) * v, y: top.y + (bot.y - top.y) * v)
    }
}
