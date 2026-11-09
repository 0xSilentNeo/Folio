import UIKit
import UniformTypeIdentifiers

/// Play in Folio (1.27.0): the share sheet's action for a link from Safari,
/// Messages or anywhere that shares one. It leaves the link for Folio in the
/// App Group and opens Folio, which plays it. Folio itself isn't loaded here
/// (an extension gets a few dozen megabytes; the player needs far more).
@objc(PlayActionViewController)
final class PlayActionViewController: UIViewController {
    private let card = UIView()
    private let label = UILabel()
    private let spinner = UIActivityIndicatorView(style: .medium)
    private let done = UIButton(type: .system)
    private var started = false

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = UIColor.black.withAlphaComponent(0.25)

        card.backgroundColor = .secondarySystemGroupedBackground
        card.layer.cornerRadius = 24
        card.layer.cornerCurve = .continuous
        card.translatesAutoresizingMaskIntoConstraints = false

        label.font = .preferredFont(forTextStyle: .headline)
        label.adjustsFontForContentSizeCategory = true
        label.numberOfLines = 0
        label.textAlignment = .center
        label.text = "Opening in Folio…"

        spinner.startAnimating()

        var config = UIButton.Configuration.filled()
        config.title = "Done"
        config.cornerStyle = .capsule
        done.configuration = config
        done.isHidden = true
        done.addAction(UIAction { [weak self] _ in self?.finish() }, for: .primaryActionTriggered)

        let stack = UIStackView(arrangedSubviews: [spinner, label, done])
        stack.axis = .vertical
        stack.spacing = 14
        stack.alignment = .center
        stack.translatesAutoresizingMaskIntoConstraints = false
        card.addSubview(stack)
        view.addSubview(card)
        NSLayoutConstraint.activate([
            card.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            card.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            card.widthAnchor.constraint(lessThanOrEqualToConstant: 340),
            card.leadingAnchor.constraint(greaterThanOrEqualTo: view.layoutMarginsGuide.leadingAnchor),
            card.trailingAnchor.constraint(lessThanOrEqualTo: view.layoutMarginsGuide.trailingAnchor),
            stack.topAnchor.constraint(equalTo: card.topAnchor, constant: 24),
            stack.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -24),
            stack.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 24),
            stack.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -24),
        ])
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        guard !started else { return }
        started = true
        Task { @MainActor in await run() }
    }

    private func run() async {
        guard let url = await sharedLink() else {
            show("Folio plays links to video streams (http, https, rtsp, smb…). This isn't one.")
            return
        }
        let link = SharedPlayLink(url: url.absoluteString, title: nil, at: Date(), id: UUID().uuidString)
        guard SharedPlayLink.leave(link), let open = link.openURL else {
            show("This install of Folio has no shared storage for its extensions. Copy the link, then use + → Open URL on Folio's Home.")
            return
        }
        if openInFolio(open) {
            try? await Task.sleep(nanoseconds: 400_000_000)
            finish()
        } else {
            show("Open Folio to play it: the link is waiting there.")
        }
    }

    private func show(_ text: String) {
        spinner.stopAnimating()
        spinner.isHidden = true
        label.text = text
        label.font = .preferredFont(forTextStyle: .body)
        done.isHidden = false
    }

    private func finish() {
        extensionContext?.completeRequest(returningItems: nil)
    }

    /// The first web link, or the first link in shared text.
    private func sharedLink() async -> URL? {
        let providers = (extensionContext?.inputItems as? [NSExtensionItem] ?? []).flatMap { $0.attachments ?? [] }
        for p in providers where p.hasItemConformingToTypeIdentifier(UTType.url.identifier) {
            if let u = try? await p.loadItem(forTypeIdentifier: UTType.url.identifier) as? URL, SharedPlayLink.isPlayable(u) { return u }
        }
        for p in providers where p.hasItemConformingToTypeIdentifier(UTType.plainText.identifier) {
            if let s = try? await p.loadItem(forTypeIdentifier: UTType.plainText.identifier) as? String,
               let u = SharedPlayLink.firstLink(in: s) { return u }
        }
        return nil
    }

    /// An extension has no public way to open its app (extensionContext's
    /// open is a widget's only). Up the responder chain to the application
    /// and its open(_:options:completionHandler:), as other apps' Open in
    /// extensions do; the old openURL: does nothing since iOS 18.
    private func openInFolio(_ url: URL) -> Bool {
        let selector = NSSelectorFromString("openURL:options:completionHandler:")
        var responder: UIResponder? = self
        while let r = responder {
            if let app = r as? UIApplication, app.responds(to: selector), let imp = app.method(for: selector) {
                typealias Open = @convention(c) (AnyObject, Selector, NSURL, NSDictionary, AnyObject?) -> Void
                unsafeBitCast(imp, to: Open.self)(app, selector, url as NSURL, NSDictionary(), nil)
                return true
            }
            responder = r.next
        }
        return false
    }
}
