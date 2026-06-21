import Foundation

/// 메인 앱(비-샌드박스)과 Control Widget 익스텐션(샌드박스) 사이의 공유 상태/IPC.
///
/// - 상태 공유: **익스텐션 샌드박스 컨테이너 내 파일**(`keepAwake.state`).
///   App Group 컨테이너는 무료 개인팀 개발서명에서 실제로 공유되지 않는 것으로 확인됨
///   (앱이 쓴 값을 익스텐션이 못 읽음). 대신:
///     · 익스텐션(샌드박스): 자기 컨테이너(NSHomeDirectory)에서 읽음 — 항상 가능.
///     · 앱(비샌드박스): 같은 절대 경로(익스텐션 컨테이너 Data)에 직접 씀 — 검증됨.
///   둘이 동일한 실제 파일을 가리킨다.
/// - 명령 전달: Darwin notification(페이로드 없음, 샌드박스 경계 통과).
///   컨트롤 탭 → toggleRequest 노티 → 앱이 현재 상태 flip + 상태 파일 갱신 + reloadControls.
enum SteamPackShared {
    /// Control Widget 익스텐션 번들 ID — 공유 파일이 사는 컨테이너.
    static let controlBundleID = "com.steampack.app.control"

    /// Control Widget의 kind — 메인 앱의 reloadControls(ofKind:)와 일치해야 함.
    static let controlKind = "com.steampack.app.keepawake"

    /// 컨트롤 → 앱: "토글 요청" 신호.
    static let toggleRequestName = "com.steampack.toggleRequested" as CFString

    /// 공유 상태 파일 ("1" = 깨어 있음/sleep 억제, "0" = 보통).
    /// 익스텐션이면 NSHomeDirectory가 이미 자기 컨테이너 Data → 그대로 사용.
    /// 앱이면 익스텐션 컨테이너 Data 절대경로를 구성 (비샌드박스라 접근 자유).
    private static var stateFileURL: URL {
        let home = NSHomeDirectory()
        let dir: URL
        if home.contains("/Containers/\(controlBundleID)/") {
            dir = URL(fileURLWithPath: home)            // 익스텐션 컨텍스트
        } else {
            dir = URL(fileURLWithPath: home)            // 앱 컨텍스트
                .appendingPathComponent("Library/Containers/\(controlBundleID)/Data")
        }
        return dir.appendingPathComponent("keepAwake.state")
    }

    static func readKeepAwake() -> Bool {
        guard let s = try? String(contentsOf: stateFileURL, encoding: .utf8) else { return false }
        return s.trimmingCharacters(in: .whitespacesAndNewlines) == "1"
    }

    static func writeKeepAwake(_ on: Bool) {
        let url = stateFileURL
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? (on ? "1" : "0").write(to: url, atomically: true, encoding: .utf8)
    }

    /// 컨트롤에서 호출 — 메인 앱에 토글을 요청.
    static func postToggleRequest() {
        CFNotificationCenterPostNotification(
            CFNotificationCenterGetDarwinNotifyCenter(),
            CFNotificationName(toggleRequestName),
            nil, nil, true)
    }
}
