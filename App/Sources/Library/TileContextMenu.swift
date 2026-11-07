import ObjectiveC
import SwiftUI
import UIKit

/// One action of a tile's or a row's long-press menu.
struct TileMenuAction: Identifiable {
    let title: String
    let systemImage: String
    var destructive = false
    let handler: () -> Void
    var id: String { title }
}

extension View {
    /// A long-press menu that belongs to this view alone (1.24.1).
    ///
    /// SwiftUI's `.contextMenu` inside a List row is the row's: one menu per
    /// row, lifting the whole row (Apple Developer Forums 127611, 688415). On
    /// Home's Thumbnails a row holds several tiles, so a long press on any of
    /// them lifted the whole row and showed the FIRST tile's menu: in the lab
    /// on 7 Nov Lab Show's tile offered Lab Other's "Mark all as watched" and
    /// "Delete all episodes" (the user's 11:03 screenshot: the row of three
    /// lifted). In List and Details the lifted preview was the row with its
    /// margins, a card in a card.
    ///
    /// Here an invisible anchor behind this view marks where it is, and one
    /// UIKit context menu interaction on the list cell finds the anchor under
    /// the finger. The anchor takes no touches, so taps still reach the
    /// SwiftUI buttons (a clear view over the tile took them: tapping a title
    /// no longer opened it). The items come from `actions` when the menu
    /// opens, not when the view was last drawn, so "Mark all as watched /
    /// unwatched" says what's true then (the 11:02 screenshot: a watched
    /// title offered "Mark all as watched"). The lifted preview is a snapshot
    /// of exactly this view, with its rounded corners.
    ///
    /// `outset`: room around the view in the lifted copy (a tile's title and
    /// subtitle sit at its very edge).
    func tileContextMenu(cornerRadius: CGFloat, outset: CGFloat = 0, actions: @escaping () -> [TileMenuAction]) -> some View {
        background(TileMenuAnchor(cornerRadius: cornerRadius, outset: outset, actions: actions))
    }
}

private struct TileMenuAnchor: UIViewRepresentable {
    let cornerRadius: CGFloat
    let outset: CGFloat
    let actions: () -> [TileMenuAction]

    func makeUIView(context: Context) -> MenuAnchorView {
        let v = MenuAnchorView()
        v.isUserInteractionEnabled = false
        v.backgroundColor = .clear
        v.isAccessibilityElement = false
        v.accessibilityElementsHidden = true
        return v
    }

    func updateUIView(_ v: MenuAnchorView, context: Context) {
        v.cornerRadius = cornerRadius
        v.outset = outset
        v.actions = actions
        v.install()
    }
}

final class MenuAnchorView: UIView {
    var cornerRadius: CGFloat = 12
    var outset: CGFloat = 0
    var actions: () -> [TileMenuAction] = { [] }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        install()
    }

    /// Joins the menu of the cell it's in (made the first time).
    func install() {
        guard window != nil, let container = Self.container(of: self) else { return }
        TileMenuHub.hub(for: container).add(self)
    }

    /// The list cell holding the view; outside a list, the view hosting it.
    private static func container(of v: UIView) -> UIView? {
        var s = v.superview
        var outermost: UIView?
        while let c = s {
            if c is UICollectionViewCell || c is UITableViewCell { return c }
            if c is UIWindow { break }
            outermost = c
            s = c.superview
        }
        return outermost
    }
}

/// The context menu interaction of one cell, shared by the anchors in it.
private final class TileMenuHub: NSObject, UIContextMenuInteractionDelegate {
    private static var key: UInt8 = 0

    static func hub(for container: UIView) -> TileMenuHub {
        if let h = objc_getAssociatedObject(container, &key) as? TileMenuHub { return h }
        let h = TileMenuHub(container: container)
        objc_setAssociatedObject(container, &key, h, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        container.addInteraction(UIContextMenuInteraction(delegate: h))
        return h
    }

    private weak var container: UIView?
    private let anchors = NSHashTable<MenuAnchorView>.weakObjects()
    private weak var active: MenuAnchorView?

    private init(container: UIView) { self.container = container }

    func add(_ a: MenuAnchorView) { anchors.add(a) }

    private func anchor(at p: CGPoint, in c: UIView) -> MenuAnchorView? {
        anchors.allObjects.first { a in
            a.window != nil && !a.isHidden && a.isDescendant(of: c) && a.convert(a.bounds, to: c).contains(p)
        }
    }

    func contextMenuInteraction(_ interaction: UIContextMenuInteraction,
                                configurationForMenuAtLocation location: CGPoint) -> UIContextMenuConfiguration? {
        guard let c = container, let a = anchor(at: location, in: c) else { return nil }
        let actions = a.actions()
        guard !actions.isEmpty else { return nil }
        active = a
        return UIContextMenuConfiguration(identifier: nil, previewProvider: nil) { _ in
            UIMenu(children: actions.map { item in
                UIAction(title: item.title, image: UIImage(systemName: item.systemImage),
                         attributes: item.destructive ? .destructive : []) { _ in item.handler() }
            })
        }
    }

    func contextMenuInteraction(_ interaction: UIContextMenuInteraction,
                                configuration: UIContextMenuConfiguration,
                                highlightPreviewForItemWithIdentifier identifier: any NSCopying) -> UITargetedPreview? {
        preview()
    }

    func contextMenuInteraction(_ interaction: UIContextMenuInteraction,
                                configuration: UIContextMenuConfiguration,
                                dismissalPreviewForItemWithIdentifier identifier: any NSCopying) -> UITargetedPreview? {
        preview()
    }

    /// What's drawn where the anchor is, cut to its rounded shape. Taken from
    /// the cell, not the window: the window also has the last menu's preview
    /// while it animates away, and a quick second long press caught it (two
    /// "Lab Show"s in the lab).
    private func preview() -> UITargetedPreview? {
        guard let c = container, let a = active, a.window != nil, a.bounds.width > 0 else { return nil }
        let area = a.bounds.insetBy(dx: -a.outset, dy: -a.outset)
        let rect = a.convert(area, to: c)
        guard let snapshot = c.resizableSnapshotView(from: rect, afterScreenUpdates: false, withCapInsets: .zero) else { return nil }
        snapshot.frame = CGRect(origin: .zero, size: rect.size)
        let parameters = UIPreviewParameters()
        parameters.visiblePath = UIBezierPath(roundedRect: snapshot.bounds, cornerRadius: a.cornerRadius + a.outset)
        // The page's colour behind the text: a list cell is clear, and the
        // tile underneath (which stays) showed through the lifted copy.
        parameters.backgroundColor = UIColor(Theme.background)
        let target = UIPreviewTarget(container: c, center: CGPoint(x: rect.midX, y: rect.midY))
        return UITargetedPreview(view: snapshot, parameters: parameters, target: target)
    }
}
