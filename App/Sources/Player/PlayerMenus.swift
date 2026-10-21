import SwiftUI
import UIKit

// MARK: - Native (UIKit) menu button

/// UIButton that reports when its menu opens/closes, so the player can keep
/// its controls visible while a menu is up. Menu contents are built lazily
/// each time it opens, so SwiftUI updates never rebuild (or dismiss) an open menu.
final class MenuUIButton: UIButton {
    var onOpen: (() -> Void)?
    var onClose: (() -> Void)?

    override func contextMenuInteraction(_ interaction: UIContextMenuInteraction,
                                         willDisplayMenuFor configuration: UIContextMenuConfiguration,
                                         animator: UIContextMenuInteractionAnimating?) {
        super.contextMenuInteraction(interaction, willDisplayMenuFor: configuration, animator: animator)
        onOpen?()
    }

    override func contextMenuInteraction(_ interaction: UIContextMenuInteraction,
                                         willEndFor configuration: UIContextMenuConfiguration,
                                         animator: UIContextMenuInteractionAnimating?) {
        super.contextMenuInteraction(interaction, willEndFor: configuration, animator: animator)
        onClose?()
    }
}

struct MenuButton: UIViewRepresentable {
    let icon: String
    var text: String? = nil
    var size: CGFloat = 18
    let ui: PlayerUIState
    let build: () -> [UIMenuElement]

    final class Coordinator {
        var build: () -> [UIMenuElement] = { [] }
        var icon = ""
        var text: String?
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> MenuUIButton {
        let b = MenuUIButton(type: .system)
        b.showsMenuAsPrimaryAction = true
        b.tintColor = .white
        let coord = context.coordinator
        coord.build = build
        b.menu = UIMenu(children: [UIDeferredMenuElement.uncached { [weak coord] done in
            done(coord?.build() ?? [])
        }])
        let ui = self.ui
        b.onOpen = { ui.menuOpen = true; ui.showControls(autoHide: false) }
        b.onClose = { ui.menuOpen = false; ui.scheduleHide() }
        apply(to: b, coord: coord)
        return b
    }

    func updateUIView(_ b: MenuUIButton, context: Context) {
        context.coordinator.build = build
        if context.coordinator.icon != icon || context.coordinator.text != text {
            apply(to: b, coord: context.coordinator)
        }
    }

    private func apply(to b: MenuUIButton, coord: Coordinator) {
        coord.icon = icon
        coord.text = text
        var cfg = UIButton.Configuration.plain()
        cfg.baseForegroundColor = .white
        cfg.contentInsets = .zero
        if let text {
            var t = AttributedString(text)
            t.font = .systemFont(ofSize: 14, weight: .bold)
            cfg.attributedTitle = t
        } else {
            cfg.image = UIImage(systemName: icon, withConfiguration: UIImage.SymbolConfiguration(pointSize: size, weight: .semibold))
        }
        b.configuration = cfg
    }
}

// MARK: - Menu contents

@MainActor
enum PlayerMenus {
    static func check(_ on: Bool) -> UIMenuElement.State { on ? .on : .off }

    static func subtitles(_ model: PlayerModel, onLoad: @escaping () -> Void) -> [UIMenuElement] {
        let subs = model.tracks("sub")
        let selected = subs.first(where: \.selected)?.id
        var tracks: [UIMenuElement] = [
            UIAction(title: "Off", state: check(selected == nil)) { _ in model.selectTrack("sub", id: nil) },
        ]
        tracks += subs.map { t in
            UIAction(title: t.label, subtitle: t.detail.isEmpty ? nil : t.detail, state: check(t.selected)) { _ in
                model.selectTrack("sub", id: t.id)
            }
        }
        let delay = UIMenu(title: String(format: "Delay  %+.1f s", model.subDelay), image: UIImage(systemName: "timer"), children: [
            step("+0.1 s") { model.setSubDelay(model.subDelay + 0.1); model.showToast(String(format: "Subtitle delay %+.1f s", model.subDelay + 0.1)) },
            step("−0.1 s") { model.setSubDelay(model.subDelay - 0.1); model.showToast(String(format: "Subtitle delay %+.1f s", model.subDelay - 0.1)) },
            step("+1 s") { model.setSubDelay(model.subDelay + 1); model.showToast(String(format: "Subtitle delay %+.1f s", model.subDelay + 1)) },
            step("−1 s") { model.setSubDelay(model.subDelay - 1); model.showToast(String(format: "Subtitle delay %+.1f s", model.subDelay - 1)) },
            UIAction(title: "Reset") { _ in model.setSubDelay(0) },
        ])
        let size = UIMenu(title: "Size", image: UIImage(systemName: "textformat.size"), children:
            [0.75, 1.0, 1.25, 1.5, 1.75, 2.0].map { s in
                UIAction(title: "\(Int(s * 100))%") { _ in model.setSubScale(s) }
            })
        return [
            UIMenu(title: "Subtitles", options: .displayInline, children: tracks),
            UIMenu(options: .displayInline, children: [delay, size,
                UIAction(title: "Load from Files…", image: UIImage(systemName: "folder")) { _ in onLoad() }]),
        ]
    }

    static func audio(_ model: PlayerModel) -> [UIMenuElement] {
        let tracks: [UIMenuElement] = model.tracks("audio").map { t in
            UIAction(title: t.label, subtitle: t.detail, state: check(t.selected)) { _ in model.selectTrack("audio", id: t.id) }
        }
        let delay = UIMenu(title: String(format: "Delay  %+.0f ms", model.audioDelay * 1000), image: UIImage(systemName: "timer"), children: [
            step("+50 ms") { model.setAudioDelay(model.audioDelay + 0.05); model.showToast(String(format: "Audio delay %+.0f ms", (model.audioDelay + 0.05) * 1000)) },
            step("−50 ms") { model.setAudioDelay(model.audioDelay - 0.05); model.showToast(String(format: "Audio delay %+.0f ms", (model.audioDelay - 0.05) * 1000)) },
            UIAction(title: "Reset") { _ in model.setAudioDelay(0) },
        ])
        var footer: [UIMenuElement] = [delay]
        if !model.audioOut.isEmpty {
            let out = AudioFormat.channelLayout(channels: model.audioOut, count: nil) ?? model.audioOut
            footer.append(UIAction(title: "Output: \(out)", attributes: .disabled) { _ in })
        }
        return [
            UIMenu(title: "Audio", options: .displayInline, children: tracks.isEmpty
                   ? [UIAction(title: "No audio", attributes: .disabled) { _ in }] : tracks),
            UIMenu(options: .displayInline, children: footer),
        ]
    }

    static func speed(_ model: PlayerModel) -> [UIMenuElement] {
        let speeds: [Double] = [0.5, 0.75, 1.0, 1.25, 1.5, 1.75, 2.0, 2.5, 3.0]
        let current = speeds.min(by: { abs($0 - model.speed) < abs($1 - model.speed) }) ?? 1
        let speedItems: [UIMenuElement] = speeds.map { s in
            UIAction(title: s == 1 ? "Normal" : String(format: "%g×", s), state: check(s == current)) { _ in model.setSpeed(s) }
        }
        let holdItems: [UIMenuElement] = [1.5, 2.0, 2.5, 3.0, 4.0].map { s in
            UIAction(title: String(format: "%g×", s), state: check(abs(model.holdSpeed - s) < 0.01)) { _ in
                model.holdSpeed = s
                model.holdEnabled = true
            }
        }
        let hold = UIMenu(title: "Hold to speed up", image: UIImage(systemName: "hand.tap"), children: [
            UIAction(title: "Press and hold the video", state: check(model.holdEnabled)) { _ in model.holdEnabled.toggle() },
            UIMenu(title: "Hold speed", options: .displayInline, children: holdItems),
        ])
        return [
            UIMenu(title: "Speed", options: .displayInline, children: speedItems),
            UIMenu(options: .displayInline, children: [hold]),
        ]
    }

    static func more(_ model: PlayerModel, ui: PlayerUIState) -> [UIMenuElement] {
        var items: [UIMenuElement] = []

        // Chapters + your own markers
        var chapterItems: [UIMenuElement] = model.chapters.map { ch in
            UIAction(title: ch.title, subtitle: PlayerModel.format(ch.time), state: check(ch.id == model.currentChapter)) { _ in model.jump(to: ch) }
        }
        let mine: [UIMenuElement] = model.userMarkers.map { m in
            UIMenu(title: m.title, subtitle: PlayerModel.format(m.time), image: UIImage(systemName: "bookmark.fill"), children: [
                UIAction(title: "Jump here", image: UIImage(systemName: "arrow.right")) { _ in model.seek(to: m.time) },
                UIAction(title: "Remove", image: UIImage(systemName: "trash"), attributes: .destructive) { _ in model.removeMarker(m) },
            ])
        }
        if !mine.isEmpty { chapterItems.append(UIMenu(title: "My markers", options: .displayInline, children: mine)) }
        chapterItems.append(UIAction(title: "Add marker here", image: UIImage(systemName: "bookmark.circle")) { _ in model.addMarker() })
        items.append(UIMenu(title: "Chapters & markers", image: UIImage(systemName: "list.bullet"), children: chapterItems))

        // Progress bar look
        let prefs = SeekBarPrefs.shared
        let styles: [(String, String)] = [("Ticks", "ticks"), ("Dots", "dots"), ("Segments", "segments"), ("Hidden", "none")]
        let colors: [(String, String)] = [("White", "white"), ("Pink", "accent"), ("Yellow", "yellow"), ("Cyan", "cyan")]
        items.append(UIMenu(title: "Progress bar", image: UIImage(systemName: "slider.horizontal.below.rectangle"), children: [
            UIMenu(title: "Chapter markers", options: .displayInline, children: styles.map { s in
                UIAction(title: s.0, state: check(prefs.markerStyle == s.1)) { _ in prefs.markerStyle = s.1 }
            }),
            UIMenu(title: "Marker colour", options: .displayInline, children: colors.map { c in
                UIAction(title: c.0, state: check(prefs.markerColor == c.1)) { _ in prefs.markerColor = c.1 }
            }),
            UIMenu(options: .displayInline, children: [
                UIAction(title: "Chapter name while scrubbing", state: check(prefs.showChapterTitle)) { _ in prefs.showChapterTitle.toggle() },
                UIAction(title: "Show skip segments", state: check(prefs.showSkipSegments)) { _ in prefs.showSkipSegments.toggle() },
            ]),
        ]))

        // Video
        let aspects: [(String, String)] = [("Auto", "no"), ("16:9", "16:9"), ("4:3", "4:3"), ("2.35:1", "2.35:1"), ("1:1", "1:1")]
        items.append(UIMenu(title: "Video", image: UIImage(systemName: "aspectratio"), children: [
            UIMenu(title: "Aspect ratio", options: .displayInline, children: aspects.map { a in
                UIAction(title: a.0, state: check(model.aspectOverride == a.1)) { _ in model.setAspect(a.1) }
            }),
            UIMenu(options: .displayInline, children: [
                UIAction(title: "Deband") { _ in model.run(command: "cycle deband") },
                UIAction(title: "Deinterlace") { _ in model.run(command: "cycle deinterlace") },
                UIAction(title: "Rotate 90°") { _ in model.run(command: "cycle-values video-rotate 90 180 270 0") },
            ]),
        ]))

        // Shaders
        let files = MPVFiles.shaders()
        var shaderItems: [UIMenuElement] = [
            UIAction(title: "Off", state: check(model.activeShaders.isEmpty)) { _ in model.setShaders([]) },
        ]
        shaderItems += ShaderPresets.available(files: files).map { p in
            UIAction(title: p.name, state: check(model.activeShaders == p.shaders)) { _ in model.setShaders(p.shaders) }
        }
        if files.isEmpty {
            shaderItems.append(UIAction(title: "Add shaders in Settings → Shaders", attributes: .disabled) { _ in })
        } else {
            shaderItems.append(UIMenu(title: "Individual", options: .displayInline, children: files.map { f in
                let name = f.lastPathComponent
                return UIAction(title: name, state: check(model.activeShaders.contains(name))) { _ in
                    var list = model.activeShaders
                    if let i = list.firstIndex(of: name) { list.remove(at: i) } else { list.append(name) }
                    model.setShaders(list)
                }
            }))
        }
        items.append(UIMenu(title: "Shaders", image: UIImage(systemName: "wand.and.stars"), children: shaderItems))

        // Commands
        var cmds: [UIMenuElement] = ScriptCommandStore.all.map { c in
            UIAction(title: c.name, subtitle: c.command) { _ in model.run(command: c.command) }
        }
        cmds.append(UIAction(title: "Run mpv command…", image: UIImage(systemName: "terminal")) { _ in ui.showConsole = true })
        items.append(UIMenu(title: "Commands", image: UIImage(systemName: "command"), children: cmds))

        items.append(UIMenu(options: .displayInline, children: [
            UIAction(title: "Screenshot", image: UIImage(systemName: "camera")) { _ in model.screenshot() },
            UIAction(title: "Media info", image: UIImage(systemName: "info.circle")) { _ in ui.showInfo = true },
        ]))
        return items
    }

    private static func step(_ title: String, _ action: @escaping () -> Void) -> UIAction {
        UIAction(title: title, attributes: .keepsMenuPresented) { _ in action() }
    }
}
