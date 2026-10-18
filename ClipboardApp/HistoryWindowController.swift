import AppKit
import ClipboardCore
import ImageIO
import UniformTypeIdentifiers
import os

@MainActor final class HistoryWindowController: NSWindowController, NSTableViewDataSource, NSTableViewDelegate, NSSearchFieldDelegate, NSTextViewDelegate, NSWindowDelegate, NSMenuItemValidation {
    private let store: HistoryStore
    private let settings: SettingsStore
    private let paste: PasteCoordinator
    private let table = HistoryTable()
    private let search = NSSearchField()
    private let typeFilter = NSPopUpButton()
    private let dates = NSPopUpButton()
    private let body = NSStackView()
    private let preview = PreviewStack()
    private let previewTitle = label("Text", size: 13)
    private let sourceLabel = label("", size: 11, color: .secondaryLabelColor)
    private let editor = NSTextView()
    private let editorScroll = NSScrollView()
    private let image = ImagePreviewView()
    private let fileLabel = label("", size: 12, color: .secondaryLabelColor)
    private let characterCount = label("", size: 11, color: .secondaryLabelColor)
    private let editStatus = label("", size: 11, color: .secondaryLabelColor)
    private let draftActions = NSStackView()
    private let previewActions = NSStackView()
    private let bulkBar = NSStackView()
    private let bulkCount = label("", size: 12)
    private let bulkCopy = ActionButton("Copy", action: {})
    private let notice = label("", size: 11, color: .secondaryLabelColor)
    private let undoButton = ActionButton("Undo", action: {})
    private var noticeContainer = NSView()
    private let recordingStatus = label("Recording paused", size: 11, color: .secondaryLabelColor)
    private let recordingToggle = ActionButton("Resume", action: {})
    private var outsideMonitor: Any?
    private var localMonitor: Any?
    var onToggleRecording: (() -> Void)?
    private let itemCount = label("", size: 11, color: .secondaryLabelColor)
    private var pages: [Int: [ClipboardEntrySummary]] = [:]
    private var pageOrder: [Int] = []
    private var loading = Set<Int>()
    private var totalCount = 0
    private var revision = 0
    private var query = HistoryQuery()
    private var searchTask: Task<Void, Never>?
    private var previewTask: Task<Void, Never>?
    private var imageTask: Task<Void, Never>?
    private let imageLoader = ImagePreviewLoader()
    private var actionTask: Task<Void, Never>?
    private var cleanupTask: Task<Void, Never>?
    private var selectedIDs = Set<UUID>()
    private var lastRenderedID: UUID?
    private var selectedDetail: ClipboardEntryDetail?
    private var drafts = DraftStore()
    private var combinedDraft: CombinedCopyDraft?
    private var undoToken: UUID?
    private var previewVisible = false
    private var restoringSelection = false
    private var isOpening = false
    private var previewWidth: NSLayoutConstraint?
    var protectedDraftIDs: Set<UUID> { drafts.ids }
    var onSettings: (() -> Void)?
    var onPasteSettings: (() -> Void)?
    private var openingInterval: OSSignpostIntervalState?
    private let relativeFormatter = RelativeDateTimeFormatter()
    private let signposter = OSSignposter(subsystem: "local.clipboard.Clipboard", category: "History")

    init(store: HistoryStore, settings: SettingsStore, paste: PasteCoordinator) {
        self.store = store; self.settings = settings; self.paste = paste
        let panel = HistoryPanel(contentRect: NSRect(x: 0, y: 0, width: 400, height: 440), styleMask: [.borderless, .resizable], backing: .buffered, defer: false)
        panel.title = "Clipboard"; panel.level = .floating; panel.isFloatingPanel = true; panel.hidesOnDeactivate = false
        panel.isOpaque = false; panel.backgroundColor = .clear
        panel.becomesKeyOnlyIfNeeded = false; panel.hasShadow = true; panel.isMovableByWindowBackground = true
        panel.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
        panel.animationBehavior = .utilityWindow
        panel.minSize = NSSize(width: 400, height: 360); panel.maxSize = NSSize(width: 500, height: 560); panel.isReleasedWhenClosed = false
        super.init(window: panel)
        panel.delegate = self
        buildUI()
        panel.command = { [weak self] in self?.handle($0) ?? false }
        table.command = { [weak self] in self?.handle($0) ?? false }
        table.onSelectedRowClick = { [weak self] in self?.updateSelection() }
        NotificationCenter.default.addObserver(self, selector: #selector(applicationBecameActive), name: NSApplication.didBecomeActiveNotification, object: nil)
    }
    required init?(coder: NSCoder) { fatalError() }
    private func buildUI() {
        guard let window else { return }
        let root = NSStackView(); root.orientation = .vertical; root.alignment = .leading; root.spacing = 0; root.distribution = .fill
        let container = PopupContentView(); container.wantsLayer = true
        container.layer?.cornerRadius = 12; container.layer?.masksToBounds = true
        window.contentView = container
        container.addSubview(root); root.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([root.leadingAnchor.constraint(equalTo: container.leadingAnchor), root.trailingAnchor.constraint(equalTo: container.trailingAnchor), root.topAnchor.constraint(equalTo: container.topAnchor), root.bottomAnchor.constraint(equalTo: container.bottomAnchor)])
        search.placeholderString = "Search clipboard history…"; search.delegate = self
        search.setAccessibilityLabel("Search clipboard history")
        let settingsButton = ActionButton("", symbol: "gearshape", action: { [weak self] in self?.onSettings?() }); settingsButton.setAccessibilityLabel("Settings"); settingsButton.toolTip = "Settings  ⌘,"
        recordingToggle.onClick = { [weak self] in self?.onToggleRecording?() }
        let header = padded(row([recordingStatus, recordingToggle, NSView(), settingsButton]), vertical: 6)
        header.heightAnchor.constraint(equalToConstant: 32).isActive = true
        root.addArrangedSubview(header)
        let searchRow = padded(search, vertical: 6)
        searchRow.heightAnchor.constraint(equalToConstant: 34).isActive = true
        root.addArrangedSubview(searchRow)
        dates.addItems(withTitles: DateFilter.allCases.map(\.rawValue)); dates.controlSize = .small; dates.target = self; dates.action = #selector(filtersChanged)
        dates.setAccessibilityLabel("Date filter")
        typeFilter.addItems(withTitles: ["All types"] + ClipboardKind.allCases.map(\.label))
        typeFilter.controlSize = .small; typeFilter.target = self; typeFilter.action = #selector(filtersChanged); typeFilter.setAccessibilityLabel("Content type")
        noticeContainer = padded(row([notice, undoButton]), vertical: 7); noticeContainer.isHidden = true; noticeContainer.heightAnchor.constraint(equalToConstant: 32).isActive = true; root.addArrangedSubview(noticeContainer)
        bulkCopy.setAccessibilityLabel("Copy selected"); bulkCopy.toolTip = "Copy selected  ⌘⇧C"
        bulkCopy.onClick = { [weak self] in self?.copySelection() }
        bulkBar.setViews([bulkCount, bulkCopy, ActionButton("Delete", action: { [weak self] in self?.deleteSelection() }), ActionButton("", symbol: "xmark", action: { [weak self] in self?.clearBulkSelection() })], in: .leading)
        (bulkBar.arrangedSubviews.last as? NSButton)?.setAccessibilityLabel("Clear selection")
        bulkBar.orientation = .horizontal; bulkBar.spacing = 6; bulkBar.alignment = .centerY
        bulkBar.isHidden = true
        let toolbar = row([bulkBar, NSView(), typeFilter, dates], spacing: 6)
        toolbar.distribution = .fill
        dates.setContentCompressionResistancePriority(.required, for: .horizontal)
        typeFilter.setContentCompressionResistancePriority(.required, for: .horizontal)
        let toolbarContainer = padded(toolbar, vertical: 6)
        toolbarContainer.heightAnchor.constraint(equalToConstant: 30).isActive = true
        root.insertArrangedSubview(toolbarContainer, at: 2)
        root.insertArrangedSubview(separator(), at: 3)
        table.headerView = nil; table.rowHeight = 52; table.intercellSpacing = .zero; table.allowsMultipleSelection = true
        table.style = .fullWidth; table.selectionHighlightStyle = .regular
        table.dataSource = self; table.delegate = self; table.target = self; table.doubleAction = #selector(pasteSelected)
        let column = NSTableColumn(identifier: .init("entry")); column.resizingMask = .autoresizingMask; table.addTableColumn(column)
        table.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
        table.setAccessibilityLabel("Clipboard history")
        let listScroll = NSScrollView(); listScroll.documentView = table; listScroll.hasVerticalScroller = true; listScroll.autohidesScrollers = true
        body.orientation = .horizontal; body.alignment = .top; body.spacing = 0; body.distribution = .fill
        body.addArrangedSubview(listScroll)
        preview.orientation = .vertical; preview.alignment = .leading; preview.spacing = 8; preview.distribution = .fill; preview.edgeInsets = NSEdgeInsets(top: 12, left: 12, bottom: 12, right: 12)
        preview.translatesAutoresizingMaskIntoConstraints = false; previewWidth = preview.widthAnchor.constraint(equalTo: body.widthAnchor, multiplier: 0.6)
        preview.addArrangedSubview(row([previewTitle, editStatus, NSView(), ActionButton("", symbol: "xmark", action: { [weak self] in self?.setPreview(false) })]))
        preview.addArrangedSubview(sourceLabel)
        if #available(macOS 15.0, *) { editor.writingToolsBehavior = .none }
        editor.isContinuousSpellCheckingEnabled = false; editor.isAutomaticSpellingCorrectionEnabled = false; editor.isAutomaticTextCompletionEnabled = false
        editor.isRichText = false; editor.importsGraphics = false; editor.allowsUndo = true; editor.isAutomaticLinkDetectionEnabled = false
        editor.isAutomaticQuoteSubstitutionEnabled = false; editor.isAutomaticDashSubstitutionEnabled = false; editor.isAutomaticTextReplacementEnabled = false
        editor.font = .systemFont(ofSize: 13); editor.textColor = .labelColor; editor.backgroundColor = .textBackgroundColor
        editor.textContainerInset = NSSize(width: 8, height: 8); editor.delegate = self; editor.isVerticallyResizable = true; editor.isHorizontallyResizable = false
        editor.autoresizingMask = [.width]; editor.textContainer?.widthTracksTextView = true
        editor.setAccessibilityLabel("Editable clipboard text")
        editorScroll.documentView = editor; editorScroll.hasVerticalScroller = true; editorScroll.borderType = .lineBorder
        preview.addArrangedSubview(editorScroll)
        image.setAccessibilityLabel("Clipboard image preview")
        image.setContentHuggingPriority(.defaultLow, for: .vertical)
        image.setContentCompressionResistancePriority(.defaultLow, for: .vertical)
        preview.addArrangedSubview(image)
        fileLabel.maximumNumberOfLines = 0; fileLabel.lineBreakMode = .byWordWrapping; fileLabel.isSelectable = true; preview.addArrangedSubview(fileLabel)
        preview.addArrangedSubview(characterCount)
        draftActions.orientation = .horizontal; draftActions.spacing = 6
        draftActions.addArrangedSubview(ActionButton("Revert", action: { [weak self] in self?.revertDraft() }))
        draftActions.addArrangedSubview(ActionButton("Save  ⌘S", action: { [weak self] in self?.saveDraft() }))
        preview.addArrangedSubview(draftActions)
        previewActions.orientation = .horizontal; previewActions.spacing = 5
        previewActions.addArrangedSubview(ActionButton("Copy", action: { [weak self] in self?.copySelection() }))
        previewActions.addArrangedSubview(ActionButton("Paste", action: { [weak self] in self?.pasteSelection() }))
        previewActions.addArrangedSubview(ActionButton("Pin", action: { [weak self] in self?.togglePin() }))
        let delete = ActionButton("", symbol: "trash", action: { [weak self] in self?.deleteSelection() }); delete.setAccessibilityLabel("Delete entry")
        previewActions.addArrangedSubview(delete); preview.addArrangedSubview(previewActions)
        body.addArrangedSubview(preview); preview.isHidden = true
        root.addArrangedSubview(body); root.addArrangedSubview(separator())
        let hints = row([label("↑↓ Navigate · ⌘C Copy · ⌘⌫ Delete", size: 10, color: .secondaryLabelColor), NSView(), itemCount, ActionButton("", symbol: "keyboard", action: { [weak self] in self?.showShortcuts() })], spacing: 6)
        hints.distribution = .fill
        let footer = padded(hints, vertical: 3)
        footer.heightAnchor.constraint(equalToConstant: 28).isActive = true
        root.addArrangedSubview(footer)
        body.heightAnchor.constraint(greaterThanOrEqualToConstant: 180).isActive = true
        undoButton.onClick = { [weak self] in self?.undoDeletion() }; undoButton.isHidden = true
        body.setContentHuggingPriority(.defaultLow, for: .vertical)
        editorScroll.setContentHuggingPriority(.defaultLow, for: .vertical)
        listScroll.widthAnchor.constraint(greaterThanOrEqualToConstant: 260).isActive = true
        for view in root.arrangedSubviews {
            view.translatesAutoresizingMaskIntoConstraints = false
            NSLayoutConstraint.activate([view.leadingAnchor.constraint(equalTo: root.leadingAnchor), view.trailingAnchor.constraint(equalTo: root.trailingAnchor)])
        }
        for view in body.arrangedSubviews {
            NSLayoutConstraint.activate([view.topAnchor.constraint(equalTo: body.topAnchor), view.bottomAnchor.constraint(equalTo: body.bottomAnchor)])
        }
        for view in preview.arrangedSubviews {
            NSLayoutConstraint.activate([view.leadingAnchor.constraint(equalTo: preview.leadingAnchor, constant: 12), view.trailingAnchor.constraint(equalTo: preview.trailingAnchor, constant: -12)])
        }
    }
    func open() {
        openingInterval = signposter.beginInterval("Open history")
        paste.rememberTarget()
        if let window {
            var frame = window.frame
            frame.size = NSSize(width: previewVisible ? 720 : 400, height: 440)
            window.setFrame(frame, display: false)
        }
        positionWindow()
        isOpening = true
        window?.orderFront(nil)
        installDismissalMonitors()
        if NSApp.isActive { finishOpening() } else { NSApp.activate() }
        refresh()
    }
    @objc private func applicationBecameActive() { if isOpening { finishOpening() } }
    private func finishOpening() {
        guard window?.isVisible == true else { isOpening = false; return }
        window?.makeKeyAndOrderFront(nil)
        window?.makeFirstResponder(table)
        isOpening = false
    }
    func toggle() {
        if window?.isVisible == true { dismissPopup() } else { open() }
    }
    func updateRecordingState(_ state: MonitorState) {
        switch state {
        case .running: recordingStatus.stringValue = "● Recording"; recordingStatus.textColor = .systemGreen
        case .manuallyPaused: recordingStatus.stringValue = "Recording paused"; recordingStatus.textColor = .secondaryLabelColor
        case .suspended: recordingStatus.stringValue = "Recording suspended"; recordingStatus.textColor = .secondaryLabelColor
        case .permissionBlocked: recordingStatus.stringValue = "Clipboard access required"; recordingStatus.textColor = .systemOrange
        case .storageBlocked: recordingStatus.stringValue = "Storage unavailable"; recordingStatus.textColor = .systemOrange
        }
        recordingToggle.title = state == .running || state == .suspended ? "Pause" : "Resume"
        recordingToggle.setAccessibilityLabel(state == .running || state == .suspended ? "Pause recording" : "Resume recording")
    }
    private func installDismissalMonitors() {
        removeDismissalMonitors()
        outsideMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]) { [weak self] _ in
            MainActor.assumeIsolated { self?.dismissPopup() }
        }
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]) { [weak self] event in
            MainActor.assumeIsolated {
                if let self, let eventWindow = event.window, eventWindow !== self.window, eventWindow.level != .statusBar, eventWindow.level.rawValue < NSWindow.Level.popUpMenu.rawValue { self.dismissPopup() }
            }
            return event
        }
    }
    private func removeDismissalMonitors() {
        if let outsideMonitor { NSEvent.removeMonitor(outsideMonitor); self.outsideMonitor = nil }
        if let localMonitor { NSEvent.removeMonitor(localMonitor); self.localMonitor = nil }
    }
    func dismissPopup() {
        guard NSApp.modalWindow == nil, window?.attachedSheet == nil else { return }
        isOpening = false
        removeDismissalMonitors()
        searchTask?.cancel(); previewTask?.cancel(); imageTask?.cancel(); revision += 1
        pages.removeAll(); pageOrder.removeAll(); loading.removeAll()
        window?.orderOut(nil); image.image = nil
        editor.string = ""; editor.undoManager?.removeAllActions(); selectedDetail = nil; lastRenderedID = nil
    }
    func windowDidResignKey(_ notification: Notification) {
        guard !isOpening else { return }
        Task { [weak self] in
            await Task.yield()
            guard let self, !isOpening, window?.isKeyWindow != true else { return }
            dismissPopup()
        }
    }
    private func positionWindow() {
        guard let window else { return }
        let pointerScreen = NSScreen.screens.first { NSMouseInRect(NSEvent.mouseLocation, $0.frame, false) }
        var screen = pointerScreen ?? NSScreen.main ?? NSScreen.screens.first
        if settings.value.activeDisplay, let pid = paste.previousApplication?.processIdentifier,
           let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]],
           let info = windows.first(where: { ($0[kCGWindowOwnerPID as String] as? Int32) == pid && ($0[kCGWindowLayer as String] as? Int) == 0 }),
           let bounds = info[kCGWindowBounds as String] as? [String: Any], let rect = CGRect(dictionaryRepresentation: bounds as CFDictionary), let primary = NSScreen.screens.first {
            let appRect = NSRect(x: rect.minX, y: primary.frame.maxY - rect.maxY, width: rect.width, height: rect.height)
            screen = NSScreen.screens.max(by: { $0.frame.intersection(appRect).area < $1.frame.intersection(appRect).area }) ?? screen
        }
        guard let screen else { return }
        let available = screen.visibleFrame.insetBy(dx: 12, dy: 12)
        var frame = window.frame; frame.size.width = min(frame.width, available.width); frame.size.height = min(frame.height, available.height)
        frame.origin.x = min(max(frame.minX, available.minX), available.maxX - frame.width)
        frame.origin.y = min(max(frame.minY, available.minY), available.maxY - frame.height)
        if !frame.intersects(screen.visibleFrame) || window.frame.origin == .zero { frame.origin = NSPoint(x: available.midX - frame.width / 2, y: available.midY - frame.height / 2) }
        window.setFrame(frame, display: false)
    }
    func historyWasCleared(includePinned: Bool) {
        undoToken = nil; undoButton.isHidden = true
        Task {
            if includePinned { drafts.removeAll() }
            else {
                for id in drafts.ids { if (try? await store.detail(id)) == nil { drafts.remove(id) } }
            }
            refresh()
        }
    }
    func refresh() {
        revision += 1; let version = revision
        query = .init(search: search.stringValue, dateFilter: DateFilter.allCases[dates.indexOfSelectedItem], kind: typeFilter.indexOfSelectedItem == 0 ? nil : ClipboardKind.allCases[typeFilter.indexOfSelectedItem - 1], pinnedFirst: settings.value.pinnedFirst)
        pages.removeAll(); pageOrder.removeAll(); loading.removeAll()
        searchTask?.cancel()
        let requested = query, retained = selectedIDs
        searchTask = Task { [weak self] in
            guard let self else { return }
            do {
                let page = try await store.page(requested)
                guard !Task.isCancelled, revision == version else { return }
                let ids = retained.isEmpty ? [] : try await store.orderedIDs(requested)
                guard !Task.isCancelled, revision == version else { return }
                totalCount = page.totalCount; cache(page)
                restoringSelection = true
                table.reloadData()
                let indexes = IndexSet(ids.enumerated().filter { retained.contains($0.element) }.map(\.offset))
                table.selectRowIndexes(indexes.isEmpty && totalCount > 0 ? IndexSet(integer: 0) : indexes, byExtendingSelection: false)
                restoringSelection = false
                itemCount.stringValue = "\(totalCount) items"
                if let interval = openingInterval { signposter.endInterval("Open history", interval); openingInterval = nil }
                updateSelection(openPreview: false)
            } catch is CancellationError {} catch { showNotice(error.localizedDescription) }
        }
    }
    func numberOfRows(in tableView: NSTableView) -> Int { totalCount }
    private func summary(at row: Int) -> ClipboardEntrySummary? { pages[row / 100]?[safe: row % 100] }
    private func cache(_ page: HistoryPage) {
        let index = page.offset / 100; pages[index] = page.entries
        pageOrder.removeAll { $0 == index }; pageOrder.append(index)
        while pageOrder.count > 5 { pages[pageOrder.removeFirst()] = nil }
    }
    private func loadPage(containing row: Int) {
        let index = row / 100, version = revision, requested = query
        guard !loading.contains(index) else { return }; loading.insert(index)
        Task { [weak self] in
            guard let self else { return }
            do {
                let page = try await store.page(requested, offset: index * 100)
                guard revision == version else { return }
                loading.remove(index); cache(page)
                if !page.entries.isEmpty { table.reloadData(forRowIndexes: IndexSet(integersIn: page.offset..<(page.offset + page.entries.count)), columnIndexes: IndexSet(integer: 0)) }
            } catch { if revision == version { loading.remove(index); showNotice(error.localizedDescription) } }
        }
    }
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let identifier = NSUserInterfaceItemIdentifier("HistoryCell")
        let cell = table.makeView(withIdentifier: identifier, owner: self) as? HistoryCell ?? HistoryCell(frame: .zero)
        cell.identifier = identifier
        guard let summary = summary(at: row) else { cell.titleLabel.stringValue = "Loading…"; cell.metadataLabel.stringValue = ""; cell.icon.image = nil; cell.copyButton.isEnabled = false; loadPage(containing: row); return cell }
        cell.titleLabel.stringValue = summary.preview.isEmpty ? "Empty text" : summary.preview
        let relative = abs(summary.createdAt.timeIntervalSinceNow) < 60 ? "Just now" : relativeFormatter.localizedString(for: summary.createdAt, relativeTo: Date())
        var metadata = [summary.kind.label, relative]
        if summary.isPinned { metadata.append("Pinned") }; if drafts.text(for: summary.id) != nil { metadata.append("Edited") }
        if let source = summary.sourceBundleID, !source.isEmpty { metadata.append(source) }
        cell.metadataLabel.stringValue = metadata.joined(separator: " · ")
        cell.icon.image = NSImage(systemSymbolName: summary.kind.symbol, accessibilityDescription: summary.kind.label)
        cell.copyButton.isEnabled = true; cell.copyButton.onClick = { [weak self] in self?.copy(ids: [summary.id]) }
        cell.setAccessibilityLabel("\(summary.preview), \(metadata.joined(separator: ", "))")
        return cell
    }
    func tableViewSelectionDidChange(_ notification: Notification) { if !restoringSelection { updateSelection() } }
    private func updateSelection(openPreview: Bool = true) {
        previewTask?.cancel()
        let indexes = table.selectedRowIndexes, requested = query, version = revision
        let cachedSelection = indexes.compactMap { summary(at: $0)?.id }
        selectedIDs = cachedSelection.count == indexes.count ? Set(cachedSelection) : []
        selectedDetail = nil; editor.isEditable = false
        bulkBar.isHidden = indexes.count < 2; bulkCount.stringValue = "\(indexes.count)"; bulkCount.setAccessibilityLabel("\(indexes.count) selected")
        guard !indexes.isEmpty else { selectedIDs = []; selectedDetail = nil; renderEmptyPreview(); return }
        previewTask = Task { [weak self] in
            guard let self else { return }
            do {
                let ordered: [UUID]
                if cachedSelection.count == indexes.count { ordered = cachedSelection }
                else { let ids = try await store.orderedIDs(requested); ordered = indexes.compactMap { ids[safe: $0] } }
                guard !Task.isCancelled, revision == version else { return }
                selectedIDs = Set(ordered)
                guard !ordered.isEmpty else { renderEmptyPreview(); return }
                if openPreview { setPreview(true) }
                if ordered.count > 1 {
                    selectedDetail = nil
                    var merged = "", compatible = true
                    for id in ordered {
                        try Task.checkCancellation()
                        guard let detail = try await store.detail(id), detail.summary.kind.isText else { compatible = false; break }
                        let text = drafts.text(for: id) ?? detail.text ?? ""
                        guard merged.utf8.count + text.utf8.count + settings.value.mergeSeparator.utf8.count <= Limits.textBytes else { compatible = false; break }
                        if !merged.isEmpty { merged += settings.value.mergeSeparator }; merged += text
                    }
                    guard !Task.isCancelled else { return }
                    if compatible {
                        if let existing = combinedDraft, existing.ids != ordered, existing.hasChanges {
                            let alert = NSAlert(); alert.messageText = "Discard combined edits?"
                            alert.informativeText = "Copy your edited combined text before starting another combined selection. Original history entries are unchanged."
                            alert.addButton(withTitle: "Copy edits"); alert.addButton(withTitle: "Discard"); alert.addButton(withTitle: "Cancel")
                            switch alert.runModal() {
                            case .alertFirstButtonReturn:
                                do { try paste.write(.plainText(existing.text)) } catch { showNotice(error.localizedDescription); clearBulkSelection(); return }
                            case .alertSecondButtonReturn: break
                            default: clearBulkSelection(); return
                            }
                        }
                        if combinedDraft?.ids != ordered || combinedDraft?.hasChanges == false {
                            combinedDraft = CombinedCopyDraft(ids: ordered, text: merged)
                        }
                    }
                    renderBulk(count: ordered.count, text: compatible ? combinedDraft?.text : nil)
                } else if let detail = try await store.detail(ordered[0]) {
                    guard !Task.isCancelled else { return }
                    selectedDetail = detail; if previewVisible { render(detail) }
                }
            } catch is CancellationError {} catch { showNotice(error.localizedDescription) }
        }
    }
    private func renderEmptyPreview() { imageTask?.cancel(); editor.string = ""; image.image = nil; sourceLabel.stringValue = ""; previewTitle.stringValue = "Select an item"; editorScroll.isHidden = true; image.isHidden = true; fileLabel.isHidden = true; previewActions.isHidden = true; draftActions.isHidden = true; characterCount.stringValue = ""; editStatus.stringValue = "" }
    private func renderBulk(count: Int, text: String?) {
        imageTask?.cancel()
        image.image = nil; image.isHidden = true; fileLabel.isHidden = text != nil
        fileLabel.stringValue = "Select compatible text, code, and links to copy together. Copy images and files individually. Large selections may exceed the 2 MiB copy limit."
        editorScroll.isHidden = text == nil; editor.setAccessibilityLabel("Combined clipboard text"); editor.isEditable = text != nil
        if editor.string != text ?? "" { editor.string = text ?? ""; editor.undoManager?.removeAllActions() }
        lastRenderedID = nil; editor.font = .systemFont(ofSize: 13)
        previewTitle.stringValue = "\(count) selected"; sourceLabel.stringValue = text == nil ? "Mixed or oversized selection" : "Combined text · history order"
        characterCount.stringValue = text == nil ? "" : "Edit the combined copy. Originals stay unchanged."
        editStatus.stringValue = text != nil && combinedDraft?.hasChanges == true ? "Edited copy" : ""
        draftActions.isHidden = text == nil || combinedDraft?.hasChanges != true
        draftActions.arrangedSubviews.last?.isHidden = true
        previewActions.isHidden = true; bulkCopy.isEnabled = text != nil
    }
    private func render(_ detail: ClipboardEntryDetail) {
        imageTask?.cancel()
        let entry = detail.summary
        image.image = nil; image.isHidden = entry.kind != .image; editorScroll.isHidden = !entry.kind.isText; fileLabel.isHidden = entry.kind != .files
        previewActions.isHidden = false; bulkCopy.isEnabled = true
        previewTitle.stringValue = entry.kind.label
        sourceLabel.stringValue = [entry.sourceBundleID, entry.createdAt.formatted(date: .abbreviated, time: .shortened)].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · ")
        editor.setAccessibilityLabel("Editable clipboard text")
        editor.isEditable = entry.kind.isText
        editor.font = entry.kind == .code ? .monospacedSystemFont(ofSize: 12, weight: .regular) : .systemFont(ofSize: 13)
        let text = drafts.text(for: entry.id) ?? detail.text ?? ""
        if lastRenderedID != entry.id || editor.string != text {
            editor.string = text; editor.undoManager?.removeAllActions()
        }
        lastRenderedID = entry.id
        characterCount.stringValue = entry.kind.isText ? "⌘S Save edits · ⌘⇧C Copy draft" : ""
        draftActions.arrangedSubviews.last?.isHidden = false
        draftActions.isHidden = drafts.text(for: entry.id) == nil; editStatus.stringValue = draftActions.isHidden ? "" : "Unsaved"
        (previewActions.arrangedSubviews[safe: 2] as? NSButton)?.title = entry.isPinned ? "Unpin" : "Pin"
        if entry.kind == .files {
            fileLabel.stringValue = detail.representations.compactMap { $0.data.flatMap { String(data: $0, encoding: .utf8) }.flatMap(URL.init(string:))?.path }.joined(separator: "\n\n") + "\n\nReferences only. Original files are unchanged."
        }
        if entry.kind == .image, let name = detail.representations.first?.attachmentName, PrivateFiles.isManagedName(name) {
            let url = store.attachmentsURL.appendingPathComponent(name), id = entry.id
            imageTask = Task { [weak self] in
                guard let self else { return }
                do {
                    let result = try await imageLoader.thumbnail(url: url)
                    guard !Task.isCancelled, selectedDetail?.summary.id == id, previewVisible else { return }
                    image.image = result.image
                } catch is CancellationError {} catch { if !Task.isCancelled { showNotice("The image preview is unavailable. The entry has been preserved.") } }
            }
        }
    }
    private func setPreview(_ visible: Bool) {
        guard previewVisible != visible else { return }
        previewVisible = visible; previewWidth?.isActive = visible; preview.isHidden = !visible
        if !visible { imageTask?.cancel(); image.image = nil; editor.string = ""; selectedDetail = nil }
        guard let window else { return }
        window.minSize = NSSize(width: visible ? 660 : 400, height: 360)
        window.maxSize = NSSize(width: visible ? 900 : 500, height: 560)
        var frame = window.frame
        let top = frame.maxY
        frame.size = NSSize(width: visible ? 720 : 400, height: min(480, max(360, frame.height)))
        frame.origin.y = top - frame.height
        window.setFrame(frame, display: true); positionWindow()
    }
    func textView(_ textView: NSTextView, shouldChangeTextIn affectedCharRange: NSRange, replacementString: String?) -> Bool {
        guard let replacementString else { return true }
        let proposed = (textView.string as NSString).replacingCharacters(in: affectedCharRange, with: replacementString)
        do {
            if let detail = selectedDetail {
                var copy = drafts; try copy.set(proposed, for: detail.summary.id, original: detail.text ?? "")
                guard copy.byteCount + (combinedDraft?.editedByteCount ?? 0) <= Limits.draftBytes else { throw CoreError.draftLimit }
            } else if var copy = combinedDraft, Set(copy.ids) == selectedIDs {
                try copy.set(proposed, otherDraftBytes: drafts.byteCount)
            } else { return false }
            return true
        }
        catch { showNotice(error.localizedDescription); NSSound.beep(); return false }
    }
    func textDidChange(_ notification: Notification) {
        if selectedIDs.count > 1, combinedDraft.map({ Set($0.ids) == selectedIDs }) == true {
            do {
                try combinedDraft?.set(editor.string, otherDraftBytes: drafts.byteCount)
                draftActions.isHidden = combinedDraft?.hasChanges != true
                editStatus.stringValue = draftActions.isHidden ? "" : "Edited copy"
            } catch { showNotice(error.localizedDescription) }
            return
        }
        guard let detail = selectedDetail else { return }
        do { try drafts.set(editor.string, for: detail.summary.id, original: detail.text ?? ""); draftActions.isHidden = drafts.text(for: detail.summary.id) == nil; editStatus.stringValue = draftActions.isHidden ? "" : "Unsaved" }
        catch { showNotice(error.localizedDescription) }
    }
    func controlTextDidChange(_ obj: Notification) {
        searchTask?.cancel()
        searchTask = Task { [weak self] in do { try await Task.sleep(for: .milliseconds(75)) } catch { return }; guard !Task.isCancelled else { return }; self?.refresh() }
    }
    @objc private func filtersChanged() { selectedIDs = []; refresh() }
    func showNotice(_ message: String) { notice.stringValue = message; noticeContainer.isHidden = message.isEmpty && undoToken == nil }
    func copySelection() { copy(ids: selectedIDs) }
    private func copy(ids: Set<UUID>) {
        guard !ids.isEmpty else { return }
        let combinedText = combinedDraft.flatMap { Set($0.ids) == ids && ids.count > 1 ? $0.text : nil }
        actionTask?.cancel()
        actionTask = Task { [weak self] in
            guard let self else { return }
            do { let payload = try await preparedPayload(ids: ids, combinedText: combinedText); try Task.checkCancellation(); try paste.write(payload); showNotice(ids.count == 1 ? "Copied." : "\(ids.count) entries copied together.") }
            catch is CancellationError {} catch { showNotice(error.localizedDescription) }
        }
    }
    private func preparedPayload(ids: Set<UUID>, combinedText: String? = nil) async throws -> ClipboardSnapshot {
        if let combinedText { return .plainText(combinedText) }
        if ids.count == 1, let id = ids.first { return try await store.materialize(id, draft: drafts.text(for: id)) }
        let ordered = try await store.orderedIDs(query).filter(ids.contains)
        var merged = ""
        for id in ordered {
            try Task.checkCancellation()
            guard let detail = try await store.detail(id), detail.summary.kind.isText else { throw CoreError.invalidData }
            let text = drafts.text(for: id) ?? detail.text ?? ""
            guard merged.utf8.count + text.utf8.count + settings.value.mergeSeparator.utf8.count <= Limits.textBytes else { throw CoreError.tooLarge }
            if !merged.isEmpty { merged += settings.value.mergeSeparator }; merged += text
        }
        return .plainText(merged)
    }
    @objc private func pasteSelected() { pasteSelection() }
    func pasteSelection() {
        guard selectedIDs.count == 1 else { showNotice("Select one item to paste. Use Copy selected to combine compatible text."); return }
        actionTask?.cancel(); let ids = selectedIDs
        actionTask = Task { [weak self] in
            guard let self else { return }
            do {
                let payload = try await preparedPayload(ids: ids)
                if settings.value.automaticPaste { dismissPopup() }
                let result = try await paste.paste(payload, enabled: settings.value.automaticPaste)
                switch result {
                case .pasteEventSent: dismissPopup()
                case .copied: showNotice("Copied.")
                default:
                    NSApp.activate()
                    window?.makeKeyAndOrderFront(nil); installDismissalMonitors(); refresh()
                    let failure = PasteFailurePresentation(outcome: result, deniedDescription: result == .permissionRequired ? PasteAccess.deniedDescription : "")
                    let alert = NSAlert(); alert.messageText = failure.title; alert.informativeText = failure.message
                    alert.addButton(withTitle: "Copy instead"); if failure.offersSettings { alert.addButton(withTitle: "Open Paste Settings…") }; alert.addButton(withTitle: "Cancel")
                    let response = alert.runModal()
                    if response == .alertFirstButtonReturn { try paste.write(payload); showNotice("Copied. Switch to your application and press ⌘V.") }
                    else if failure.offersSettings && response == .alertSecondButtonReturn { onPasteSettings?() }
                }
            } catch is CancellationError {} catch { showNotice(error.localizedDescription) }
        }
    }
    private func saveDraft() {
        guard let id = selectedDetail?.summary.id, let text = drafts.text(for: id) else { return }
        Task { do { try await store.saveText(id, text: text); drafts.remove(id); showNotice("Saved to history."); refresh() } catch { showNotice(error.localizedDescription) } }
    }
    private func revertDraft() {
        if let detail = selectedDetail { drafts.remove(detail.summary.id); render(detail) }
        else if selectedIDs.count > 1, Set(combinedDraft?.ids ?? []) == selectedIDs {
            combinedDraft?.revert(); renderBulk(count: selectedIDs.count, text: combinedDraft?.text)
        }
    }
    private func togglePin() {
        guard selectedIDs.count == 1, let id = selectedIDs.first else { return }
        Task { do { guard let detail = try await store.detail(id) else { return }; try await store.setPinned(id, pinned: !detail.summary.isPinned); refresh() } catch { showNotice(error.localizedDescription) } }
    }
    private func clearBulkSelection() {
        if let first = table.selectedRowIndexes.first { table.selectRowIndexes(IndexSet(integer: first), byExtendingSelection: false) }
    }
    func deleteSelection() {
        let ids = selectedIDs; guard !ids.isEmpty else { return }
        Task {
            do {
                var pinned = false
                for id in ids { if try await store.detail(id)?.summary.isPinned == true { pinned = true } }
                if ids.count > 1 || pinned || !drafts.ids.isDisjoint(with: ids) {
                    let alert = NSAlert(); alert.messageText = "Delete \(ids.count) \(ids.count == 1 ? "entry" : "entries")?"
                    alert.informativeText = "\(pinned ? "This includes pinned entries. " : "")\(!drafts.ids.isDisjoint(with: ids) ? "Unsaved drafts for these entries will be discarded. " : "")Original referenced files will not be removed. You can Undo for 10 seconds."
                    alert.addButton(withTitle: "Delete"); alert.addButton(withTitle: "Cancel")
                    alert.buttons[0].keyEquivalent = ""; alert.buttons[1].keyEquivalent = "\r"
                    guard alert.runModal() == .alertFirstButtonReturn else { return }
                }
                undoToken = try await store.markDeleted(ids)
                for id in ids { drafts.remove(id) }; selectedIDs = []
                undoButton.isHidden = false; showNotice("\(ids.count) \(ids.count == 1 ? "entry" : "entries") deleted."); refresh()
                cleanupTask?.cancel()
                let token = undoToken
                cleanupTask = Task {
                    do { try await Task.sleep(for: .seconds(10)); try await store.purgeExpired(); if undoToken == token { undoToken = nil; undoButton.isHidden = true; showNotice("") } } catch is CancellationError {} catch { showNotice(error.localizedDescription) }
                }
            } catch { showNotice(error.localizedDescription) }
        }
    }
    private func undoDeletion() {
        guard let token = undoToken else { return }
        Task { do { try await store.undoDelete(token); undoToken = nil; undoButton.isHidden = true; showNotice("Entries restored."); refresh() } catch { showNotice(error.localizedDescription) } }
    }
    func requestClose(afterPaste: Bool = false, completion: (() -> Void)? = nil) {
        if let combinedDraft, combinedDraft.hasChanges {
            let alert = NSAlert(); alert.messageText = "Keep your combined edits?"
            alert.informativeText = "Combined edits can be copied. Original history entries stay unchanged."
            alert.addButton(withTitle: "Copy edits"); alert.addButton(withTitle: "Discard"); alert.addButton(withTitle: "Cancel")
            switch alert.runModal() {
            case .alertFirstButtonReturn:
                do { try paste.write(.plainText(combinedDraft.text)) } catch { showNotice(error.localizedDescription); return }
            case .alertSecondButtonReturn: break
            default: return
            }
            self.combinedDraft = nil
        }
        guard !drafts.isEmpty else { window?.orderOut(nil); releasePreview(); completion?(); return }
        let alert = NSAlert(); alert.messageText = "Save edited clipboard entries?"; alert.informativeText = afterPaste ? "The paste event was sent. Your edits have not yet been saved to history." : "Your drafts are only held in memory. Save them to history or discard them before closing."
        alert.addButton(withTitle: "Save all"); alert.addButton(withTitle: "Discard"); alert.addButton(withTitle: "Cancel")
        switch alert.runModal() {
        case .alertFirstButtonReturn:
            let values = Dictionary(uniqueKeysWithValues: drafts.ids.compactMap { id in drafts.text(for: id).map { (id, $0) } })
            Task { do { try await store.saveTexts(values); drafts.removeAll(); window?.orderOut(nil); releasePreview(); completion?() } catch { showNotice(error.localizedDescription) } }
        case .alertSecondButtonReturn: drafts.removeAll(); window?.orderOut(nil); releasePreview(); completion?()
        default: break
        }
    }
    func windowShouldClose(_ sender: NSWindow) -> Bool { requestClose(); return false }
    private func releasePreview() { removeDismissalMonitors(); previewTask?.cancel(); combinedDraft = nil; imageTask?.cancel(); image.image = nil; editor.string = ""; selectedDetail = nil; pages.removeAll(); pageOrder.removeAll() }
    func suspendWindow() { dismissPopup(); pages.removeAll(); pageOrder.removeAll() }
    private func handle(_ event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask), command = flags.contains(.command), shift = flags.contains(.shift)
        let textEditing = window?.firstResponder is NSTextView
        let key = event.charactersIgnoringModifiers?.lowercased() ?? ""
        if command && key == "f" { window?.makeFirstResponder(search); return true }
        if command && key == "," { onSettings?(); return true }
        if command && key == "s" { saveDraft(); return true }
        if command && key == "c" && shift { copySelection(); return true }
        if command && event.keyCode == 36 { pasteSelection(); return true }
        if event.keyCode == 53 { escape(); return true }
        guard !textEditing else { return false }
        if command && key == "c" { copySelection(); return true }
        if command && key == "p" { togglePin(); return true }
        if event.keyCode == 51 || event.keyCode == 117 { deleteSelection(); return true }
        if event.keyCode == 36 { pasteSelection(); return true }
        if event.keyCode == 49 { if previewVisible { setPreview(false) } else { setPreview(true); updateSelection() }; return true }
        return false
    }
    private func escape() {
        if selectedIDs.count > 1 { clearBulkSelection() }
        else if previewVisible { setPreview(false); window?.makeFirstResponder(table) }
        else { dismissPopup() }
    }
    func textView(_ textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        if commandSelector == #selector(NSResponder.cancelOperation(_:)) { escape(); return true }
        return false
    }
    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        if commandSelector == #selector(NSResponder.cancelOperation(_:)) { escape(); return true }
        return false
    }
    private func showShortcuts() {
        let alert = NSAlert(); alert.messageText = "Keyboard shortcuts"
        alert.informativeText = "List: ↑↓ Navigate · ⇧↑↓ Extend selection\n⌘click Toggle · ⇧click Range · ⌘A Select all\n⌘C Copy · Delete / ⌘⌫ Delete entries\nEnter Paste · ⌘P Pin · Space Toggle preview\n\nEditor: ⌘S Save · ⌘Enter Paste draft\n⌘⇧C Copy item · ⌘F Search\n\nCopy and Delete retain normal text-editing behavior inside text fields.\nEscape closes the preview before dismissing history."
        alert.runModal()
    }
    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool { !selectedIDs.isEmpty }
}
private struct PreviewImage: @unchecked Sendable { let image: CGImage }
private extension CGRect { var area: CGFloat { isNull ? 0 : width * height } }
private extension Array { subscript(safe index: Int) -> Element? { indices.contains(index) ? self[index] : nil } }

private actor ImagePreviewLoader {
    func thumbnail(url: URL) throws -> PreviewImage {
        try Task.checkCancellation()
        try PrivateFiles.rejectLink(url)
        guard let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceThumbnailMaxPixelSize: 1024, kCGImageSourceCreateThumbnailWithTransform: true, kCGImageSourceShouldCacheImmediately: true] as CFDictionary) else { throw CoreError.inaccessibleAttachment }
        try Task.checkCancellation()
        return PreviewImage(image: image)
    }
}
