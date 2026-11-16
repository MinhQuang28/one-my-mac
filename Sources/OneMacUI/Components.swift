import SwiftUI

/// Rounded surface every panel section sits in.
public struct Card<Content: View>: View {
    private let content: Content
    public init(@ViewBuilder content: () -> Content) { self.content = content() }
    public var body: some View {
        VStack(alignment: .leading, spacing: Gap.sm) { content }
            .padding(Gap.md)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: Rad.lg, style: .continuous).fill(Color.cardFill))
            .overlay(RoundedRectangle(cornerRadius: Rad.lg, style: .continuous).stroke(Color.hairline))
    }
}

/// Square tinted icon used at the leading edge of a card header.
public struct IconBadge: View {
    let systemName: String
    let tint: Color
    public init(_ systemName: String, tint: Color = .accentColor) {
        self.systemName = systemName; self.tint = tint
    }
    public var body: some View {
        Image(systemName: systemName)
            .font(.system(size: FS.subhead, weight: .semibold))
            .foregroundStyle(tint)
            .frame(width: 30, height: 30)
            .background(RoundedRectangle(cornerRadius: Rad.sm + 2, style: .continuous).fill(tint.opacity(0.15)))
    }
}

/// Card header: icon, title, optional subtitle and a trailing accessory (toggle, value, button).
public struct CardHeader<Trailing: View>: View {
    let icon: String
    let tint: Color
    let title: String
    let subtitle: String?
    let trailing: Trailing
    public init(icon: String, tint: Color = .accentColor, title: String, subtitle: String? = nil,
                @ViewBuilder trailing: () -> Trailing) {
        self.icon = icon; self.tint = tint; self.title = title; self.subtitle = subtitle
        self.trailing = trailing()
    }
    public var body: some View {
        HStack(spacing: Gap.sm + 2) {
            IconBadge(icon, tint: tint)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: FS.title, weight: .semibold)).lineLimit(1)
                if let subtitle {
                    Text(subtitle).font(.system(size: FS.label)).foregroundStyle(.secondary)
                        .lineLimit(2).fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: Gap.sm)
            trailing
        }
    }
}

public extension CardHeader where Trailing == EmptyView {
    init(icon: String, tint: Color = .accentColor, title: String, subtitle: String? = nil) {
        self.init(icon: icon, tint: tint, title: title, subtitle: subtitle) { EmptyView() }
    }
}

/// A compact switch.
public struct CompactToggle: View {
    @Binding var isOn: Bool
    public init(isOn: Binding<Bool>) { _isOn = isOn }
    public var body: some View {
        Toggle("", isOn: $isOn).toggleStyle(.switch).controlSize(.small).labelsHidden()
    }
}

/// One line inside a card: label (+ optional icon) on the left, a switch on the right.
public struct ToggleRow: View {
    let title: String
    let icon: String?
    @Binding var isOn: Bool
    public init(_ title: String, icon: String? = nil, isOn: Binding<Bool>) {
        self.title = title; self.icon = icon; _isOn = isOn
    }
    public var body: some View {
        HStack(spacing: Gap.sm) {
            if let icon {
                Image(systemName: icon).font(.system(size: FS.body)).foregroundStyle(.secondary).frame(width: 16)
            }
            Text(title).font(.system(size: FS.body))
            Spacer()
            CompactToggle(isOn: $isOn)
        }
    }
}

/// Small stat block: caption title, big value, optional footnote.
public struct StatTile: View {
    let title: String
    let value: String
    let note: String?
    let valueColor: Color
    public init(_ title: String, value: String, note: String? = nil, valueColor: Color = .primary) {
        self.title = title; self.value = value; self.note = note; self.valueColor = valueColor
    }
    public var body: some View {
        VStack(spacing: 3) {
            Text(title).font(.system(size: FS.caption, weight: .medium)).foregroundStyle(.secondary)
            Text(value).font(.system(size: FS.title, weight: .semibold)).foregroundStyle(valueColor)
                .monospacedDigit().lineLimit(1).minimumScaleFactor(0.7)
            if let note {
                Text(note).font(.system(size: FS.caption)).foregroundStyle(.tertiary).lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, Gap.sm)
        .background(RoundedRectangle(cornerRadius: Rad.md, style: .continuous).fill(Color.tileFill))
    }
}

/// Segmented chips: equal-width buttons, one selected.
public struct ChipPicker<Value: Hashable>: View {
    let options: [(Value, String)]
    @Binding var selection: Value
    public init(_ options: [(Value, String)], selection: Binding<Value>) {
        self.options = options; _selection = selection
    }
    public var body: some View {
        HStack(spacing: Gap.xs) {
            ForEach(Array(options.enumerated()), id: \.offset) { _, option in
                let selected = option.0 == selection
                Button { selection = option.0 } label: {
                    Text(option.1)
                        .font(.system(size: FS.label, weight: selected ? .semibold : .medium))
                        .frame(maxWidth: .infinity).padding(.vertical, 6)
                        .foregroundStyle(selected ? Color.white : Color.primary)
                        .background(RoundedRectangle(cornerRadius: Rad.sm + 1, style: .continuous)
                            .fill(selected ? Color.accentColor : Color.tileFill))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
    }
}

/// Inline warning strip with an action.
public struct NoticeRow: View {
    let text: String
    let actionTitle: String?
    let action: (() -> Void)?
    public init(_ text: String, actionTitle: String? = nil, action: (() -> Void)? = nil) {
        self.text = text; self.actionTitle = actionTitle; self.action = action
    }
    public var body: some View {
        HStack(alignment: .center, spacing: Gap.sm) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            Text(text).font(.system(size: FS.label)).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            if let actionTitle, let action {
                Button(actionTitle, action: action).buttonStyle(.borderless)
                    .font(.system(size: FS.label, weight: .semibold)).foregroundStyle(.orange)
            }
        }
        .padding(Gap.sm + 2)
        .background(RoundedRectangle(cornerRadius: Rad.md, style: .continuous).fill(Color.orange.opacity(0.12)))
    }
}

/// Text-style action button used for "open advanced settings" links inside cards.
public struct LinkButton: View {
    let title: String
    let icon: String
    let action: () -> Void
    public init(_ title: String, icon: String = "chevron.right", action: @escaping () -> Void) {
        self.title = title; self.icon = icon; self.action = action
    }
    public var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Text(title)
                Image(systemName: icon).font(.system(size: FS.caption, weight: .semibold))
            }
            .font(.system(size: FS.label, weight: .medium))
        }
        .buttonStyle(.borderless)
    }
}
