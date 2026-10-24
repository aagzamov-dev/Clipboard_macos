import AppKit
import ClipboardCore

@MainActor final class SettingsStore {
    private(set) var value: AppSettings
    let isPersistent: Bool
    var onChange: (() -> Void)?
    init(persistent: Bool = true) {
        isPersistent = persistent
        if persistent, let data = UserDefaults.standard.data(forKey: "settings"), let decoded = try? AppSettings.decode(data) { value = decoded }
        else { value = AppSettings() }
    }
    func update(_ body: (inout AppSettings) -> Void) throws {
        var next = value; body(&next); try next.validate()
        if isPersistent { UserDefaults.standard.set(try JSONEncoder().encode(next), forKey: "settings") }
        value = next; onChange?()
    }
    func importSettings(_ data: Data) throws {
        var imported = try AppSettings.decode(data)
        imported.onboardingComplete = value.onboardingComplete
        imported.lastCleanup = nil
        try update { $0 = imported }
    }
}
