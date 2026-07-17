import Foundation

struct SleepToggleSessionIdentity: Equatable {
    let token: String
    let processID: Int32
    let processObjectID: ObjectIdentifier
}

struct SleepToggleSessionState {
    private(set) var activeSession: SleepToggleSessionIdentity?

    mutating func activate(_ session: SleepToggleSessionIdentity) {
        activeSession = session
    }

    func matches(_ session: SleepToggleSessionIdentity) -> Bool {
        activeSession == session
    }

    @discardableResult
    mutating func consumeTermination(
        _ session: SleepToggleSessionIdentity
    ) -> Bool {
        guard matches(session) else { return false }
        activeSession = nil
        return true
    }

    @discardableResult
    mutating func clearIfMatching(_ session: SleepToggleSessionIdentity) -> Bool {
        consumeTermination(session)
    }
}

class SleepToggle {
    private(set) var isDisableSleep: Bool = false
    var onStateChange: (() -> Void)?
    private var sessionState = SleepToggleSessionState()
    // Process 인스턴스를 보관해야 terminationHandler/자식 추적이 보장됨
    // (로컬 변수면 스코프 이탈 시 콜백 신뢰성이 깨짐)
    private var caffeinateProcess: Process?

    init() { refresh() }

    func refresh() {
        isDisableSleep = currentStatus()
    }

    func currentStatus() -> Bool {
        // Retain and query the exact child Process object. A bare kill(pid, 0)
        // check can mistake a reused PID for this enable cycle.
        // (기존 pmset assertion regex는 powerd의 "Prevent sleep while display is on"에
        //  항상 매칭되어 false positive → caffeinate가 영영 시작되지 않는 버그)
        guard let process = caffeinateProcess,
              let session = sessionState.activeSession,
              session.processID == process.processIdentifier,
              session.processObjectID == ObjectIdentifier(process) else { return false }
        return process.isRunning
    }

    enum ToggleResult {
        case success
        case failed(String)
    }

    func toggle() -> ToggleResult {
        if isDisableSleep {
            return stopCaffeinate()
        } else {
            return startCaffeinate()
        }
    }

    private func startCaffeinate() -> ToggleResult {
        let p = Process()
        let token = UUID().uuidString
        let processObjectID = ObjectIdentifier(p)
        p.executableURL = URL(fileURLWithPath: "/usr/bin/caffeinate")
        // -w <자기 PID>: 부모(SteamPack)가 죽으면 caffeinate도 자동 종료.
        // applicationWillTerminate는 SIGKILL/크래시엔 안 불리므로, 이 옵션이
        // 고아 caffeinate가 sleep을 영영 차단하는 것을 커널 레벨에서 막는다.
        let selfPID = ProcessInfo.processInfo.processIdentifier
        // -s(시스템 sleep 방지)는 AC 전용이라 배터리에서 무력 → 제거.
        // -d(디스플레이) -i(유휴 시스템) -m(디스크)는 전원 무관 작동(뚜껑 열림 기준).
        p.arguments = ["-d", "-i", "-m", "-w", "\(selfPID)"]
        // 자식이 예기치 않게 죽으면 상태 리셋 (UI는 다음 메뉴 오픈 시 동기화).
        // terminationHandler는 임의 백그라운드 큐에서 호출되므로
        // 상태 변수 변경은 메인 스레드로 디스패치해 데이터 레이스 방지.
        p.terminationHandler = { [weak self] terminatedProcess in
            let terminatedSession = SleepToggleSessionIdentity(
                token: token,
                processID: terminatedProcess.processIdentifier,
                processObjectID: processObjectID
            )
            DispatchQueue.main.async {
                self?.handleTermination(of: terminatedSession)
            }
        }
        do {
            try p.run()
            sessionState.activate(SleepToggleSessionIdentity(
                token: token,
                processID: p.processIdentifier,
                processObjectID: processObjectID
            ))
            caffeinateProcess = p
            isDisableSleep = true
        } catch {
            return .failed(error.localizedDescription)
        }
        return .success
    }

    private func stopCaffeinate() -> ToggleResult {
        guard let session = sessionState.activeSession else {
            caffeinateProcess = nil
            isDisableSleep = false
            return .success
        }

        if let process = caffeinateProcess,
           session.processID == process.processIdentifier,
           session.processObjectID == ObjectIdentifier(process),
           process.isRunning,
           kill(session.processID, SIGTERM) != 0,
           errno != ESRCH {
            return .failed(NSError(
                domain: NSPOSIXErrorDomain,
                code: Int(errno)
            ).localizedDescription)
        }
        _ = sessionState.clearIfMatching(session)
        if caffeinateProcess.map(ObjectIdentifier.init) == session.processObjectID {
            caffeinateProcess = nil
        }
        isDisableSleep = false
        return .success
    }

    private func handleTermination(of session: SleepToggleSessionIdentity) {
        // A stopped child may deliver its handler after a new child is already
        // active. Only the token + Process object + PID that created this handler
        // may clear the current session.
        guard sessionState.consumeTermination(session) else { return }
        if caffeinateProcess.map(ObjectIdentifier.init) == session.processObjectID {
            caffeinateProcess = nil
        }
        isDisableSleep = false
        onStateChange?()
    }
}
