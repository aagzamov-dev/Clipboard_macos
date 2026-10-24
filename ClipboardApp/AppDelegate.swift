import AppKit
import ClipboardCore

@MainActor final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem?
    private var history: HistoryWindowController?
    private var preferences: SettingsWindowController?
    private var settings: SettingsStore?
    private var store: HistoryStore?
    private var monitor: ClipboardMonitor?
    private var shortcut: GlobalShortcut?
    private var paste: PasteCoordinator?
    private var pasteCheck: PasteCheckController?
    private var cleanupTimer: Timer?
    private var manuallyPaused = false
    private var blocked: MonitorState?
    private var suspended = Set<String>()
    private var currentState: MonitorState = .manuallyPaused
    private var statusMenu: NSMenu?
    private var pauseItem: NSMenuItem?
    private var fixtureMode = false
    private var quitting = false
    private var restarting = false
    private var updates: UpdateController?
    private var registeredShortcut: (UInt32, UInt32)?

    func applicationDidFinishLaunching(_ notification: Notification) {
        umask(0o077)
        NSApp.setActivationPolicy(.accessory)
        #if DEBUG
        fixtureMode = CommandLine.arguments.contains("--fixtures") || Bundle.main.object(forInfoDictionaryKey: "ClipboardFixtureMode") as? String == "YES"
        #endif
        Task { await initialize() }
    }
    private func initialize() async {
        do {
            let root: URL
            if fixtureMode {
                root = FileManager.default.temporaryDirectory.appendingPathComponent("Clipboard-Fixtures-\(ProcessInfo.processInfo.processIdentifier)")
            } else { root = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true).appendingPathComponent("Clipboard", isDirectory: true) }
            let store = try await Task.detached(priority: .userInitiated) { try HistoryStore(rootURL: root) }.value
            self.store = store
            let settings = SettingsStore(persistent: !fixtureMode); self.settings = settings
            let monitor = ClipboardMonitor(store: store, onState: { [weak self] state in self?.monitorChanged(state) }, onCapture: { [weak self] in if self?.history?.window?.isVisible == true { self?.history?.refresh() } }, onError: { [weak self] message in self?.history?.showNotice(message) })
            self.monitor = monitor
            let paste = PasteCoordinator(sessionToken: monitor.sessionToken, testMode: fixtureMode); self.paste = paste
            let history = HistoryWindowController(store: store, settings: settings, paste: paste); self.history = history
            let preferences = SettingsWindowController(settings: settings, store: store, pasteStatus: { [weak paste] in paste?.lastStatus ?? "No paste attempted." }); self.preferences = preferences
            if !fixtureMode {
                let updates = UpdateController(); self.updates = updates
                updates.prepareToInstall = { [weak history] install in
                    history?.requestClose(completion: install)
                }
                preferences.updateChecksEnabled = { [weak updates] in updates?.automaticChecks ?? false }
                preferences.onUpdateChecksChanged = { [weak updates] in updates?.automaticChecks = $0 }
                preferences.onCheckForUpdates = { [weak self] in self?.checkForUpdates(nil) }
                preferences.canCheckForUpdates = { [weak updates] in updates?.canCheck ?? false }
            }
            if !fixtureMode {
                let check = PasteCheckController(sessionToken: monitor.sessionToken); pasteCheck = check
                preferences.onPasteTest = { [weak check, weak preferences] in
                    preferences?.showPasteTestResult("Testing paste delivery…", running: true)
                    Task {
                        let result = await check?.run() ?? "Paste test unavailable."
                        preferences?.showPasteTestResult(result)
                        preferences?.openPasteSettings()
                    }
                }
            }
            if !fixtureMode { preferences.onRestart = { [weak self] in self?.restart() } }
            paste.onStatusChanged = { [weak preferences] in preferences?.refreshPermissionStatus() }
            history.onToggleRecording = { [weak self] in self?.togglePause() }
            history.onPasteSettings = { [weak preferences] in preferences?.openPasteSettings() }
            history.onSettings = { [weak preferences] in preferences?.open() }
            preferences.onHistoryChanged = { [weak history] in history?.refresh() }
            preferences.onHistoryCleared = { [weak history] includePinned in history?.historyWasCleared(includePinned: includePinned) }
            preferences.onPause = { [weak self] in self?.togglePause() }
            preferences.onCaptureResume = { [weak self] in self?.blocked = nil; self?.manuallyPaused = false; self?.applyCaptureState() }
            preferences.onShortcut = { [weak self] key, modifiers in try self?.registerShortcut(key, modifiers) }
            settings.onChange = { [weak self] in self?.settingsChanged() }
            let shortcut = GlobalShortcut(); self.shortcut = shortcut; shortcut.onOpen = { [weak self] in guard let self, !restarting else { return }; history.toggle() }
            if !fixtureMode {
                do { try registerShortcut(settings.value.shortcutKeyCode, settings.value.shortcutModifiers) }
                catch { history.showNotice(error.localizedDescription) }
            }
            buildMenu(); buildApplicationMenu(); observeWorkspace(); applyAppearance()
            try await store.reconcileAttachments()
            if fixtureMode {
                let page = try await store.page(.init())
                if page.totalCount == 0 { for text in ["Keep it simple. Make it feel native.", "let clipboard = NSPasteboard.general", "https://developer.apple.com/design/human-interface-guidelines", "The best tools get out of your way.\n\nA small, thoughtful utility that keeps what you copy, so you can stay focused on what you’re making."] { try await store.insert(.plainText(text)) } }
                manuallyPaused = true; history.open()
            } else if !settings.value.onboardingComplete { showOnboarding() }
            else { manuallyPaused = false; applyCaptureState(); updates?.start() }
            if !fixtureMode { await performMaintenance() }
            startMaintenanceTimer()
            if !fixtureMode, CommandLine.arguments.contains(AppRestart.permissionsArgument) { preferences.openPasteSettings() }
        } catch {
            let alert = NSAlert(); alert.alertStyle = .critical; alert.messageText = "Clipboard could not open history"; alert.informativeText = "Existing data has been preserved. \(error.localizedDescription)\n\nNo replacement database has been created. You can inspect or copy the existing history folder before attempting recovery."
            alert.addButton(withTitle: "Quit"); alert.runModal(); NSApp.terminate(nil)
        }
    }
    private func registerShortcut(_ key: UInt32, _ modifiers: UInt32) throws {
        guard !fixtureMode else { return }
        if let registeredShortcut, registeredShortcut == (key, modifiers) { return }
        try shortcut?.register(keyCode: key, modifiers: modifiers); registeredShortcut = (key, modifiers)
    }
    private func showOnboarding() {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert(); alert.messageText = "Your clipboard, kept on this Mac"
        alert.informativeText = "Clipboard saves supported items locally after you copy them. Unpinned entries expire after 30 days. Recognized confidential markers are skipped, but not every password or secret can be detected.\n\nHistory is not encrypted by this app. There are no accounts or analytics. Optional update checks contact GitHub; clipboard contents stay on this Mac. macOS may ask permission to read the clipboard. Automatic paste is optional and can be enabled separately."
        alert.addButton(withTitle: "Start local history"); alert.addButton(withTitle: "Not now")
        if alert.runModal() == .alertFirstButtonReturn {
            do { try settings?.update { $0.onboardingComplete = true }; manuallyPaused = false; applyCaptureState(); updates?.start() } catch { history?.showNotice(error.localizedDescription) }
        } else { manuallyPaused = true; applyCaptureState() }
    }
    private func buildMenu() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength); statusItem = item
        item.button?.image = NSImage(systemSymbolName: "clipboard", accessibilityDescription: "Clipboard")
        let menu = NSMenu()
        menu.addItem(withTitle: "Open Clipboard", action: #selector(openHistory), keyEquivalent: "").target = self
        pauseItem = menu.addItem(withTitle: "Pause monitoring", action: #selector(pause), keyEquivalent: ""); pauseItem?.target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: "Permissions…", action: #selector(openPermissions), keyEquivalent: "").target = self
        menu.addItem(withTitle: "Settings…", action: #selector(openSettings), keyEquivalent: ",").target = self
        menu.addItem(withTitle: "Check for Updates…", action: #selector(checkForUpdates), keyEquivalent: "").target = self
        menu.addItem(withTitle: "Quit Clipboard", action: #selector(quit), keyEquivalent: "q").target = self
        statusMenu = menu
        item.button?.target = self; item.button?.action = #selector(statusClicked)
        item.button?.sendAction(on: [.leftMouseDown, .rightMouseDown])
        updateStatus()
    }
    private func buildApplicationMenu() {
        let main = NSMenu(), appMenu = NSMenu()
        let app = NSMenuItem(); app.submenu = appMenu; main.addItem(app)
        appMenu.addItem(withTitle: "Settings…", action: #selector(openSettings), keyEquivalent: ",").target = self
        appMenu.addItem(.separator()); appMenu.addItem(withTitle: "Quit Clipboard", action: #selector(quit), keyEquivalent: "q").target = self
        let editMenu = NSMenu(title: "Edit"), edit = NSMenuItem(title: "Edit", action: nil, keyEquivalent: ""); edit.submenu = editMenu; main.addItem(edit)
        for (title, selector, key) in [("Undo", Selector(("undo:")), "z"), ("Cut", #selector(NSText.cut(_:)), "x"), ("Copy", #selector(NSText.copy(_:)), "c"), ("Paste", #selector(NSText.paste(_:)), "v"), ("Select All", #selector(NSText.selectAll(_:)), "a")] { editMenu.addItem(withTitle: title, action: selector, keyEquivalent: key) }
        NSApp.mainMenu = main
    }
    private func observeWorkspace() {
        let center = NSWorkspace.shared.notificationCenter
        center.addObserver(self, selector: #selector(appActivated), name: NSWorkspace.didActivateApplicationNotification, object: nil)
        for name in [NSWorkspace.willSleepNotification, NSWorkspace.screensDidSleepNotification, NSWorkspace.sessionDidResignActiveNotification] { center.addObserver(self, selector: #selector(suspend), name: name, object: nil) }
        for name in [NSWorkspace.didWakeNotification, NSWorkspace.screensDidWakeNotification, NSWorkspace.sessionDidBecomeActiveNotification] { center.addObserver(self, selector: #selector(resume), name: name, object: nil) }
    }
    @objc private func appActivated() { monitor?.updateForeground(NSWorkspace.shared.frontmostApplication?.bundleIdentifier) }
    @objc private func suspend(_ notification: Notification) { suspended.insert(reason(notification.name)); history?.suspendWindow(); applyCaptureState() }
    @objc private func resume(_ notification: Notification) { suspended.remove(reason(notification.name)); applyCaptureState() }
    private func reason(_ name: Notification.Name) -> String {
        if name == NSWorkspace.willSleepNotification || name == NSWorkspace.didWakeNotification { return "system" }
        if name == NSWorkspace.screensDidSleepNotification || name == NSWorkspace.screensDidWakeNotification { return "display" }
        return "session"
    }
    private func settingsChanged() { applyAppearance(); applyCaptureState(); if history?.window?.isVisible == true { history?.refresh() } }
    private func applyAppearance() {
        switch settings?.value.appearance { case "Light": NSApp.appearance = NSAppearance(named: .aqua); case "Dark": NSApp.appearance = NSAppearance(named: .darkAqua); default: NSApp.appearance = nil }
    }
    private func applyCaptureState() {
        guard !fixtureMode, let settings else { return }
        let state: MonitorState = !settings.value.onboardingComplete || manuallyPaused ? .manuallyPaused : !suspended.isEmpty ? .suspended : blocked ?? .running
        monitor?.configure(settings: settings.value, state: state, foregroundBundleID: NSWorkspace.shared.frontmostApplication?.bundleIdentifier)
    }
    private func monitorChanged(_ state: MonitorState) {
        currentState = state
        if state == .storageBlocked || state == .permissionBlocked { blocked = state; applyCaptureState() }
        updateStatus()
        if state == .permissionBlocked { history?.showNotice("Clipboard access is blocked or requires repeated prompts. Allow ongoing Clipboard access in System Settings, then choose Retry clipboard access in Settings.") }
    }
    private func updateStatus() {
        let running = currentState == .running
        statusItem?.button?.toolTip = running ? "Clipboard" : "Clipboard — monitoring paused"
        pauseItem?.title = running || currentState == .suspended ? "Pause monitoring" : "Resume monitoring"
        history?.updateRecordingState(currentState)
    }
    private func togglePause() {
        if settings?.value.onboardingComplete != true { showOnboarding(); return }
        if currentState == .running || currentState == .suspended { manuallyPaused = true } else { manuallyPaused = false; blocked = nil }
        applyCaptureState()
    }
    private func startMaintenanceTimer() {
        let timer = Timer(timeInterval: 60, target: self, selector: #selector(maintenanceTick), userInfo: nil, repeats: true)
        timer.tolerance = 10; RunLoop.main.add(timer, forMode: .common); cleanupTimer = timer
    }
    @objc private func maintenanceTick() { Task { await performMaintenance() } }
    private func performMaintenance() async {
        guard !fixtureMode, let store, let settings else { return }
        do {
            try await store.purgeExpired()
            let interval = settings.value.weeklyCleanup ? 7.0 * 86400 : 86400
            if settings.value.lastCleanup.map({ Date().timeIntervalSince($0) >= interval }) ?? true {
                try await store.retention(days: settings.value.retentionDays, maximumCount: settings.value.maximumCount, protectedIDs: history?.protectedDraftIDs ?? [])
                try settings.update { $0.lastCleanup = Date() }
                if history?.window?.isVisible == true { history?.refresh() }
            }
        } catch { blocked = .storageBlocked; applyCaptureState(); history?.showNotice(error.localizedDescription) }
    }
    @objc private func statusClicked() {
        guard !restarting else { return }
        if NSApp.currentEvent?.type == .rightMouseDown, let item = statusItem {
            history?.dismissPopup()
            item.menu = statusMenu; item.button?.performClick(nil); item.menu = nil
        } else { history?.toggle() }
    }
    @objc private func checkForUpdates(_ sender: Any?) {
        guard settings?.value.onboardingComplete == true else { showOnboarding(); return }
        history?.dismissPopup()
        updates?.start()
        updates?.checkForUpdates(sender)
    }
    @objc private func openHistory() { if !restarting { history?.open() } }
    @objc private func openPermissions() { preferences?.openPasteSettings() }
    @objc private func openSettings() { preferences?.open() }
    @objc private func pause() { togglePause() }
    private func restart() {
        guard !fixtureMode, !restarting else { return }
        history?.requestClose { [weak self] in
            guard let self, !restarting else { return }
            restarting = true
            Task {
                do {
                    try await AppRestart.schedule()
                    quitting = true
                    NSApp.terminate(nil)
                } catch {
                    restarting = false
                    let alert = NSAlert(); alert.messageText = "Clipboard could not restart"
                    alert.informativeText = error.localizedDescription
                    alert.runModal()
                }
            }
        }
    }
    @objc private func quit() { history?.requestClose { [weak self] in self?.quitting = true; NSApp.terminate(nil) } }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if quitting || history?.hasUnsavedEdits != true { return .terminateNow }
        quit(); return .terminateCancel
    }
    func applicationWillTerminate(_ notification: Notification) { shortcut?.invalidate(); cleanupTimer?.invalidate() }
}
