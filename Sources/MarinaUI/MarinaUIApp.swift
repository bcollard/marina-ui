import SwiftUI
import AppKit

@main
struct MarinaUIApp: App {
    @State private var settings: AppSettings
    @State private var model: AppModel

    init() {
        NSApplication.shared.setActivationPolicy(.regular)
        // SwiftUI `.help()` tooltips use AppKit's default initial delay (~1s+),
        // which feels sluggish. AppKit reads this key (milliseconds) from the
        // standard defaults; set it early so all tooltips appear promptly.
        UserDefaults.standard.set(350, forKey: "NSInitialToolTipDelay")

        // Settings and model share one AppSettings instance: the views read it
        // from the environment, AppModel reads poll cadences off it directly.
        let settings = AppSettings()
        _settings = State(initialValue: settings)
        _model = State(initialValue: AppModel(settings: settings))
    }

    var body: some Scene {
        WindowGroup("Marina") {
            RootView(model: model)
                .environment(settings)
                .frame(minWidth: 800, minHeight: 500)
        }
        .windowResizability(.contentMinSize)
        .commands {
            // Standard place for it on macOS: right under "About Marina".
            CommandGroup(after: .appInfo) {
                Button("Check for Updates…") {
                    Task { await model.checkForUpdatesManually() }
                }
                .disabled(model.updates.checking)
            }
        }

        // Standard macOS Settings scene — bound to ⌘, and the "Settings…" menu item.
        Settings {
            SettingsView(model: model)
                .environment(settings)
        }
    }
}
