import SwiftUI

/// The Settings tiles' colours (1.26.3): earthy tones that sit with Folio's
/// cream and ink and its clay action colour, instead of iOS's rainbow. Dark
/// mode lifts each a little so it keeps its shape on the dark cards; a white
/// glyph stays above 4:1 on every one (light values: clay 5.2, brick 7.3,
/// ochre 4.0, olive 5.3, sage 4.8, pine 6.8, slate 6.4, plum 7.3,
/// graphite 7.4, sand 4.5).
enum SettingsPalette {
    static let clay = Color(light: 0xB0502E, dark: 0xBE5C38)
    static let brick = Color(light: 0x93392B, dark: 0xA84634)
    static let ochre = Color(light: 0xA8742A, dark: 0xA8742A)
    static let olive = Color(light: 0x66713F, dark: 0x76824A)
    static let sage = Color(light: 0x5E7A5A, dark: 0x6A8866)
    static let pine = Color(light: 0x2F6460, dark: 0x3B7772)
    static let slate = Color(light: 0x4A6080, dark: 0x587094)
    static let plum = Color(light: 0x744866, dark: 0x8A5779)
    static let graphite = Color(light: 0x5A5550, dark: 0x6E6862)
    static let sand = Color(light: 0x8A7458, dark: 0x947E62)

    /// Every one, in a fixed order (placeholder art picks from them).
    static let all: [Color] = [clay, brick, ochre, olive, sage, pine, slate, plum, graphite, sand]
}
