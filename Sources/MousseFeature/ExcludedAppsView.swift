import SwiftUI
import OneMacUI
import UniformTypeIdentifiers

/// Settings section for the scroll-exclusion list: apps where smoothing is bypassed so the wheel
/// stays a native legacy notch (needed by horizontal-only views, e.g. Nimble Commander's panels).
struct ExcludedAppsView: View {
    @EnvironmentObject var store: ConfigStore

    var body: some View {
        AppListSection(
            title: tr("Apps without smoothing", "Ứng dụng không làm mượt"),
            emptyLabel: tr("No excluded apps", "Chưa loại trừ ứng dụng nào"),
            addPrompt: tr("Exclude", "Loại trừ"),
            footer: tr("The wheel behaves natively over these apps; reverse and speed still apply. Terminal apps are always excluded — a smooth glide would jump many lines per notch there.",
                       "Bánh xe cuộn kiểu gốc trên các ứng dụng này; đảo chiều và tốc độ vẫn áp dụng. Ứng dụng terminal luôn được loại trừ — cuộn mượt ở đó sẽ nhảy nhiều dòng mỗi nấc."),
            bundleIDs: $store.config.excludedBundleIDs)
    }
}

/// Settings section for the axis-swap list: apps where the wheel's vertical motion scrolls
/// HORIZONTALLY (purpose-built for horizontal-first browsers like Nimble Commander's Brief
/// panels). Unlike exclusion, smoothing keeps working — we transpose the axes ourselves.
struct TransposedAppsView: View {
    @EnvironmentObject var store: ConfigStore

    var body: some View {
        AppListSection(
            title: tr("Apps that scroll sideways", "Ứng dụng cuộn ngang"),
            emptyLabel: tr("No axis-swap apps", "Chưa có ứng dụng đổi trục"),
            addPrompt: tr("Add", "Thêm"),
            footer: tr("Over these apps the wheel scrolls horizontally (and tilt scrolls vertically). Made for horizontal-first views such as Nimble Commander's Brief mode.",
                       "Trên các ứng dụng này bánh xe cuộn ngang (và nghiêng bánh xe cuộn dọc). Dành cho giao diện ưu tiên chiều ngang như chế độ Brief của Nimble Commander."),
            bundleIDs: $store.config.verticalToHorizontalBundleIDs)
    }
}

/// One reusable per-app list section: rows with app icon/name, remove buttons, an add-app picker.
private struct AppListSection: View {
    let title: String
    let emptyLabel: String
    let addPrompt: String
    let footer: String
    @Binding var bundleIDs: [String]

    var body: some View {
        SettingsSection(title, footer: footer) {
            if bundleIDs.isEmpty {
                Text(emptyLabel).font(.system(size: FS.body)).foregroundStyle(.secondary)
            }
            ForEach(bundleIDs, id: \.self) { bundleID in
                HStack {
                    AppRow(bundleID: bundleID)
                    Spacer()
                    Button {
                        bundleIDs.removeAll { $0 == bundleID }
                    } label: {
                        Image(systemName: "minus.circle.fill").foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .help(tr("Remove from this list", "Xoá khỏi danh sách"))
                }
            }
            Button(action: addApp) {
                Label(tr("Add App…", "Thêm ứng dụng…"), systemImage: "plus")
                    .font(.system(size: FS.body, weight: .medium))
            }
            .buttonStyle(.borderless)
        }
    }

    private func addApp() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = true
        panel.allowedContentTypes = [.applicationBundle]
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.prompt = addPrompt
        guard panel.runModal() == .OK else { return }
        for url in panel.urls {
            guard let id = Bundle(url: url)?.bundleIdentifier,
                  !bundleIDs.contains(id) else { continue }
            bundleIDs.append(id)
        }
    }
}

/// One listed app: icon + display name when the app is installed, otherwise the raw bundle ID.
private struct AppRow: View {
    let bundleID: String

    var body: some View {
        HStack(spacing: Gap.sm) {
            if let app = InstalledApp.lookup(bundleID) {
                Image(nsImage: app.icon).resizable().frame(width: 20, height: 20)
                Text(app.name).font(.system(size: FS.title))
            } else {
                Image(systemName: "questionmark.app").frame(width: 18, height: 18)
                Text(bundleID).foregroundStyle(.secondary)
            }
        }
    }
}

/// Icon + display name for a bundle ID, resolved once and memoized.
///
/// This is read from a SwiftUI `body`, which re-runs on every re-render of the Settings form —
/// including once per step while dragging the scroll-speed slider. Resolving it inline meant a
/// LaunchServices query plus icon and display-name lookups (disk I/O) per listed app per frame,
/// which is exactly the kind of work a view body must not do. The set of installed apps barely
/// changes while a Settings window is open, so a plain memo is the whole fix.
@MainActor
private struct InstalledApp {
    let icon: NSImage
    let name: String

    private static var cache: [String: InstalledApp?] = [:]

    static func lookup(_ bundleID: String) -> InstalledApp? {
        if let memoized = cache[bundleID] { return memoized }
        let resolved = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID).map {
            InstalledApp(icon: NSWorkspace.shared.icon(forFile: $0.path),
                         name: FileManager.default.displayName(atPath: $0.path))
        }
        cache[bundleID] = resolved
        return resolved
    }
}
