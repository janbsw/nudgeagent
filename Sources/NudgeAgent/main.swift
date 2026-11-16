import AppKit

// Composition root: builds every module and wires them through the Shared protocols.

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var settings = AppSettings.load()
    private var state: SessionState!
    private var sensors: SensorHub!
    private var inspector: ScreenInspector!
    private var llm: LLMClient!
    private var classifier: Classifier!
    private var profileGenerator: ProfileGenerator!
    private var coordinator: SessionCoordinator!
    private var ui: AppUI!

    func applicationDidFinishLaunching(_ notification: Notification) {
        let settingsProvider: () -> AppSettings = { [unowned self] in self.settings }

        state = SessionState()
        sensors = SensorHub(settingsProvider: settingsProvider)
        inspector = ScreenInspector(settingsProvider: settingsProvider)
        llm = LLMClient()
        classifier = Classifier(llm: llm, inspector: inspector, settingsProvider: settingsProvider)
        profileGenerator = ProfileGenerator(llm: llm, settingsProvider: settingsProvider)
        coordinator = SessionCoordinator(state: state, sensors: sensors, classifier: classifier, profileGenerator: profileGenerator)

        ui = AppUI(state: state, controller: coordinator)
        coordinator.presenter = ui.presenter
        ui.onSettingsChanged = { [unowned self] newSettings in
            self.settings = newSettings
            self.coordinator.reloadSettings(newSettings)
        }

        coordinator.reloadSettings(settings)
        ui.start()
        coordinator.start()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
