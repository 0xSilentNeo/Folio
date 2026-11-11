import SwiftUI

// MARK: - The passcode screen

/// What a code typed on the passcode screen gets.
enum PasscodeAnswer {
    /// Right: the circles stay full while the screen goes.
    case accepted
    /// Taken, and another code is asked for (a new passcode's second entry).
    case next
    /// Wrong: a shake and a buzz, then empty circles.
    case wrong
}

/// The passcode as the Lock Screen asks for it (1.22.1): the title, four
/// circles, a 3×4 pad of large round translucent keys with their letters,
/// Cancel that becomes Delete once a digit is in, and Face ID at the bottom
/// left when it may stand in. White on a blurred dark background, whatever
/// the app's appearance. Every place the kids passcode is asked for or
/// chosen shows it (KidsPasscodeScreen); until 1.22.1 each had a small pad
/// of its own.
///
/// 1.28.5: while Face ID looks (`scanning`), only its symbol and a way to
/// the passcode show, as on the Lock Screen; the keys come in when it
/// gives up. The keys are the Lock Screen's size: a fifth of the screen's
/// width (75 pt on a 375 pt phone, 88 pt on a Pro Max).
struct PasscodeScreen: View {
    let title: String
    /// Under the circles: what it's for, or what went wrong.
    var message: String?
    /// "Face ID", "Touch ID" or "Optic ID": its button, bottom left.
    var biometry: String?
    var onBiometry: () -> Void = {}
    /// Face ID is looking: its symbol instead of the circles, no keys yet.
    var scanning = false
    /// "Enter Passcode" while Face ID looks: the keys now.
    var onSkipBiometry: () -> Void = {}
    /// Too many wrong tries: the keys wait.
    var locked = false
    let onCancel: () -> Void
    let onEntered: (String) -> PasscodeAnswer

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var code = ""
    @State private var shakes: CGFloat = 0
    /// From the fourth digit until the answer is in: no more typing.
    @State private var busy = false

    /// The letters under the digits, as on a phone's keypad.
    private static let letters = ["", "ABC", "DEF", "GHI", "JKL", "MNO", "PQRS", "TUV", "WXYZ"]

    var body: some View {
        GeometryReader { geo in
            // A phone on its side has no room for the pad under the title: side by side then.
            let landscape = geo.size.width > geo.size.height && geo.size.height < 600
            let key = Self.keySize(geo.size, landscape: landscape)
            Group {
                if landscape {
                    HStack(spacing: 0) {
                        VStack(spacing: 0) {
                            Spacer(minLength: 8)
                            header(key)
                            Spacer(minLength: 8)
                            bottomBar(key)
                        }
                        .padding(.bottom, 8)
                        .frame(maxWidth: .infinity)
                        keypad(key).frame(maxWidth: .infinity)
                    }
                } else {
                    VStack(spacing: 0) {
                        Spacer(minLength: 12).frame(maxHeight: 110)
                        header(key)
                        Spacer().frame(height: key * 0.55)
                        keypad(key)
                        Spacer(minLength: 12)
                        bottomBar(key)
                    }
                    .padding(.bottom, 4)
                }
            }
            .frame(width: geo.size.width, height: geo.size.height)
            // The keys come in as on the Lock Screen when Face ID gives up.
            .animation(reduceMotion ? .easeOut(duration: 0.2) : .spring(duration: 0.4, bounce: 0.2), value: scanning)
        }
        .foregroundStyle(.white)
        .background(PasscodeBackground())
        .environment(\.colorScheme, .dark)
        .dynamicTypeSize(...DynamicTypeSize.xxLarge)
    }

    /// A key's size: the Lock Screen's, a fifth of the screen's width (75 pt
    /// on a 375 pt phone, 88 pt on a 6.9" one); smaller where it's short.
    static func keySize(_ size: CGSize, landscape: Bool) -> CGFloat {
        landscape
            ? max(52, min(80, (size.height - 3 * 12 - 24) / 4))
            : max(56, min(90, size.width / 5, (size.height - 300) / 4.8))
    }

    /// The title and circles, with Face ID's symbol over them while it looks.
    /// Both are laid out the whole time, so nothing moves when the keys come.
    private func header(_ key: CGFloat) -> some View {
        passcodeHeader(key)
            .opacity(scanning ? 0 : 1)
            .accessibilityHidden(scanning)
            .overlay {
                if scanning {
                    VStack(spacing: 14) {
                        Image(systemName: KidsProfile.biometrySymbol(biometry))
                            .font(.system(size: key * 0.6, weight: .light))
                            .symbolEffect(.pulse, isActive: !reduceMotion)
                            .accessibilityHidden(true)
                        Text(biometry ?? "Face ID").font(.title3)
                            .accessibilityAddTraits(.isHeader)
                            .accessibilityIdentifier("passcodeScanning")
                    }
                    .transition(.opacity)
                }
            }
    }

    private func passcodeHeader(_ key: CGFloat) -> some View {
        VStack(spacing: 0) {
            // Text styles, not fixed sizes (1.27.0), so they grow up to the screen's cap.
            Text(title).font(.title3).multilineTextAlignment(.center)
                .accessibilityAddTraits(.isHeader)
                .accessibilityIdentifier("passcodeTitle")
            dots(key).padding(.top, 20)
            // Two lines kept for it, so nothing moves when it appears.
            Text(message ?? " ").font(.subheadline).foregroundStyle(.white.opacity(0.75))
                .multilineTextAlignment(.center)
                .lineLimit(2, reservesSpace: true)
                .padding(.top, 14).padding(.horizontal, 32)
                .accessibilityIdentifier("passcodeMessage")
        }
    }

    private func dots(_ key: CGFloat) -> some View {
        HStack(spacing: key * 0.3) {
            ForEach(0..<4, id: \.self) { i in
                Circle().strokeBorder(.white, lineWidth: 1.2)
                    .background(Circle().fill(i < code.count ? Color.white : .clear))
                    .frame(width: key * 0.16, height: key * 0.16)
            }
        }
        .modifier(Shake(amount: shakes))
        // The wrong-passcode buzz (1.28.8: SwiftUI's own), with the shake.
        .sensoryFeedback(.error, trigger: shakes)
        .accessibilityElement()
        .accessibilityLabel("\(code.count) of 4 digits entered")
        .accessibilityIdentifier("passcodeDots")
    }

    /// The Lock Screen's spacing: 28 pt across and 15 down between 75 pt keys.
    private func keypad(_ size: CGFloat) -> some View {
        VStack(spacing: size * 0.2) {
            ForEach(0..<3, id: \.self) { row in
                HStack(spacing: size * 0.37) { ForEach(1...3, id: \.self) { col in key(row * 3 + col, size) } }
            }
            key(0, size)
        }
        .opacity(scanning ? 0 : locked ? 0.4 : 1)
        .scaleEffect(scanning && !reduceMotion ? 0.88 : 1)
        .allowsHitTesting(!scanning)
        .accessibilityHidden(scanning)
    }

    private func key(_ n: Int, _ size: CGFloat) -> some View {
        Button { type(String(n)) } label: {
            VStack(spacing: 0) {
                Text("\(n)").font(.system(size: size * 0.46))
                // 1 and 0 have no letters; the line is kept so every digit sits level.
                Text(n >= 2 ? Self.letters[n - 1] : " ")
                    .font(.system(size: size * 0.125, weight: .bold)).tracking(size * 0.025)
                    .padding(.top, -size * 0.04)
            }
            .frame(width: size, height: size)
            .contentShape(Circle())
        }
        .buttonStyle(KeyStyle())
        .disabled(locked)
        .accessibilityLabel("\(n)")
        .accessibilityIdentifier("pin\(n)")
    }

    /// Where the Lock Screen has Emergency and Cancel: under the 7 and the 9.
    private func bottomBar(_ size: CGFloat) -> some View {
        HStack(spacing: size * 0.37) {
            if scanning {
                // Under the 7 and the 8: the passcode instead of Face ID.
                Button("Enter Passcode", action: onSkipBiometry)
                    .frame(width: size * 2.37)
                    .accessibilityIdentifier("passcodeSkipBiometry")
            } else {
                Group {
                    if let biometry {
                        Button(biometry, action: onBiometry).accessibilityIdentifier("passcodeBiometry")
                    } else {
                        Color.clear
                    }
                }
                .frame(width: size)
                Color.clear.frame(width: size, height: 1)
            }
            Button(code.isEmpty || scanning ? "Cancel" : "Delete") {
                if code.isEmpty || scanning { onCancel() } else if !busy { code.removeLast() }
            }
            .frame(width: size)
            .accessibilityIdentifier(code.isEmpty || scanning ? "passcodeCancel" : "passcodeDelete")
        }
        .font(.body)
        .lineLimit(1).minimumScaleFactor(0.7)
        .buttonStyle(.plain)
        .frame(height: 44)
    }

    private func type(_ d: String) {
        guard !busy, !locked, !scanning, code.count < 4 else { return }
        code += d
        guard code.count == 4 else { return }
        busy = true
        let entered = code
        // A moment with four full circles, then the answer.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
            switch onEntered(entered) {
            case .accepted:
                break
            case .next:
                code = ""
                busy = false
            case .wrong:
                UIAccessibility.post(notification: .announcement, argument: "Wrong passcode")
                withAnimation(.linear(duration: 0.45)) { shakes += 1 }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) {
                    code = ""
                    busy = false
                }
            }
        }
    }
}

/// A key as the Lock Screen's: on iOS 26 clear Liquid Glass that bends
/// what's behind it and swells under the finger (1.22.2; it was a flat
/// translucent disc). Before iOS 26 it lights up and fades back.
private struct KeyStyle: ButtonStyle {
    @ViewBuilder
    func makeBody(configuration: Configuration) -> some View {
        #if compiler(>=6.2)
        if #available(iOS 26.0, *) {
            // contentShape: the whole key takes the tap, not only its digits (see GlassCircle).
            configuration.label
                .glassEffect(.clear.interactive(), in: .circle)
                .contentShape(Circle())
        } else {
            flat(configuration)
        }
        #else
        flat(configuration)
        #endif
    }

    private func flat(_ configuration: Configuration) -> some View {
        configuration.label
            .background(Circle().fill(.white.opacity(configuration.isPressed ? 0.5 : 0.15)))
            .animation(configuration.isPressed ? nil : .easeOut(duration: 0.4), value: configuration.isPressed)
    }
}

/// What's under the passcode screen, blurred and dimmed. Lighter than
/// before 1.22.2, so the glass keys have the page to bend, as the Lock
/// Screen's have the wallpaper.
struct PasscodeBackground: View {
    var body: some View {
        ZStack {
            Rectangle().fill(.ultraThinMaterial)
            Color.black.opacity(0.3)
        }
        .environment(\.colorScheme, .dark)
        .ignoresSafeArea()
    }
}

private struct Shake: GeometryEffect {
    var amount: CGFloat
    var animatableData: CGFloat {
        get { amount }
        set { amount = newValue }
    }
    func effectValue(size: CGSize) -> ProjectionTransform {
        ProjectionTransform(CGAffineTransform(translationX: 10 * sin(amount * .pi * 6), y: 0))
    }
}

// MARK: - The kids passcode

/// What the kids passcode is asked for.
enum KidsPasscodePurpose: Equatable {
    /// The passcode (or Face ID) before a way out of the profile. `reason`
    /// goes under the circles and in Face ID's prompt.
    case unlock(reason: String)
    /// The first time the profile is turned on: a new passcode, entered twice.
    case choose
    /// The current passcode (or Face ID), then a new one twice.
    case change
}

/// The passcode screen for the kids profile: checks the passcode
/// (KidsProfile.check, with its 30-second wait after five wrong tries),
/// offers Face ID first when it may stand in, and takes a new passcode twice.
struct KidsPasscodeScreen: View {
    let purpose: KidsPasscodePurpose
    let cancel: () -> Void
    /// Said yes: nil for .unlock, the new passcode for .choose and .change.
    let done: (String?) -> Void

    private enum Step: Equatable { case current, new, confirm(String) }
    @State private var step: Step
    @State private var note: String?
    /// Seconds left of the wait after too many tries.
    @State private var waitLeft: Int?
    @State private var waitGeneration = 0
    @State private var biometryName: String?
    /// Face ID is looking: the keys stay hidden until it gives up (1.28.5).
    @State private var scanning: Bool
    @State private var finished = false
    @ObservedObject private var kids = KidsProfile.shared

    init(purpose: KidsPasscodePurpose, cancel: @escaping () -> Void, done: @escaping (String?) -> Void) {
        self.purpose = purpose
        self.cancel = cancel
        self.done = done
        _step = State(initialValue: purpose == .choose ? .new : .current)
        // Known before the first frame, so the keys don't show and go.
        let kids = KidsProfile.shared
        let name = purpose != .choose && kids.allowBiometrics && kids.lockedFor == nil ? kids.biometryName : nil
        _biometryName = State(initialValue: name)
        _scanning = State(initialValue: name != nil)
    }

    private var title: String {
        switch step {
        case .current: return "Enter Passcode"
        case .new: return "Enter New Passcode"
        case .confirm: return "Re-enter New Passcode"
        }
    }

    /// What it's for, in words for the screen and for Face ID's prompt.
    private var reason: String {
        switch purpose {
        case .unlock(let r): return r
        case .choose: return "To turn on the kids profile"
        case .change: return "To change the kids passcode"
        }
    }

    private var message: String? {
        if let s = waitLeft { return "Too many tries. Try again in \(s) s." }
        if let note { return note }
        // Only what went wrong, as on the Lock Screen's pad: nothing else under
        // the circles (the reason is still Face ID's prompt).
        return nil
    }

    var body: some View {
        PasscodeScreen(title: title, message: message,
                       biometry: step == .current && kids.allowBiometrics ? biometryName : nil,
                       onBiometry: useBiometry, scanning: scanning, onSkipBiometry: skipBiometry,
                       locked: waitLeft != nil, onCancel: cancel, onEntered: entered)
            .task {
                if biometryName == nil, purpose != .choose { biometryName = kids.biometryName }
                // Face ID first, as the Lock Screen does: once the screen is up.
                guard scanning else { return }
                try? await Task.sleep(for: .milliseconds(350))
                if Task.isCancelled || !scanning { return }
                useBiometry()
            }
            .onDisappear { kids.cancelBiometrics() }
            .task(id: waitGeneration) {
                // The wait after five wrong tries counts down here (it's kept across launches).
                while let left = kids.lockedFor, !Task.isCancelled {
                    waitLeft = Int(left.rounded(.up))
                    try? await Task.sleep(nanoseconds: 1_000_000_000)
                }
                waitLeft = nil
            }
    }

    private func entered(_ code: String) -> PasscodeAnswer {
        guard !finished else { return .accepted }
        switch step {
        case .current:
            switch kids.check(code) {
            case .right:
                note = nil
                if purpose == .change { step = .new; return .next }
                finish(nil)
                return .accepted
            case .wrong(let left):
                note = left == 1 ? "Wrong passcode. One more try before a 30-second wait." : "Wrong passcode."
                return .wrong
            case .locked:
                note = nil
                waitGeneration += 1
                return .wrong
            }
        case .new:
            note = nil
            step = .confirm(code)
            return .next
        case .confirm(let first):
            guard code == first else {
                note = "The passcodes didn't match. Try again."
                step = .new
                return .wrong
            }
            finish(code)
            return .accepted
        }
    }

    /// Face ID's own prompt: a second try is offered there; when it gives up
    /// (or Cancel or Enter Passcode is chosen in it) the keys come in.
    private func useBiometry() {
        let why = reason
        Task {
            let ok = await kids.unlockWithBiometrics(why)
            guard !finished else { return }
            guard ok else {
                scanning = false
                return
            }
            if purpose == .change {
                note = nil
                step = .new
                scanning = false
            } else {
                // The screen goes with the symbol still up: no keys flash past.
                finish(nil)
            }
        }
    }

    private func skipBiometry() {
        scanning = false
        kids.cancelBiometrics()
    }

    private func finish(_ code: String?) {
        guard !finished else { return }
        finished = true
        done(code)
    }
}

/// A way out of the kids profile, or a new passcode (1.22.1). The passcode
/// screen comes up each time one is wanted: no "unlocked for this visit".
/// `then` runs once it said yes, with the new passcode for .choose and .change.
struct KidsGate: Identifiable {
    let id = UUID()
    let purpose: KidsPasscodePurpose
    let then: (String?) -> Void

    /// Without a sheet's slide: the pad comes up in place, as the Lock Screen's
    /// does. On the next turn of the run loop: asked for from a rating
    /// picker's menu while the menu was still closing, the pad never showed
    /// (simulator run, 3 Nov).
    @MainActor
    static func open(_ gate: Binding<KidsGate?>, _ purpose: KidsPasscodePurpose, then: @escaping (String?) -> Void) {
        let g = KidsGate(purpose: purpose, then: then)
        DispatchQueue.main.async {
            withTransaction(\.disablesAnimations, true) { gate.wrappedValue = g }
        }
    }

    @MainActor
    static func close(_ gate: Binding<KidsGate?>) {
        withTransaction(\.disablesAnimations, true) { gate.wrappedValue = nil }
    }
}

extension View {
    /// The passcode screen over the whole app, with the page under it
    /// blurred, while `gate` is set.
    func kidsPasscode(_ gate: Binding<KidsGate?>) -> some View {
        fullScreenCover(item: gate) { g in
            KidsPasscodeCover(gate: g, binding: gate)
                .presentationBackground(.clear)
        }
    }
}

private struct KidsPasscodeCover: View {
    let gate: KidsGate
    let binding: Binding<KidsGate?>

    var body: some View {
        KidsPasscodeScreen(purpose: gate.purpose) {
            KidsGate.close(binding)
        } done: { code in
            KidsGate.close(binding)
            // After the screen has gone: what it opens can remove the view it hangs on (Home's badge).
            DispatchQueue.main.async { gate.then(code) }
        }
        // A container of its own: without it the identifier replaced every
        // key's ("pin2" was "kidsPasscode").
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("kidsPasscode")
    }
}

// MARK: - Settings → Kids profile

struct KidsProfileSettings: View {
    @ObservedObject private var kids = KidsProfile.shared
    @State private var gate: KidsGate?

    var body: some View {
        Form {
            Section {
                if kids.isOn {
                    Label("The kids profile is on", systemImage: "figure.and.child.holdinghands")
                    changePasscodeButton
                } else {
                    Button {
                        // The passcode chosen the first time stays (1.22.2): turning on asks for nothing.
                        if kids.hasPasscode {
                            kids.turnOn()
                        } else {
                            KidsGate.open($gate, .choose) { code in if let code { kids.turnOn(passcode: code) } }
                        }
                    } label: { Label(kids.hasPasscode ? "Turn On Kids Profile" : "Turn On Kids Profile…", systemImage: "figure.and.child.holdinghands") }
                    .accessibilityIdentifier("kidsTurnOn")
                    if kids.hasPasscode { changePasscodeButton }
                }
            } footer: {
                Text(kids.isOn
                     ? "Settings, turning the profile off, and changing its ratings or passcode each ask for the passcode, every time."
                     : kids.hasPasscode
                     ? "Discover, search and your library show only titles rated for kids, and Settings and leaving the profile need your passcode. It stays the same until you change it."
                     : "Discover, search and your library show only titles rated for kids, Settings are locked behind a 4-digit passcode, and leaving the profile needs it too. You choose the passcode the first time, and it stays until you change it.")
            }
            Section {
                Picker("Films up to", selection: limit(\.film)) {
                    ForEach(KidsRules.FilmLimit.allCases) { Text($0.rawValue).tag($0) }
                }
                Picker("Shows up to", selection: limit(\.show)) {
                    ForEach(KidsRules.ShowLimit.allCases) { Text($0.rawValue).tag($0) }
                }
            } header: { Text("Ratings") } footer: {
                Text("Titles rated above these are hidden. Other countries' ratings count as their nearest match (12A and M as PG-13). A title with no rating goes by its genres: family, kids and animation (not anime) count as G. Anything Folio knows nothing about is hidden.")
            }
            if let name = kids.biometryName {
                Section {
                    Toggle("Unlock with \(name)", isOn: biometrics)
                } footer: { Text("\(name) can stand in for the passcode. Anyone whose face or finger this device knows can then unlock.") }
            }
            // 1.26.1: on its own at the end, away from Change Passcode.
            if kids.isOn {
                Section {
                    Button("Turn Off Kids Profile", role: .destructive) {
                        KidsGate.open($gate, .unlock(reason: "To turn off the kids profile")) { _ in kids.turnOff() }
                    }
                    .accessibilityIdentifier("kidsTurnOff")
                }
            }
        }
        .brandListBackground()
        .navigationTitle("Kids Profile")
        .navigationBarTitleDisplayMode(.inline)
        .kidsPasscode($gate)
    }

    private var changePasscodeButton: some View {
        Button("Change Passcode…") {
            KidsGate.open($gate, .change) { code in if let code { kids.changePasscode(to: code) } }
        }
        .accessibilityIdentifier("kidsChangePasscode")
    }

    /// A rating limit. While the profile is on, a new one is kept only after
    /// the passcode; until then (and on Cancel) the picker shows the old one.
    private func limit<T: Equatable>(_ key: WritableKeyPath<KidsRules.Limits, T>) -> Binding<T> {
        Binding {
            kids.limits[keyPath: key]
        } set: { value in
            guard kids.limits[keyPath: key] != value else { return }
            guard kids.isOn else { kids.limits[keyPath: key] = value; return }
            KidsGate.open($gate, .unlock(reason: "To change the kids profile's ratings")) { _ in kids.limits[keyPath: key] = value }
        }
    }

    /// Face ID in place of the passcode: changed only with the passcode while the profile is on.
    private var biometrics: Binding<Bool> {
        Binding {
            kids.allowBiometrics
        } set: { value in
            guard kids.isOn else { kids.allowBiometrics = value; return }
            KidsGate.open($gate, .unlock(reason: value ? "To let Face ID or Touch ID unlock the kids profile" : "To change how the kids profile unlocks")) { _ in
                kids.allowBiometrics = value
            }
        }
    }
}

/// Settings while the kids profile is on (1.22.1): the passcode screen over
/// them each time they open, until the passcode or Face ID is given. Cancel
/// goes back.
struct SettingsLocked: View {
    let cancel: () -> Void
    let unlocked: () -> Void
    var body: some View {
        KidsPasscodeScreen(purpose: .unlock(reason: "To open Settings"), cancel: cancel) { _ in unlocked() }
            .background(HomeBackdrop().ignoresSafeArea())
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("settingsLocked")
    }
}

// MARK: - Pieces for the pages it filters

/// A title page the kids profile doesn't allow (opened by a link or from
/// another device): what it is rated, and nothing to play.
struct KidsBlockedView: View {
    let verdict: KidsRules.Verdict
    var body: some View {
        ContentUnavailableView {
            Label("Not in the kids profile", systemImage: "hand.raised")
        } description: {
            switch verdict {
            case .above(let r): Text("This title is rated \(r), above what the kids profile allows.")
            default: Text("Folio doesn't know this title's rating, so the kids profile hides it.")
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(HomeBackdrop().ignoresSafeArea())
        .accessibilityIdentifier("kidsBlocked")
    }
}

/// On Home while the kids profile is on; a tap asks for the passcode to leave it.
struct KidsBadge: View {
    @State private var gate: KidsGate?
    var body: some View {
        Button {
            KidsGate.open($gate, .unlock(reason: "To leave the kids profile")) { _ in KidsProfile.shared.turnOff() }
        } label: {
            Label("Kids", systemImage: "figure.and.child.holdinghands")
                .font(.subheadline.weight(.semibold))
                .padding(.horizontal, 12).frame(height: 44)
                .glass(cornerRadius: 22, interactive: true)
        }
        .buttonStyle(PressStyle())
        .foregroundStyle(.primary)
        .accessibilityLabel("Kids profile on")
        .accessibilityHint("Asks for the passcode to leave it")
        .accessibilityIdentifier("kidsBadge")
        .kidsPasscode($gate)
    }
}

/// The line under a list the kids profile filters.
struct KidsFilterNote: View {
    let limits: KidsRules.Limits
    var body: some View {
        Label("Kids profile: titles rated \(KidsRules.summary(limits))", systemImage: "figure.and.child.holdinghands")
            .font(.caption).foregroundStyle(.secondary)
    }
}
