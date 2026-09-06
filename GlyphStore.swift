import Foundation
import UIKit

/// 字模库：手动标注时自动学习该字的图案指纹（24×24 二值），
/// 识别时按汉明距离匹配。同一游戏字体下极准，完全离线，跨次持久（UserDefaults）。
enum GlyphStore {
    private static let key = "sqjq_glyphs"
    private static var cache: [String: [String]] = [:]
    private static var loaded = false

    private static func ensureLoaded() {
        guard !loaded else { return }
        loaded = true
        if let raw = UserDefaults.standard.string(forKey: key),
           let obj = try? JSONDecoder().decode([String: [String]].self, from: Data(raw.utf8)) {
            cache = obj
        }
    }
    private static func persist() {
        if let d = try? JSONEncoder().encode(cache) {
            UserDefaults.standard.set(String(data: d, encoding: .utf8), forKey: key)
        }
    }

    static var learnedCount: Int {
        ensureLoaded()
        return cache.keys.count
    }
    static var learnedShorts: [String] {
        ensureLoaded()
        return Rank.allCases.filter { !(cache[$0.rawValue] ?? []).isEmpty }.map(\.short)
    }
    static func clear() {
        ensureLoaded()
        cache = [:]
        persist()
    }

    /// 24×24 均值二值指纹
    static func hashBits(of crop: CGImage) -> String? {
        let n = 24
        guard crop.width >= 8, crop.height >= 8,
              let ctx = CGContext(data: nil, width: n, height: n, bitsPerComponent: 8, bytesPerRow: n * 4,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.interpolationQuality = .medium
        ctx.draw(crop, in: CGRect(x: 0, y: 0, width: n, height: n))
        guard let data = ctx.data else { return nil }
        let px = data.bindMemory(to: UInt8.self, capacity: n * n * 4)
        var sum = 0.0
        var lum = [Double](repeating: 0, count: n * n)
        for k in 0..<(n * n) {
            let l = 0.299 * Double(px[k * 4]) + 0.587 * Double(px[k * 4 + 1]) + 0.114 * Double(px[k * 4 + 2])
            lum[k] = l; sum += l
        }
        let mean = sum / Double(n * n)
        var bits = ""
        for k in 0..<(n * n) { bits += lum[k] < mean ? "1" : "0" }
        return bits
    }

    static func hamming(_ a: String, _ b: String) -> Double {
        let aa = Array(a), bb = Array(b)
        guard aa.count == bb.count, !aa.isEmpty else { return 1.0 }
        var d = 0
        for k in 0..<aa.count where aa[k] != bb[k] { d += 1 }
        return Double(d) / Double(aa.count)
    }

    static func learn(_ bits: String, rank: Rank) {
        ensureLoaded()
        var list = cache[rank.rawValue] ?? []
        if list.contains(where: { hamming($0, bits) < 0.12 }) { return }
        list.append(bits)
        cache[rank.rawValue] = list
        persist()
    }

    static func match(_ bits: String) -> Rank? {
        ensureLoaded()
        var best: Rank? = nil
        var bestD = 1.0
        var second = 1.0
        for (name, list) in cache {
            guard let r = Rank(rawValue: name) else { continue }
            for b in list {
                let dd = hamming(b, bits)
                if dd < bestD { second = bestD; bestD = dd; best = r }
                else if dd < second { second = dd }
            }
        }
        if let r = best, bestD <= 0.16, (second - bestD) >= 0.03 { return r }
        return nil
    }
}
