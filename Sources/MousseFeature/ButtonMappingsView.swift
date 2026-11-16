import OneMacUI
import SwiftUI

/// Button mappings. Add one by clicking the actual mouse button into the capture field, then
/// assign an action — no guessing button numbers.
struct ButtonMappingsView: View {
    @EnvironmentObject var store: ConfigStore

    var body: some View {
        SettingsPage(pane: .mouseButtons) {
            ButtonCaptureField(onCapture: addMapping)
            if store.config.mappings.isEmpty {
                ContentUnavailableView(tr("No buttons mapped", "Chưa gán nút nào"), systemImage: "computermouse",
                                       description: Text(tr("Click the field above with a side button to start.",
                                                            "Bấm một nút bên của chuột vào ô phía trên để bắt đầu.")))
                    .frame(maxWidth: .infinity).padding(.vertical, Gap.lg)
            } else {
                SettingsSection(tr("Mapped buttons", "Nút đã gán")) {
                    ForEach($store.config.mappings) { $mapping in
                        MappingRow(mapping: $mapping) { delete(mapping.id) }
                    }
                }
            }
        }
    }

    /// Add a mapping for a freshly-captured button (ignore left/right click, and duplicates).
    private func addMapping(button: Int) {
        guard button >= 3 else { return } // don't let users break left/right click
        guard !store.config.mappings.contains(where: { $0.buttonNumber == button }) else { return }
        store.config.mappings.append(ButtonMapping(buttonNumber: button, action: .spaceLeft))
    }

    private func delete(_ id: UUID) {
        store.config.mappings.removeAll { $0.id == id }
    }
}

/// One row: captured button (fixed label) + action control + delete.
private struct MappingRow: View {
    @Binding var mapping: ButtonMapping
    let onDelete: () -> Void

    var body: some View {
        HStack(spacing: Gap.sm + 2) {
            Label(tr("Button \(mapping.buttonNumber)", "Nút \(mapping.buttonNumber)"), systemImage: "computermouse.fill")
                .font(.system(size: FS.title, weight: .medium))
                .frame(width: 110, alignment: .leading)
            Image(systemName: "arrow.right").foregroundStyle(.tertiary)
            ShortcutControl(action: $mapping.action)
            Spacer()
            Button(role: .destructive, action: onDelete) {
                Image(systemName: "trash")
            }
            .buttonStyle(.borderless)
            .help(tr("Remove this mapping", "Xoá gán nút này"))
        }
    }
}
