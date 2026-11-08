import SwiftUI

/// Whether a connected service gets what you watch.
struct SyncEnabledToggle: View {
    let service: SyncService
    @AppStorage private var on: Bool

    init(service: SyncService) {
        self.service = service
        _on = AppStorage(wrappedValue: false, service.enabledKey)
    }

    var body: some View {
        Toggle("Send what I watch", isOn: $on)
    }
}
