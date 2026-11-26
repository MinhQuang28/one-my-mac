import OneMacUI
import SwiftUI

/// The history window: search and type filter on top, the list beside a preview of the selected
/// item, and two glass capsules floating over the bottom edge with the main actions.
struct ClipboardPanelView: View {
    @ObservedObject var history: ClipboardHistory
    @ObservedObject var model: ClipboardPanelModel
    let perform: (ClipboardAction, ClipboardItem) -> Void
    @FocusState private var searchFocused: Bool

    /// Room the floating capsules take at the bottom, so the last row can scroll clear of them.
    private static let bottomBar: CGFloat = 62

    var body: some View {
        let results = history.store.matching(model.query, kind: model.kind)
        let selected = results.indices.contains(model.selection) ? results[model.selection] : nil
        let shape = RoundedRectangle(cornerRadius: ClipboardPanelMetrics.cornerRadius, style: .continuous)
        VStack(spacing: 0) {
            header
            if results.isEmpty {
                Text(model.query.isEmpty && model.kind == nil ? tr("Nothing copied yet", "Chưa có gì được sao chép")
                                                             : tr("No matches", "Không tìm thấy"))
                    .font(.system(size: FS.subhead)).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                HStack(spacing: 0) {
                    list(results).frame(width: 310)
                    Rectangle().fill(Color.white.opacity(0.08)).frame(width: 1).padding(.bottom, Gap.md)
                    if let selected {
                        ClipboardPreview(item: selected, history: history, bottomInset: Self.bottomBar)
                    }
                }
            }
        }
        .overlay(alignment: .bottom) { bottomBar(selected) }
        .overlay(alignment: .bottomTrailing) {
            if model.actionsOpen, let selected {
                ClipboardActionsMenu(item: selected, model: model, perform: perform)
                    .padding(.trailing, Gap.md).padding(.bottom, Self.bottomBar)
            }
        }
        .frame(width: ClipboardPanelMetrics.content.width, height: ClipboardPanelMetrics.content.height)
        .clipShape(shape)
        .clipboardGlass(in: shape, tint: ClipboardPanelMetrics.tint)
        .shadow(color: .black.opacity(0.4), radius: 22, y: 10)
        .padding(ClipboardPanelMetrics.margin)
        // Always the dark form: the glass is tinted dark, so the text must stay white whatever the
        // desktop behind it looks like. Glass would otherwise pick its own text colour.
        .foregroundStyle(.white)
        .environment(\.colorScheme, .dark)
        .onAppear { searchFocused = true }
    }

    private var header: some View {
        HStack(spacing: Gap.md) {
            Image(systemName: "magnifyingglass").font(.system(size: 15, weight: .medium)).foregroundStyle(.secondary)
            TextField(tr("Type to filter entries…", "Gõ để lọc…"), text: $model.query)
                .textFieldStyle(.plain).font(.system(size: 17))
                .focused($searchFocused)
            Menu {
                Button { model.kind = nil } label: { Label(tr("All Types", "Tất cả"), systemImage: "list.bullet") }
                Divider()
                ForEach(ClipboardKind.allCases) { kind in
                    Button { model.kind = kind } label: { Label(kind.title, systemImage: kind.icon) }
                }
            } label: {
                Label(model.kind?.title ?? tr("All Types", "Tất cả"), systemImage: model.kind?.icon ?? "list.bullet")
                    .font(.system(size: FS.title, weight: .medium))
            }
            .menuStyle(.borderlessButton).fixedSize()
            .help(tr("Tab switches the type", "Tab để đổi loại"))
        }
        .padding(.horizontal, 22).padding(.top, 22).padding(.bottom, Gap.md)
    }

    private func list(_ results: [ClipboardItem]) -> some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    ForEach(Array(results.enumerated()), id: \.element.id) { index, item in
                        // A heading wherever the day (or the pinned group) changes.
                        if index == 0 || Self.section(of: item) != Self.section(of: results[index - 1]) {
                            Text(Self.section(of: item))
                                .font(.system(size: FS.label, weight: .medium)).foregroundStyle(.secondary)
                                .padding(.horizontal, Gap.md).padding(.top, index == 0 ? 2 : Gap.md).padding(.bottom, 4)
                        }
                        ClipboardRow(item: item, selected: index == model.selection,
                                     thumbnail: history.thumbnail(for: item, maxPixel: 72))
                            .id(item.id)
                            .contentShape(Rectangle())
                            // Simultaneous, so a single click selects at once instead of waiting
                            // out the double-click interval.
                            .onTapGesture { model.selection = index }
                            .simultaneousGesture(TapGesture(count: 2).onEnded { perform(.paste, item) })
                    }
                }
                .padding(.horizontal, Gap.sm + 2).padding(.bottom, Self.bottomBar)
            }
            .scrollIndicators(.never)
            .onChange(of: model.selection) { _, selection in
                guard results.indices.contains(selection) else { return }
                withAnimation(.easeOut(duration: 0.12)) { proxy.scrollTo(results[selection].id) }
            }
        }
    }

    /// Two capsules floating over the content: what this window is, and what Return and ⌘K do.
    private func bottomBar(_ selected: ClipboardItem?) -> some View {
        HStack {
            Label(tr("Clipboard History", "Lịch sử clipboard"), systemImage: "doc.on.clipboard.fill")
                .font(.system(size: FS.title, weight: .medium))
                .padding(.horizontal, 14).frame(height: 34)
                .clipboardGlass(in: Capsule())
            Spacer()
            if let selected {
                HStack(spacing: 14) {
                    barButton(history.canPasteDirectly ? ClipboardAction.paste.title(for: selected, target: model.targetApp)
                                                       : ClipboardAction.copy.title(for: selected, target: nil),
                              keys: ["↩"]) { perform(.paste, selected) }
                    barButton(tr("Actions", "Thao tác"), keys: ["⌘", "K"]) {
                        model.actionSelection = 0
                        model.actionsOpen.toggle()
                    }
                }
                .padding(.horizontal, 14).frame(height: 34)
                .clipboardGlass(in: Capsule())
            }
        }
        .padding(.horizontal, Gap.md).padding(.bottom, Gap.md)
    }

    private func barButton(_ title: String, keys: [String], action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Text(title).font(.system(size: FS.title, weight: .medium)).lineLimit(1)
                ForEach(keys, id: \.self) { KeyCap($0) }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain).focusEffectDisabled()
    }

    /// "Pinned", "Today", "Yesterday", or the date.
    static func section(of item: ClipboardItem) -> String {
        if item.isPinned { return tr("Pinned", "Đã ghim") }
        let calendar = Calendar.current
        if calendar.isDateInToday(item.copiedAt) { return tr("Today", "Hôm nay") }
        if calendar.isDateInYesterday(item.copiedAt) { return tr("Yesterday", "Hôm qua") }
        return item.copiedAt.formatted(date: .abbreviated, time: .omitted)
    }
}

/// A key printed as a small rounded cap.
struct KeyCap: View {
    let text: String
    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text).font(.system(size: FS.label, weight: .medium, design: .rounded))
            .frame(minWidth: 20, minHeight: 20).padding(.horizontal, 2)
            .background(RoundedRectangle(cornerRadius: 6, style: .continuous).strokeBorder(Color.white.opacity(0.25)))
    }
}

/// One copy in the list: its kind (or a thumbnail) and one line of what it is.
private struct ClipboardRow: View {
    let item: ClipboardItem
    let selected: Bool
    let thumbnail: NSImage?

    var body: some View {
        HStack(spacing: Gap.sm + 2) {
            Group {
                if let thumbnail {
                    Image(nsImage: thumbnail).resizable().scaledToFill()
                } else {
                    Image(systemName: item.kind.icon).font(.system(size: 13, weight: .medium))
                }
            }
            .frame(width: 26, height: 26)
            .background(Color.white.opacity(0.08))
            .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
            Text(item.title).font(.system(size: FS.title)).lineLimit(1).truncationMode(.tail)
            Spacer(minLength: 0)
            if item.isPinned {
                Image(systemName: "pin.fill").font(.system(size: FS.label)).foregroundStyle(.orange)
            }
        }
        .padding(.horizontal, Gap.sm + 2).padding(.vertical, 5)
        .background(RoundedRectangle(cornerRadius: 11, style: .continuous)
            .fill(selected ? Color.white.opacity(0.1) : Color.clear))
    }
}
