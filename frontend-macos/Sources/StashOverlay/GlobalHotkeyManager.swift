import AppKit
import Carbon
import Foundation

enum GlobalHotkeyAction: UInt32 {
    case latestQuickChat = 1
    case pickerQuickChat = 2
}

struct GlobalHotkeySpec: Equatable {
    let action: GlobalHotkeyAction
    let keyCode: UInt32
    let modifiers: UInt32

    static let `default`: [GlobalHotkeySpec] = [
        GlobalHotkeySpec(
            action: .latestQuickChat,
            keyCode: UInt32(kVK_Space),
            modifiers: UInt32(controlKey)
        ),
        GlobalHotkeySpec(
            action: .pickerQuickChat,
            keyCode: UInt32(kVK_Space),
            modifiers: UInt32(controlKey | shiftKey)
        ),
    ]

    static func action(for eventID: UInt32) -> GlobalHotkeyAction? {
        GlobalHotkeyAction(rawValue: eventID)
    }
}

final class GlobalHotkeyManager {
    var onLatestQuickChat: (() -> Void)?
    var onPickerQuickChat: (() -> Void)?

    private static let hotkeySignature: OSType = {
        let bytes: [UInt8] = [83, 84, 83, 72] // STSH
        return bytes.reduce(0) { ($0 << 8) | OSType($1) }
    }()

    private var eventHandlerRef: EventHandlerRef?
    private var hotKeyRefs: [GlobalHotkeyAction: EventHotKeyRef] = [:]
    private var isStarted = false

    deinit {
        stop()
    }

    func start() {
        guard !isStarted else { return }
        isStarted = true

        installEventHandler()
        for spec in GlobalHotkeySpec.default {
            registerHotKey(spec)
        }
    }

    func stop() {
        guard isStarted else { return }
        isStarted = false

        for hotKeyRef in hotKeyRefs.values {
            UnregisterEventHotKey(hotKeyRef)
        }
        hotKeyRefs.removeAll()

        if let eventHandlerRef {
            RemoveEventHandler(eventHandlerRef)
            self.eventHandlerRef = nil
        }
    }

    private func installEventHandler() {
        guard eventHandlerRef == nil else { return }

        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )

        let status = InstallEventHandler(
            GetApplicationEventTarget(),
            { _, eventRef, userData in
                guard let eventRef, let userData else { return noErr }
                let manager = Unmanaged<GlobalHotkeyManager>.fromOpaque(userData).takeUnretainedValue()
                manager.handleHotKeyPressed(eventRef)
                return noErr
            },
            1,
            &eventType,
            UnsafeMutableRawPointer(Unmanaged.passUnretained(self).toOpaque()),
            &eventHandlerRef
        )

        if status != noErr {
            print("Failed to install global hotkey event handler (status: \(status)).")
        }
    }

    private func registerHotKey(_ spec: GlobalHotkeySpec) {
        guard eventHandlerRef != nil else {
            print("Cannot register hotkey without event handler.")
            return
        }

        let hotKeyID = EventHotKeyID(
            signature: Self.hotkeySignature,
            id: spec.action.rawValue
        )

        var hotKeyRef: EventHotKeyRef?
        let status = RegisterEventHotKey(
            spec.keyCode,
            spec.modifiers,
            hotKeyID,
            GetApplicationEventTarget(),
            0,
            &hotKeyRef
        )

        if status == noErr, let hotKeyRef {
            hotKeyRefs[spec.action] = hotKeyRef
            return
        }

        if status == eventHotKeyExistsErr {
            print("Global hotkey already registered or unavailable for action \(spec.action).")
        } else {
            print("Failed to register global hotkey for action \(spec.action) (status: \(status)).")
        }
    }

    private func handleHotKeyPressed(_ eventRef: EventRef) {
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

        guard status == noErr else { return }
        guard hotKeyID.signature == Self.hotkeySignature else { return }
        guard let action = GlobalHotkeySpec.action(for: hotKeyID.id) else { return }

        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            switch action {
            case .latestQuickChat:
                self.onLatestQuickChat?()
            case .pickerQuickChat:
                self.onPickerQuickChat?()
            }
        }
    }
}
