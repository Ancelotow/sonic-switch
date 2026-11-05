import SwiftUI
import AppKit

@main struct SonicSwitchApp: App {
    // Views observe this model; status changes must not rebuild the scene graph.
    private let model = AppModel()
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        Window("SonicSwitch", id: "main") {
            AppWindow(model: model, delegate: delegate)
                .frame(minWidth: 820, minHeight: 560)
        }
        .defaultSize(width: 920, height: 680)
        .commands {
            CommandGroup(replacing: .newItem) { }
        }
    }
}

private struct AppWindow: View {
    let model: AppModel
    let delegate: AppDelegate
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        MainView(model: model)
            .onAppear {
                delegate.configure(model: model) { openWindow(id: "main") }
            }
    }
}

@MainActor final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var statusItem: NSStatusItem?
    private var model: AppModel?
    private var showWindow: (() -> Void)?

    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls { ConnectionFeedback.shared.receive(url) }
    }

    func configure(model: AppModel, showWindow: @escaping () -> Void) {
        self.model = model
        self.showWindow = showWindow
        guard statusItem == nil else { return }
        // Populate a native menu when opened, independently of SwiftUI rendering.
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.title = " VPN"
        item.button?.image = NSImage(systemSymbolName: "network", accessibilityDescription: "VPN")
        item.button?.imagePosition = .imageLeading
        let menu = NSMenu()
        menu.autoenablesItems = false
        menu.delegate = self
        item.menu = menu
        statusItem = item
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        guard let model else { return }
        menu.removeAllItems()
        let state = model.monitoringError != nil ? "État VPN indisponible" : model.active.map { "\($0.name) · \($0.stateLabel)" } ?? "VPN déconnecté"
        add(state, to: menu)
        if model.busy { add("Opération en cours…", to: menu) }
        if model.message != nil { add("Échec : ouvrir SonicSwitch pour les détails", to: menu) }
        menu.addItem(.separator())
        for profile in model.sortedProfiles {
            let item = add(profile.name, to: menu, action: #selector(connectProfile(_:)))
            item.representedObject = profile.id.uuidString
            item.isEnabled = !model.busy && model.ready
            item.state = model.services.contains { $0.name == profile.connectionName && $0.isConnected } ? .on : .off
        }
        if model.busy || model.active != nil {
            add(model.busy ? "Annuler et déconnecter" : "Déconnecter", to: menu, action: #selector(disconnectVPN))
        }
        menu.addItem(.separator())
        add("Ouvrir SonicSwitch", to: menu, action: #selector(openMainWindow))
        add("Afficher Mobile Connect", to: menu, action: #selector(openClient))
        menu.addItem(.separator())
        add("Quitter SonicSwitch", to: menu, action: #selector(quit))
    }

    @discardableResult private func add(_ title: String, to menu: NSMenu, action: Selector? = nil) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        item.isEnabled = action != nil
        menu.addItem(item)
        return item
    }

    @objc private func connectProfile(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String,
              let profile = model?.profiles.first(where: { $0.id.uuidString == id }) else { return }
        openMainWindow()
        model?.connect(profile)
    }
    @objc private func disconnectVPN() { model?.disconnect() }
    @objc private func openClient() { model?.openSonicWall() }
    @objc private func quit() { NSApp.terminate(nil) }
    @objc private func openMainWindow() {
        showWindow?()
        NSApp.activate(ignoringOtherApps: true)
    }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { openMainWindow() }
        return true
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
    func applicationWillTerminate(_ notification: Notification) { model?.clearCopiedPassword() }
}
