import AppKit
import ClipboardCore

final class ClipboardMonitor: @unchecked Sendable {
    static let tokenType = NSPasteboard.PasteboardType("local.clipboard.write-token")
    let sessionToken = UUID().uuidString
    private let queue = DispatchQueue(label: "local.clipboard.capture", qos: .utility)
    private var timer: DispatchSourceTimer?
    private var generation = 0
    private var deduplicator = ConsecutiveDeduplicator()
    private var busy = false
    private var storageTask: Task<Void, Never>?
    private var epoch = 0
    private var settings = AppSettings()
    private var foregroundExcluded = false
    private var requestedState: MonitorState = .manuallyPaused
    private let pasteboard: NSPasteboard
    private let store: HistoryStore
    private let onState: @MainActor @Sendable (MonitorState) -> Void
    private let onCapture: @MainActor @Sendable () -> Void
    private let onError: @MainActor @Sendable (String) -> Void

    init(store: HistoryStore, pasteboard: NSPasteboard = .general, onState: @escaping @MainActor @Sendable (MonitorState) -> Void, onCapture: @escaping @MainActor @Sendable () -> Void, onError: @escaping @MainActor @Sendable (String) -> Void) {
        self.store = store; self.pasteboard = pasteboard; self.onState = onState; self.onCapture = onCapture; self.onError = onError
    }
    func configure(settings: AppSettings, state: MonitorState, foregroundBundleID: String?) {
        queue.async { [self] in
            let excluded = foregroundBundleID.map(settings.excludedApps.contains) ?? false
            let unchanged = self.settings.pollingInterval == settings.pollingInterval && self.settings.excludedApps == settings.excludedApps && requestedState == state && foregroundExcluded == excluded
            self.settings = settings
            guard !unchanged || (state == .running && !excluded && timer == nil) else { return }
            requestedState = state; foregroundExcluded = excluded
            restart()
        }
    }
    private func restart() {
        epoch += 1
        storageTask?.cancel()
        timer?.cancel(); timer = nil
        generation = pasteboard.changeCount
        deduplicator.reset()
        guard requestedState == .running, !foregroundExcluded else {
            let state = requestedState == .running ? MonitorState.suspended : requestedState
            Task { await onState(state) }; return
        }
        let source = DispatchSource.makeTimerSource(queue: queue)
        source.schedule(deadline: .now() + settings.pollingInterval, repeating: settings.pollingInterval, leeway: .milliseconds(100))
        source.setEventHandler { [weak self] in self?.poll() }
        timer = source; source.resume()
        Task { await onState(.running) }
    }
    func updateForeground(_ bundleID: String?) {
        queue.async { [self] in
            let excluded = bundleID.map(settings.excludedApps.contains) ?? false
            guard excluded != foregroundExcluded else { return }
            foregroundExcluded = excluded; restart()
        }
    }
    func captureNow() {
        queue.async { [self] in
            guard requestedState == .running, timer != nil else { return }
            poll()
        }
    }
    private func poll() {
        guard !busy, !foregroundExcluded else { return }
        let board = pasteboard
        let next = board.changeCount
        guard next != generation else { return }
        if #available(macOS 15.4, *) {
            if board.accessBehavior == .alwaysDeny || board.accessBehavior == .ask {
                timer?.cancel(); timer = nil
                Task { await onState(.permissionBlocked) }
                return
            }
        }
        busy = true
        let thisEpoch = epoch
        do {
            let snapshot = try read(board: board, generation: next)
            guard board.changeCount == next else { busy = false; return }
            generation = next
            guard let snapshot else { deduplicator.reset(); busy = false; return }
            try PayloadRules.validate(snapshot)
            try PayloadRules.validateImage(snapshot)
            let hash = snapshot.contentHash
            guard deduplicator.accepts(hash) else { busy = false; return }
            storageTask = Task {
                do {
                    try await store.insert(snapshot)
                    queue.async { [self] in if epoch == thisEpoch { deduplicator.committed(hash) }; busy = false; storageTask = nil }
                    await onCapture()
                } catch is CancellationError {
                    queue.async { [self] in busy = false; storageTask = nil }
                } catch {
                    queue.async { [self] in
                        busy = false; storageTask = nil
                        guard epoch == thisEpoch else { return }
                        timer?.cancel(); timer = nil
                        Task {
                            await onState(.storageBlocked)
                            await onError("Capture paused because this entry could not be stored. Existing history is preserved. Resume monitoring to retry.")
                        }
                    }
                }
            }
        } catch {
            generation = next; deduplicator.reset(); busy = false
            Task { await onError(error is CoreError ? error.localizedDescription : "This clipboard item could not be read.") }
        }
    }
    private func read(board: NSPasteboard, generation: Int) throws -> ClipboardSnapshot? {
        try Self.decode(board: board, generation: generation, ownToken: sessionToken, excluded: Set(settings.excludedApps))
    }
    static func decode(board: NSPasteboard, generation: Int, ownToken: String, excluded: Set<String>) throws -> ClipboardSnapshot? {
        let items = board.pasteboardItems ?? []
        let types = Set(((board.types ?? []) + items.flatMap(\.types)).map(\.rawValue))
        if !types.isDisjoint(with: PayloadRules.ignoredMarkers) { return nil }
        if board.string(forType: Self.tokenType) == ownToken { return nil }
        let source = board.string(forType: .init("org.nspasteboard.source"))
        if PayloadRules.shouldSkip(types: types, source: source, excluded: excluded) { return nil }
        if items.contains(where: { $0.string(forType: .init("org.nspasteboard.source")).map(excluded.contains) == true }) { return nil }
        guard !items.isEmpty else { return nil }
        guard items.count <= Limits.fileCount else { throw CoreError.tooLarge }
        let files = items.enumerated().compactMap { index, item -> CapturedRepresentation? in
            guard let string = item.string(forType: .fileURL), let url = URL(string: string), url.isFileURL else { return nil }
            return .init(itemIndex: index, type: PayloadRules.fileType, data: Data(string.utf8))
        }
        if files.count == items.count { return .init(generation: generation, kind: .files, representations: files, sourceBundleID: source) }
        guard items.count == 1, let item = items.first else { return nil }
        if let text = item.string(forType: .string) ?? item.string(forType: .URL) {
            guard text.utf8.count <= Limits.textBytes else { throw CoreError.tooLarge }
            var reps = [CapturedRepresentation(type: PayloadRules.textType, data: Data(text.utf8))]
            if let rtf = item.data(forType: .rtf), rtf.count <= Limits.rtfBytes { reps.append(.init(type: "public.rtf", data: rtf)) }
            return .init(generation: generation, kind: .classify(text), text: text, representations: reps, sourceBundleID: source)
        }
        for type in [NSPasteboard.PasteboardType.png, .tiff] {
            if let data = item.data(forType: type) {
                guard data.count <= Limits.imageBytes else { throw CoreError.tooLarge }
                return .init(generation: generation, kind: .image, representations: [.init(type: type.rawValue, data: data)], sourceBundleID: source)
            }
        }
        return nil
    }
}
