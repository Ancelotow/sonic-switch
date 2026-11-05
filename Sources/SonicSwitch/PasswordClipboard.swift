import AppKit

@MainActor final class PasswordClipboard {
    private let pasteboard: NSPasteboard
    private let lifetime: Duration
    private var ownedChangeCount: Int?
    private var cleanup: Task<Void, Never>?

    init(pasteboard: NSPasteboard = .general, lifetime: Duration = .seconds(30)) {
        self.pasteboard = pasteboard
        self.lifetime = lifetime
    }

    func copy(_ password: String) {
        cleanup?.cancel()
        pasteboard.clearContents()
        let item = NSPasteboardItem()
        item.setString(password, forType: .string)
        item.setData(Data(), forType: .init("org.nspasteboard.ConcealedType"))
        item.setData(Data(), forType: .init("org.nspasteboard.TransientType"))
        pasteboard.writeObjects([item])
        ownedChangeCount = pasteboard.changeCount
        cleanup = Task { [weak self, lifetime] in
            do { try await Task.sleep(for: lifetime) } catch { return }
            self?.clearIfOwned()
        }
    }

    func clearIfOwned() {
        cleanup?.cancel()
        cleanup = nil
        if let ownedChangeCount, pasteboard.changeCount == ownedChangeCount { pasteboard.clearContents() }
        ownedChangeCount = nil
    }
}
