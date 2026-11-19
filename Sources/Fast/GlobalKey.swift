import AppKit
import Carbon.HIToolbox

/// A key for the whole Mac: a hot key the system hands to this app whichever
/// is in front, with no permission to ask for, which a key monitor for other
/// apps' keys would need. The small window's (⌥⌘N) and Show Yab's (none out
/// of the box) are two of them, told apart by their id.
@MainActor
@Observable final class GlobalKey {
    enum State: Equatable {
        case heard, off
        /// macOS gave it to another app first, Arc's Little Arc say.
        case taken
    }

    /// Whether the key is heard from every app, for the rows that name it:
    /// they say so when it isn't.
    private(set) var state: State = .off

    private let id: UInt32
    private let pressed: () -> Void
    /// Asked again as the keyboard layout changes.
    private let again: () -> Void
    @ObservationIgnored private var hot: EventHotKeyRef?
    @ObservationIgnored private var registered: Hotkey?
    @ObservationIgnored private var registeredCode: UInt16?

    private static var keys: [UInt32: GlobalKey] = [:]
    private static var hearing: EventHandlerRef?
    private static var layoutWatch: NSObjectProtocol?

    init(id: UInt32, pressed: @escaping () -> Void, again: @escaping () -> Void) {
        self.id = id
        self.pressed = pressed
        self.again = again
        Self.keys[id] = self
    }

    /// What `register` is to do: nothing, or register these keys under this
    /// key code. Nil when it is off, or the key has no code to be heard by.
    nonisolated static func plan(on: Bool, keys: Hotkey?, code: (String) -> UInt16?) -> (keys: Hotkey, code: UInt16)? {
        guard on, let keys, !keys.flags.intersection([.command, .option, .control]).isEmpty,
              let code = code(keys.key) else { return nil }
        return (keys, code)
    }

    func register(on: Bool, keys: Hotkey?) {
        // macOS hears a hot key by its key code, so the code is the one that
        // types the key on the ASCII layout picked, again as that changes:
        // ⌥⌘N is under B on a QWERTY keyboard set to Dvorak.
        let plan = Self.plan(on: on, keys: keys, code: { KeyLayout.code(for: $0) })
        // A key refused before is asked for again: the app holding it may
        // have quit since.
        guard plan?.keys != registered || plan?.code != registeredCode || state == .taken else { return }
        if let hot { UnregisterEventHotKey(hot) }
        hot = nil
        registered = nil
        registeredCode = nil
        guard let (wanted, code) = plan else {
            if state != .off { state = .off }
            return
        }
        Self.listen()
        var modifiers: UInt32 = 0
        if wanted.flags.contains(.command) { modifiers |= UInt32(cmdKey) }
        if wanted.flags.contains(.option) { modifiers |= UInt32(optionKey) }
        if wanted.flags.contains(.control) { modifiers |= UInt32(controlKey) }
        if wanted.flags.contains(.shift) { modifiers |= UInt32(shiftKey) }
        // "YAB!", and which of this app's keys for the Mac it is.
        let hotID = EventHotKeyID(signature: 0x5941_4221, id: id)
        let now: State
        if RegisterEventHotKey(UInt32(code), modifiers, hotID, GetApplicationEventTarget(), 0, &hot) == noErr {
            registered = wanted
            registeredCode = code
            now = .heard
        } else {
            hot = nil
            now = .taken
        }
        if state != now { state = now }
    }

    private static func listen() {
        if layoutWatch == nil {
            layoutWatch = DistributedNotificationCenter.default().addObserver(
                forName: NSNotification.Name(kTISNotifySelectedKeyboardInputSourceChanged as String), object: nil, queue: .main
            ) { _ in
                MainActor.assumeIsolated { GlobalKey.keys.values.forEach { $0.again() } }
            }
        }
        guard hearing == nil else { return }
        var pressed = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, _ in
            var hotID = EventHotKeyID()
            guard let event, GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                                               nil, MemoryLayout<EventHotKeyID>.size, nil, &hotID) == noErr,
                  hotID.signature == 0x5941_4221 else { return OSStatus(eventNotHandledErr) }
            let id = hotID.id
            DispatchQueue.main.async { MainActor.assumeIsolated { GlobalKey.keys[id]?.pressed() } }
            return noErr
        }, 1, &pressed, nil, &hearing)
    }
}
