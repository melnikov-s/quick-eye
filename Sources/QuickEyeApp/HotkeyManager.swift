import Carbon
import Foundation

@MainActor
final class HotkeyManager {
    private static var sharedHandlerInstalled = false
    private static var actionByIdentifier: [UInt32: () -> Void] = [:]
    private static var nextIdentifier: UInt32 = 1

    private var hotKeyRef: EventHotKeyRef?
    private var identifier: UInt32?

    func registerDefaultHotKey(action: @escaping () -> Void) {
        let defaultShortcut = HotKeyShortcut(
            keyCode: UInt32(kVK_ANSI_6),
            modifiers: UInt32(shiftKey) | UInt32(cmdKey)
        )

        register(shortcut: defaultShortcut, action: action)
    }

    func register(shortcut: HotKeyShortcut, action: @escaping () -> Void) {
        unregister()
        installHandlerIfNeeded()

        let currentIdentifier = Self.nextIdentifier
        Self.nextIdentifier += 1
        Self.actionByIdentifier[currentIdentifier] = action
        identifier = currentIdentifier

        let hotKeyID = EventHotKeyID(signature: fourCharCode(from: "QKYE"), id: currentIdentifier)
        RegisterEventHotKey(
            shortcut.keyCode,
            shortcut.modifiers,
            hotKeyID,
            GetApplicationEventTarget(),
            0,
            &hotKeyRef
        )
    }

    func unregister() {
        if let hotKeyRef {
            UnregisterEventHotKey(hotKeyRef)
            self.hotKeyRef = nil
        }

        if let identifier {
            Self.actionByIdentifier.removeValue(forKey: identifier)
            self.identifier = nil
        }
    }

    private func installHandlerIfNeeded() {
        guard !Self.sharedHandlerInstalled else { return }

        var eventSpec = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )

        InstallEventHandler(
            GetApplicationEventTarget(),
            { _, eventRef, _ in
                var hotKeyID = EventHotKeyID()
                let status = GetEventParameter(
                    eventRef,
                    EventParamName(kEventParamDirectObject),
                    EventParamType(typeEventHotKeyID),
                    nil,
                    MemoryLayout<EventHotKeyID>.size,
                    nil,
                    &hotKeyID
                )

                guard status == noErr else {
                    return OSStatus(eventNotHandledErr)
                }

                Task { @MainActor in
                    HotkeyManager.actionByIdentifier[hotKeyID.id]?()
                }
                return noErr
            },
            1,
            &eventSpec,
            nil,
            nil
        )

        Self.sharedHandlerInstalled = true
    }

    private func fourCharCode(from string: String) -> OSType {
        string.utf8.reduce(0) { partial, scalar in
            (partial << 8) + OSType(scalar)
        }
    }
}

struct HotKeyShortcut {
    let keyCode: UInt32
    let modifiers: UInt32
}
