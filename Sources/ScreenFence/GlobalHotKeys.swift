import Carbon
import Foundation

@MainActor
final class GlobalHotKeys {
    private var references: [EventHotKeyRef] = []
    private var eventHandler: EventHandlerRef?
    private let onToggle: () -> Void
    private let onEmergency: () -> Void
    private static let signature: OSType = 0x53464E43 // SFNC

    init(onToggle: @escaping () -> Void, onEmergency: @escaping () -> Void) {
        self.onToggle = onToggle
        self.onEmergency = onEmergency
    }

    func register() -> Bool {
        var specification = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let status = InstallEventHandler(
            GetApplicationEventTarget(),
            { _, event, context in
                guard let event, let context else { return OSStatus(eventNotHandledErr) }
                var identifier = EventHotKeyID()
                let result = GetEventParameter(
                    event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                    nil, MemoryLayout<EventHotKeyID>.size, nil, &identifier
                )
                guard result == noErr else { return result }
                let manager = Unmanaged<GlobalHotKeys>.fromOpaque(context).takeUnretainedValue()
                MainActor.assumeIsolated {
                    if identifier.signature == GlobalHotKeys.signature {
                        if identifier.id == 1 { manager.onToggle() }
                        if identifier.id == 2 { manager.onEmergency() }
                    }
                }
                return noErr
            },
            1, &specification, Unmanaged.passUnretained(self).toOpaque(), &eventHandler
        )
        guard status == noErr else { return false }
        let bindings = [
            (id: UInt32(1), key: UInt32(kVK_ANSI_L), modifiers: UInt32(cmdKey)),
            (id: UInt32(2), key: UInt32(kVK_Escape), modifiers: UInt32(controlKey | optionKey | cmdKey))
        ]
        for binding in bindings {
            var reference: EventHotKeyRef?
            let result = RegisterEventHotKey(
                binding.key, binding.modifiers, EventHotKeyID(signature: Self.signature, id: binding.id),
                GetApplicationEventTarget(), 0, &reference
            )
            guard result == noErr, let reference else { unregister(); return false }
            references.append(reference)
        }
        return true
    }

    func unregister() {
        for reference in references { UnregisterEventHotKey(reference) }
        references.removeAll()
        if let eventHandler { RemoveEventHandler(eventHandler) }
        eventHandler = nil
    }
}
