import Foundation

public struct CoverPalette: Equatable, Sendable {
    public let dominant: UInt32
    public let vibrant: UInt32?
    public struct Atmosphere: Equatable, Sendable {
        public let top: UInt32
        public let middle: UInt32
        public let accent: UInt32
    }
    public static func extract(argb: [UInt32]) -> Self? {
        var sum = SIMD3<Double>.zero, count = 0.0
        var weights = Array(repeating: 0.0, count: 24), colors = Array(repeating: SIMD3<Double>.zero, count: 24)
        for pixel in argb where pixel >> 24 >= 128 {
            let color = rgb(pixel), value = hsl(color)
            sum += color; count += 1
            guard value.y >= 0.25, (0.14...0.82).contains(value.z) else { continue }
            let weight = value.y * value.y * (1 - abs(value.z - 0.5) * 1.4)
            let bin = min(23, max(0, Int(value.x / 15)))
            weights[bin] += weight; colors[bin] += color * weight
        }
        guard count > 0 else { return nil }
        let best = weights.indices.max { weights[$0] < weights[$1] }!
        return Self(dominant: packed(sum / count), vibrant: weights[best] >= count * 0.01 ? packed(colors[best] / weights[best]) : nil)
    }
    public static func atmosphere(_ palette: Self?, background: UInt32, dark: Bool, fallback: UInt32) -> Atmosphere {
        let seed = hsl(rgb(palette?.vibrant ?? fallback)), base = rgb(background)
        let saturation = min(0.62, max(0.28, seed.y))
        var lightness = dark ? 0.72 : 0.40, accent = color(hue: seed.x, saturation: saturation, lightness: dark ? 0.72 : 0.40)
        for _ in 0..<12 {
            if contrast(packed(accent), background) >= 4.5 { break }
            lightness = min(0.95, max(0.05, lightness + (dark ? 0.03 : -0.03)))
            accent = color(hue: seed.x, saturation: saturation, lightness: lightness)
        }
        let wash = color(hue: seed.x, saturation: min(0.55, max(0.2, seed.y)), lightness: dark ? 0.26 : 0.78)
        let strength = palette?.vibrant == nil ? 0.6 : 1.0
        return Atmosphere(top: packed(base + (wash - base) * (dark ? 0.78 : 0.72) * strength), middle: packed(base + (wash - base) * (dark ? 0.3 : 0.26) * strength), accent: packed(accent))
    }
    public static func contrast(_ lhs: UInt32, _ rhs: UInt32) -> Double {
        func luminance(_ pixel: UInt32) -> Double {
            let c = rgb(pixel)
            func linear(_ v: Double) -> Double { v <= 0.04045 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4) }
            return linear(c.x) * 0.2126 + linear(c.y) * 0.7152 + linear(c.z) * 0.0722
        }
        let a = luminance(lhs), b = luminance(rhs)
        return (max(a, b) + 0.05) / (min(a, b) + 0.05)
    }
    private static func rgb(_ value: UInt32) -> SIMD3<Double> { SIMD3(Double((value >> 16) & 255), Double((value >> 8) & 255), Double(value & 255)) / 255 }
    private static func packed(_ c: SIMD3<Double>) -> UInt32 {
        func byte(_ value: Double) -> UInt32 { UInt32(min(255, max(0, (value * 255).rounded()))) }
        return byte(c.x) << 16 | byte(c.y) << 8 | byte(c.z)
    }
    private static func hsl(_ c: SIMD3<Double>) -> SIMD3<Double> {
        let high = max(c.x, max(c.y, c.z)), low = min(c.x, min(c.y, c.z)), delta = high - low, lightness = (high + low) / 2
        guard delta >= 0.000001 else { return SIMD3(0, 0, lightness) }
        let hue = high == c.x ? (c.y - c.z) / delta : high == c.y ? (c.z - c.x) / delta + 2 : (c.x - c.y) / delta + 4
        return SIMD3((hue * 60 + 360).truncatingRemainder(dividingBy: 360), min(1, max(0, delta / (1 - abs(2 * lightness - 1)))), lightness)
    }
    private static func color(hue: Double, saturation: Double, lightness: Double) -> SIMD3<Double> {
        let chroma = (1 - abs(2 * lightness - 1)) * saturation, x = chroma * (1 - abs((hue / 60).truncatingRemainder(dividingBy: 2) - 1)), m = lightness - chroma / 2
        let base: SIMD3<Double>
        switch Int(hue / 60) { case 0: base = SIMD3(chroma, x, 0); case 1: base = SIMD3(x, chroma, 0); case 2: base = SIMD3(0, chroma, x); case 3: base = SIMD3(0, x, chroma); case 4: base = SIMD3(x, 0, chroma); default: base = SIMD3(chroma, 0, x) }
        return base + SIMD3(repeating: m)
    }
}
