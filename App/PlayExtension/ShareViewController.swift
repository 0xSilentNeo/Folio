import UIKit
import UniformTypeIdentifiers

/// Folio in the share sheet (1.27.0 as the Play in Folio action, whose icon
/// was blank; 1.27.1 a share extension, in the app row with Folio's icon).
/// A link from Safari or Messages, or a video from Files or Photos, is left
/// for Folio in the App Group, and Folio opens and plays it. Folio itself
/// isn't loaded here (an extension gets a few dozen megabytes; the player
/// needs far more).
@objc(ShareViewController)
final class ShareViewController: UIViewController {
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
        let id = UUID().uuidString
        var link: SharedPlayLink
        if let video = videoProvider() {
            label.text = "Copying to Folio…"
            guard let file = await copyVideo(video, id: id) else {
                show(SharedPlayLink.inbox == nil
                     ? "This install of Folio has no shared storage for its extensions. Open the video in Files and choose Folio there."
                     : "Folio couldn't read this video.")
                return
            }
            link = SharedPlayLink(url: "", at: Date(), id: id, file: file)
        } else if let url = await sharedLink() {
            link = SharedPlayLink(url: url.absoluteString, at: Date(), id: id)
        } else {
            show("Folio plays videos and links to video streams (http, https, rtsp, smb…). This isn't one.")
            return
        }
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

    /// A shared video (Files, Photos), if that's what came.
    private func videoProvider() -> NSItemProvider? {
        let providers = (extensionContext?.inputItems as? [NSExtensionItem] ?? []).flatMap { $0.attachments ?? [] }
        return providers.first { $0.hasItemConformingToTypeIdentifier(UTType.audiovisualContent.identifier) }
    }

    /// The video moved (or copied) into the App Group's Share/Inbox/<id>/.
    /// Returns its path there.
    private func copyVideo(_ provider: NSItemProvider, id: String) async -> String? {
        guard let inbox = SharedPlayLink.inbox else { return nil }
        let type = provider.registeredTypeIdentifiers.first { UTType($0)?.conforms(to: .audiovisualContent) == true }
            ?? UTType.audiovisualContent.identifier
        return await withCheckedContinuation { (done: CheckedContinuation<String?, Never>) in
            _ = provider.loadFileRepresentation(forTypeIdentifier: type) { url, _ in
                // The file is only there until this returns: moved now.
                guard let url else { done.resume(returning: nil); return }
                let dir = inbox.appendingPathComponent(id, isDirectory: true)
                let name = url.lastPathComponent.isEmpty ? "Video.mov" : url.lastPathComponent
                let dest = dir.appendingPathComponent(name)
                do {
                    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                    do { try FileManager.default.moveItem(at: url, to: dest) } catch { try FileManager.default.copyItem(at: url, to: dest) }
                    done.resume(returning: "Share/Inbox/\(id)/\(name)")
                } catch {
                    done.resume(returning: nil)
                }
            }
        }
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
