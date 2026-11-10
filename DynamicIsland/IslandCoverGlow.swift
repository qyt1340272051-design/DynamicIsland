import AppKit
import SwiftUI

/// Resolve the visible cover's actual bounds, including native control layout,
/// compact wing placement and the current display scale.
struct IslandArtworkBoundsPreferenceKey: PreferenceKey {
    static var defaultValue: Anchor<CGRect>? { nil }

    static func reduce(value: inout Anchor<CGRect>?, nextValue: () -> Anchor<CGRect>?) {
        if let next = nextValue() { value = next }
    }
}

/// A coarse cover palette radiates from the cover itself and disappears into
/// an opaque black backing. No desktop sampling or repeating animation is used.
struct IslandCoverGlow: View {
    let artwork: NSImage
    let sourceRect: CGRect
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var palette = CoverGlowPalette.empty
    @State private var hasPalette = false

    var body: some View {
        GeometryReader { geometry in
            let side = max(sourceRect.width, sourceRect.height)
            let radius = side * 1.8
            ZStack {
                Color.black
                ForEach(palette.colors.indices, id: \.self) { index in
                    let offset = CoverGlowPalette.offsets[index]
                    RadialGradient(stops: [
                        .init(color: palette.colors[index].color.opacity(0.34), location: 0),
                        .init(color: palette.colors[index].color.opacity(0.24), location: 0.25),
                        .init(color: palette.colors[index].color.opacity(0.08), location: 0.55),
                        .init(color: .clear, location: 1)
                    ], center: .center, startRadius: 0, endRadius: radius)
                    .frame(width: radius * 2, height: radius * 2)
                    .position(x: sourceRect.midX + offset.x * side * 0.2,
                              y: sourceRect.midY + offset.y * side * 0.2)
                }
            }
            .frame(width: geometry.size.width, height: geometry.size.height)
            .clipped()
            .animation(reduceMotion ? nil : .easeInOut(duration: 0.45), value: palette)
        }
        // The provider already owns the decoded, bounded NSImage. Sample only
        // when that image changes, never on progress ticks or layout updates.
        .task(id: ObjectIdentifier(artwork)) {
            let next = CoverGlowPalette(artwork: artwork)
            if hasPalette {
                palette = next
            } else {
                // A newly inserted light already has its own opacity
                // transition; do not also grow its color out of black.
                var transaction = Transaction(animation: nil)
                transaction.disablesAnimations = true
                withTransaction(transaction) {
                    palette = next
                    hasPalette = true
                }
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

private struct CoverGlowPalette: Equatable {
    struct RGB: Equatable {
        let red: Double
        let green: Double
        let blue: Double

        var color: Color { Color(.sRGB, red: red, green: green, blue: blue) }
    }

    static let offsets = [CGPoint(x: -1, y: -1), CGPoint(x: 1, y: -1),
                          CGPoint(x: -1, y: 1), CGPoint(x: 1, y: 1)]
    static let empty = CoverGlowPalette(colors: Array(repeating: RGB(red: 0, green: 0, blue: 0), count: 4))
    let colors: [RGB]

    private init(colors: [RGB]) { self.colors = colors }

    init(artwork: NSImage) {
        guard let image = artwork.cgImage(forProposedRect: nil, context: nil, hints: nil),
              let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) else {
            self = .empty
            return
        }
        // A 20 x 20 sample retains broad regional colors without cover detail.
        // Four quadrants avoid turning contrasting cover colors into one gray.
        let side = 20
        var pixels = [UInt8](repeating: 0, count: side * side * 4)
        let sampled = pixels.withUnsafeMutableBytes { bytes in
            guard let context = CGContext(data: bytes.baseAddress, width: side, height: side,
                                          bitsPerComponent: 8, bytesPerRow: side * 4,
                                          space: colorSpace,
                                          bitmapInfo: CGBitmapInfo.byteOrder32Big.rawValue
                                            | CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            context.interpolationQuality = .low
            context.draw(image, in: CGRect(x: 0, y: 0, width: side, height: side))
            return true
        }
        guard sampled else { self = .empty; return }

        colors = (0..<4).map { quadrant in
            let startX = quadrant % 2 * (side / 2)
            let startY = quadrant / 2 * (side / 2)
            var red = 0.0, green = 0.0, blue = 0.0, total = 0.0
            for y in startY..<(startY + side / 2) {
                for x in startX..<(startX + side / 2) {
                    let index = (y * side + x) * 4
                    let alpha = Double(pixels[index + 3]) / 255
                    guard alpha > 0 else { continue }
                    let r = min(1, Double(pixels[index]) / 255 / alpha)
                    let g = min(1, Double(pixels[index + 1]) / 255 / alpha)
                    let b = min(1, Double(pixels[index + 2]) / 255 / alpha)
                    // Give colored highlights a little more influence than
                    // black margins, while preserving neutral and dark covers.
                    let weight = alpha * (0.25 + 0.75 * max(r, g, b))
                    red += r * weight
                    green += g * weight
                    blue += b * weight
                    total += weight
                }
            }
            guard total > 0 else { return RGB(red: 0, green: 0, blue: 0) }
            return RGB(red: red / total, green: green / total, blue: blue / total)
        }
    }
}
