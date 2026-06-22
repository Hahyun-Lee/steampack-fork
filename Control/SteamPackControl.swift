import WidgetKit
import AppIntents
import SwiftUI

// MARK: - Keep Awake (caffeinate) 토글

struct SetKeepAwakeIntent: SetValueIntent {
    static let title: LocalizedStringResource = "Keep Awake"
    @Parameter(title: "Keep Awake") var value: Bool
    init() {}
    func perform() async throws -> some IntentResult {
        SteamPackShared.writeKeepAwake(value)
        SteamPackShared.postKeepAwakeRequest()
        return .result()
    }
}

struct KeepAwakeProvider: ControlValueProvider {
    var previewValue: Bool { false }
    func currentValue() async throws -> Bool { SteamPackShared.readKeepAwake() }
}

struct KeepAwakeControl: ControlWidget {
    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(
            kind: SteamPackShared.keepAwakeKind,
            provider: KeepAwakeProvider()
        ) { isOn in
            ControlWidgetToggle(
                "Keep Awake",
                isOn: isOn,
                action: SetKeepAwakeIntent()
            ) { on in
                Label(on ? "Awake" : "Sleep OK",
                      systemImage: on ? "eye.fill" : "eye.half.closed.fill")
            }
            .tint(.indigo)
        }
        .displayName("SteamPack Keep Awake")
        .description("Prevent sleep (display lid open).")
    }
}

// MARK: - Clamshell (pmset disablesleep) 토글

struct SetClamshellIntent: SetValueIntent {
    static let title: LocalizedStringResource = "Clamshell Mode"
    @Parameter(title: "Clamshell Mode") var value: Bool
    init() {}
    func perform() async throws -> some IntentResult {
        SteamPackShared.writeClamshell(value)
        SteamPackShared.postClamshellRequest()
        return .result()
    }
}

struct ClamshellProvider: ControlValueProvider {
    var previewValue: Bool { false }
    func currentValue() async throws -> Bool { SteamPackShared.readClamshell() }
}

struct ClamshellControl: ControlWidget {
    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(
            kind: SteamPackShared.clamshellKind,
            provider: ClamshellProvider()
        ) { isOn in
            ControlWidgetToggle(
                "Clamshell",
                isOn: isOn,
                action: SetClamshellIntent()
            ) { on in
                Label(on ? "Clamshell On" : "Clamshell Off",
                      systemImage: on ? "laptopcomputer" : "laptopcomputer.slash")
            }
            .tint(.orange)
        }
        .displayName("SteamPack Clamshell")
        .description("Keep awake with lid closed (battery too).")
    }
}

// MARK: - Bundle

@main
struct SteamPackControlBundle: WidgetBundle {
    var body: some Widget {
        KeepAwakeControl()
        ClamshellControl()
    }
}
