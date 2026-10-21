import Foundation

/// Bundled Anime4K (MIT) shader chains, following the mode table in the
/// Anime4K README: A for most 1080p anime, B for blurrier sources, C for
/// noisy/older ones; the doubled modes (A+A, B+B, C+A) restore twice.
enum Anime4KMode: String, CaseIterable, Identifiable {
    case off, a, b, c, aa, bb, ca
    var id: String { rawValue }

    var title: String {
        switch self {
        case .off: return "Off"
        case .a: return "Mode A"
        case .b: return "Mode B"
        case .c: return "Mode C"
        case .aa: return "Mode A+A"
        case .bb: return "Mode B+B"
        case .ca: return "Mode C+A"
        }
    }

    var hint: String {
        switch self {
        case .off: return "No anime processing"
        case .a: return "Most 1080p anime"
        case .b: return "Soft or blurry sources"
        case .c: return "Noisy or old sources"
        case .aa: return "Mode A, restored twice (sharpest)"
        case .bb: return "Mode B, restored twice"
        case .ca: return "Denoise, then restore"
        }
    }
}

enum Anime4KQuality: String, CaseIterable, Identifiable {
    case fast, balanced, high
    var id: String { rawValue }
    var title: String { rawValue.capitalized }
    var hint: String {
        switch self {
        case .fast: return "Light on the GPU and battery"
        case .balanced: return "Larger networks, 1080p and below"
        case .high: return "Heaviest; may drop frames"
        }
    }
    /// (first-pass size, second-pass size)
    var sizes: (String, String) {
        switch self {
        case .fast: return ("M", "S")
        case .balanced: return ("L", "M")
        case .high: return ("VL", "M")
        }
    }
}

enum Anime4K {
    static var mode: Anime4KMode {
        get { Anime4KMode(rawValue: UserDefaults.standard.string(forKey: SettingsKey.anime4kMode) ?? "off") ?? .off }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: SettingsKey.anime4kMode) }
    }
    static var quality: Anime4KQuality {
        get { Anime4KQuality(rawValue: UserDefaults.standard.string(forKey: SettingsKey.anime4kQuality) ?? "fast") ?? .fast }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: SettingsKey.anime4kQuality) }
    }

    static var bundleDir: URL? { Bundle.main.resourceURL?.appendingPathComponent("shaders", isDirectory: true) }

    /// Shader file names, in order, for a mode and quality.
    static func chain(mode: Anime4KMode, quality: Anime4KQuality) -> [String] {
        let (p1, p2) = quality.sizes
        let clamp = "Anime4K_Clamp_Highlights"
        let down = ["Anime4K_AutoDownscalePre_x2", "Anime4K_AutoDownscalePre_x4"]
        let up2 = "Anime4K_Upscale_CNN_x2_\(p2)"
        let names: [String]
        switch mode {
        case .off: return []
        case .a: names = [clamp, "Anime4K_Restore_CNN_\(p1)", "Anime4K_Upscale_CNN_x2_\(p1)"] + down + [up2]
        case .b: names = [clamp, "Anime4K_Restore_CNN_Soft_\(p1)", "Anime4K_Upscale_CNN_x2_\(p1)"] + down + [up2]
        case .c: names = [clamp, "Anime4K_Upscale_Denoise_CNN_x2_\(p1)"] + down + [up2]
        case .aa: names = [clamp, "Anime4K_Restore_CNN_\(p1)", "Anime4K_Upscale_CNN_x2_\(p1)", "Anime4K_Restore_CNN_\(p2)"] + down + [up2]
        case .bb: names = [clamp, "Anime4K_Restore_CNN_Soft_\(p1)", "Anime4K_Upscale_CNN_x2_\(p1)"] + down + ["Anime4K_Restore_CNN_Soft_\(p2)", up2]
        case .ca: names = [clamp, "Anime4K_Upscale_Denoise_CNN_x2_\(p1)"] + down + ["Anime4K_Restore_CNN_\(p2)", up2]
        }
        return names.map { $0 + ".glsl" }
    }

    static func paths(mode: Anime4KMode, quality: Anime4KQuality) -> [String] {
        guard let dir = bundleDir else { return [] }
        return chain(mode: mode, quality: quality)
            .map { dir.appendingPathComponent($0).path }
            .filter { FileManager.default.fileExists(atPath: $0) }
    }

    /// Full `glsl-shaders` value: Anime4K chain first, then the user's own shaders.
    static func currentShaderList() -> String {
        (paths(mode: mode, quality: quality) + MPVFiles.activeShaderPaths).joined(separator: ":")
    }
}

/// "Enhanced Quality": mpv's high-quality scaling and processing set,
/// roughly what desktop users enable with profile=high-quality.
enum EnhancedQuality {
    static let options: [(String, String)] = [
        ("scale", "ewa_lanczossharp"),
        ("cscale", "ewa_lanczossharp"),
        ("dscale", "mitchell"),
        ("correct-downscaling", "yes"),
        ("linear-downscaling", "yes"),
        ("sigmoid-upscaling", "yes"),
        ("deband", "yes"),
        ("deband-iterations", "2"),
        ("deband-threshold", "35"),
        ("dither-depth", "auto"),
    ]
    static let defaults: [(String, String)] = [
        ("scale", "lanczos"), ("cscale", "lanczos"), ("dscale", "hermite"),
        ("correct-downscaling", "no"), ("linear-downscaling", "no"), ("sigmoid-upscaling", "no"),
        ("deband", "no"), ("deband-iterations", "1"), ("deband-threshold", "48"), ("dither-depth", "no"),
    ]
}
