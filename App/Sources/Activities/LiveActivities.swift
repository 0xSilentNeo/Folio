import ActivityKit
import UIKit

/// Live Activities (1.22.0): downloads (DownloadActivity) and what's playing
/// (NowPlayingActivity), on the Lock Screen and in the Dynamic Island. One
/// switch for both: Settings → Downloads → Live Activities (on by default).
/// The widget extension draws them (App/Widget/Extension).
@MainActor
enum LiveActivities {
    private static let authorization = ActivityAuthorizationInfo()
    private static var started = false
    /// iOS's switch, read again each time Folio comes back to the screen
    /// (where it's changed): the downloads activity asks several times a second.
    private static var systemAllows = authorization.areActivitiesEnabled

    /// Folio's switch, and iOS's own (Settings → Folio → Live Activities).
    static var enabled: Bool {
        UserDefaults.standard.bool(forKey: SettingsKey.liveActivities) && systemAllows
    }

    /// Off in iOS Settings, whatever Folio's switch says.
    static var blockedBySystem: Bool { !authorization.areActivitiesEnabled }

    /// iOS starts an activity only for an app on screen; one already
    /// running can be updated and ended from the background.
    static var canStart: Bool { UIApplication.shared.applicationState != .background }

    /// At launch (DownloadManager): a now-playing activity left from the last
    /// run goes (the player isn't open yet); the downloads one is picked up
    /// again (Folio is often relaunched in the background for its downloads).
    static func start() {
        guard !started else { return }
        started = true
        NowPlayingActivity.launch()
        DownloadActivity.shared.start()
        // Back on screen: an activity that couldn't start in the background can now.
        NotificationCenter.default.addObserver(forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated {
                systemAllows = authorization.areActivitiesEnabled
                NowPlayingActivity.becameActive()
                DownloadActivity.shared.refresh()
            }
        }
        if CommandLine.arguments.contains("-labLiveActivities") { lab(nowPlaying: !CommandLine.arguments.contains("-labDownloadsOnly")) }
    }

    /// Settings → Downloads → Live Activities was switched.
    static func settingChanged() {
        dlog("activity", "Live Activities \(UserDefaults.standard.bool(forKey: SettingsKey.liveActivities) ? "on" : "off")")
        NowPlayingActivity.settingChanged()
        DownloadActivity.shared.refresh()
    }

    // MARK: Pictures

    /// About a Lock Screen activity's artwork at 3x on its short side. The
    /// extension draws it as it is: a bigger picture costs memory it has little of.
    nonisolated static let picturePixels: CGFloat = 180

    /// Saves `image`, small, for the extension (LiveActivityFiles), off the
    /// main thread, and deletes older pictures with the same prefix. Returns
    /// its file name; nil without the App Group.
    nonisolated static func savePicture(_ image: UIImage, prefix: String) async -> String? {
        await Task.detached(priority: .utility) { () -> String? in
            guard let dir = LiveActivityFiles.directory(create: true) else { return nil }
            let px = CGSize(width: image.size.width * image.scale, height: image.size.height * image.scale)
            let short = min(px.width, px.height)
            guard short >= 1 else { return nil }
            let k = min(1, LiveActivities.picturePixels / short)
            let size = CGSize(width: max(1, (px.width * k).rounded()), height: max(1, (px.height * k).rounded()))
            let format = UIGraphicsImageRendererFormat()
            format.scale = 1
            format.opaque = true
            let data = UIGraphicsImageRenderer(size: size, format: format).jpegData(withCompressionQuality: 0.8) { _ in
                image.draw(in: CGRect(origin: .zero, size: size))
            }
            // A new name each time: the extension may keep the old picture by name.
            let name = "\(prefix)-\(UUID().uuidString.prefix(8)).jpg"
            do { try data.write(to: dir.appendingPathComponent(name), options: .atomic) } catch { return nil }
            let fm = FileManager.default
            for old in (try? fm.contentsOfDirectory(atPath: dir.path)) ?? [] where old.hasPrefix(prefix + "-") && old != name {
                try? fm.removeItem(at: dir.appendingPathComponent(old))
            }
            return name
        }.value
    }

    /// The picture's colour for the activity's glow and ring ("RRGGBB",
    /// 1.22.1), off the main thread: its average, made bright and a little
    /// more vivid so it reads as light on the dark glass. Nil for a picture
    /// with hardly any colour (the widget's warm light then).
    nonisolated static func tint(of image: UIImage) async -> String? {
        await Task.detached(priority: .utility) { () -> String? in
            guard let cg = image.cgImage else { return nil }
            var px = [UInt8](repeating: 0, count: 4)
            let ok = px.withUnsafeMutableBytes { buf -> Bool in
                guard let ctx = CGContext(data: buf.baseAddress, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                                          space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
                ctx.interpolationQuality = .medium
                ctx.draw(cg, in: CGRect(x: 0, y: 0, width: 1, height: 1))
                return true
            }
            guard ok else { return nil }
            return tintHex(red: Double(px[0]) / 255, green: Double(px[1]) / 255, blue: Double(px[2]) / 255)
        }.value
    }

    /// An average colour made into a glow: nil when it's nearly grey.
    nonisolated static func tintHex(red: Double, green: Double, blue: Double) -> String? {
        var h: CGFloat = 0, s: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        UIColor(red: red, green: green, blue: blue, alpha: 1).getHue(&h, saturation: &s, brightness: &b, alpha: &a)
        guard s >= 0.12 else { return nil }
        let c = UIColor(hue: h, saturation: min(0.75, s * 1.35 + 0.1), brightness: max(0.85, b), alpha: 1)
        var r: CGFloat = 0, g: CGFloat = 0, bl: CGFloat = 0
        c.getRed(&r, green: &g, blue: &bl, alpha: &a)
        return String(format: "%02X%02X%02X", Int((r * 255).rounded()), Int((g * 255).rounded()), Int((bl * 255).rounded()))
    }

    // MARK: Lab

    /// -labLiveActivities: both activities with sample content, to see them
    /// in the simulator (with -labDownloadsOnly, the downloads one alone:
    /// the Dynamic Island shows the now-playing one first). The now-playing
    /// buttons work on the sample.
    private static func lab(nowPlaying: Bool) {
        dlog("activity", "lab: sample activities")
        DownloadActivity.shared.lab()
        guard nowPlaying else { return }
        let size = CGSize(width: 320, height: 180)
        let art = UIGraphicsImageRenderer(size: size).image { ctx in
            let colors = [UIColor(red: 0.36, green: 0.30, blue: 0.24, alpha: 1).cgColor, UIColor(red: 0.08, green: 0.07, blue: 0.07, alpha: 1).cgColor]
            if let g = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors as CFArray, locations: [0, 1]) {
                ctx.cgContext.drawLinearGradient(g, start: .zero, end: CGPoint(x: size.width, y: size.height), options: [])
            }
        }
        NowPlayingActivity.start(id: NowPlayingActivity.labID, title: "Lab Show", subtitle: "S1 · E3 · The Lab Episode",
                                 duration: 1440, position: 300, paused: false, artwork: art)
    }
}
