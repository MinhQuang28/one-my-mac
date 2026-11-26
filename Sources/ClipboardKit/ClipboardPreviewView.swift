import AppKit
import OneMacUI
import SwiftUI

/// The right-hand side: the selected item in full, then what is known about it.
struct ClipboardPreview: View {
    let item: ClipboardItem
    @ObservedObject var history: ClipboardHistory
    /// Space at the bottom kept clear for the capsules floating over the window.
    var bottomInset: CGFloat = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            content.frame(maxWidth: .infinity, maxHeight: .infinity).padding(Gap.lg)
            VStack(alignment: .leading, spacing: 0) {
                Text(tr("Information", "Thông tin")).font(.system(size: FS.label, weight: .medium))
                    .foregroundStyle(.secondary).padding(.horizontal, Gap.sm).padding(.bottom, 6)
                ForEach(Array(facts.enumerated()), id: \.offset) { index, fact in
                    HStack(spacing: 6) {
                        Text(fact.0).foregroundStyle(.secondary)
                        Spacer(minLength: Gap.md)
                        if index == 0, let icon = sourceIcon {
                            Image(nsImage: icon).resizable().frame(width: 18, height: 18)
                        }
                        Text(fact.1).fontWeight(.medium).lineLimit(1).truncationMode(.middle).monospacedDigit()
                    }
                    .font(.system(size: FS.body)).padding(.horizontal, Gap.sm + 2).padding(.vertical, 6)
                    .background(RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .fill(index.isMultiple(of: 2) ? Color.white.opacity(0.06) : Color.clear))
                }
            }
            .padding(.horizontal, Gap.md).padding(.bottom, bottomInset)
        }
    }

    /// The icon of the app the item was copied from, when that app is still installed.
    private var sourceIcon: NSImage? {
        guard let id = item.sourceBundleID,
              let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) else { return nil }
        return NSWorkspace.shared.icon(forFile: url.path)
    }

    @ViewBuilder private var content: some View {
        switch item.kind {
        case .image:
            if let image = history.thumbnail(for: item, maxPixel: 1_200) {
                Image(nsImage: image).resizable().scaledToFit()
                    .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            } else {
                // Still decoding, or the file is gone; either way there is nothing to draw yet.
                ProgressView().controlSize(.small)
            }
        case .file:
            ScrollView {
                VStack(alignment: .leading, spacing: Gap.sm) {
                    ForEach(item.filePaths, id: \.self) { path in
                        HStack(spacing: Gap.sm) {
                            Image(nsImage: NSWorkspace.shared.icon(forFile: path)).resizable().frame(width: 28, height: 28)
                            VStack(alignment: .leading, spacing: 1) {
                                Text((path as NSString).lastPathComponent).font(.system(size: FS.title)).lineLimit(1)
                                Text((path as NSString).deletingLastPathComponent)
                                    .font(.system(size: FS.label)).foregroundStyle(.secondary)
                                    .lineLimit(1).truncationMode(.head)
                            }
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        case .text, .link, .email:
            ScrollView {
                // A very long copy is cut for display only; pasting uses all of it.
                Text(item.text.prefix(6_000))
                    .font(.system(size: FS.title, design: item.kind == .text ? .default : .monospaced))
                    .foregroundStyle(item.kind == .text ? Color.white : Color.accentColor)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    /// Label and value pairs for the Information list.
    private var facts: [(String, String)] {
        var facts = [(tr("Source", "Nguồn"), item.sourceApp ?? "—"), (tr("Type", "Loại"), item.kind.title)]
        switch item.kind {
        case .image:
            if let width = item.pixelWidth, let height = item.pixelHeight {
                facts.append((tr("Dimensions", "Kích thước"), "\(width)×\(height)"))
            }
            if let bytes = item.byteCount {
                facts.append((tr("Size", "Dung lượng"), ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)))
            }
        case .file:
            facts.append((tr("Items", "Số mục"), "\(item.filePaths.count)"))
        case .text, .link, .email:
            facts.append((tr("Characters", "Ký tự"), "\(item.text.count)"))
            if item.kind == .text {
                facts.append((tr("Words", "Số từ"), "\(item.text.split(whereSeparator: \.isWhitespace).count)"))
            }
        }
        facts.append((tr("Copied", "Sao chép lúc"), item.copiedAt.formatted(date: .abbreviated, time: .shortened)))
        return facts
    }
}

/// The ⌘K menu: every action for the selected item with its own shortcut.
struct ClipboardActionsMenu: View {
    let item: ClipboardItem
    @ObservedObject var model: ClipboardPanelModel
    let perform: (ClipboardAction, ClipboardItem) -> Void

    var body: some View {
        VStack(spacing: 2) {
            ForEach(Array(ClipboardAction.available(for: item).enumerated()), id: \.element) { index, action in
                HStack(spacing: Gap.sm) {
                    Image(systemName: action.icon).frame(width: 18)
                        .foregroundStyle(action == .delete ? Color.red : Color.white)
                    Text(action.title(for: item, target: model.targetApp))
                        .foregroundStyle(action == .delete ? Color.red : Color.white)
                    Spacer(minLength: Gap.lg)
                    Text(action.keys).foregroundStyle(.secondary)
                }
                .font(.system(size: FS.title))
                .padding(.horizontal, Gap.sm).padding(.vertical, 6)
                .background(RoundedRectangle(cornerRadius: 11, style: .continuous)
                    .fill(index == model.actionSelection ? Color.white.opacity(0.12) : Color.clear))
                .contentShape(Rectangle())
                .onTapGesture { perform(action, item) }
                .onHover { if $0 { model.actionSelection = index } }
            }
        }
        .padding(7)
        .frame(width: 290)
        .clipboardGlass(in: RoundedRectangle(cornerRadius: 18, style: .continuous), tint: ClipboardPanelMetrics.tint)
        .shadow(color: .black.opacity(0.3), radius: 16, y: 6)
    }
}
