import AppKit
import Carbon.HIToolbox

@MainActor
final class HotkeyManager {
    private var eventHandler: EventHandlerRef?
    private var hotKeyRef: EventHotKeyRef?
    private let callback: () -> Void
    private static var sharedCallback: (() -> Void)?

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

    deinit {
        if let hotKeyRef { UnregisterEventHotKey(hotKeyRef) }
        if let eventHandler { RemoveEventHandler(eventHandler) }
    }
}
