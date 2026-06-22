import Foundation

/// 메인 앱(비-샌드박스)과 Control Widget 익스텐션(샌드박스) 공유 상태/IPC.
///
/// - 컨트롤 2개(각각 이진 토글): Keep Awake(caffeinate) / Clamshell(pmset disablesleep).
///   토글은 이진이라 optimistic=실제와 일치 → 탭 시 아이콘이 정확히 따라옴.
/// - 상태 공유: 익스텐션 샌드박스 컨테이너 내 파일(App Group은 무료 개인팀에서 미공유 확인).
///   익스텐션=자기 컨테이너 읽기 / 앱=같은 절대경로 쓰기 (검증됨).
/// - 명령 전달: Darwin notification → 앱이 두 상태 파일을 읽어 caffeinate/pmset 적용.
enum SteamPackShared {
    static let controlBundleID = "com.steampack.app.control"

    /// 두 컨트롤의 kind (reloadControls·StaticControlConfiguration 일치).
    static let keepAwakeKind = "com.steampack.app.keepawake"
    static let clamshellKind = "com.steampack.app.clamshell"

    /// 컨트롤 → 앱: 어느 토글이 눌렸는지 구분 (계층 로직 적용 위해).
    static let keepAwakeRequestName = "com.steampack.keepAwakeRequested" as CFString
    static let clamshellRequestName = "com.steampack.clamshellRequested" as CFString

    /// 익스텐션 컨테이너 Data 내 상태 파일 경로 (앱·익스텐션 동일 실파일).
    private static func stateFileURL(_ name: String) -> URL {
        let home = NSHomeDirectory()
        let dir: URL
        if home.contains("/Containers/\(controlBundleID)/") {
            dir = URL(fileURLWithPath: home)                       // 익스텐션
        } else {
            dir = URL(fileURLWithPath: home)                       // 앱
                .appendingPathComponent("Library/Containers/\(controlBundleID)/Data")
        }
        return dir.appendingPathComponent(name)
    }

    private static func readBool(_ name: String) -> Bool {
        guard let s = try? String(contentsOf: stateFileURL(name), encoding: .utf8) else { return false }
        return s.trimmingCharacters(in: .whitespacesAndNewlines) == "1"
    }

    private static func writeBool(_ name: String, _ on: Bool) {
        let url = stateFileURL(name)
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? (on ? "1" : "0").write(to: url, atomically: true, encoding: .utf8)
    }

    // Keep Awake (caffeinate)
    static func readKeepAwake() -> Bool { readBool("keepAwake.state") }
    static func writeKeepAwake(_ on: Bool) { writeBool("keepAwake.state", on) }

    // Clamshell (pmset disablesleep)
    static func readClamshell() -> Bool { readBool("clamshell.state") }
    static func writeClamshell(_ on: Bool) { writeBool("clamshell.state", on) }

    /// 컨트롤에서 호출 — 어느 토글인지 알림.
    static func postKeepAwakeRequest() { post(keepAwakeRequestName) }
    static func postClamshellRequest() { post(clamshellRequestName) }
    private static func post(_ name: CFString) {
        CFNotificationCenterPostNotification(
            CFNotificationCenterGetDarwinNotifyCenter(),
            CFNotificationName(name), nil, nil, true)
    }
}
