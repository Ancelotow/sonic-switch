import AppKit
import ApplicationServices
import VPNCore

private final class LoginCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var stopped = false
    func cancel() { lock.lock(); stopped = true; lock.unlock() }
    var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return stopped }
}

@MainActor final class LoginAssistant: ObservableObject {
    static let shared = LoginAssistant()
    @Published private(set) var permissionGranted = AXIsProcessTrusted()
    @Published private(set) var message: String?
    @Published private(set) var connectionName: String?
    private struct Pending: Sendable {
        let id = UUID()
        let request: LoginRequest
        let cancellation = LoginCancellation()
    }
    private var pending: Pending?
    private var scanning = false

    func refreshPermission() {
        let granted = AXIsProcessTrusted()
        if granted != permissionGranted { permissionGranted = granted }
    }

    func requestPermission() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
        refreshPermission()
        if !permissionGranted, let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }

    func prepare(_ url: URL) {
        finish()
        message = nil
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        func value(_ key: String) -> String { items.first { $0.name == key }?.value ?? "" }
        connectionName = value("name")
        let request = LoginRequest(server: value("server"), username: value("username"), password: value("password"))
        guard !request.password.isEmpty else { return }
        pending = Pending(request: request)
        refreshPermission()
        if !permissionGranted {
            message = "Pour remplir le formulaire SonicWall sans ressaisie, autorise SonicSwitch dans Accessibilité."
        } else if request.server.isEmpty {
            message = "Renseigne le serveur dans le profil pour identifier le formulaire SonicWall à remplir."
        } else {
            message = "Remplissage automatique prêt : en attente du formulaire SonicWall."
        }
    }

    func tick() async {
        guard !scanning, let current = pending else { return }
        refreshPermission()
        guard permissionGranted, !current.request.server.isEmpty,
              let app = NSWorkspace.shared.frontmostApplication,
              app.bundleIdentifier == SystemTransport.bundleID else { return }
        scanning = true
        let pid = app.processIdentifier
        let result = await withTaskCancellationHandler {
            await Task.detached(priority: .userInitiated) {
                SonicWallLoginForm.fill(pid: pid, request: current.request, cancellation: current.cancellation)
            }.value
        } onCancel: { current.cancellation.cancel() }
        scanning = false
        guard pending?.id == current.id, !current.cancellation.isCancelled else { return }
        switch result {
        case .noForm: break
        case .submitted:
            message = "Identifiants renseignés et formulaire SonicWall validé."
            finish()
        case .filled:
            message = "Mot de passe renseigné dans SonicWall. Valide la connexion dans sa fenêtre."
            finish()
        case .refused:
            message = "SonicWall refuse le remplissage du champ. Le bouton Copier le mot de passe reste disponible."
            finish()
        }
    }

    func finish() {
        pending?.cancellation.cancel()
        pending = nil
        if message == "Remplissage automatique prêt : en attente du formulaire SonicWall." { message = nil }
    }
}

private enum SonicWallLoginForm {
    enum Result: Sendable { case noForm, filled, submitted, refused }

    static func fill(pid: pid_t, request: LoginRequest, cancellation: LoginCancellation) -> Result {
        guard !cancellation.isCancelled,
              NSRunningApplication(processIdentifier: pid)?.bundleIdentifier == SystemTransport.bundleID else { return .noForm }
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.08)
        guard flag(app, kAXFrontmostAttribute), let rawWindow = attribute(app, kAXFocusedWindowAttribute),
              CFGetTypeID(rawWindow) == AXUIElementGetTypeID() else { return .noForm }
        let window = rawWindow as! AXUIElement
        let sheets = (attribute(window, "AXSheets") as? [AXUIElement]) ?? []
        guard sheets.count <= 1 else { return .noForm }
        let deadline = ContinuousClock.now + .milliseconds(600)
        var elements: [AXUIElement] = []
        var controls: [LoginControl] = []
        var queue = [sheets.first ?? window]
        while !queue.isEmpty {
            guard !cancellation.isCancelled, ContinuousClock.now < deadline, elements.count < 180 else { return .noForm }
            let element = queue.removeFirst()
            if elements.contains(where: { CFEqual($0, element) }) { continue }
            AXUIElementSetMessagingTimeout(element, 0.05)
            if flag(element, "AXHidden") { continue }
            let role = string(element, kAXRoleAttribute)
            let secure = string(element, kAXSubroleAttribute) == kAXSecureTextFieldSubrole as String
            let id = elements.count
            elements.append(element)
            var settable = DarwinBoolean(false)
            AXUIElementIsAttributeSettable(element, kAXValueAttribute as CFString, &settable)
            let title = string(element, kAXTitleAttribute)
            let label = role == kAXButtonRole as String ? title : [title, string(element, kAXDescriptionAttribute), string(element, kAXIdentifierAttribute)].joined(separator: " ")
            // Never ask Accessibility for the contents of a secure field.
            let passwordLabel = label.lowercased().contains("password") || label.lowercased().contains("mot de passe")
            let value = !secure && !passwordLabel && ["AXTextField", "AXStaticText", "AXComboBox"].contains(role) ? string(element, kAXValueAttribute) : ""
            controls.append(LoginControl(id: id, role: role, secure: secure, editable: settable.boolValue,
                                         enabled: (attribute(element, kAXEnabledAttribute) as? Bool) ?? true,
                                         label: label, value: value))
            queue += (attribute(element, kAXChildrenAttribute) as? [AXUIElement]) ?? []
            queue += (attribute(element, "AXSheets") as? [AXUIElement]) ?? []
        }
        guard let match = LoginFormPolicy.match(controls, request: request),
              !cancellation.isCancelled, flag(app, kAXFrontmostAttribute),
              NSRunningApplication(processIdentifier: pid)?.bundleIdentifier == SystemTransport.bundleID else { return .noForm }
        let username = elements[match.usernameID]
        let password = elements[match.passwordID]
        if controls[match.usernameID].value.isEmpty {
            guard AXUIElementSetAttributeValue(username, kAXValueAttribute as CFString, request.username as CFString) == .success else { return .refused }
        }
        guard !cancellation.isCancelled, flag(app, kAXFrontmostAttribute) else { return .noForm }
        guard AXUIElementSetAttributeValue(password, kAXValueAttribute as CFString, request.password as CFString) == .success else { return .refused }
        guard !cancellation.isCancelled else { return .filled }
        // Focus changes commit AppKit's field bindings before the login action.
        _ = AXUIElementSetAttributeValue(password, kAXFocusedAttribute as CFString, kCFBooleanTrue)
        guard let submit = match.submitID else { return .filled }
        guard flag(app, kAXFrontmostAttribute) else { return .filled }
        return AXUIElementPerformAction(elements[submit], kAXPressAction as CFString) == .success ? .submitted : .filled
    }

    private static func attribute(_ element: AXUIElement, _ key: String) -> CFTypeRef? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, key as CFString, &value) == .success else { return nil }
        return value
    }
    private static func string(_ element: AXUIElement, _ key: String) -> String { attribute(element, key) as? String ?? "" }
    private static func flag(_ element: AXUIElement, _ key: String) -> Bool { attribute(element, key) as? Bool == true }
}
