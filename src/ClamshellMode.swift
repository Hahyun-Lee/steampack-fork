import Foundation

/// 배터리 상태에서도 클램쉘(뚜껑 닫기) sleep을 차단하는 커널 레벨 모드.
/// `sudo pmset disablesleep 1` 래퍼 — sudoers NOPASSWD 등록 필요 (scripts/install-sudoers.sh).
/// caffeinate -s는 AC 전원에서만 유효하므로, 배터리 이동 시엔 이 모드가 유일한 수단.
class ClamshellMode {
    private(set) var isOn: Bool = false

    init() { refresh() }

    func refresh() {
        isOn = currentStatus()
    }

    func currentStatus() -> Bool {
        // pmset -g 출력에 "SleepDisabled 1" 존재 여부로 판정
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/pmset")
        p.arguments = ["-g"]
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = FileHandle.nullDevice
        do { try p.run(); p.waitUntilExit() } catch { return false }
        let out = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        return out.range(of: #"SleepDisabled\s+1"#, options: .regularExpression) != nil
    }

    enum ToggleResult {
        case success
        case failed(String)
    }

    func toggle() -> ToggleResult {
        return set(!isOn)
    }

    @discardableResult
    func set(_ on: Bool) -> ToggleResult {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/sudo")
        // -n: 비밀번호 프롬프트 금지 — sudoers 미등록이면 즉시 실패시켜 안내 alert로 유도
        p.arguments = ["-n", "/usr/bin/pmset", "disablesleep", on ? "1" : "0"]
        let errPipe = Pipe()
        p.standardError = errPipe
        p.standardOutput = FileHandle.nullDevice
        do {
            try p.run()
            p.waitUntilExit()
        } catch {
            return .failed(error.localizedDescription)
        }
        if p.terminationStatus != 0 {
            let err = String(data: errPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            return .failed(err.isEmpty ? "sudo 권한 없음 (sudoers 미등록)" : err)
        }
        isOn = on
        return .success
    }
}
