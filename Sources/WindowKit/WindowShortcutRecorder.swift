import AppKit
import OneMacUI
import SwiftUI

/// One action's shortcut: click the key caps to record a new one, ✕ to remove it, ↺ to go back to
/// the default. Recording uses a local key-down monitor, so the captured keys never reach other UI.
struct WindowShortcutRecorder: View {
    let action: WindowAction
    @ObservedObject private var snapping = WindowSnapping.shared
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
            if !recording {
                if !snapping.keyCaps(for: action).isEmpty {
                    iconButton("xmark.circle.fill", tr("Remove shortcut", "Bỏ phím tắt")) { apply(nil) }
                }
                if !snapping.isDefaultShortcut(action) {
                    iconButton("arrow.uturn.backward.circle.fill", tr("Back to default", "Về mặc định")) {
                        report(snapping.resetShortcut(action))
                    }
                }
            }
        }
        .onDisappear { stopRecording() }
    }

    @ViewBuilder private var label: some View {
        let caps = snapping.keyCaps(for: action)
        if recording {
            Text(tr("Press keys…  (⎋ cancels)", "Nhấn phím…  (⎋ để huỷ)"))
                .font(.system(size: FS.body)).foregroundStyle(.orange)
        } else if caps.isEmpty {
            Text(tr("Record shortcut", "Ghi phím tắt"))
                .font(.system(size: FS.body)).foregroundStyle(.secondary)
        } else {
            let active = snapping.shortcutsEnabled && !snapping.unavailable.contains(action)
            HStack(spacing: 3) {
                ForEach(Array(caps.enumerated()), id: \.offset) { _, cap in
                    Text(cap).font(.system(size: FS.body, weight: .medium, design: .rounded))
                        .frame(minWidth: 22, minHeight: 22)
                        .background(RoundedRectangle(cornerRadius: Rad.sm, style: .continuous).fill(Color.tileFill))
                }
            }
            .opacity(active ? 1 : 0.4)
        }
    }

    private func iconButton(_ systemName: String, _ help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) { Image(systemName: systemName).foregroundStyle(.tertiary) }
            .buttonStyle(.plain)
            .help(help)
    }

    private func startRecording() {
        problem = nil
        recording = true
        snapping.setRecording(true)
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            if event.keyCode == 53, flags.isDisjoint(with: [.control, .option, .command]) { // Esc cancels
                stopRecording()
            } else if let shortcut = WindowShortcut(keyCode: Int(event.keyCode), flags: flags) {
                stopRecording()
                apply(shortcut)
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
        snapping.setRecording(false)
    }

    private func apply(_ shortcut: WindowShortcut?) { report(snapping.assign(shortcut, to: action)) }

    private func report(_ holder: WindowAction?) {
        problem = holder.map { tr("Used by “\($0.title)”", "“\($0.title)” đang dùng") }
    }
}
