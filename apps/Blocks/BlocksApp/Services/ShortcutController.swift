import AppKit
import Carbon.HIToolbox
import OSLog

enum ShortcutModifierPreset: String, CaseIterable, Identifiable {
    case option
    case control
    case shift
    case command
    case controlShift
    case controlOption
    case shiftOption
    case commandOption

    var id: String { rawValue }

    var modifierFlags: NSEvent.ModifierFlags {
        switch self {
        case .option:
            [.option]
        case .control:
            [.control]
        case .shift:
            [.shift]
        case .command:
            [.command]
        case .controlShift:
            [.control, .shift]
        case .controlOption:
            [.control, .option]
        case .shiftOption:
            [.shift, .option]
        case .commandOption:
            [.command, .option]
        }
    }

    var localizedTitle: String {
        switch self {
        case .option:
            L10n.string("shortcut.modifier.option")
        case .control:
            L10n.string("shortcut.modifier.control")
        case .shift:
            L10n.string("shortcut.modifier.shift")
        case .command:
            L10n.string("shortcut.modifier.command")
        case .controlShift:
            L10n.string("shortcut.modifier.controlShift")
        case .controlOption:
            L10n.string("shortcut.modifier.controlOption")
        case .shiftOption:
            L10n.string("shortcut.modifier.shiftOption")
        case .commandOption:
            L10n.string("shortcut.modifier.commandOption")
        }
    }
}

enum ShortcutBindingSource: String {
    case global
    case custom

    var localizedTitle: String {
        switch self {
        case .global:
            L10n.string("settings.shortcutSource.global")
        case .custom:
            L10n.string("settings.shortcutSource.custom")
        }
    }
}

enum ShortcutCommand: String, CaseIterable, Identifiable {
    case screenshotSmart
    case clipboardHistory
    case translationPanel
    case translationScreenshot
    case clipboardQuickPaste1
    case clipboardQuickPaste2
    case clipboardQuickPaste3
    case clipboardQuickPaste4
    case clipboardQuickPaste5
    case clipboardQuickPaste6
    case clipboardQuickPaste7
    case clipboardQuickPaste8
    case clipboardQuickPaste9

    var id: String { rawValue }

    static let settingsVisibleCases: [ShortcutCommand] = [
        .screenshotSmart,
        .clipboardHistory,
        .translationPanel,
        .translationScreenshot
    ]

    var quickPasteIndex: Int? {
        switch self {
        case .clipboardQuickPaste1:
            1
        case .clipboardQuickPaste2:
            2
        case .clipboardQuickPaste3:
            3
        case .clipboardQuickPaste4:
            4
        case .clipboardQuickPaste5:
            5
        case .clipboardQuickPaste6:
            6
        case .clipboardQuickPaste7:
            7
        case .clipboardQuickPaste8:
            8
        case .clipboardQuickPaste9:
            9
        case .screenshotSmart, .clipboardHistory, .translationPanel, .translationScreenshot:
            nil
        }
    }

    var titleKey: String {
        switch self {
        case .screenshotSmart:
            "menu.screenshot"
        case .clipboardHistory:
            "menu.clipboard"
        case .translationPanel:
            "menu.translation"
        case .translationScreenshot:
            "translation.shortcut.screenshot"
        case .clipboardQuickPaste1,
             .clipboardQuickPaste2,
             .clipboardQuickPaste3,
             .clipboardQuickPaste4,
             .clipboardQuickPaste5,
             .clipboardQuickPaste6,
             .clipboardQuickPaste7,
             .clipboardQuickPaste8,
             .clipboardQuickPaste9:
            "clipboard.quickPaste"
        }
    }

    var keyEquivalent: String {
        ShortcutBindingStore.effectiveBinding(for: self).displayValue
    }

    var defaultKeyEquivalent: String {
        switch self {
        case .screenshotSmart:
            "Control + Option + A"
        case .clipboardHistory:
            "Control + Option + V"
        case .translationPanel:
            "Control + Option + D"
        case .translationScreenshot:
            "Control + Option + S"
        case .clipboardQuickPaste1:
            "Command + 1"
        case .clipboardQuickPaste2:
            "Command + 2"
        case .clipboardQuickPaste3:
            "Command + 3"
        case .clipboardQuickPaste4:
            "Command + 4"
        case .clipboardQuickPaste5:
            "Command + 5"
        case .clipboardQuickPaste6:
            "Command + 6"
        case .clipboardQuickPaste7:
            "Command + 7"
        case .clipboardQuickPaste8:
            "Command + 8"
        case .clipboardQuickPaste9:
            "Command + 9"
        }
    }

    var hotKeyID: UInt32 {
        switch self {
        case .screenshotSmart:
            1
        case .clipboardHistory:
            2
        case .translationPanel:
            3
        case .translationScreenshot:
            4
        case .clipboardQuickPaste1:
            101
        case .clipboardQuickPaste2:
            102
        case .clipboardQuickPaste3:
            103
        case .clipboardQuickPaste4:
            104
        case .clipboardQuickPaste5:
            105
        case .clipboardQuickPaste6:
            106
        case .clipboardQuickPaste7:
            107
        case .clipboardQuickPaste8:
            108
        case .clipboardQuickPaste9:
            109
        }
    }

    var keyCode: UInt32 {
        defaultBinding.keyCode
    }

    var defaultBinding: ShortcutBinding {
        switch self {
        case .screenshotSmart:
            ShortcutBinding(command: self, keyCode: UInt32(kVK_ANSI_A), keyLabel: "A", modifierFlagsRawValue: UInt(NSEvent.ModifierFlags([.control, .option]).rawValue), enabled: true)
        case .clipboardHistory:
            ShortcutBinding(command: self, keyCode: UInt32(kVK_ANSI_V), keyLabel: "V", modifierFlagsRawValue: UInt(NSEvent.ModifierFlags([.control, .option]).rawValue), enabled: true)
        case .translationPanel:
            ShortcutBinding(command: self, keyCode: UInt32(kVK_ANSI_D), keyLabel: "D", modifierFlagsRawValue: UInt(NSEvent.ModifierFlags([.control, .option]).rawValue), enabled: true)
        case .translationScreenshot:
            ShortcutBinding(command: self, keyCode: UInt32(kVK_ANSI_S), keyLabel: "S", modifierFlagsRawValue: UInt(NSEvent.ModifierFlags([.control, .option]).rawValue), enabled: true)
        case .clipboardQuickPaste1:
            ShortcutBinding(command: self, keyCode: UInt32(kVK_ANSI_1), keyLabel: "1", modifierFlagsRawValue: UInt(NSEvent.ModifierFlags([.command]).rawValue), enabled: true)
        case .clipboardQuickPaste2:
            ShortcutBinding(command: self, keyCode: UInt32(kVK_ANSI_2), keyLabel: "2", modifierFlagsRawValue: UInt(NSEvent.ModifierFlags([.command]).rawValue), enabled: true)
        case .clipboardQuickPaste3:
            ShortcutBinding(command: self, keyCode: UInt32(kVK_ANSI_3), keyLabel: "3", modifierFlagsRawValue: UInt(NSEvent.ModifierFlags([.command]).rawValue), enabled: true)
        case .clipboardQuickPaste4:
            ShortcutBinding(command: self, keyCode: UInt32(kVK_ANSI_4), keyLabel: "4", modifierFlagsRawValue: UInt(NSEvent.ModifierFlags([.command]).rawValue), enabled: true)
        case .clipboardQuickPaste5:
            ShortcutBinding(command: self, keyCode: UInt32(kVK_ANSI_5), keyLabel: "5", modifierFlagsRawValue: UInt(NSEvent.ModifierFlags([.command]).rawValue), enabled: true)
        case .clipboardQuickPaste6:
            ShortcutBinding(command: self, keyCode: UInt32(kVK_ANSI_6), keyLabel: "6", modifierFlagsRawValue: UInt(NSEvent.ModifierFlags([.command]).rawValue), enabled: true)
        case .clipboardQuickPaste7:
            ShortcutBinding(command: self, keyCode: UInt32(kVK_ANSI_7), keyLabel: "7", modifierFlagsRawValue: UInt(NSEvent.ModifierFlags([.command]).rawValue), enabled: true)
        case .clipboardQuickPaste8:
            ShortcutBinding(command: self, keyCode: UInt32(kVK_ANSI_8), keyLabel: "8", modifierFlagsRawValue: UInt(NSEvent.ModifierFlags([.command]).rawValue), enabled: true)
        case .clipboardQuickPaste9:
            ShortcutBinding(command: self, keyCode: UInt32(kVK_ANSI_9), keyLabel: "9", modifierFlagsRawValue: UInt(NSEvent.ModifierFlags([.command]).rawValue), enabled: true)
        }
    }

    var localizedTitle: String {
        L10n.string(titleKey)
    }
}

struct ShortcutBinding: Codable, Equatable, Identifiable {
    let commandRawValue: String
    var keyCode: UInt32
    var keyLabel: String
    var modifierFlagsRawValue: UInt
    var enabled: Bool

    init(command: ShortcutCommand, keyCode: UInt32, keyLabel: String, modifierFlagsRawValue: UInt, enabled: Bool) {
        self.commandRawValue = command.rawValue
        self.keyCode = keyCode
        self.keyLabel = keyLabel
        self.modifierFlagsRawValue = modifierFlagsRawValue
        self.enabled = enabled
    }

    var id: String { commandRawValue }

    var command: ShortcutCommand? {
        ShortcutCommand(rawValue: commandRawValue)
    }

    var modifierFlags: NSEvent.ModifierFlags {
        NSEvent.ModifierFlags(rawValue: UInt(modifierFlagsRawValue))
    }

    var carbonModifiers: UInt32 {
        var modifiers: UInt32 = 0
        let flags = modifierFlags
        if flags.contains(.command) {
            modifiers |= UInt32(cmdKey)
        }
        if flags.contains(.option) {
            modifiers |= UInt32(optionKey)
        }
        if flags.contains(.control) {
            modifiers |= UInt32(controlKey)
        }
        if flags.contains(.shift) {
            modifiers |= UInt32(shiftKey)
        }
        return modifiers
    }

    var displayValue: String {
        let pieces = modifierLabels + [Self.canonicalKeyLabel(for: keyCode) ?? keyLabel.uppercased()]
        return pieces.joined(separator: " + ")
    }

    func replacingModifierFlags(_ flags: NSEvent.ModifierFlags) -> ShortcutBinding {
        ShortcutBinding(
            command: command ?? .screenshotSmart,
            keyCode: keyCode,
            keyLabel: keyLabel,
            modifierFlagsRawValue: UInt(flags.rawValue),
            enabled: enabled
        )
    }

    private var modifierLabels: [String] {
        var labels: [String] = []
        let flags = modifierFlags
        if flags.contains(.control) {
            labels.append("Control")
        }
        if flags.contains(.option) {
            labels.append("Option")
        }
        if flags.contains(.shift) {
            labels.append("Shift")
        }
        if flags.contains(.command) {
            labels.append("Command")
        }
        return labels
    }

    static func make(command: ShortcutCommand, event: NSEvent, enabled: Bool) -> ShortcutBinding? {
        make(
            command: command,
            keyCode: UInt32(event.keyCode),
            modifierFlags: event.modifierFlags,
            enabled: enabled
        )
    }

#if DEBUG
    static func makeForFixtures(
        command: ShortcutCommand,
        keyCode: UInt32,
        modifierFlags: NSEvent.ModifierFlags,
        charactersIgnoringModifiers _: String?,
        enabled: Bool
    ) -> ShortcutBinding? {
        make(
            command: command,
            keyCode: keyCode,
            modifierFlags: modifierFlags,
            enabled: enabled
        )
    }
#endif

    static func canonicalKeyLabel(for keyCode: UInt32) -> String? {
        ansiKeyLabels[keyCode]
    }

    static func supportedModifierFlags(from flags: NSEvent.ModifierFlags) -> NSEvent.ModifierFlags {
        flags.intersection([.command, .option, .control, .shift])
    }

    func normalizedForRegistration() -> ShortcutBinding? {
        guard let keyLabel = Self.canonicalKeyLabel(for: keyCode) else {
            return nil
        }
        let modifierFlags = Self.supportedModifierFlags(from: modifierFlags)
        guard !modifierFlags.isEmpty else {
            return nil
        }
        var normalized = self
        normalized.keyLabel = keyLabel
        normalized.modifierFlagsRawValue = UInt(modifierFlags.rawValue)
        return normalized
    }

    private static func make(
        command: ShortcutCommand,
        keyCode: UInt32,
        modifierFlags: NSEvent.ModifierFlags,
        enabled: Bool
    ) -> ShortcutBinding? {
        let filteredModifiers = supportedModifierFlags(from: modifierFlags)
        guard !filteredModifiers.isEmpty else {
            return nil
        }
        guard let keyLabel = canonicalKeyLabel(for: keyCode) else {
            return nil
        }
        return ShortcutBinding(
            command: command,
            keyCode: keyCode,
            keyLabel: keyLabel,
            modifierFlagsRawValue: UInt(filteredModifiers.rawValue),
            enabled: enabled
        )
    }

    private static let ansiKeyLabels: [UInt32: String] = [
        UInt32(kVK_ANSI_A): "A", UInt32(kVK_ANSI_B): "B", UInt32(kVK_ANSI_C): "C", UInt32(kVK_ANSI_D): "D",
        UInt32(kVK_ANSI_E): "E", UInt32(kVK_ANSI_F): "F", UInt32(kVK_ANSI_G): "G", UInt32(kVK_ANSI_H): "H",
        UInt32(kVK_ANSI_I): "I", UInt32(kVK_ANSI_J): "J", UInt32(kVK_ANSI_K): "K", UInt32(kVK_ANSI_L): "L",
        UInt32(kVK_ANSI_M): "M", UInt32(kVK_ANSI_N): "N", UInt32(kVK_ANSI_O): "O", UInt32(kVK_ANSI_P): "P",
        UInt32(kVK_ANSI_Q): "Q", UInt32(kVK_ANSI_R): "R", UInt32(kVK_ANSI_S): "S", UInt32(kVK_ANSI_T): "T",
        UInt32(kVK_ANSI_U): "U", UInt32(kVK_ANSI_V): "V", UInt32(kVK_ANSI_W): "W", UInt32(kVK_ANSI_X): "X",
        UInt32(kVK_ANSI_Y): "Y", UInt32(kVK_ANSI_Z): "Z",
        UInt32(kVK_ANSI_0): "0", UInt32(kVK_ANSI_1): "1", UInt32(kVK_ANSI_2): "2", UInt32(kVK_ANSI_3): "3",
        UInt32(kVK_ANSI_4): "4", UInt32(kVK_ANSI_5): "5", UInt32(kVK_ANSI_6): "6", UInt32(kVK_ANSI_7): "7",
        UInt32(kVK_ANSI_8): "8", UInt32(kVK_ANSI_9): "9",
        UInt32(kVK_ANSI_Grave): "`", UInt32(kVK_ANSI_Minus): "-", UInt32(kVK_ANSI_Equal): "=",
        UInt32(kVK_ANSI_LeftBracket): "[", UInt32(kVK_ANSI_RightBracket): "]", UInt32(kVK_ANSI_Backslash): "\\",
        UInt32(kVK_ANSI_Semicolon): ";", UInt32(kVK_ANSI_Quote): "'", UInt32(kVK_ANSI_Comma): ",",
        UInt32(kVK_ANSI_Period): ".", UInt32(kVK_ANSI_Slash): "/",
        UInt32(kVK_ANSI_Keypad0): "Keypad 0", UInt32(kVK_ANSI_Keypad1): "Keypad 1",
        UInt32(kVK_ANSI_Keypad2): "Keypad 2", UInt32(kVK_ANSI_Keypad3): "Keypad 3",
        UInt32(kVK_ANSI_Keypad4): "Keypad 4", UInt32(kVK_ANSI_Keypad5): "Keypad 5",
        UInt32(kVK_ANSI_Keypad6): "Keypad 6", UInt32(kVK_ANSI_Keypad7): "Keypad 7",
        UInt32(kVK_ANSI_Keypad8): "Keypad 8", UInt32(kVK_ANSI_Keypad9): "Keypad 9",
        UInt32(kVK_ANSI_KeypadDecimal): "Keypad .", UInt32(kVK_ANSI_KeypadDivide): "Keypad /",
        UInt32(kVK_ANSI_KeypadMinus): "Keypad -", UInt32(kVK_ANSI_KeypadEquals): "Keypad ="
    ]
}

enum ShortcutBindingStore {
    private static let encoder = JSONEncoder()
    private static let decoder = JSONDecoder()
    private static let globalModifierKey = "shortcut.globalModifier"
    private static let defaultGlobalModifierPreset: ShortcutModifierPreset = .controlOption

    static func binding(for command: ShortcutCommand, userDefaults: UserDefaults = .standard) -> ShortcutBinding {
        effectiveBinding(for: command, userDefaults: userDefaults)
    }

    static func effectiveBinding(for command: ShortcutCommand, userDefaults: UserDefaults = .standard) -> ShortcutBinding {
        if let custom = customBinding(for: command, userDefaults: userDefaults) {
            return custom
        }
        return defaultBindingWithEnabledOverride(command: command, userDefaults: userDefaults)
    }

    static func customBinding(for command: ShortcutCommand, userDefaults: UserDefaults = .standard) -> ShortcutBinding? {
        guard command.quickPasteIndex == nil else {
            return nil
        }
        guard
            let rawValue = userDefaults.string(forKey: bindingKey(for: command)),
            let data = rawValue.data(using: .utf8),
            var binding = try? decoder.decode(ShortcutBinding.self, from: data),
            binding.command == command
        else {
            return nil
        }
        guard let normalizedBinding = binding.normalizedForRegistration() else {
            return nil
        }
        binding = normalizedBinding
        if userDefaults.object(forKey: enabledKey(for: command)) != nil {
            binding.enabled = userDefaults.bool(forKey: enabledKey(for: command))
        }
        return binding
    }

    static func hasCustomBinding(for command: ShortcutCommand, userDefaults: UserDefaults = .standard) -> Bool {
        customBinding(for: command, userDefaults: userDefaults) != nil
    }

    static func bindingSource(for command: ShortcutCommand, userDefaults: UserDefaults = .standard) -> ShortcutBindingSource {
        hasCustomBinding(for: command, userDefaults: userDefaults) ? .custom : .global
    }

    static func globalModifierPreset(userDefaults: UserDefaults = .standard) -> ShortcutModifierPreset {
        return ShortcutModifierPreset(rawValue: userDefaults.string(forKey: globalModifierKey) ?? "") ?? defaultGlobalModifierPreset
    }

    static func setGlobalModifierPreset(_ preset: ShortcutModifierPreset, userDefaults: UserDefaults = .standard) {
        userDefaults.set(preset.rawValue, forKey: globalModifierKey)
    }

    static func save(_ binding: ShortcutBinding, userDefaults: UserDefaults = .standard) {
        guard let command = binding.command, let keyLabel = ShortcutBinding.canonicalKeyLabel(for: binding.keyCode) else {
            return
        }
        guard command.quickPasteIndex == nil else {
            return
        }
        guard var canonicalBinding = binding.normalizedForRegistration() else {
            return
        }
        canonicalBinding.keyLabel = keyLabel
        guard let data = try? encoder.encode(canonicalBinding), let rawValue = String(data: data, encoding: .utf8) else {
            return
        }
        userDefaults.set(rawValue, forKey: bindingKey(for: command))
        userDefaults.set(canonicalBinding.enabled, forKey: enabledKey(for: command))
    }

    static func setEnabled(_ enabled: Bool, for command: ShortcutCommand, userDefaults: UserDefaults = .standard) {
        guard command.quickPasteIndex == nil else {
            return
        }
        var binding = binding(for: command, userDefaults: userDefaults)
        binding.enabled = enabled
        save(binding, userDefaults: userDefaults)
    }

    static func restoreDefault(for command: ShortcutCommand, userDefaults: UserDefaults = .standard) {
        userDefaults.removeObject(forKey: bindingKey(for: command))
        userDefaults.removeObject(forKey: enabledKey(for: command))
    }

    static func restoreAllDefaults(userDefaults: UserDefaults = .standard) {
        for command in ShortcutCommand.allCases {
            restoreDefault(for: command, userDefaults: userDefaults)
        }
        userDefaults.removeObject(forKey: globalModifierKey)
    }

    private static func defaultBindingWithEnabledOverride(command: ShortcutCommand, userDefaults: UserDefaults) -> ShortcutBinding {
        guard command.quickPasteIndex == nil else {
            return command.defaultBinding
        }
        var binding = command.defaultBinding.replacingModifierFlags(globalModifierPreset(userDefaults: userDefaults).modifierFlags)
        if userDefaults.object(forKey: enabledKey(for: command)) != nil {
            binding.enabled = userDefaults.bool(forKey: enabledKey(for: command))
        }
        return binding
    }

    private static func bindingKey(for command: ShortcutCommand) -> String {
        "shortcut.binding.\(command.rawValue)"
    }

    private static func enabledKey(for command: ShortcutCommand) -> String {
        "shortcut.enabled.\(command.rawValue)"
    }
}

enum ShortcutRegistrationFailureReason: Equatable {
    case missingReference
    case unregistrationFailed
    case invalidBinding
}

struct ShortcutRegistrationResult: Identifiable {
    let command: ShortcutCommand
    let binding: ShortcutBinding
    let registered: Bool
    let osStatus: OSStatus
    let runtimeDisabled: Bool
    let failureReason: ShortcutRegistrationFailureReason?

    init(
        command: ShortcutCommand,
        binding: ShortcutBinding,
        registered: Bool,
        osStatus: OSStatus,
        runtimeDisabled: Bool = false,
        failureReason: ShortcutRegistrationFailureReason? = nil
    ) {
        self.command = command
        self.binding = binding
        self.registered = registered
        self.osStatus = osStatus
        self.runtimeDisabled = runtimeDisabled
        self.failureReason = failureReason
    }

    var id: String { command.id }

    var keyEquivalent: String {
        binding.displayValue
    }

    var localizedStatus: String {
        guard !runtimeDisabled else {
            return L10n.string("settings.shortcutFeatureDisabled")
        }
        guard binding.enabled else {
            return L10n.string("settings.shortcutDisabled")
        }
        if registered {
            return L10n.string("settings.shortcutRegistered")
        }
        if failureReason == .missingReference || failureReason == .unregistrationFailed || failureReason == .invalidBinding {
            return L10n.string("settings.shortcutReregisterFailedTitle")
        }
        return L10n.format("settings.shortcutConflict", String(osStatus))
    }
}

final class ShortcutController {
#if DEBUG
    typealias FixtureHotKeyRegistrar = (
        UInt32,
        UInt32,
        EventHotKeyID,
        OptionBits
    ) -> (status: OSStatus, hasReference: Bool)

    typealias FixtureHotKeyUnregistrar = (EventHotKeyID) -> OSStatus

    struct SystemRegistrationCallCounts: Equatable {
        fileprivate(set) var eventTargetLookups = 0
        fileprivate(set) var handlerInstallations = 0
        fileprivate(set) var registrations = 0
        fileprivate(set) var unregistrations = 0

        static let zero = SystemRegistrationCallCounts()
    }
#endif

    private enum RegistrationBackend {
        case system
#if DEBUG
        case fixture(
            registrar: FixtureHotKeyRegistrar,
            unregistrar: FixtureHotKeyUnregistrar,
            handlerInstallStatus: OSStatus
        )
#endif
    }

    private enum RegisteredHotKey {
        case system(EventHotKeyRef)
#if DEBUG
        case fixture(EventHotKeyID)
#endif
    }

    private struct UnregistrationFailure {
        let command: ShortcutCommand
        let status: OSStatus
    }

    private struct OrphanedRegistration {
        let command: ShortcutCommand
        // This closure owns only the Carbon reference or fixture unregistrar.
        // It must never retain the controller that created the registration.
        let unregister: () -> OSStatus
    }

    private final class CarbonCallbackRouter {
        private struct RouteKey: Hashable {
            let signature: OSType
            let id: UInt32
        }

        private final class Route {
            weak var controller: ShortcutController?
            let controllerIdentifier: ObjectIdentifier
            let registrationEpoch: UInt64
            let hotKeyID: UInt32

            init(
                controller: ShortcutController,
                registrationEpoch: UInt64,
                hotKeyID: UInt32
            ) {
                self.controller = controller
                controllerIdentifier = ObjectIdentifier(controller)
                self.registrationEpoch = registrationEpoch
                self.hotKeyID = hotKeyID
            }
        }

        private let lock = NSLock()
        private var eventHandler: EventHandlerRef?
        private var nextRouteToken: UInt64 = 1
        private var routes: [RouteKey: Route] = [:]

        func installHandlerIfNeeded(on eventTarget: EventTargetRef) -> OSStatus {
            lock.lock()
            defer { lock.unlock() }

            guard eventHandler == nil else {
                return noErr
            }

            var eventTypes = [
                EventTypeSpec(
                    eventClass: OSType(kEventClassKeyboard),
                    eventKind: UInt32(kEventHotKeyPressed)
                ),
                EventTypeSpec(
                    eventClass: OSType(kEventClassKeyboard),
                    eventKind: UInt32(kEventHotKeyReleased)
                )
            ]
            var installedHandler: EventHandlerRef?
            let status = eventTypes.withUnsafeMutableBufferPointer { buffer in
                InstallEventHandler(
                    eventTarget,
                    { _, event, userData in
                        guard let userData else {
                            return noErr
                        }
                        let router = Unmanaged<CarbonCallbackRouter>
                            .fromOpaque(userData)
                            .takeUnretainedValue()
                        return router.route(event: event)
                    },
                    buffer.count,
                    buffer.baseAddress,
                    Unmanaged.passUnretained(self).toOpaque(),
                    &installedHandler
                )
            }
            if status == noErr {
                eventHandler = installedHandler
            }
            return status
        }

        func reserveRoute(
            signature: OSType,
            controller: ShortcutController,
            registrationEpoch: UInt64,
            hotKeyID: UInt32
        ) -> UInt32? {
            lock.lock()
            defer { lock.unlock() }

            guard nextRouteToken <= UInt64(UInt32.max) else {
                return nil
            }
            let routeToken = UInt32(nextRouteToken)
            nextRouteToken += 1
            routes[RouteKey(signature: signature, id: routeToken)] = Route(
                controller: controller,
                registrationEpoch: registrationEpoch,
                hotKeyID: hotKeyID
            )
            return routeToken
        }

        func removeRoutes(for controller: ShortcutController) {
            let controllerIdentifier = ObjectIdentifier(controller)
            lock.lock()
            routes = routes.filter { $0.value.controllerIdentifier != controllerIdentifier }
            lock.unlock()
        }

        func removeRoute(signature: OSType, id: UInt32, for controller: ShortcutController) {
            let key = RouteKey(signature: signature, id: id)
            let controllerIdentifier = ObjectIdentifier(controller)
            lock.lock()
            if routes[key]?.controllerIdentifier == controllerIdentifier {
                routes.removeValue(forKey: key)
            }
            lock.unlock()
        }

        private func route(event: EventRef?) -> OSStatus {
            guard let event else {
                return OSStatus(eventNotHandledErr)
            }
            var carbonHotKeyID = EventHotKeyID()
            let status = GetEventParameter(
                event,
                EventParamName(kEventParamDirectObject),
                EventParamType(typeEventHotKeyID),
                nil,
                MemoryLayout<EventHotKeyID>.size,
                nil,
                &carbonHotKeyID
            )
            guard status == noErr else {
                return status
            }

            let key = RouteKey(signature: carbonHotKeyID.signature, id: carbonHotKeyID.id)
            lock.lock()
            let route = routes[key]
            lock.unlock()
            guard let route, let controller = route.controller else {
                return OSStatus(eventNotHandledErr)
            }
            dispatch(
                route: route,
                eventKind: GetEventKind(event),
                controller: controller
            )
            return noErr
        }

        private func dispatch(
            route: Route,
            eventKind: UInt32,
            controller: ShortcutController
        ) {
            let hotKeyID = route.hotKeyID
            let registrationEpoch = route.registrationEpoch
            DispatchQueue.main.async { [weak controller] in
                switch eventKind {
                case UInt32(kEventHotKeyPressed):
                    controller?.invokePressed(
                        hotKeyID: hotKeyID,
                        registrationEpoch: registrationEpoch
                    )
                case UInt32(kEventHotKeyReleased):
                    controller?.markReleased(
                        hotKeyID: hotKeyID,
                        registrationEpoch: registrationEpoch
                    )
                default:
                    break
                }
            }
        }

#if DEBUG
        func activeRouteCount(for controller: ShortcutController) -> Int {
            let controllerIdentifier = ObjectIdentifier(controller)
            lock.lock()
            defer { lock.unlock() }
            return routes.values.count {
                $0.controllerIdentifier == controllerIdentifier
            }
        }

        func simulateEvent(signature: OSType, id: UInt32, eventKind: UInt32) {
            let key = RouteKey(signature: signature, id: id)
            lock.lock()
            let route = routes[key]
            lock.unlock()
            guard let route, let controller = route.controller else {
                return
            }
            dispatch(route: route, eventKind: eventKind, controller: controller)
        }

        func handlesRouteForFixtures(signature: OSType, id: UInt32) -> Bool {
            let key = RouteKey(signature: signature, id: id)
            lock.lock()
            defer { lock.unlock() }
            return routes[key]?.controller != nil
        }
#endif
    }

    private static let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "com.blocks.app",
        category: "global-shortcut"
    )
    private static let carbonRouter = CarbonCallbackRouter()
    private static let signature: OSType = 0x4A44544C
    // This lock is never acquired while holding the Carbon router lock.
    private static let orphanedRegistrationLock = NSLock()
    private static var orphanedRegistrations: [OrphanedRegistration] = []
    private let duplicateShortcutStatus: OSStatus = -9878
    private let applicationNotReadyStatus: OSStatus = -9879
    private let routeTokenExhaustedStatus: OSStatus = -108
    private let stalePressedHotKeyResetDelay: TimeInterval = 2.0
    private let registrationBackend: RegistrationBackend
    private var hotKeys: [ShortcutCommand: RegisteredHotKey] = [:]
    private var pendingUnregistrations: [ShortcutCommand: [RegisteredHotKey]] = [:]
    private var routeTokensByCommand: [ShortcutCommand: UInt32] = [:]
    private var actions: [UInt32: () -> Void] = [:]
    private var commandsByHotKeyID: [UInt32: ShortcutCommand] = [:]
    private var pressedHotKeyIDs: Set<UInt32> = []
    private var pressedHotKeyResetTasks: [UInt32: DispatchWorkItem] = [:]
    private var eventDeliveryObserver: ((ShortcutCommand, UInt64) -> Void)?
    private var registrationEpoch: UInt64 = 0
#if DEBUG
    private var systemRegistrationCallCounts = SystemRegistrationCallCounts.zero
#endif

    init() {
        registrationBackend = .system
    }

#if DEBUG
    static func fixture(
        registrar: @escaping FixtureHotKeyRegistrar = { _, _, _, _ in
            (status: noErr, hasReference: true)
        },
        unregistrar: @escaping FixtureHotKeyUnregistrar = { _ in noErr },
        handlerInstallStatus: OSStatus = noErr
    ) -> ShortcutController {
        ShortcutController(
            registrationBackend: .fixture(
                registrar: registrar,
                unregistrar: unregistrar,
                handlerInstallStatus: handlerInstallStatus
            )
        )
    }

    private init(registrationBackend: RegistrationBackend) {
        self.registrationBackend = registrationBackend
    }

    var systemRegistrationCallCountsForFixtures: SystemRegistrationCallCounts {
        systemRegistrationCallCounts
    }

    var usesSystemRegistrationForFixtures: Bool { usesSystemRegistration }
#endif

    var currentRegistrationEpoch: UInt64 { registrationEpoch }

    deinit {
        unregisterAll()
        movePendingUnregistrationsToOrphanRegistry()
    }

    func setEventDeliveryObserver(_ observer: @escaping (ShortcutCommand, UInt64) -> Void) {
        eventDeliveryObserver = observer
    }

#if DEBUG
    func simulateDeliveryForFixtures(_ command: ShortcutCommand) {
        let epoch = registrationEpoch
        DispatchQueue.main.async { [weak self] in
            self?.deliver(command: command, registrationEpoch: epoch)
        }
    }

    func simulateActionDeliveryForFixtures(_ command: ShortcutCommand) {
        let epoch = registrationEpoch
        DispatchQueue.main.async { [weak self] in
            self?.invokePressed(hotKeyID: command.hotKeyID, registrationEpoch: epoch)
        }
    }

    @discardableResult
    func replaceRoutesForFixtures(
        commands: [ShortcutCommand],
        actions: [ShortcutCommand: () -> Void]
    ) -> [ShortcutCommand: UInt32] {
        registrationEpoch &+= 1
        clearRouteAndActionState()
        self.actions = Dictionary(
            uniqueKeysWithValues: actions.map { ($0.key.hotKeyID, $0.value) }
        )
        commandsByHotKeyID = Dictionary(
            uniqueKeysWithValues: actions.map { ($0.key.hotKeyID, $0.key) }
        )

        for command in commands {
            guard let routeToken = Self.carbonRouter.reserveRoute(
                signature: Self.signature,
                controller: self,
                registrationEpoch: registrationEpoch,
                hotKeyID: command.hotKeyID
            ) else {
                break
            }
            routeTokensByCommand[command] = routeToken
        }
        return routeTokensByCommand
    }

    var activeRouteCountForFixtures: Int {
        Self.carbonRouter.activeRouteCount(for: self)
    }

    func routeTokenForFixtures(for command: ShortcutCommand) -> UInt32? {
        routeTokensByCommand[command]
    }

    func simulateRoutedEventForFixtures(routeToken: UInt32, pressed: Bool) {
        Self.carbonRouter.simulateEvent(
            signature: Self.signature,
            id: routeToken,
            eventKind: pressed ? UInt32(kEventHotKeyPressed) : UInt32(kEventHotKeyReleased)
        )
    }

    func handlesRoutedEventForFixtures(signature: OSType, routeToken: UInt32) -> Bool {
        Self.carbonRouter.handlesRouteForFixtures(
            signature: signature,
            id: routeToken
        )
    }

    static var routeSignatureForFixtures: OSType { signature }

    var pressedHotKeyIDsForFixtures: Set<UInt32> {
        pressedHotKeyIDs
    }

    var pendingUnregistrationCountForFixtures: Int {
        pendingUnregistrations.values.reduce(0) { $0 + $1.count }
    }

    static var orphanedUnregistrationCountForFixtures: Int {
        orphanedRegistrationLock.lock()
        defer { orphanedRegistrationLock.unlock() }
        return orphanedRegistrations.count
    }

    static func resetOrphanedUnregistrationsForFixtures() {
        orphanedRegistrationLock.lock()
        orphanedRegistrations.removeAll()
        orphanedRegistrationLock.unlock()
    }
#endif

    func registerDefaultShortcuts(
        actions: [ShortcutCommand: () -> Void],
        runtimeDisabledCommands: Set<ShortcutCommand> = []
    ) -> [ShortcutRegistrationResult] {
        registerConfiguredShortcuts(
            actions: actions,
            runtimeDisabledCommands: runtimeDisabledCommands
        )
    }

    func registerConfiguredShortcuts(
        actions: [ShortcutCommand: () -> Void],
        runtimeDisabledCommands: Set<ShortcutCommand> = []
    ) -> [ShortcutRegistrationResult] {
        let bindings = Dictionary(
            uniqueKeysWithValues: ShortcutCommand.allCases.map { command in
                (command, ShortcutBindingStore.effectiveBinding(for: command))
            }
        )
        return registerShortcuts(
            bindings: bindings,
            actions: actions,
            runtimeDisabledCommands: runtimeDisabledCommands
        )
    }

    func registerShortcuts(
        bindings: [ShortcutCommand: ShortcutBinding],
        actions: [ShortcutCommand: () -> Void],
        runtimeDisabledCommands: Set<ShortcutCommand> = []
    ) -> [ShortcutRegistrationResult] {
        // Always invalidate this controller's delivery generation and routes
        // before an unrelated orphan can block replacement registration.
        registrationEpoch &+= 1
        let localUnregistrationFailures = clearRegistrations()
        let orphanFailures = Self.retryOrphanedRegistrations()
        let unregistrationFailures = localUnregistrationFailures + orphanFailures
        guard unregistrationFailures.isEmpty else {
            return registrationRejectedResults(
                bindings: bindings,
                runtimeDisabledCommands: runtimeDisabledCommands,
                failures: unregistrationFailures
            )
        }

        self.actions = Dictionary(uniqueKeysWithValues: actions.map { ($0.key.hotKeyID, $0.value) })
        commandsByHotKeyID = Dictionary(uniqueKeysWithValues: actions.map { ($0.key.hotKeyID, $0.key) })
        return registerCleanShortcuts(
            bindings: bindings,
            runtimeDisabledCommands: runtimeDisabledCommands
        )
    }

    private func registrationRejectedResults(
        bindings: [ShortcutCommand: ShortcutBinding],
        runtimeDisabledCommands: Set<ShortcutCommand>,
        failures: [UnregistrationFailure]
    ) -> [ShortcutRegistrationResult] {
        let firstStatus = failures[0].status
        let statusByCommand = Dictionary(
            failures.map { ($0.command, $0.status) },
            uniquingKeysWith: { first, _ in first }
        )
        return ShortcutCommand.allCases.map { command in
            let binding = bindings[command] ?? ShortcutBindingStore.binding(for: command)
            let runtimeDisabled = runtimeDisabledCommands.contains(command)
            let shouldReportFailure = binding.enabled && !runtimeDisabled
            return ShortcutRegistrationResult(
                command: command,
                binding: binding,
                registered: false,
                osStatus: shouldReportFailure ? (statusByCommand[command] ?? firstStatus) : noErr,
                runtimeDisabled: runtimeDisabled,
                failureReason: shouldReportFailure ? .unregistrationFailed : nil
            )
        }
    }

    private static func retryOrphanedRegistrations() -> [UnregistrationFailure] {
        orphanedRegistrationLock.lock()
        defer { orphanedRegistrationLock.unlock() }

        orphanedRegistrations.sort { commandOrder($0.command) < commandOrder($1.command) }
        var remaining: [OrphanedRegistration] = []
        var failures: [UnregistrationFailure] = []
        for registration in orphanedRegistrations {
            let status = registration.unregister()
            if status != noErr {
                remaining.append(registration)
                failures.append(.init(command: registration.command, status: status))
            }
        }
        orphanedRegistrations = remaining
        return failures
    }

    private static func commandOrder(_ command: ShortcutCommand) -> Int {
        ShortcutCommand.allCases.firstIndex(of: command) ?? .max
    }

    private func movePendingUnregistrationsToOrphanRegistry() {
        let pending = pendingUnregistrations
        pendingUnregistrations.removeAll()
        guard !pending.isEmpty else { return }

        var orphaned: [OrphanedRegistration] = []
        for command in ShortcutCommand.allCases {
            for registeredHotKey in pending[command] ?? [] {
                orphaned.append(.init(
                    command: command,
                    unregister: orphanUnregistrationClosure(for: registeredHotKey)
                ))
            }
        }
        Self.orphanedRegistrationLock.lock()
        Self.orphanedRegistrations.append(contentsOf: orphaned)
        Self.orphanedRegistrations.sort { Self.commandOrder($0.command) < Self.commandOrder($1.command) }
        Self.orphanedRegistrationLock.unlock()
    }

    private func orphanUnregistrationClosure(
        for registeredHotKey: RegisteredHotKey
    ) -> () -> OSStatus {
        switch registeredHotKey {
        case let .system(ref):
            return { UnregisterEventHotKey(ref) }
#if DEBUG
        case let .fixture(hotKeyID):
            guard case let .fixture(_, unregistrar, _) = registrationBackend else {
                return { OSStatus(paramErr) }
            }
            return { unregistrar(hotKeyID) }
#endif
        }
    }

    private func registerCleanShortcuts(
        bindings: [ShortcutCommand: ShortcutBinding],
        runtimeDisabledCommands: Set<ShortcutCommand>
    ) -> [ShortcutRegistrationResult] {
        guard NSApp.isRunning else {
            Self.logger.error("stage=registration-rejected reason=application-not-running")
            return ShortcutCommand.allCases.map {
                ShortcutRegistrationResult(
                    command: $0,
                    binding: bindings[$0] ?? ShortcutBindingStore.binding(for: $0),
                    registered: false,
                    osStatus: applicationNotReadyStatus,
                    runtimeDisabled: runtimeDisabledCommands.contains($0)
                )
            }
        }

        var hotKeyEventTarget: EventTargetRef?
        let handlerStatus: OSStatus
        switch registrationBackend {
        case .system:
#if DEBUG
            systemRegistrationCallCounts.eventTargetLookups += 1
#endif
            guard let target = GetApplicationEventTarget() else {
                Self.logger.error("stage=registration-rejected reason=application-event-target-unavailable")
                return ShortcutCommand.allCases.map {
                    ShortcutRegistrationResult(
                        command: $0,
                        binding: bindings[$0] ?? ShortcutBindingStore.binding(for: $0),
                        registered: false,
                        osStatus: applicationNotReadyStatus,
                        runtimeDisabled: runtimeDisabledCommands.contains($0)
                    )
                }
            }
            hotKeyEventTarget = target
#if DEBUG
            systemRegistrationCallCounts.handlerInstallations += 1
#endif
            handlerStatus = Self.carbonRouter.installHandlerIfNeeded(on: target)
            Self.logger.info("stage=handler-install status=\(handlerStatus, privacy: .public)")
#if DEBUG
        case let .fixture(_, _, handlerInstallStatus):
            handlerStatus = handlerInstallStatus
#endif
        }

        guard handlerStatus == noErr else {
            return ShortcutCommand.allCases.map {
                ShortcutRegistrationResult(
                    command: $0,
                    binding: bindings[$0] ?? ShortcutBindingStore.binding(for: $0),
                    registered: false,
                    osStatus: handlerStatus,
                    runtimeDisabled: runtimeDisabledCommands.contains($0)
                )
            }
        }

        var seenShortcuts: Set<String> = []
        return ShortcutCommand.allCases.map { command in
            var binding = bindings[command] ?? ShortcutBindingStore.binding(for: command)
            guard !runtimeDisabledCommands.contains(command) else {
                return ShortcutRegistrationResult(
                    command: command,
                    binding: binding,
                    registered: false,
                    osStatus: noErr,
                    runtimeDisabled: true
                )
            }
            guard binding.enabled else {
                return ShortcutRegistrationResult(command: command, binding: binding, registered: false, osStatus: noErr)
            }
            guard binding.command == command, let normalizedBinding = binding.normalizedForRegistration() else {
                return ShortcutRegistrationResult(
                    command: command,
                    binding: binding,
                    registered: false,
                    osStatus: OSStatus(paramErr),
                    failureReason: .invalidBinding
                )
            }
            binding = normalizedBinding
            let shortcutSignature = "\(binding.keyCode)-\(binding.carbonModifiers)"
            guard seenShortcuts.insert(shortcutSignature).inserted else {
                return ShortcutRegistrationResult(command: command, binding: binding, registered: false, osStatus: duplicateShortcutStatus)
            }

            guard let routeToken = Self.carbonRouter.reserveRoute(
                signature: Self.signature,
                controller: self,
                registrationEpoch: registrationEpoch,
                hotKeyID: command.hotKeyID
            ) else {
                Self.logger.error(
                    "stage=hotkey-register command=\(command.rawValue, privacy: .public) reason=route-token-exhausted"
                )
                return ShortcutRegistrationResult(
                    command: command,
                    binding: binding,
                    registered: false,
                    osStatus: routeTokenExhaustedStatus
                )
            }

            let hotKeyID = EventHotKeyID(signature: Self.signature, id: routeToken)
            let status: OSStatus
            let hasReference: Bool
            let registeredHotKey: RegisteredHotKey?
            switch registrationBackend {
            case .system:
                guard let hotKeyEventTarget else {
                    Self.carbonRouter.removeRoute(
                        signature: Self.signature,
                        id: routeToken,
                        for: self
                    )
                    return ShortcutRegistrationResult(
                        command: command,
                        binding: binding,
                        registered: false,
                        osStatus: applicationNotReadyStatus
                    )
                }
                var ref: EventHotKeyRef?
#if DEBUG
                systemRegistrationCallCounts.registrations += 1
#endif
                status = RegisterEventHotKey(
                    binding.keyCode,
                    binding.carbonModifiers,
                    hotKeyID,
                    hotKeyEventTarget,
                    0,
                    &ref
                )
                hasReference = ref != nil
                registeredHotKey = ref.map(RegisteredHotKey.system)
#if DEBUG
            case let .fixture(registrar, _, _):
                let outcome = registrar(
                    binding.keyCode,
                    binding.carbonModifiers,
                    hotKeyID,
                    0
                )
                status = outcome.status
                hasReference = outcome.hasReference
                registeredHotKey = outcome.hasReference ? .fixture(hotKeyID) : nil
#endif
            }
            let registered = status == noErr && registeredHotKey != nil
            let failureReason: ShortcutRegistrationFailureReason? = status == noErr && !hasReference
                ? .missingReference
                : nil
            if let registeredHotKey, registered {
                hotKeys[command] = registeredHotKey
                routeTokensByCommand[command] = routeToken
            } else {
                Self.carbonRouter.removeRoute(
                    signature: Self.signature,
                    id: routeToken,
                    for: self
                )
            }
            if usesSystemRegistration {
                Self.logger.info(
                    "stage=hotkey-register command=\(command.rawValue, privacy: .public) binding=\(binding.displayValue, privacy: .public) status=\(status, privacy: .public) hasReference=\(hasReference, privacy: .public)"
                )
            }
            return ShortcutRegistrationResult(
                command: command,
                binding: binding,
                registered: registered,
                osStatus: status,
                failureReason: failureReason
            )
        }
    }

    func unregisterAll() {
        registrationEpoch &+= 1
        _ = clearRegistrations()
    }

    private func clearRegistrations() -> [UnregistrationFailure] {
        let pending = pendingUnregistrations
        let active = hotKeys
        pendingUnregistrations.removeAll()
        hotKeys.removeAll()
        clearRouteAndActionState()

        var failures: [UnregistrationFailure] = []
        func unregister(_ registeredHotKey: RegisteredHotKey) -> OSStatus {
            switch registeredHotKey {
            case let .system(ref):
#if DEBUG
                systemRegistrationCallCounts.unregistrations += 1
#endif
                return UnregisterEventHotKey(ref)
#if DEBUG
            case let .fixture(hotKeyID):
                guard case let .fixture(_, unregistrar, _) = registrationBackend else {
                    return OSStatus(paramErr)
                }
                return unregistrar(hotKeyID)
#endif
            }
        }

        for command in ShortcutCommand.allCases {
            let registeredHotKeys = (pending[command] ?? []) + (active[command].map { [$0] } ?? [])
            for registeredHotKey in registeredHotKeys {
                let status = unregister(registeredHotKey)
                if status != noErr {
                    pendingUnregistrations[command, default: []].append(registeredHotKey)
                    failures.append(.init(command: command, status: status))
                }
                if usesSystemRegistration {
                    Self.logger.info(
                        "stage=hotkey-unregister command=\(command.rawValue, privacy: .public) status=\(status, privacy: .public)"
                    )
                }
            }
        }
        return failures
    }

    private var usesSystemRegistration: Bool {
        switch registrationBackend {
        case .system:
            return true
#if DEBUG
        case .fixture:
            return false
#endif
        }
    }

    private func clearRouteAndActionState() {
        Self.carbonRouter.removeRoutes(for: self)
        routeTokensByCommand.removeAll()
        actions.removeAll()
        commandsByHotKeyID.removeAll()
        pressedHotKeyResetTasks.values.forEach { $0.cancel() }
        pressedHotKeyResetTasks.removeAll()
        pressedHotKeyIDs.removeAll()
    }

    private func invokePressed(hotKeyID: UInt32, registrationEpoch: UInt64) {
        guard registrationEpoch == self.registrationEpoch else {
            return
        }
        guard pressedHotKeyIDs.insert(hotKeyID).inserted else {
            return
        }
        guard let action = actions[hotKeyID] else {
            Self.logger.error("stage=event-received hotKeyID=\(hotKeyID, privacy: .public) reason=action-missing")
            markReleased(hotKeyID: hotKeyID, registrationEpoch: registrationEpoch)
            return
        }
        if let command = commandsByHotKeyID[hotKeyID] {
            Self.logger.info("stage=event-delivered command=\(command.rawValue, privacy: .public)")
            eventDeliveryObserver?(command, registrationEpoch)
        } else {
            Self.logger.error("stage=event-received hotKeyID=\(hotKeyID, privacy: .public) reason=command-missing")
        }
        scheduleStalePressedHotKeyReset(hotKeyID: hotKeyID)
        action()
    }

    private func deliver(command: ShortcutCommand, registrationEpoch: UInt64) {
        guard registrationEpoch == self.registrationEpoch else {
            return
        }
        eventDeliveryObserver?(command, registrationEpoch)
    }

    private func markReleased(hotKeyID: UInt32, registrationEpoch: UInt64? = nil) {
        if let registrationEpoch, registrationEpoch != self.registrationEpoch {
            return
        }
        pressedHotKeyResetTasks.removeValue(forKey: hotKeyID)?.cancel()
        pressedHotKeyIDs.remove(hotKeyID)
    }

    private func scheduleStalePressedHotKeyReset(hotKeyID: UInt32) {
        pressedHotKeyResetTasks.removeValue(forKey: hotKeyID)?.cancel()
        let resetTask = DispatchWorkItem { [weak self] in
            self?.markReleased(hotKeyID: hotKeyID)
        }
        pressedHotKeyResetTasks[hotKeyID] = resetTask
        DispatchQueue.main.asyncAfter(deadline: .now() + stalePressedHotKeyResetDelay, execute: resetTask)
    }
}
