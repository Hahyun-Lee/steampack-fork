import WidgetKit
import AppIntents
import SwiftUI

enum SteamPackControlConfirmation {
    static let pollNanoseconds: UInt64 = 25_000_000

    static func wait(for request: SteamPackControlRequest) async throws {
        try await withTaskCancellationHandler {
            let deadline = request.expiresAt
                ?? Date().addingTimeInterval(SteamPackShared.controlRequestLifetime)
            while Date() < deadline {
                try Task.checkCancellation()
                switch SteamPackShared.appliedStatus(for: request) {
                case .applied, .superseded:
                    try Task.checkCancellation()
                    return
                case .rejected:
                    throw SteamPackControlError.requestRejected
                case .pending:
                    try await Task<Never, Never>.sleep(nanoseconds: pollNanoseconds)
                }
            }
            try Task.checkCancellation()
            // Close the race at the deadline before cancelling. If the app applied
            // the exact request just before expiry, report that result. Otherwise a
            // compare-and-swap rollback prevents a timed-out request from taking
            // effect later after the system has already shown an error.
            switch SteamPackShared.appliedStatus(for: request) {
            case .applied, .superseded:
                try Task.checkCancellation()
                return
            case .rejected:
                throw SteamPackControlError.requestRejected
            case .pending:
                _ = SteamPackShared.cancelTimedOutControlRequest(request)
            }
            throw SteamPackControlError.responseTimedOut
        } onCancel: {
            // The system may cancel an intent when its surface disappears. Treat
            // that exactly like a timeout so the abandoned target cannot apply
            // later after the user has moved on.
            _ = SteamPackShared.cancelTimedOutControlRequest(request)
        }
    }
}

// MARK: - Keep Awake (caffeinate) 토글

struct SetKeepAwakeIntent: SetValueIntent {
    static let title: LocalizedStringResource = "Keep Awake"
    @Parameter(title: "Keep Awake") var value: Bool
    init() {}
    func perform() async throws -> some IntentResult {
        guard let request = SteamPackShared.requestKeepAwakeRecord(value) else {
            throw SteamPackControlError.appNotRunning
        }
        try await SteamPackControlConfirmation.wait(for: request)
        return .result()
    }
}

struct KeepAwakeProvider: ControlValueProvider {
    var previewValue: Bool { false }
    func currentValue() async throws -> Bool {
        guard let state = SteamPackShared.readAppliedState() else {
            throw SteamPackControlError.stateUnavailable
        }
        return state.keepAwake
    }
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
                Label(SteamPackL10n.text(on ? "Awake" : "Sleep OK"),
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
    static let title: LocalizedStringResource = "Closed Lid"
    @Parameter(title: "Closed Lid") var value: Bool
    init() {}
    func perform() async throws -> some IntentResult {
        guard let request = SteamPackShared.requestClamshellRecord(value) else {
            throw SteamPackControlError.appNotRunning
        }
        try await SteamPackControlConfirmation.wait(for: request)
        return .result()
    }
}

struct ClamshellProvider: ControlValueProvider {
    var previewValue: Bool { false }
    func currentValue() async throws -> Bool {
        guard let state = SteamPackShared.readAppliedState() else {
            throw SteamPackControlError.stateUnavailable
        }
        return state.clamshell
    }
}

struct ClamshellControl: ControlWidget {
    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(
            kind: SteamPackShared.clamshellKind,
            provider: ClamshellProvider()
        ) { isOn in
            ControlWidgetToggle(
                "Closed Lid",
                isOn: isOn,
                action: SetClamshellIntent()
            ) { on in
                Label(SteamPackL10n.text(on ? "Closed Lid On" : "Closed Lid Off"),
                      systemImage: on ? "laptopcomputer" : "laptopcomputer.slash")
            }
            .tint(.orange)
        }
        .displayName("SteamPack Closed Lid")
        .description("Keep working after you close the lid, even on battery.")
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
