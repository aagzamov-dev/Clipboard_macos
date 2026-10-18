import AppKit
import Carbon

@MainActor final class GlobalShortcut {
    private var hotKey: EventHotKeyRef?
    private var handler: EventHandlerRef?
    var onOpen: (() -> Void)?
    init() {
        var type = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, context in
            guard let context, let event else { return OSStatus(eventNotHandledErr) }
            var identifier = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), nil, MemoryLayout<EventHotKeyID>.size, nil, &identifier)
            guard identifier.signature == 0x434C4950 else { return OSStatus(eventNotHandledErr) }
            MainActor.assumeIsolated { Unmanaged<GlobalShortcut>.fromOpaque(context).takeUnretainedValue().onOpen?() }
            return noErr
        }, 1, &type, Unmanaged.passUnretained(self).toOpaque(), &handler)
    }
    func register(keyCode: UInt32, modifiers: UInt32) throws {
        var replacement: EventHotKeyRef?
        let code = RegisterEventHotKey(keyCode, modifiers, EventHotKeyID(signature: 0x434C4950, id: 1), GetApplicationEventTarget(), OptionBits(kEventHotKeyExclusive), &replacement)
        guard code == noErr else { throw ShortcutError.conflict }
        if let hotKey { UnregisterEventHotKey(hotKey) }
        hotKey = replacement
    }
    func invalidate() { if let hotKey { UnregisterEventHotKey(hotKey) }; hotKey = nil; if let handler { RemoveEventHandler(handler) }; handler = nil }
    enum ShortcutError: LocalizedError { case conflict; var errorDescription: String? { "That shortcut is unavailable. Choose another combination in Settings." } }
}
