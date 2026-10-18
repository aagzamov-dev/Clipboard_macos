import AppKit
import Sparkle

@MainActor final class UpdateController: NSObject, SPUUpdaterDelegate {
    private var controller: SPUStandardUpdaterController!
    private var started = false
    private var pendingInstall: (() -> Void)?
    var prepareToInstall: (@escaping () -> Void) -> Void = { $0() }
    var canCheck: Bool { started && (pendingInstall != nil || controller.updater.canCheckForUpdates) }
    var automaticChecks: Bool {
        get { controller.updater.automaticallyChecksForUpdates }
        set { controller.updater.automaticallyChecksForUpdates = newValue }
    }
    override init() {
        super.init()
        controller = SPUStandardUpdaterController(startingUpdater: false, updaterDelegate: self, userDriverDelegate: nil)
        controller.updater.sendsSystemProfile = false
    }
    func start() {
        guard !started else { return }
        started = true
        controller.startUpdater()
    }
    @objc func checkForUpdates(_ sender: Any?) {
        if pendingInstall != nil { completePendingInstall() }
        else if canCheck { controller.checkForUpdates(sender) }
    }
    func updater(_ updater: SPUUpdater, shouldPostponeRelaunchForUpdate item: SUAppcastItem, untilInvokingBlock installHandler: @escaping () -> Void) -> Bool {
        pendingInstall = installHandler
        Task { [weak self] in self?.completePendingInstall() }
        return true
    }
    private func completePendingInstall() {
        prepareToInstall { [weak self] in
            guard let self, let install = pendingInstall else { return }
            pendingInstall = nil
            install()
        }
    }
}
