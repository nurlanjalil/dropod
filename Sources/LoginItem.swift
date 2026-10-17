import AppKit
import ServiceManagement

/// Opening Dropod at login, through macOS's login items (System Settings → General → Login Items).
/// Only the copy in /Applications registers itself, never a build folder that gets replaced.
enum LoginItem {
    static var isInstalled: Bool {
        Bundle.main.bundlePath.hasPrefix("/Applications/")
            || Bundle.main.bundlePath.hasPrefix(NSHomeDirectory() + "/Applications/")
    }

    static var isEnabled: Bool { SMAppService.mainApp.status == .enabled }

    /// macOS wants the user to allow it in System Settings first.
    static var needsApproval: Bool { SMAppService.mainApp.status == .requiresApproval }

    /// On by default: the first time Dropod runs from /Applications, it turns itself on once.
    static func setUpIfNeeded() {
        guard isInstalled, !Settings.loginItemSetUp else { return }
        Settings.loginItemSetUp = true
        try? SMAppService.mainApp.register()
    }

    static func toggle() {
        do {
            if isEnabled || needsApproval {
                try SMAppService.mainApp.unregister()
            } else {
                try SMAppService.mainApp.register()
            }
        } catch {
            let alert = NSAlert()
            alert.messageText = "Couldn't change Open at Login"
            alert.informativeText = error.localizedDescription
            NSApp.activate()
            alert.runModal()
        }
    }

    static func openSystemSettings() { SMAppService.openSystemSettingsLoginItems() }
}
