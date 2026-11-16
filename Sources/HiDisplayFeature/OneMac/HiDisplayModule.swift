import Combine
import HiDisplayKit
import OneMacUI
import SwiftUI

/// What OneMac needs from the HiDisplay feature: lifecycle, the panel cards and the settings pages.
@MainActor
public enum HiDisplayModule {
    public static func start() async { await AppModel.shared.start() }
    /// Clears software dimming and flushes profiles; must finish before the process exits.
    public static func stop() async { await AppModel.shared.stop() }
    public static func resetDimming() { AppModel.shared.resetDimming() }
    public static var version: String { AppModel.version }
}

/// Lightweight, public view of the connected displays for the settings sidebar.
public struct DisplaySummary: Identifiable, Hashable, Sendable {
    public let id: String
    public let name: String
    public let isBuiltIn: Bool
    public let isMain: Bool
}

/// Publishes `DisplaySummary` values without exposing `AppModel`.
@MainActor
public final class DisplayDirectory: ObservableObject {
    public static let shared = DisplayDirectory()
    @Published public private(set) var displays: [DisplaySummary] = []
    private var cancellable: AnyCancellable?

    private init() {
        cancellable = AppModel.shared.$displays.sink { [weak self] list in
            self?.displays = list.map {
                DisplaySummary(id: $0.id, name: $0.name, isBuiltIn: $0.isBuiltIn, isMain: $0.isMain)
            }
        }
    }
}

/// One settings page from the HiDisplay feature.
public struct HiDisplayPaneView: View {
    let pane: SettingsPane
    @ObservedObject private var model = AppModel.shared
    public init(pane: SettingsPane) { self.pane = pane }

    public var body: some View {
        Group {
            switch pane {
            case .display(let id):
                if let display = model.displays.first(where: { $0.id == id }) {
                    DisplayPage(display: display)
                } else {
                    ContentUnavailableView(tr("Display disconnected", "Màn hình đã ngắt"),
                                           systemImage: "display.trianglebadge.exclamationmark")
                }
            case .hiDPI: HiDPIWizard()
            case .brightnessKeys: BrightnessKeysPage()
            case .displayDiagnostics: DiagnosticsPage()
            default: EmptyView()
            }
        }
        .environmentObject(model)
        .onAppear(perform: syncRoute)
        .onChange(of: pane) { syncRoute() }
    }

    /// The HiDisplay pages read the selected display from the model's route.
    private func syncRoute() {
        switch pane {
        case .display(let id): model.navigate(to: .display(id))
        case .hiDPI: model.navigate(to: .hiDPI)
        case .brightnessKeys: model.navigate(to: .brightnessKeys)
        case .displayDiagnostics: model.navigate(to: .diagnostics)
        default: break
        }
    }
}
