import AppKit

@MainActor final class ActionButton: NSButton {
    var onClick: (() -> Void)?
    init(_ title: String, symbol: String? = nil, action: @escaping () -> Void) {
        super.init(frame: .zero)
        self.title = title; onClick = action; target = self; self.action = #selector(clicked)
        bezelStyle = .rounded; controlSize = .small; font = .systemFont(ofSize: 12)
        if let symbol { image = NSImage(systemSymbolName: symbol, accessibilityDescription: title); imagePosition = title.isEmpty ? .imageOnly : .imageLeading }
        let accessibilityTitle = title.isEmpty ? ["xmark": "Close preview", "keyboard": "Keyboard shortcuts", "gearshape": "Settings", "trash": "Delete entry"][symbol ?? ""] ?? "Action" : title
        setAccessibilityLabel(accessibilityTitle)
        if title.isEmpty { toolTip = accessibilityTitle }
    }
    required init?(coder: NSCoder) { fatalError() }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    @objc private func clicked() { onClick?() }
}
@MainActor func label(_ text: String, size: CGFloat = 12, color: NSColor = .labelColor) -> NSTextField {
    let view = NSTextField(labelWithString: text)
    view.font = .systemFont(ofSize: size); view.textColor = color
    view.lineBreakMode = .byTruncatingTail; view.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    return view
}
@MainActor func row(_ views: [NSView], spacing: CGFloat = 8) -> NSStackView {
    let stack = NSStackView(views: views); stack.orientation = .horizontal; stack.alignment = .centerY; stack.spacing = spacing
    return stack
}
@MainActor func padded(_ view: NSView, horizontal: CGFloat = 14, vertical: CGFloat = 10) -> NSView {
    let container = NSView(); container.addSubview(view); view.translatesAutoresizingMaskIntoConstraints = false
    NSLayoutConstraint.activate([view.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: horizontal), view.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -horizontal), view.topAnchor.constraint(equalTo: container.topAnchor, constant: vertical), view.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -vertical)])
    return container
}
@MainActor func separator() -> NSBox { let box = NSBox(); box.boxType = .separator; return box }
@MainActor final class HistoryTable: NSTableView {
    var command: ((NSEvent) -> Bool)?
    var entryID: ((Int) -> UUID?)?
    var onRowClick: ((UUID) -> Void)?
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseDown(with event: NSEvent) {
        let clickedRow = row(at: convert(event.locationInWindow, from: nil))
        let clickedID = entryID?(clickedRow)
        super.mouseDown(with: event)
        if let clickedID, event.clickCount == 1,
           event.modifierFlags.intersection([.command, .shift, .control, .option]).isEmpty {
            onRowClick?(clickedID)
        }
    }

    override func keyDown(with event: NSEvent) { if command?(event) != true { super.keyDown(with: event) } }
    override func performKeyEquivalent(with event: NSEvent) -> Bool { if command?(event) == true { return true }; return super.performKeyEquivalent(with: event) }
}
@MainActor final class HistoryPanel: NSPanel {
    var command: ((NSEvent) -> Bool)?
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
    override func performKeyEquivalent(with event: NSEvent) -> Bool { if command?(event) == true { return true }; return super.performKeyEquivalent(with: event) }
}
@MainActor final class HistoryCell: NSTableCellView {
    let icon = NSImageView()
    let thumbnail = NSImageView()
    var representedID: UUID?
    var thumbnailTask: Task<Void, Never>?
    let titleLabel = label("", size: 13)
    let metadataLabel = label("", size: 11, color: .secondaryLabelColor)
    let copyButton = ActionButton("", symbol: "doc.on.doc", action: {})
    let previewButton = ActionButton("", symbol: "eye", action: {})
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        icon.imageScaling = .scaleProportionallyDown
        icon.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([icon.widthAnchor.constraint(equalToConstant: 22), icon.heightAnchor.constraint(equalToConstant: 22)])
        thumbnail.imageScaling = .scaleProportionallyDown
        thumbnail.setAccessibilityLabel("Image thumbnail")
        thumbnail.isHidden = true
        thumbnail.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([thumbnail.widthAnchor.constraint(equalToConstant: 64), thumbnail.heightAnchor.constraint(equalToConstant: 48)])
        let visual = row([icon, thumbnail], spacing: 0)
        let text = NSStackView(views: [titleLabel, metadataLabel]); text.orientation = .vertical; text.alignment = .leading; text.spacing = 4
        for (button, name) in [(previewButton, "Preview"), (copyButton, "Copy")] {
            button.setAccessibilityLabel(name); button.toolTip = name
            button.controlSize = .regular
            button.image = button.image?.withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 16, weight: .regular))
            button.translatesAutoresizingMaskIntoConstraints = false
            NSLayoutConstraint.activate([button.widthAnchor.constraint(equalToConstant: 36), button.heightAnchor.constraint(equalToConstant: 36)])
        }
        let actions = row([previewButton, copyButton], spacing: 4)
        for view in [visual, text, actions] {
            addSubview(view)
            view.translatesAutoresizingMaskIntoConstraints = false
        }
        NSLayoutConstraint.activate([
            visual.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            visual.centerYAnchor.constraint(equalTo: centerYAnchor),
            text.leadingAnchor.constraint(equalTo: visual.trailingAnchor, constant: 8),
            text.trailingAnchor.constraint(equalTo: actions.leadingAnchor, constant: -8),
            text.centerYAnchor.constraint(equalTo: centerYAnchor),
            actions.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            actions.centerYAnchor.constraint(equalTo: centerYAnchor)
        ])
        text.setContentHuggingPriority(.defaultLow, for: .horizontal)
        text.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        actions.setContentHuggingPriority(.required, for: .horizontal)
        actions.setContentCompressionResistancePriority(.required, for: .horizontal)
    }
    required init?(coder: NSCoder) { fatalError() }
}

@MainActor final class PreviewStack: NSStackView {
    override func draw(_ dirtyRect: NSRect) { NSColor.controlBackgroundColor.setFill(); bounds.intersection(dirtyRect).fill() }
    override func viewDidChangeEffectiveAppearance() { super.viewDidChangeEffectiveAppearance(); needsDisplay = true }
}

@MainActor final class PopupContentView: NSView {
    override func draw(_ dirtyRect: NSRect) { NSColor.windowBackgroundColor.setFill(); bounds.intersection(dirtyRect).fill() }
    override func viewDidChangeEffectiveAppearance() { super.viewDidChangeEffectiveAppearance(); needsDisplay = true }
}

@MainActor final class ImagePreviewView: NSView {
    var image: CGImage? { didSet { needsDisplay = true } }
    override var intrinsicContentSize: NSSize { NSSize(width: NSView.noIntrinsicMetric, height: NSView.noIntrinsicMetric) }
    var fittedImageRect: NSRect {
        guard let image, bounds.width > 0, bounds.height > 0 else { return .zero }
        let available = bounds.insetBy(dx: 8, dy: 8)
        guard available.width > 0, available.height > 0 else { return .zero }
        let scale = min(available.width / CGFloat(image.width), available.height / CGFloat(image.height), 1)
        let size = NSSize(width: CGFloat(image.width) * scale, height: CGFloat(image.height) * scale)
        return NSRect(x: bounds.midX - size.width / 2, y: bounds.midY - size.height / 2, width: size.width, height: size.height)
    }
    override func draw(_ dirtyRect: NSRect) {
        NSColor.textBackgroundColor.setFill(); bounds.intersection(dirtyRect).fill()
        guard let image, let context = NSGraphicsContext.current?.cgContext else { return }
        context.saveGState()
        context.clip(to: bounds)
        context.interpolationQuality = .high
        context.draw(image, in: fittedImageRect)
        context.restoreGState()
    }
    override func viewDidChangeEffectiveAppearance() { super.viewDidChangeEffectiveAppearance(); needsDisplay = true }
}
