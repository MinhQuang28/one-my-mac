import AppKit
import OneMacUI
import SwiftUI
import WindowKit

/// The shortcut that opens the history: click the key caps to record a new one, ↺ to go back to
/// the default. Recording uses a local key-down monitor, so the captured keys reach nothing else.
struct ClipboardShortcutRecorder: View {
    @ObservedObject private var history = ClipboardHistory.shared
    @State private var recording = false
    @State private var monitor: Any?
    /// Why the last attempt was refused; cleared by the next one.
    @State private var problem: String?

    var body: some View {
        HStack(spacing: 6) {
            if let problem {
                Text(problem).font(.system(size: FS.caption)).foregroundStyle(.orange).lineLimit(1)
            }
            Button(action: { recording ? stopRecording() : startRecording() }) { label }
                .buttonStyle(.plain)
                .help(tr("Click, then press the new shortcut", "Bấm rồi nhấn phím tắt mới"))
            if !recording, !history.usesDefaultShortcut {
                Button { history.shortcut = ClipboardShortcutDefaults.standard } label: {
                    Image(systemName: "arrow.uturn.backward.circle.fill").foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
                .help(tr("Back to default", "Về mặc định"))
            }
        }
        .onDisappear { stopRecording() }
    }

    @ViewBuilder private var label: some View {
        if recording {
            Text(tr("Press keys…  (⎋ cancels)", "Nhấn phím…  (⎋ để huỷ)"))
                .font(.system(size: FS.body)).foregroundStyle(.orange)
        } else {
            HStack(spacing: 3) {
                ForEach(Array(history.shortcut.keyCaps.enumerated()), id: \.offset) { _, cap in
                    Text(cap).font(.system(size: FS.body, weight: .medium, design: .rounded))
                        .frame(minWidth: 22, minHeight: 22)
                        .background(RoundedRectangle(cornerRadius: Rad.sm, style: .continuous).fill(Color.tileFill))
                }
            }
            .opacity(history.isEnabled && history.shortcutRegistered ? 1 : 0.4)
        }
    }

    private func startRecording() {
        problem = nil
        recording = true
        history.isRecordingShortcut = true
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            if event.keyCode == 53, flags.isDisjoint(with: [.control, .option, .command]) { // Esc cancels
                stopRecording()
            } else if let shortcut = WindowShortcut(keyCode: Int(event.keyCode), flags: flags) {
                stopRecording()
                history.shortcut = shortcut
            } else {
                problem = tr("Add ⌃, ⌥ or ⌘", "Cần thêm ⌃, ⌥ hoặc ⌘")
            }
            return nil // swallow the captured key so it doesn't trigger anything
        }
    }

    private func stopRecording() {
        guard recording else { return }
        recording = false
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        history.isRecordingShortcut = false
    }
}
