import AppKit
import SwiftUI

/// Native editor synchronization without a SwiftUI render pass or server fixture receipt.
@main struct CodexComposerSyncChecks {
    @MainActor static func main() {
        _ = NSApplication.shared
        let domain = "MacTools.ComposerSync." + UUID().uuidString
        let prefs = UserDefaults(suiteName: domain)!
        defer { prefs.removePersistentDomain(forName: domain) }
        let store = CodexStore(defaults: prefs, followAllChats: false)
        func composer(_ key: String) -> CodexComposer {
            CodexComposer(store: store, draftKey: key, height: .constant(44), send: {})
        }
        let editor = CodexComposer.Editor(frame: NSRect(x: 0, y: 0, width: 400, height: 80))
        let coordinator = composer("first").makeCoordinator()
        editor.delegate = coordinator
        coordinator.observeDraft(in: editor)
        editor.string = "venv activ at ecommand"
        coordinator.textDidChange(Notification(name: NSText.didChangeNotification, object: editor))
        precondition(store.drafts["first"] == editor.string)
        store.drafts["first"] = ""
        precondition(editor.string.isEmpty, "Accepted draft must clear native text synchronously, even without hosting-view updates")
        precondition(editor.selectedRange() == NSRange(location: 0, length: 0))
        store.drafts["first"] = "Entwurf nach geschlossener Ansicht"
        precondition(editor.string == store.drafts["first"], "A retained hidden editor must follow store changes")
        store.drafts["second"] = "Anderer Chat"
        coordinator.parent = composer("second")
        coordinator.observeDraft(in: editor)
        precondition(editor.string == "Anderer Chat")
        store.drafts["first"] = "Verspätete Änderung im vorherigen Chat"
        precondition(editor.string == "Anderer Chat", "Previous chat subscription must be cancelled")
        store.drafts["second"] = ""
        precondition(editor.string.isEmpty)
        store.drafts["second"] = "Fehlgeschlagener Entwurf"
        precondition(editor.string == "Fehlgeschlagener Entwurf")
        let other = CodexComposer.Editor(frame: editor.frame)
        let otherCoordinator = composer("second").makeCoordinator()
        otherCoordinator.observeDraft(in: other)
        store.drafts["second"] = ""
        precondition(editor.string.isEmpty && other.string.isEmpty)
        print("PASS: actual native composer clears synchronously without SwiftUI rendering; retained editors, chat switching, draft restoration and multiple editors stay synchronized")
    }
}
