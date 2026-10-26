import SwiftUI
import UIKit

/// Controlled experiment for the CI simulator (launch argument `-popLab`):
/// shows the same small menu presented six different ways, each labelled on
/// screen, so the screen recording shows which presentation morphs out of its
/// button.
@MainActor
enum PopLab {
    static var enabled: Bool { CommandLine.arguments.contains("-popLab") }
    /// UI test: just show the lab screen; the test presses its toolbar items.
    static var isStatic: Bool { CommandLine.arguments.contains("-popLabStatic") }
    private static var vc: PopLabViewController?

    static func start() {
        guard enabled else { return }
        dlog("lab", "pop lab")
        if isStatic { DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { open() }; return }
        let steps: [(Double, () -> Void)] = [
            (1.5, { open() }),
            (3.0, { vc?.run(1) }), (5.0, { vc?.dismissAll() }),
            (6.5, { vc?.run(2) }), (8.5, { vc?.dismissAll() }),
            (10.0, { vc?.run(3) }), (12.0, { vc?.dismissAll() }),
            (13.5, { vc?.run(4) }), (15.5, { vc?.dismissAll() }),
            (17.0, { vc?.run(5) }), (19.0, { vc?.dismissAll() }),
            (20.5, { vc?.run(6) }), (22.5, { vc?.dismissAll() }),
            (24.0, { vc?.run(7) }), (26.0, { vc?.dismissAll() }),
            (27.5, { vc?.run(8) }), (29.5, { vc?.dismissAll() }),
            (31.0, { vc?.run(9) }), (31.8, { vc?.segment(2) }), (32.8, { vc?.segment(1) }), (33.8, { vc?.segment(0) }),
            (35.0, { vc?.label.text = "done"; dlog("lab", "pop lab done") }),
        ]
        for (t, a) in steps { DispatchQueue.main.asyncAfter(deadline: .now() + t, execute: a) }
    }

    private static func open() {
        guard let scene = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).first,
              let root = scene.windows.first(where: { $0.isKeyWindow })?.rootViewController else { dlog("lab/error", "no root"); return }
        let v = PopLabViewController()
        v.modalPresentationStyle = .fullScreen
        root.present(v, animated: false)
        vc = v
    }
}

final class PopLabState: ObservableObject {
    @Published var swiftUIPopover = false
    @Published var presentInUpdate = false
}

struct PopLabContent: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Audio").font(.headline)
            ForEach(["English · TrueHD 5.1", "English · AC-3 5.1", "Commentary", "Off"], id: \.self) { s in
                HStack(spacing: 10) { Image(systemName: "checkmark.circle"); Text(s) }
            }
        }
        .foregroundStyle(.white)
        .padding(20)
        .frame(width: 300, alignment: .leading)
    }
}

/// SwiftUI side: V5 (SwiftUI `.popover`) and V6 (UIKit present called from
/// inside a SwiftUI update, which is how the player presented panels).
struct PopLabSwiftUI: View {
    @ObservedObject var state: PopLabState
    let presentFromUpdate: () -> Void
    var body: some View {
        HStack(spacing: 24) {
            Button { state.swiftUIPopover.toggle() } label: {
                Image(systemName: "list.bullet").font(.system(size: 18, weight: .semibold)).foregroundStyle(.white).frame(width: 46, height: 46)
            }
            .glassCircle()
            .popover(isPresented: $state.swiftUIPopover, arrowEdge: .bottom) {
                PopLabContent().presentationCompactAdaptation(.popover)
            }
            Text("SwiftUI").font(.caption).foregroundStyle(.white.opacity(0.6))
        }
        .onChange(of: state.presentInUpdate) { _, on in if on { presentFromUpdate() } }
    }
}

final class PopLabDelegate: NSObject, UIPopoverPresentationControllerDelegate {
    static let shared = PopLabDelegate()
    func adaptivePresentationStyle(for controller: UIPresentationController, traitCollection: UITraitCollection) -> UIModalPresentationStyle { .none }
    func adaptivePresentationStyle(for controller: UIPresentationController) -> UIModalPresentationStyle { .none }
}

final class PopLabViewController: UIViewController {
    let label = UILabel()
    private let pill = PanelPillUIView(height: 46)
    private let plainAnchor = UIView()
    private let state = PopLabState()
    private var host: UIHostingController<PopLabSwiftUI>!
    private let toolbar = UIToolbar()
    private var barItems: [UIBarButtonItem] = []
    private let seg = UISegmentedControl(items: ["Playlist", "Chapters", "Markers"])

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = UIColor(red: 0.12, green: 0.14, blue: 0.18, alpha: 1)
        // Background stripes so glass lensing is visible.
        for i in 0..<12 {
            let s = UIView(frame: CGRect(x: 0, y: CGFloat(i) * 70, width: 2000, height: 34))
            s.backgroundColor = UIColor(hue: CGFloat(i) / 12, saturation: 0.5, brightness: 0.45, alpha: 1)
            view.addSubview(s)
        }
        label.font = .systemFont(ofSize: 22, weight: .bold)
        label.textColor = .white
        label.numberOfLines = 2
        label.text = "pop lab"
        label.frame = CGRect(x: 20, y: 70, width: 340, height: 70)
        view.addSubview(label)

        pill.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(pill)
        plainAnchor.backgroundColor = UIColor.white.withAlphaComponent(0.25)
        plainAnchor.layer.cornerRadius = 23
        plainAnchor.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(plainAnchor)

        host = UIHostingController(rootView: PopLabSwiftUI(state: state, presentFromUpdate: { [weak self] in self?.presentUIKit(clear: false, source: self?.pill.buttons[.nowPlaying]) }))
        host.view.backgroundColor = .clear
        addChild(host)
        host.view.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(host.view)
        host.didMove(toParent: self)

        // Toolbar with three bar button items.
        func item(_ symbol: String, _ label: String) -> UIBarButtonItem {
            let i = UIBarButtonItem(primaryAction: UIAction(title: label, image: UIImage(systemName: symbol)) { [weak self] action in
                guard let self, let it = self.barItems.first(where: { $0.title == label || $0.accessibilityLabel == label }) else { return }
                self.label.text = "UIKit toolbar → \(label)"
                self.presentFromBar(it, clear: false)
            })
            i.accessibilityLabel = label
            return i
        }
        let a = item("switch.2", "LabTracks"), b = item("slider.horizontal.3", "LabSettings"), c = item("list.bullet", "LabNowPlaying")
        barItems = [a, b, c]
        toolbar.items = [.flexibleSpace(), a, b, c]
        toolbar.tintColor = .white
        toolbar.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(toolbar)
        seg.selectedSegmentIndex = 0
        seg.selectedSegmentTintColor = UIColor(Theme.accent)
        seg.setTitleTextAttributes([.foregroundColor: UIColor.white], for: .normal)
        seg.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(seg)

        NSLayoutConstraint.activate([
            toolbar.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            toolbar.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            toolbar.bottomAnchor.constraint(equalTo: pill.topAnchor, constant: -40),
            seg.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 20),
            seg.topAnchor.constraint(equalTo: label.bottomAnchor, constant: 30),
            seg.widthAnchor.constraint(equalToConstant: 300),
            pill.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -20),
            pill.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -20),
            pill.widthAnchor.constraint(equalToConstant: 46 * 3 + 8),
            plainAnchor.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 30),
            plainAnchor.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -20),
            plainAnchor.widthAnchor.constraint(equalToConstant: 46), plainAnchor.heightAnchor.constraint(equalToConstant: 46),
            host.view.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 30),
            host.view.bottomAnchor.constraint(equalTo: pill.topAnchor, constant: -150),
        ])
    }

    func run(_ n: Int) {
        let names = [
            1: "V1 UIKit popover\nsystem glass bg · glass button",
            2: "V2 UIKit popover\nCLEAR bg (1.9.6–1.9.8)",
            3: "V3 UIKit popover\nsystem bg · plain anchor",
            4: "V4 UIKit popover\nsystem bg · presented async",
            5: "V5 SwiftUI .popover",
            6: "V6 UIKit present\ninside SwiftUI onChange",
            7: "V7 popover from UIBarButtonItem\nin UIToolbar · system bg",
            8: "V8 popover from UIBarButtonItem\nCLEAR bg",
            9: "V9 UISegmentedControl\n(programmatic changes)",
        ]
        label.text = names[n]
        dlog("lab", "pop V\(n)")
        switch n {
        case 1: presentUIKit(clear: false, source: pill.buttons[.tracks])
        case 2: presentUIKit(clear: true, source: pill.buttons[.settings])
        case 3: presentUIKit(clear: false, source: plainAnchor)
        case 4: DispatchQueue.main.async { self.presentUIKit(clear: false, source: self.pill.buttons[.nowPlaying]) }
        case 5: state.swiftUIPopover = true
        case 6: state.presentInUpdate = true
        case 7: presentFromBar(barItems[2], clear: false)
        case 8: presentFromBar(barItems[1], clear: true)
        default: break
        }
    }

    func presentUIKit(clear: Bool, source: UIView?) {
        guard let source else { return }
        let c = UIHostingController(rootView: PopLabContent())
        c.view.backgroundColor = .clear
        c.preferredContentSize = CGSize(width: 300, height: 230)
        c.modalPresentationStyle = .popover
        if let pc = c.popoverPresentationController {
            pc.sourceView = source
            pc.sourceRect = source.bounds
            pc.permittedArrowDirections = [.down]
            pc.delegate = PopLabDelegate.shared
            if clear {
                pc.popoverBackgroundViewClass = ClearPopoverBackground.self
                pc.backgroundColor = .clear
            }
        }
        present(c, animated: true)
    }

    func segment(_ i: Int) {
        seg.selectedSegmentIndex = i
        seg.sendActions(for: .valueChanged)
    }

    func presentFromBar(_ item: UIBarButtonItem, clear: Bool) {
        let c = UIHostingController(rootView: PopLabContent())
        c.view.backgroundColor = .clear
        c.preferredContentSize = CGSize(width: 300, height: 230)
        c.modalPresentationStyle = .popover
        if let pc = c.popoverPresentationController {
            pc.sourceItem = item
            pc.delegate = PopLabDelegate.shared
            if clear {
                pc.popoverBackgroundViewClass = ClearPopoverBackground.self
                pc.backgroundColor = .clear
            }
        }
        present(c, animated: true)
    }

    func dismissAll() {
        state.swiftUIPopover = false
        state.presentInUpdate = false
        presentedViewController?.dismiss(animated: true)
    }
}
