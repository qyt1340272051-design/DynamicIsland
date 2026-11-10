import AppKit
import SwiftUI

enum IslandAppearance: String, CaseIterable, Identifiable {
    case classic
    case coverGlass
    case coverGlow
    case frostedGlass

    static let defaultsKey = "island.appearance"
    var id: Self { self }

    var title: String {
        switch self {
        case .classic: "默认外观"
        case .coverGlass: "封面流光"
        case .coverGlow: "封面光晕"
        case .frostedGlass: "透明毛玻璃"
        }
    }

    var detail: String {
        switch self {
        case .classic: "纯黑背景，与屏幕顶部自然融合。"
        case .coverGlass: "封面的整体色彩从封面处透过磨砂玻璃，柔和晕染到背景板。随歌曲封面变化，无封面时使用深色背景。"
        case .coverGlow: "封面的整体色彩从封面位置向四周散发柔光，越远越暗，渐变融入默认黑色背景。随歌曲封面变化，无封面时恢复纯黑。"
        case .frostedGlass: "桌面与后方窗口透过半透明玻璃柔和模糊，保留清晰的文字与操作。适用于所有页面；开启系统“减少透明度”时使用实色背景。"
        }
    }
}

/// Blurs the complete artwork rather than averaging it to a single tint.
/// The opaque backing keeps desktop content out of the music's glass surface.
struct IslandCoverGlass: View {
    let artwork: NSImage
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        GeometryReader { geometry in
            let size = geometry.size
            ZStack {
                Color.black
                Image(nsImage: artwork)
                    .resizable()
                    .interpolation(.medium)
                    .frame(width: size.width * 1.18, height: size.height * 1.4)
                    .blur(radius: size.height * 0.22, opaque: true)
                    .frame(width: size.width, height: size.height)
                    .clipped()
                    .mask {
                        LinearGradient(colors: [.white, .white.opacity(0.85), .white.opacity(0.5)],
                                       startPoint: .leading, endPoint: .trailing)
                    }
                    .id(ObjectIdentifier(artwork))
                    .transition(.opacity)
                // A soft glass veil above the color, with a darker reading area.
                LinearGradient(colors: [.white.opacity(0.10), .white.opacity(0.025), .clear],
                               startPoint: .topLeading, endPoint: .bottomTrailing)
                LinearGradient(colors: [.black.opacity(0.28), .black.opacity(0.48)],
                               startPoint: .top, endPoint: .bottom)
            }
            .animation(reduceMotion ? nil : .easeInOut(duration: 0.45), value: ObjectIdentifier(artwork))
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}
