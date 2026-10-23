import SwiftUI

enum Theme {
    static let accent = Color(red: 1.0, green: 0.48, blue: 0.66)          // sakura
    static let accentSoft = Color(red: 1.0, green: 0.48, blue: 0.66).opacity(0.18)
    static let background = Color(red: 0.04, green: 0.05, blue: 0.08)
    static let card = Color(red: 0.09, green: 0.10, blue: 0.15)
    static let cardHighlight = Color(red: 0.13, green: 0.14, blue: 0.21)
    static let secondaryText = Color.white.opacity(0.6)
    static let gradient = LinearGradient(colors: [Color(red: 1.0, green: 0.48, blue: 0.66), Color(red: 0.62, green: 0.45, blue: 1.0)],
                                         startPoint: .topLeading, endPoint: .bottomTrailing)
}

/// Frosted "glass" background. Uses Liquid Glass on iOS 26 when built with
/// the iOS 26 SDK, material blur otherwise.
struct GlassBackground: ViewModifier {
    var cornerRadius: CGFloat = 18
    var interactive = false

    @ViewBuilder
    func body(content: Content) -> some View {
        #if compiler(>=6.2)
        if #available(iOS 26.0, *) {
            if interactive {
                content.glassEffect(.regular.interactive(), in: .rect(cornerRadius: cornerRadius))
                    .contentShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            } else {
                content.glassEffect(.regular, in: .rect(cornerRadius: cornerRadius))
            }
        } else {
            fallback(content)
        }
        #else
        fallback(content)
        #endif
    }

    private func fallback(_ content: Content) -> some View {
        content
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous).strokeBorder(.white.opacity(0.12), lineWidth: 0.5))
    }
}

struct GlassCircle: ViewModifier {
    @ViewBuilder
    func body(content: Content) -> some View {
        #if compiler(>=6.2)
        if #available(iOS 26.0, *) {
            // contentShape: the whole circle is the button. Without it a tap on
            // the interactive glass (not on the icon) went to the glass effect
            // and the button's action never ran — the title page's Back button
            // only worked when you hit the chevron itself.
            content.glassEffect(.regular.interactive(), in: .circle).contentShape(Circle())
        } else {
            content.background(.ultraThinMaterial, in: Circle())
                .overlay(Circle().strokeBorder(.white.opacity(0.12), lineWidth: 0.5))
        }
        #else
        content.background(.ultraThinMaterial, in: Circle())
            .overlay(Circle().strokeBorder(.white.opacity(0.12), lineWidth: 0.5))
        #endif
    }
}

extension View {
    func glass(cornerRadius: CGFloat = 18, interactive: Bool = false) -> some View {
        modifier(GlassBackground(cornerRadius: cornerRadius, interactive: interactive))
    }
    func glassCircle() -> some View { modifier(GlassCircle()) }
}

/// Simple async image with a placeholder.
struct PosterImage: View {
    let url: String?
    var aspect: CGFloat = 2.0 / 3.0
    var cornerRadius: CGFloat = 12

    var body: some View {
        Color.clear
            .aspectRatio(aspect, contentMode: .fit)
            .overlay {
                if let url, let u = URL(string: url) {
                    CachedImage(url: u, maxPixel: 700) { $0.resizable().scaledToFill() } placeholder: { placeholder }
                } else {
                    placeholder
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
    }

    private var placeholder: some View {
        ZStack {
            Theme.card
            Image(systemName: "film").font(.title2).foregroundStyle(.white.opacity(0.25))
        }
    }
}

extension Int64 {
    var byteString: String { ByteCountFormatter.string(fromByteCount: self, countStyle: .file) }
}
