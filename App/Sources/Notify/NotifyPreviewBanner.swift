import SwiftUI

/// A notification as it would come, worded in `tone` (Personality's preview, 1.26.3).
struct NotifyPreviewBanner: View {
    let tone: NotifyTone

    var body: some View {
        let text = NotifyWording.text(.paused, tone, ["show": "Your show", "time": "31:04"], variation: 0)
        let title = text?.title ?? "Folio"
        let message = text?.body ?? ""
        HStack(alignment: .top, spacing: 10) {
            Image("IconPreview-primary")
                .resizable()
                .frame(width: 38, height: 38)
                .clipShape(.rect(cornerRadius: 9, style: .continuous))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                HStack(alignment: .firstTextBaseline) {
                    Text(title).font(.subheadline.weight(.semibold))
                    Spacer(minLength: 8)
                    Text("now").font(.caption).foregroundStyle(.secondary)
                }
                Text(message)
                    .font(.subheadline)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .contentTransition(.opacity)
        }
        .padding(12)
        .background(Color.primary.opacity(0.05), in: .rect(cornerRadius: 20, style: .continuous))
        .animation(.smooth(duration: 0.25), value: tone)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Example notification: \(title). \(message)")
    }
}
