import AppKit
import SwiftUI

struct IslandFrostedGlassSurface: View {
    var shape: IslandShellShape
    let reduceTransparency: Bool

    var body: some View {
        if reduceTransparency {
            shape.fill(Color.black)
        } else {
            ZStack {
                IslandFrostedGlass(shape: shape)
                shape.fill(LinearGradient(
                    colors: [.white.opacity(0.035), .black.opacity(0.12)],
                    startPoint: .topLeading, endPoint: .bottomTrailing))
            }
        }
    }
}

/// Behind-window blending samples the actual desktop through the transparent
/// panel. Keep it out of a drawing/compositing group or an opaque backing fill.
struct IslandFrostedGlass: NSViewRepresentable, Animatable {
    var shape: IslandShellShape

    var animatableData: IslandShellShape.AnimatableData {
        get { shape.animatableData }
        set { shape.animatableData = newValue }
    }

    func makeNSView(context: Context) -> EffectView {
        let view = EffectView()
        view.material = .hudWindow
        view.blendingMode = .behindWindow
        // The island is a nonactivating panel and still needs its blur while
        // the user is working in another application.
        view.state = .active
        view.appearance = NSAppearance(named: .darkAqua)
        view.setAccessibilityElement(false)
        view.apply(shape)
        return view
    }

    func updateNSView(_ view: EffectView, context: Context) {
        view.apply(shape)
    }

    final class EffectView: NSVisualEffectView {
        private var shellShape = IslandShellShape(size: .zero, topCornerRadius: 0, bottomCornerRadius: 0)
        private var lastMask: MaskGeometry?

        private struct MaskGeometry: Equatable {
            let bounds: CGRect
            let size: CGSize
            let top: CGFloat
            let bottom: CGFloat
        }

        override var isFlipped: Bool { true }

        // Decorative background must never swallow controls or file drops.
        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        func apply(_ shape: IslandShellShape) {
            shellShape = shape
            updateMaskIfNeeded()
        }

        override func layout() {
            super.layout()
            updateMaskIfNeeded()
        }

        private func updateMaskIfNeeded() {
            guard bounds.width > 0, bounds.height > 0 else { return }
            let geometry = MaskGeometry(bounds: bounds, size: shellShape.size,
                                        top: shellShape.topCornerRadius, bottom: shellShape.bottomCornerRadius)
            guard geometry != lastMask else { return }
            lastMask = geometry
            let path = shellShape.path(in: CGRect(origin: .zero, size: bounds.size)).cgPath
            // Mask the native material itself, including the clear space below
            // the compact shell. SwiftUI clipping alone can leave backdrop
            // sampling over the panel's larger, stable animation canvas.
            maskImage = NSImage(size: bounds.size, flipped: true) { _ in
                guard let context = NSGraphicsContext.current?.cgContext else { return false }
                context.setFillColor(NSColor.black.cgColor)
                context.addPath(path)
                context.fillPath()
                return true
            }
        }
    }
}
