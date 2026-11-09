import SwiftUI

/// Records a Now Playing row's frame in its list (the "nowPlayingList" space), by key.
struct RowFrame: ViewModifier {
    let key: String
    @Binding var frames: [String: CGRect]

    func body(content: Content) -> some View {
        content.onGeometryChange(for: CGRect.self) { $0.frame(in: .named("nowPlayingList")) } action: { f in
            if frames[key] != f { frames[key] = f }
        }
    }
}
