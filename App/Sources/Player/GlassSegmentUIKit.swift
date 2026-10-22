import SwiftUI
import UIKit

/// Segmented control with a Liquid Glass thumb that slides — UIKit, animated
/// with UIView springs. Glass while it moves (tap or drag), accent colour
/// once settled; draggable like the main tab bar.
struct SegmentPicker<T: Hashable>: View {
    let options: [(T, String)]
    @Binding var selection: T

    var body: some View {
        UISegmentPicker(options: options, selection: $selection)
            .frame(width: GlassSegmentUIView.width(for: options.map(\.1)), height: 38)
    }
}

struct UISegmentPicker<T: Hashable>: UIViewRepresentable {
    let options: [(T, String)]
    @Binding var selection: T

    func makeUIView(context: Context) -> GlassSegmentUIView {
        let v = GlassSegmentUIView(labels: options.map(\.1))
        v.onSelect = { i in
            let value = options[i].0
            if value != selection { selection = value }
        }
        v.setSelected(options.firstIndex { $0.0 == selection } ?? 0, animated: false)
        return v
    }

    func updateUIView(_ v: GlassSegmentUIView, context: Context) {
        let i = options.firstIndex { $0.0 == selection } ?? 0
        if v.selected != i && !v.isDragging { v.setSelected(i, animated: true) }
    }
}

final class GlassSegmentUIView: UIView {
    var onSelect: ((Int) -> Void)?
    private(set) var selected = 0
    private(set) var isDragging = false

    private let labels: [UILabel]
    private let thumb: UIVisualEffectView
    private let tint = UIView()
    private let track = UIView()
    private let segW: CGFloat
    private var settleWork: DispatchWorkItem?
    private static let pad: CGFloat = 3
    private static let h: CGFloat = 32

    static func segmentWidth(for titles: [String]) -> CGFloat {
        let font = UIFont.systemFont(ofSize: 15, weight: .semibold)
        let w = titles.map { ($0 as NSString).size(withAttributes: [.font: font]).width }.max() ?? 40
        return ceil(w) + 26
    }
    static func width(for titles: [String]) -> CGFloat { segmentWidth(for: titles) * CGFloat(titles.count) + pad * 2 }

    init(labels titles: [String]) {
        segW = Self.segmentWidth(for: titles)
        labels = titles.map { t in
            let l = UILabel(); l.text = t; l.font = .systemFont(ofSize: 15, weight: .semibold); l.textColor = .white; l.textAlignment = .center
            return l
        }
        #if compiler(>=6.2)
        if #available(iOS 26.0, *) {
            thumb = UIVisualEffectView(effect: UIGlassEffect())
            thumb.cornerConfiguration = .capsule()
        } else {
            thumb = UIVisualEffectView(effect: UIBlurEffect(style: .systemThinMaterialLight))
            thumb.layer.cornerRadius = Self.h / 2; thumb.clipsToBounds = true
        }
        #else
        thumb = UIVisualEffectView(effect: UIBlurEffect(style: .systemThinMaterialLight))
        thumb.layer.cornerRadius = Self.h / 2; thumb.clipsToBounds = true
        #endif
        super.init(frame: .zero)
        track.backgroundColor = UIColor.white.withAlphaComponent(0.12)
        track.layer.cornerRadius = (Self.h + Self.pad * 2) / 2
        track.isUserInteractionEnabled = false
        addSubview(track)
        tint.backgroundColor = UIColor(Theme.accent)
        tint.layer.cornerRadius = Self.h / 2
        thumb.contentView.addSubview(tint)
        thumb.isUserInteractionEnabled = false
        addSubview(thumb)
        for l in labels { l.isUserInteractionEnabled = false; addSubview(l) }
        addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(tap(_:))))
        let pan = UIPanGestureRecognizer(target: self, action: #selector(pan(_:)))
        addGestureRecognizer(pan)
    }

    required init?(coder: NSCoder) { fatalError() }

    override var intrinsicContentSize: CGSize { CGSize(width: segW * CGFloat(labels.count) + Self.pad * 2, height: Self.h + Self.pad * 2) }

    override func layoutSubviews() {
        super.layoutSubviews()
        track.frame = bounds
        for (i, l) in labels.enumerated() {
            l.frame = CGRect(x: Self.pad + segW * CGFloat(i), y: Self.pad, width: segW, height: Self.h)
        }
        if !isDragging && thumb.layer.animationKeys()?.isEmpty ?? true {
            thumb.frame = frame(for: selected)
            tint.frame = thumb.bounds
        }
    }

    private func frame(for i: Int) -> CGRect {
        CGRect(x: Self.pad + segW * CGFloat(i), y: Self.pad, width: segW, height: Self.h)
    }

    func setSelected(_ i: Int, animated: Bool) {
        selected = i
        guard animated else { thumb.frame = frame(for: i); tint.frame = thumb.bounds; return }
        settleWork?.cancel()
        UIView.animate(withDuration: 0.15) { self.tint.alpha = 0 }
        UIView.animate(withDuration: 0.45, delay: 0, usingSpringWithDamping: 0.72, initialSpringVelocity: 0.5, options: [.allowUserInteraction]) {
            self.thumb.frame = self.frame(for: i)
            self.tint.frame = self.thumb.bounds
        }
        let w = DispatchWorkItem { UIView.animate(withDuration: 0.25) { self.tint.alpha = 1 } }
        settleWork = w
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.32, execute: w)
    }

    @objc private func tap(_ g: UITapGestureRecognizer) {
        let i = index(at: g.location(in: self).x)
        guard i != selected else { return }
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        setSelected(i, animated: true)
        onSelect?(i)
    }

    private func index(at x: CGFloat) -> Int {
        max(0, min(labels.count - 1, Int((x - Self.pad) / segW)))
    }

    @objc private func pan(_ g: UIPanGestureRecognizer) {
        let x = g.location(in: self).x
        switch g.state {
        case .began:
            isDragging = true
            settleWork?.cancel()
            UIView.animate(withDuration: 0.2, delay: 0, usingSpringWithDamping: 0.7, initialSpringVelocity: 0) {
                self.tint.alpha = 0
                var f = self.thumb.frame; f.size.width = self.segW * 1.12; self.thumb.frame = f; self.tint.frame = self.thumb.bounds
            }
        case .changed:
            var f = thumb.frame
            f.origin.x = min(max(x - f.width / 2, Self.pad - segW * 0.06), bounds.width - Self.pad - f.width + segW * 0.06)
            thumb.frame = f
            tint.frame = thumb.bounds
            let i = index(at: x)
            if i != selected { selected = i; UISelectionFeedbackGenerator().selectionChanged(); onSelect?(i) }
        case .ended, .cancelled, .failed:
            isDragging = false
            let i = index(at: x)
            selected = i
            onSelect?(i)
            setSelected(i, animated: true)
        default: break
        }
    }
}
