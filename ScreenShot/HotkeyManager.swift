import AppKit
import Carbon.HIToolbox

@MainActor
final class HotkeyManager {
    private var eventHandler: EventHandlerRef?
    private var escapeEventHandler: EventHandlerRef?
    private var hotKeyRef: EventHotKeyRef?
    private var escapeHotKeyRef: EventHotKeyRef?
    private let callback: () -> Void
    private static var sharedCallback: (() -> Void)?
    private static var escapeCallback: (() -> Void)?

    init(callback: @escaping () -> Void) {
        self.callback = callback
    }

    func register() throws {
        HotkeyManager.sharedCallback = callback

        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )

        let handler: EventHandlerUPP = { _, _, _ in
            DispatchQueue.main.async {
                HotkeyManager.sharedCallback?()
            }
            return noErr
        }

        let installStatus = InstallEventHandler(
            GetApplicationEventTarget(),
            handler,
            1,
            &eventType,
            nil,
            &eventHandler
        )
        guard installStatus == noErr else {
            throw NSError(domain: "ScreenShot.Hotkey", code: Int(installStatus),
                          userInfo: [NSLocalizedDescriptionKey: "InstallEventHandler failed"])
        }

        let hotKeyID = EventHotKeyID(signature: OSType(0x53534854 /* 'SSHT' */), id: 1)
        let registerStatus = RegisterEventHotKey(
            UInt32(kVK_F4),
            0,
            hotKeyID,
            GetApplicationEventTarget(),
            0,
            &hotKeyRef
        )
        guard registerStatus == noErr else {
            throw NSError(domain: "ScreenShot.Hotkey", code: Int(registerStatus),
                          userInfo: [NSLocalizedDescriptionKey: "RegisterEventHotKey failed (\(registerStatus))"])
        }
    }

    func registerEscapeHotkey(_ callback: @escaping () -> Void) throws {
        guard escapeHotKeyRef == nil else { return }
        HotkeyManager.escapeCallback = callback

        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )

        let handler: EventHandlerUPP = { _, _, _ in
            DispatchQueue.main.async {
                HotkeyManager.escapeCallback?()
            }
            return noErr
        }

        let installStatus = InstallEventHandler(
            GetApplicationEventTarget(),
            handler,
            1,
            &eventType,
            nil,
            &escapeEventHandler
        )
        guard installStatus == noErr else {
            HotkeyManager.escapeCallback = nil
            throw NSError(domain: "ScreenShot.Hotkey", code: Int(installStatus),
                          userInfo: [NSLocalizedDescriptionKey: "InstallEventHandler Escape failed"])
        }

        let hotKeyID = EventHotKeyID(signature: OSType(0x53534854 /* 'SSHT' */), id: 2)
        var ref: EventHotKeyRef?
        let registerStatus = RegisterEventHotKey(
            UInt32(kVK_Escape),
            0,
            hotKeyID,
            GetApplicationEventTarget(),
            0,
            &ref
        )
        guard registerStatus == noErr, let ref else {
            if let escapeEventHandler { RemoveEventHandler(escapeEventHandler) }
            self.escapeEventHandler = nil
            HotkeyManager.escapeCallback = nil
            throw NSError(domain: "ScreenShot.Hotkey", code: Int(registerStatus),
                          userInfo: [NSLocalizedDescriptionKey: "RegisterEventHotKey Escape failed (\(registerStatus))"])
        }
        escapeHotKeyRef = ref
    }

    func unregisterEscapeHotkey() {
        if let escapeHotKeyRef {
            UnregisterEventHotKey(escapeHotKeyRef)
            self.escapeHotKeyRef = nil
        }
        if let escapeEventHandler {
            RemoveEventHandler(escapeEventHandler)
            self.escapeEventHandler = nil
        }
        HotkeyManager.escapeCallback = nil
    }

    deinit {
        if let escapeHotKeyRef { UnregisterEventHotKey(escapeHotKeyRef) }
        if let escapeEventHandler { RemoveEventHandler(escapeEventHandler) }
        if let hotKeyRef { UnregisterEventHotKey(hotKeyRef) }
        if let eventHandler { RemoveEventHandler(eventHandler) }
    }
}
