import Foundation
import IOKit.ps
import UserNotifications

struct PowerSafetySnapshot: Equatable {
    let batteryPercent: Int?
    let isOnACPower: Bool
    let thermalState: ProcessInfo.ThermalState
}

enum PowerSafetyIssue: Equatable, CustomStringConvertible {
    case lowBattery(percent: Int)
    case highTemperature

    var description: String {
        switch self {
        case .lowBattery(let percent):
            return "Battery is at \(percent)%"
        case .highTemperature:
            return "Mac temperature is too high"
        }
    }
}

enum PowerSafetyPolicy {
    static let minimumBatteryPercent = 20

    static func issue(for snapshot: PowerSafetySnapshot) -> PowerSafetyIssue? {
        switch snapshot.thermalState {
        case .serious, .critical:
            return .highTemperature
        case .nominal, .fair:
            break
        @unknown default:
            return .highTemperature
        }

        if !snapshot.isOnACPower,
           let batteryPercent = snapshot.batteryPercent,
           batteryPercent <= minimumBatteryPercent {
            return .lowBattery(percent: batteryPercent)
        }
        return nil
    }
}

final class PowerSafetyMonitor {
    private(set) var snapshot = PowerSafetyMonitor.readSnapshot()
    private var timer: Timer?
    private var observers: [NSObjectProtocol] = []

    var onUpdate: ((PowerSafetySnapshot) -> Void)?
    var onUnsafe: ((PowerSafetyIssue) -> Void)?

    func start() {
        guard timer == nil else { return }

        let center = NotificationCenter.default
        observers.append(center.addObserver(
            forName: ProcessInfo.thermalStateDidChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.refresh()
        })
        observers.append(center.addObserver(
            forName: Notification.Name.NSProcessInfoPowerStateDidChange,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.refresh()
        })

        timer = Timer.scheduledTimer(withTimeInterval: 15, repeats: true) { [weak self] _ in
            self?.refresh()
        }
        refresh()
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        let center = NotificationCenter.default
        observers.forEach(center.removeObserver)
        observers.removeAll()
    }

    func refresh() {
        snapshot = Self.readSnapshot()
        onUpdate?(snapshot)
        if let issue = PowerSafetyPolicy.issue(for: snapshot) {
            onUnsafe?(issue)
        }
    }

    static func readSnapshot() -> PowerSafetySnapshot {
        var batteryPercent: Int?
        var isOnACPower = true

        if let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
           let sourceList = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef] {
            for source in sourceList {
                guard let description = IOPSGetPowerSourceDescription(info, source)?.takeUnretainedValue()
                        as? [String: Any] else { continue }

                let type = description[kIOPSTypeKey as String] as? String
                guard type == (kIOPSInternalBatteryType as String) else { continue }

                let current = description[kIOPSCurrentCapacityKey as String] as? Int
                let maximum = description[kIOPSMaxCapacityKey as String] as? Int
                if let current, let maximum, maximum > 0 {
                    batteryPercent = Int((Double(current) / Double(maximum) * 100).rounded())
                }

                let state = description[kIOPSPowerSourceStateKey as String] as? String
                isOnACPower = state == (kIOPSACPowerValue as String)
                break
            }
        }

        return PowerSafetySnapshot(
            batteryPercent: batteryPercent,
            isOnACPower: isOnACPower,
            thermalState: ProcessInfo.processInfo.thermalState
        )
    }

    deinit {
        stop()
    }
}

enum PowerSafetyNotifier {
    static func prepare() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    static func notifyAutomaticDisarm(_ issue: PowerSafetyIssue) {
        notify(
            title: "SteamPack restored normal sleep",
            body: "Clamshell Mode was turned off for safety. \(issue.description)."
        )
    }

    static func notifyWatchdogFailure() {
        notify(
            title: "SteamPack watchdog stopped",
            body: "Normal lid-close sleep was restored because crash recovery was no longer available."
        )
    }

    static func notifyControlFailure(_ message: String) {
        notify(title: "SteamPack could not apply the control", body: message)
    }

    private static func notify(title: String, body: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        let request = UNNotificationRequest(
            identifier: "steampack-\(UUID().uuidString)",
            content: content,
            trigger: nil
        )
        UNUserNotificationCenter.current().add(request)
    }
}
