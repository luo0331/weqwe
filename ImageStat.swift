import Foundation
import CoreGraphics

/// 纯 CoreGraphics 的节点小图统计：占用判定（对比度/边缘）+ 归属（色相）。
enum ImageStat {

    struct Patch {
        var meanLuma: Double
        var stdLuma: Double
        var edge: Double
        var hue: Double?   // 0~1，低饱和时为 nil
        var sat: Double
    }

    static let rgbSpace = CGColorSpace(name: CGColorSpace.sRGB)!

    /// 将 CGImage 的 rect 区域重采样为 32×32 并统计。
    /// CGImage 坐标系为左上原点，与屏幕一致；统计量对翻转不敏感。
    static func sample(_ image: CGImage, rect: CGRect, out: Int = 32) -> Patch? {
        guard let ctx = CGContext(
            data: nil, width: out, height: out, bitsPerComponent: 8, bytesPerRow: out * 4,
            space: rgbSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        ctx.interpolationQuality = .medium
        let bounds = CGRect(x: 0, y: 0, width: image.width, height: image.height)
        let clip = rect.intersection(bounds)
        guard !clip.isNull, clip.width >= 2, clip.height >= 2,
              let crop = image.cropping(to: clip) else { return nil }
        ctx.draw(crop, in: CGRect(x: 0, y: 0, width: out, height: out))
        guard let data = ctx.data else { return nil }
        let px = data.bindMemory(to: UInt8.self, capacity: out * out * 4)

        var sum = 0.0, sum2 = 0.0
        var rh: [Double] = [], gs: [Double] = [], bl: [Double] = []
        var edgeSum = 0.0
        rh.reserveCapacity(out * out); gs.reserveCapacity(out * out); bl.reserveCapacity(out * out)
        let lumas = UnsafeBufferPointer(start: UnsafePointer(px), count: out * out * 4)
        var lumaGrid: [Double] = Array(repeating: 0, count: out * out)
        for i in 0..<(out * out) {
            let r = Double(lumas[i * 4]) / 255.0
            let g = Double(lumas[i * 4 + 1]) / 255.0
            let b = Double(lumas[i * 4 + 2]) / 255.0
            let l = 0.299 * r + 0.587 * g + 0.114 * b
            lumaGrid[i] = l
            sum += l; sum2 += l * l
            rh.append(r); gs.append(g); bl.append(b)
        }
        let n = Double(out * out)
        let mean = sum / n
        let std = sqrt(max(0, sum2 / n - mean * mean))
        // 边缘：水平+垂直一阶差分绝对值均值
        for y in 0..<out {
            for x in 0..<(out - 1) {
                edgeSum += abs(lumaGrid[y * out + x + 1] - lumaGrid[y * out + x])
            }
        }
        for y in 0..<(out - 1) {
            for x in 0..<out {
                edgeSum += abs(lumaGrid[(y + 1) * out + x] - lumaGrid[y * out + x])
            }
        }
        let edge = edgeSum / n
        // 色相/饱和度（用中位色，抗局部噪声）
        func median(_ a: [Double]) -> Double {
            let s = a.sorted()
            return s[s.count / 2]
        }
        let r = median(rh), g = median(gs), b = median(bl)
        let mx = max(r, g, b), mn = min(r, g, b)
        let sat = mx <= 0 ? 0 : (mx - mn) / mx
        var hue: Double? = nil
        if sat > 0.12 {
            var h: Double = 0
            if mx == r { h = (g - b) / (mx - mn) }
            else if mx == g { h = 2 + (b - r) / (mx - mn) }
            else { h = 4 + (r - g) / (mx - mn) }
            h = h / 6.0
            if h < 0 { h += 1 }
            hue = h
        }
        return Patch(meanLuma: mean, stdLuma: std, edge: edge, hue: hue, sat: sat)
    }

    /// 占用强度：棋子卡片有明显边框和文字 → 高对比；空棋盘线 → 低。
    static func occupancyMetric(_ p: Patch) -> Double {
        p.stdLuma * 0.6 + p.edge * 2.2
    }

    /// 色相环距离 0~0.5
    static func hueDist(_ a: Double, _ b: Double) -> Double {
        let d = abs(a - b).truncatingRemainder(dividingBy: 1.0)
        return min(d, 1 - d)
    }

    /// 放大裁剪图供 OCR（保持方向）
    static func upscaled(_ image: CGImage, rect: CGRect, scale: CGFloat = 3, minSide: CGFloat = 96) -> CGImage? {
        let bounds = CGRect(x: 0, y: 0, width: image.width, height: image.height)
        let clip = rect.intersection(bounds)
        guard !clip.isNull, clip.width >= 4, clip.height >= 4,
              let crop = image.cropping(to: clip) else { return nil }
        let target = max(CGFloat(crop.width) * scale, minSide)
        let ratio = target / CGFloat(crop.width)
        let w = Int(CGFloat(crop.width) * ratio), h = Int(CGFloat(crop.height) * ratio)
        guard w > 0, h > 0, w < 4096, h < 4096,
              let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8,
                                  bytesPerRow: w * 4, space: rgbSpace,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.interpolationQuality = .high
        ctx.translateBy(x: 0, y: CGFloat(h))
        ctx.scaleBy(x: 1, y: -1)
        ctx.draw(crop, in: CGRect(x: 0, y: 0, width: w, height: h))
        return ctx.makeImage()
    }
}
