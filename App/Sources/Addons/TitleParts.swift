import SwiftUI

/// Horizontal strip of cast members: round headshot, actor, character.
struct CastStrip: View {
    let credits: [CastMember]
    @Environment(\.openURL) private var openURL

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                Text("Cast").font(.title3.weight(.bold))
                Text("\(credits.count)").font(.subheadline).foregroundStyle(.secondary)
            }
            .padding(.horizontal, 16)
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(alignment: .top, spacing: 14) {
                    ForEach(credits) { c in
                        Button {
                            if let u = c.imdbURL { openURL(u) }
                        } label: {
                            VStack(spacing: 6) {
                                ZStack {
                                    Circle().fill(Theme.card)
                                    if let p = c.photo, let u = URL(string: p) {
                                        CachedImage(url: u, maxPixel: 180) { $0.resizable().scaledToFill() } placeholder: { initials(c.name) }
                                    } else {
                                        initials(c.name)
                                    }
                                }
                                .frame(width: 72, height: 72)
                                .clipShape(Circle())
                                .overlay(Circle().strokeBorder(Theme.hairline, lineWidth: 1))
                                Text(c.name).font(.caption.weight(.semibold)).foregroundStyle(.primary).lineLimit(2)
                                if let ch = c.character {
                                    Text(ch).font(.caption2).foregroundStyle(.secondary).lineLimit(2)
                                }
                            }
                            .frame(width: 84)
                            .multilineTextAlignment(.center)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 16)
            }
        }
    }

    private func initials(_ name: String) -> some View {
        Text(name.split(separator: " ").prefix(2).compactMap { $0.first }.map(String.init).joined())
            .font(.headline).foregroundStyle(.secondary)
    }
}

/// "Wikipedia · IMDb" buttons under a title. Wikipedia is resolved through
/// Wikipedia's own search (cached); until then the button opens that search.
struct TitleLinks: View {
    let name: String
    var year: String?
    let type: String
    var imdbID: String?
    @State private var wiki: URL?
    @Environment(\.openURL) private var openURL

    var body: some View {
        HStack(spacing: 10) {
            link("Wikipedia", symbol: "W") { openURL(wiki ?? Wikipedia.searchURL(name: name, year: year, type: type)) }
            if let imdbID, imdbID.hasPrefix("tt"), let u = URL(string: "https://www.imdb.com/title/\(imdbID)/") {
                link("IMDb", symbol: "i") { openURL(u) }
            }
        }
        .task(id: name) { wiki = await Wikipedia.article(name: name, year: year, type: type) }
    }

    private func link(_ title: String, symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Text(symbol).font(.system(size: 13, weight: .heavy, design: .serif))
                    .frame(width: 22, height: 22).background(Theme.fill, in: Circle())
                Text(title).font(.subheadline.weight(.semibold))
                Image(systemName: "arrow.up.right").font(.caption2.weight(.bold)).foregroundStyle(.secondary)
            }
            .foregroundStyle(.primary)
            .padding(.leading, 8).padding(.trailing, 14).frame(height: 40)
            .glass(cornerRadius: 20, interactive: true)
        }
        .buttonStyle(PressStyle())
    }
}
