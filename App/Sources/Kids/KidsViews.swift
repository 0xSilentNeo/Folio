import SwiftUI

// MARK: - The passcode pad

/// Four dots and a number pad. `onEntered` gets each full code; it returns
/// a message to show under the dots (wrong code, locked), or nil when the
/// code was right (or taken).
struct PasscodePad: View {
    let title: String
    var message: String? = nil
    /// "Face ID" or "Touch ID": a button for it beside 0.
    var biometry: String? = nil
    var onBiometry: (() -> Void)? = nil
    let onEntered: (String) -> String?

    @State private var code = ""
    @State private var note: String?
    @State private var shake: CGFloat = 0

    var body: some View {
        VStack(spacing: 22) {
            VStack(spacing: 8) {
                Image(systemName: "lock.fill").font(.system(size: 24, weight: .semibold)).foregroundStyle(Theme.accent)
                Text(title).font(.title3.weight(.semibold)).multilineTextAlignment(.center).padding(.horizontal, 24)
                // Two lines kept for it, so the dots and keys don't move when it appears.
                Text(note ?? message ?? " ").font(.footnote).foregroundStyle(.secondary).multilineTextAlignment(.center)
                    .lineLimit(2).frame(minHeight: 36, alignment: .top).padding(.horizontal, 24)
            }
            HStack(spacing: 18) {
                ForEach(0..<4, id: \.self) { i in
                    Circle()
                        .strokeBorder(Theme.accent, lineWidth: 1.5)
                        .background(Circle().fill(i < code.count ? Theme.accent : .clear))
                        .frame(width: 14, height: 14)
                }
            }
            .modifier(Shake(amount: shake))
            .accessibilityElement()
            .accessibilityLabel("\(code.count) of 4 digits entered")
            Grid(horizontalSpacing: 22, verticalSpacing: 14) {
                ForEach(0..<3) { row in
                    GridRow { ForEach(1...3, id: \.self) { col in key(String(row * 3 + col)) } }
                }
                GridRow {
                    if let biometry, let onBiometry {
                        Button(action: onBiometry) {
                            Image(systemName: biometry == "Touch ID" ? "touchid" : biometry == "Optic ID" ? "opticid" : "faceid")
                                .font(.system(size: 24)).frame(width: 72, height: 72)
                        }
                        .buttonStyle(PressStyle())
                        .accessibilityLabel("Use \(biometry)")
                    } else {
                        Color.clear.frame(width: 72, height: 72)
                    }
                    key("0")
                    Button { if !code.isEmpty { code.removeLast() } } label: {
                        Image(systemName: "delete.left").font(.system(size: 22)).frame(width: 72, height: 72)
                    }
                    .buttonStyle(PressStyle())
                    .accessibilityLabel("Delete")
                    .opacity(code.isEmpty ? 0.3 : 1)
                }
            }
            .foregroundStyle(.primary)
        }
        .padding(.vertical, 12)
    }

    private func key(_ d: String) -> some View {
        Button { type(d) } label: {
            Text(d).font(.system(size: 30, weight: .regular, design: .rounded))
                .frame(width: 72, height: 72)
                .background(Theme.fill, in: Circle())
        }
        .buttonStyle(PressStyle())
        .accessibilityIdentifier("pin" + d)
    }

    private func type(_ d: String) {
        guard code.count < 4 else { return }
        code += d
        guard code.count == 4 else { return }
        let entered = code
        // A moment with four dots, then the answer.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) {
            let answer = onEntered(entered)
            code = ""
            note = answer
            if answer != nil {
                UINotificationFeedbackGenerator().notificationOccurred(.error)
                withAnimation(.linear(duration: 0.4)) { shake += 1 }
            }
        }
    }
}

private struct Shake: GeometryEffect {
    var amount: CGFloat
    var animatableData: CGFloat {
        get { amount }
        set { amount = newValue }
    }
    func effectValue(size: CGSize) -> ProjectionTransform {
        ProjectionTransform(CGAffineTransform(translationX: 9 * sin(amount * .pi * 6), y: 0))
    }
}

// MARK: - Unlocking

/// The passcode (or Face ID) asked for in place: Settings while the kids
/// profile is on, leaving the profile.
struct KidsUnlock: View {
    let title: String
    let reason: String
    let unlocked: () -> Void
    @ObservedObject private var kids = KidsProfile.shared
    @State private var triedBiometry = false

    var body: some View {
        let bio = kids.allowBiometrics ? kids.biometryName : nil
        PasscodePad(title: title, message: kids.lockedFor.map { "Too many tries. Try again in \(Int($0.rounded(.up))) s." },
                    biometry: bio, onBiometry: bio == nil ? nil : { useBiometry() }) { code in
            switch kids.check(code) {
            case .right:
                unlocked()
                return nil
            case .wrong(let left):
                return left == 1 ? "Wrong passcode. One more try before a 30-second wait." : "Wrong passcode."
            case .locked(let s):
                return "Too many tries. Try again in \(s) s."
            }
        }
        .onAppear {
            // Face ID at once, the way the Lock Screen does; once per visit.
            guard bio != nil, !triedBiometry else { return }
            triedBiometry = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { useBiometry() }
        }
    }

    private func useBiometry() {
        Task { if await kids.unlockWithBiometrics(reason) { unlocked() } }
    }
}

/// Leaving the kids profile from Home: the passcode in a sheet.
struct KidsLeaveSheet: View {
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        NavigationStack {
            KidsUnlock(title: "Enter the passcode to leave the kids profile", reason: "Leave the kids profile") {
                KidsProfile.shared.turnOff()
                dismiss()
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(HomeBackdrop().ignoresSafeArea())
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
        }
    }
}

/// Setting the passcode: typed twice.
struct KidsSetPasscodeSheet: View {
    let done: (String) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var first: String?

    var body: some View {
        NavigationStack {
            Group {
                if let first {
                    PasscodePad(title: "Enter it again", message: "To be sure it's the one you meant.") { code in
                        guard code == first else {
                            self.first = nil
                            return "They didn't match. Start again."
                        }
                        done(code)
                        dismiss()
                        return nil
                    }
                    .id("confirm")
                } else {
                    PasscodePad(title: "Choose a 4-digit passcode",
                                message: "It's asked for to open Settings and to leave the kids profile. Folio can't show it again.") { code in
                        first = code
                        return nil
                    }
                    .id("first")
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(HomeBackdrop().ignoresSafeArea())
            .navigationTitle("Kids Profile")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
        }
        .interactiveDismissDisabled(first != nil)
    }
}

// MARK: - Settings → Kids profile

struct KidsProfileSettings: View {
    @ObservedObject private var kids = KidsProfile.shared
    @State private var settingPasscode = false

    var body: some View {
        Form {
            Section {
                if kids.isOn {
                    Label("The kids profile is on", systemImage: "figure.and.child.holdinghands")
                    Button("Turn Off Kids Profile", role: .destructive) { kids.turnOff() }
                } else {
                    Button { settingPasscode = true } label: { Label("Turn On Kids Profile…", systemImage: "figure.and.child.holdinghands") }
                }
            } footer: {
                Text(kids.isOn
                     ? "Settings lock when you close them, and stay locked behind the passcode until you turn the profile off."
                     : "Discover, search and your library show only titles rated for kids, Settings are locked behind a 4-digit passcode, and leaving the profile needs it too. You choose the passcode when you turn it on.")
            }
            Section {
                Picker("Films up to", selection: $kids.limits.film) {
                    ForEach(KidsRules.FilmLimit.allCases) { Text($0.rawValue).tag($0) }
                }
                Picker("Shows up to", selection: $kids.limits.show) {
                    ForEach(KidsRules.ShowLimit.allCases) { Text($0.rawValue).tag($0) }
                }
            } header: { Text("Ratings") } footer: {
                Text("Titles rated above these are hidden. Other countries' ratings count as their nearest match (12A and M as PG-13). A title with no rating goes by its genres: family, kids and animation (not anime) count as G. Anything Folio knows nothing about is hidden.")
            }
            if let name = kids.biometryName {
                Section {
                    Toggle("Unlock with \(name)", isOn: $kids.allowBiometrics)
                } footer: { Text("\(name) can stand in for the passcode. Anyone whose face or finger this device knows can then unlock.") }
            }
        }
        .brandListBackground()
        .navigationTitle("Kids Profile")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $settingPasscode) { KidsSetPasscodeSheet { kids.turnOn(passcode: $0) } }
    }
}

/// Settings while the kids profile is on, until the passcode is entered.
struct SettingsLocked: View {
    let unlocked: () -> Void
    var body: some View {
        ScrollView {
            VStack(spacing: 6) {
                Text("Settings are locked").font(.headline).padding(.top, 24)
                Text("The kids profile is on.").font(.subheadline).foregroundStyle(.secondary)
                KidsUnlock(title: "Enter the passcode", reason: "Open Settings", unlocked: unlocked)
                    .padding(.top, 8)
            }
            .frame(maxWidth: .infinity)
        }
        .background(HomeBackdrop().ignoresSafeArea())
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
    @State private var leaving = false
    var body: some View {
        Button { leaving = true } label: {
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
        .sheet(isPresented: $leaving) { KidsLeaveSheet() }
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
