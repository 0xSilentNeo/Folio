import Foundation
import CryptoKit
import LocalAuthentication
import UIKit

/// The kids profile (1.22.0): on or off, its limits, and its passcode.
///
/// - The passcode is the user's own, four digits, kept in the Keychain as a
///   salted SHA-256, never as the digits themselves.
/// - Five wrong tries lock the pad for 30 seconds (kept in UserDefaults, so
///   closing the app doesn't start the count again).
/// - Face ID or Touch ID can stand in for the passcode when it's allowed.
/// - Its settings are never in a preset (no registered defaults, see
///   SettingsPreset.known): importing one can't turn the profile off.
@MainActor
final class KidsProfile: ObservableObject {
    static let shared = KidsProfile()

    @Published private(set) var isOn: Bool
    @Published var limits: KidsRules.Limits {
        didSet {
            UserDefaults.standard.set(limits.film.rawValue, forKey: SettingsKey.kidsFilmLimit)
            UserDefaults.standard.set(limits.show.rawValue, forKey: SettingsKey.kidsShowLimit)
            dlog("kids", "limits now \(KidsRules.summary(limits))")
        }
    }
    @Published var allowBiometrics: Bool {
        didSet { UserDefaults.standard.set(allowBiometrics, forKey: SettingsKey.kidsBiometrics) }
    }
    /// When Settings last had to lock again (1.22.1): the profile was turned
    /// on, or Folio went to the background. A passcode given before this no
    /// longer opens them (SettingsView), even if Settings stayed open under
    /// a page pushed from them.
    @Published private(set) var relockedAt = Date()
    /// When Folio last went to the background (1.26.1): Home then closes
    /// Settings and every page opened from it while the profile is on. Not
    /// on turning the profile on: the Kids Profile page stays, its buttons
    /// asking for the passcode (relockedAt closed it then).
    @Published private(set) var backgroundedAt = Date()

    private init() {
        isOn = Self.isOnNow
        limits = Self.currentLimits
        allowBiometrics = UserDefaults.standard.object(forKey: SettingsKey.kidsBiometrics) as? Bool ?? true
        NotificationCenter.default.addObserver(forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated {
                let now = Date()
                KidsProfile.shared.relockedAt = now
                KidsProfile.shared.backgroundedAt = now
                KidsProfile.shared.biometryCache = nil
            }
        }
    }

    /// For code off the main actor (and the first frame): read straight from UserDefaults.
    nonisolated static var isOnNow: Bool { UserDefaults.standard.bool(forKey: SettingsKey.kidsProfile) }
    nonisolated static var currentLimits: KidsRules.Limits {
        let d = UserDefaults.standard
        return KidsRules.Limits(film: KidsRules.FilmLimit(rawValue: d.string(forKey: SettingsKey.kidsFilmLimit) ?? "") ?? .pg,
                                show: KidsRules.ShowLimit(rawValue: d.string(forKey: SettingsKey.kidsShowLimit) ?? "") ?? .tvPG)
    }

    /// The limits while the profile is on; nil when it's off (nothing filtered).
    var activeLimits: KidsRules.Limits? { isOn ? limits : nil }

    // MARK: On and off

    /// A passcode was chosen once: it's kept until it's changed (1.22.2;
    /// until then turning the profile on asked for a new one every time).
    var hasPasscode: Bool { Keychain.get(Self.passcodeAccount) != nil }

    /// Turned on with the passcode chosen before, or with `passcode` the
    /// first time (or after it was cleared).
    func turnOn(passcode: String? = nil) {
        if let passcode {
            guard Self.isValid(passcode) else { return }
            Keychain.set(Self.hashed(passcode, salt: Self.newSalt()), for: Self.passcodeAccount)
        }
        guard hasPasscode else { return }
        UserDefaults.standard.set(true, forKey: SettingsKey.kidsProfile)
        resetTries()
        isOn = true
        relockedAt = Date()
        ContinueSnapshotWriter.schedule()           // the widget empties
        // None of Folio's own stay pending, "Tomorrow" ones too, nor the
        // tracker's new-episode alerts (1.28.6), and no grown-up titles on the widgets.
        NotifyCenter.takeBack(asked: true)
        AiringNotifications.reschedule(TrackingStore.shared.shows)
        GlanceWriter.kidsChanged()
        dlog("kids", "kids profile on (\(KidsRules.summary(limits)))")
    }

    /// A new passcode, whether the profile is on or off. Only after the
    /// current one (or Face ID) was given just now (KidsPasscodeScreen's .change).
    func changePasscode(to passcode: String) {
        guard hasPasscode, Self.isValid(passcode) else { return }
        Keychain.set(Self.hashed(passcode, salt: Self.newSalt()), for: Self.passcodeAccount)
        resetTries()
        dlog("kids", "kids passcode changed")
    }

    /// Only right after the passcode (or Face ID) was given for it: every
    /// way out asks each time (KidsGate), never "unlocked for a while".
    func turnOff() {
        UserDefaults.standard.set(false, forKey: SettingsKey.kidsProfile)
        isOn = false
        ContinueSnapshotWriter.schedule()
        AiringNotifications.reschedule(TrackingStore.shared.shows)
        GlanceWriter.kidsChanged()
        dlog("kids", "kids profile off")
    }

    // MARK: Passcode

    static let passcodeAccount = "kidsPasscode"
    static let maxTries = 5
    static let lockout: TimeInterval = 30

    nonisolated static func isValid(_ code: String) -> Bool { code.count == 4 && code.allSatisfy { $0.isASCII && $0.isNumber } }

    nonisolated static func newSalt() -> String {
        (0..<16).map { _ in String(format: "%02x", UInt8.random(in: 0...255)) }.joined()
    }

    /// "salt$hash": what the Keychain keeps.
    nonisolated static func hashed(_ code: String, salt: String) -> String {
        let digest = SHA256.hash(data: Data("folio-kids|\(salt)|\(code)".utf8))
        return salt + "$" + digest.map { String(format: "%02x", $0) }.joined()
    }

    nonisolated static func matches(_ code: String, stored: String) -> Bool {
        guard let sep = stored.firstIndex(of: "$") else { return false }
        return hashed(code, salt: String(stored[..<sep])) == stored
    }

    /// Seconds left before the pad takes another try; nil when it does now.
    var lockedFor: TimeInterval? {
        let until = UserDefaults.standard.double(forKey: Self.lockedUntilKey)
        let left = until - Date().timeIntervalSince1970
        return left > 0 ? left : nil
    }

    enum Check: Equatable { case right, wrong(triesLeft: Int), locked(seconds: Int) }

    func check(_ code: String) -> Check {
        if let left = lockedFor { return .locked(seconds: Int(left.rounded(.up))) }
        guard let stored = Keychain.get(Self.passcodeAccount), Self.matches(code, stored: stored) else {
            let d = UserDefaults.standard
            let tries = d.integer(forKey: Self.triesKey) + 1
            dlog("kids", "wrong passcode (\(tries) of \(Self.maxTries))")
            if tries >= Self.maxTries {
                // Each lockout in a row waits longer (30 s, 1 min, 5 min,
                // 15 min, then an hour) until the right code: a fixed 30 s
                // let every code be tried in an afternoon (review, 5 Nov).
                let n = d.integer(forKey: Self.lockoutsKey)
                let wait = Self.lockout(after: n)
                d.set(n + 1, forKey: Self.lockoutsKey)
                d.set(0, forKey: Self.triesKey)
                d.set(Date().timeIntervalSince1970 + wait, forKey: Self.lockedUntilKey)
                dlog("kids", "passcode locked for \(Int(wait)) s (lockout \(n + 1) in a row)")
                return .locked(seconds: Int(wait))
            }
            d.set(tries, forKey: Self.triesKey)
            return .wrong(triesLeft: Self.maxTries - tries)
        }
        resetTries()
        return .right
    }

    private static let triesKey = "kidsPasscodeTries"
    private static let lockedUntilKey = "kidsPasscodeLockedUntil"
    private static let lockoutsKey = "kidsPasscodeLockouts"

    /// The wait after the n-th lockout in a row (0 is the first).
    nonisolated static func lockout(after n: Int) -> TimeInterval {
        let waits: [TimeInterval] = [lockout, 60, 300, 900, 3600]
        return waits[min(max(0, n), waits.count - 1)]
    }

    private func resetTries() {
        UserDefaults.standard.removeObject(forKey: Self.triesKey)
        UserDefaults.standard.removeObject(forKey: Self.lockoutsKey)
        UserDefaults.standard.removeObject(forKey: Self.lockedUntilKey)
    }

    // MARK: Face ID / Touch ID

    /// "Face ID", "Touch ID" or "Optic ID" when the device has one set up; nil otherwise.
    /// Asked of iOS once until Folio next leaves the screen (1.28.5: the
    /// passcode screen reads it as it's made, which can be often).
    var biometryName: String? {
        if let known = biometryCache { return known }
        let c = LAContext()
        var name: String?
        if c.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: nil) {
            switch c.biometryType {
            case .faceID: name = "Face ID"
            case .touchID: name = "Touch ID"
            case .opticID: name = "Optic ID"
            default: name = nil
            }
        }
        biometryCache = .some(name)
        return name
    }

    /// biometryName's answer; asked again after a trip to iOS Settings.
    private var biometryCache: String??

    /// Face ID or Touch ID instead of the passcode, when allowed. The system
    /// shows its own prompt; the answer comes back here.
    func unlockWithBiometrics(_ reason: String) async -> Bool {
        guard allowBiometrics, biometryName != nil else { return false }
        let c = LAContext()
        c.localizedFallbackTitle = "Enter Passcode"
        biometryContext = c
        defer { if biometryContext === c { biometryContext = nil } }
        do {
            let ok = try await c.evaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, localizedReason: reason)
            dlog("kids", "unlocked with \(biometryName ?? "biometrics"): \(ok)")
            if ok { resetTries() }
            return ok
        } catch {
            dlog("kids", "biometric unlock not done: \(error.localizedDescription)")
            return false
        }
    }

    /// The Face ID prompt that's up, so "Enter Passcode" can take it down.
    private var biometryContext: LAContext?

    /// Stops a Face ID check still going (1.28.5): its answer comes back as no.
    func cancelBiometrics() {
        biometryContext?.invalidate()
    }

    /// The symbol for `biometryName`, as on the Lock Screen.
    static func biometrySymbol(_ name: String?) -> String {
        switch name {
        case "Touch ID": return "touchid"
        case "Optic ID": return "opticid"
        default: return "faceid"
        }
    }
}
