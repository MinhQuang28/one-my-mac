import SwiftUI

/// One page of the settings window: a centred, scrollable column with a header (icon, title,
/// one-line description) and sections below it.
public struct SettingsPage<Content: View>: View {
    let icon: String
    let tint: Color
    let title: String
    let subtitle: String?
    let content: Content

    public init(icon: String, tint: Color = .accentColor, title: String, subtitle: String? = nil,
                @ViewBuilder content: () -> Content) {
        self.icon = icon; self.tint = tint; self.title = title; self.subtitle = subtitle
        self.content = content()
    }

    public var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Gap.lg) {
                HStack(spacing: Gap.md) {
                    Image(systemName: icon)
                        .font(.system(size: 20, weight: .semibold)).foregroundStyle(.white)
                        .frame(width: 42, height: 42)
                        .background(RoundedRectangle(cornerRadius: Rad.md, style: .continuous).fill(tint.gradient))
                    VStack(alignment: .leading, spacing: 2) {
                        Text(title).font(.system(size: 20, weight: .semibold))
                        if let subtitle {
                            Text(subtitle).font(.system(size: FS.body)).foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
                .padding(.bottom, Gap.xs)
                content
            }
            .padding(.horizontal, 28).padding(.vertical, Gap.lg + 4)
            .frame(maxWidth: 720, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
    }
}

/// A titled group of rows on one card. Rows are separated by hairlines automatically, so a row
/// behind an `if` needs no divider bookkeeping.
public struct SettingsSection<Content: View>: View {
    let title: String?
    let footer: String?
    let content: Content

    public init(_ title: String? = nil, footer: String? = nil, @ViewBuilder content: () -> Content) {
        self.title = title; self.footer = footer; self.content = content()
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let title {
                Text(title).font(.system(size: FS.label, weight: .semibold)).foregroundStyle(.secondary)
                    .padding(.leading, Gap.xs)
            }
            VStack(alignment: .leading, spacing: 0) {
                Group(subviews: content) { rows in
                    ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
                        if index > 0 { Divider().padding(.leading, Gap.md + 2) }
                        row.padding(.horizontal, Gap.md + 2).padding(.vertical, 10)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
            .background(RoundedRectangle(cornerRadius: Rad.lg - 2, style: .continuous).fill(Color.cardFill))
            .overlay(RoundedRectangle(cornerRadius: Rad.lg - 2, style: .continuous).stroke(Color.hairline))
            if let footer {
                Text(footer).font(.system(size: FS.label)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true).padding(.horizontal, Gap.xs)
            }
        }
    }
}

/// One setting: optional icon, title, optional explanation under it, and the control on the right.
public struct SettingsRow<Trailing: View>: View {
    let title: String
    let detail: String?
    let icon: String?
    let trailing: Trailing

    public init(_ title: String, detail: String? = nil, icon: String? = nil,
                @ViewBuilder trailing: () -> Trailing) {
        self.title = title; self.detail = detail; self.icon = icon; self.trailing = trailing()
    }

    public var body: some View {
        HStack(spacing: Gap.sm + 2) {
            if let icon {
                Image(systemName: icon).font(.system(size: FS.title)).foregroundStyle(.secondary).frame(width: 20)
            }
            SettingsRowText(title: title, detail: detail)
            Spacer(minLength: Gap.md)
            trailing
        }
    }
}

public extension SettingsRow where Trailing == EmptyView {
    init(_ title: String, detail: String? = nil, icon: String? = nil) {
        self.init(title, detail: detail, icon: icon) { EmptyView() }
    }
}

public extension SettingsRow where Trailing == SettingsSwitch {
    /// A switch row.
    init(_ title: String, detail: String? = nil, icon: String? = nil, isOn: Binding<Bool>) {
        self.init(title, detail: detail, icon: icon) { SettingsSwitch(isOn: isOn) }
    }
}

public extension SettingsRow where Trailing == SettingsValue {
    /// A read-only value row.
    init(_ title: String, value: String, detail: String? = nil, icon: String? = nil) {
        self.init(title, detail: detail, icon: icon) { SettingsValue(value) }
    }
}

/// A setting whose control needs the full width (chips, a slider, a list): title on top, control below.
public struct SettingsStack<Content: View>: View {
    let title: String
    let detail: String?
    let value: String?
    let content: Content

    public init(_ title: String, detail: String? = nil, value: String? = nil, @ViewBuilder content: () -> Content) {
        self.title = title; self.detail = detail; self.value = value; self.content = content()
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: Gap.sm) {
            HStack(alignment: .firstTextBaseline) {
                SettingsRowText(title: title, detail: detail)
                Spacer(minLength: Gap.md)
                if let value { SettingsValue(value) }
            }
            content
        }
    }
}

public struct SettingsSwitch: View {
    @Binding var isOn: Bool
    public init(isOn: Binding<Bool>) { _isOn = isOn }
    public var body: some View {
        Toggle("", isOn: $isOn).toggleStyle(.switch).controlSize(.small).labelsHidden()
    }
}

public struct SettingsValue: View {
    let text: String
    public init(_ text: String) { self.text = text }
    public var body: some View {
        Text(text).font(.system(size: FS.body)).foregroundStyle(.secondary).monospacedDigit()
            .multilineTextAlignment(.trailing).textSelection(.enabled)
    }
}

/// Granted / missing state with an optional fix-it button.
public struct SettingsStatus: View {
    let ok: Bool
    let text: String
    let actionTitle: String?
    let action: (() -> Void)?

    public init(ok: Bool, text: String, actionTitle: String? = nil, action: (() -> Void)? = nil) {
        self.ok = ok; self.text = text; self.actionTitle = actionTitle; self.action = action
    }

    public var body: some View {
        HStack(spacing: Gap.sm) {
            Label(text, systemImage: ok ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                .font(.system(size: FS.body, weight: .medium)).foregroundStyle(ok ? .green : .orange)
            if !ok, let actionTitle, let action {
                Button(actionTitle, action: action).controlSize(.small)
            }
        }
    }
}

struct SettingsRowText: View {
    let title: String
    let detail: String?
    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.system(size: FS.title))
            if let detail {
                Text(detail).font(.system(size: FS.label)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}
