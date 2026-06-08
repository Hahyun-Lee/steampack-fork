import Foundation

class SleepToggle {
    private(set) var isDisableSleep: Bool = false
    private var caffeinatePID: Int32 = -1
    // Process 인스턴스를 보관해야 terminationHandler/자식 추적이 보장됨
    // (로컬 변수면 스코프 이탈 시 콜백 신뢰성이 깨짐)
    private var caffeinateProcess: Process?

    init() { refresh() }

    func refresh() {
        isDisableSleep = currentStatus()
    }

    func currentStatus() -> Bool {
        // 자기 자식 caffeinate의 생존 여부로만 판정.
        // (기존 pmset assertion regex는 powerd의 "Prevent sleep while display is on"에
        //  항상 매칭되어 false positive → caffeinate가 영영 시작되지 않는 버그)
        return caffeinatePID > 0 && kill(caffeinatePID, 0) == 0
    }

    enum ToggleResult {
        case success
        case failed(String)
    }

    func toggle() -> ToggleResult {
        if isDisableSleep {
            stopCaffeinate()
            isDisableSleep = false
        } else {
            return startCaffeinate()
        }
        return .success
    }

    private func startCaffeinate() -> ToggleResult {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/caffeinate")
        // -w <자기 PID>: 부모(SteamPack)가 죽으면 caffeinate도 자동 종료.
        // applicationWillTerminate는 SIGKILL/크래시엔 안 불리므로, 이 옵션이
        // 고아 caffeinate가 sleep을 영영 차단하는 것을 커널 레벨에서 막는다.
        let selfPID = ProcessInfo.processInfo.processIdentifier
        p.arguments = ["-s", "-d", "-i", "-w", "\(selfPID)"]
        // 자식이 예기치 않게 죽으면 상태 리셋 (UI는 다음 메뉴 오픈 시 동기화).
        // terminationHandler는 임의 백그라운드 큐에서 호출되므로
        // 상태 변수 변경은 메인 스레드로 디스패치해 데이터 레이스 방지.
        p.terminationHandler = { [weak self] _ in
            DispatchQueue.main.async {
                self?.caffeinatePID = -1
                self?.isDisableSleep = false
                self?.caffeinateProcess = nil
            }
        }
        do {
            try p.run()
            caffeinatePID = p.processIdentifier
            caffeinateProcess = p
            isDisableSleep = true
        } catch {
            return .failed(error.localizedDescription)
        }
        return .success
    }

    private func stopCaffeinate() {
        if caffeinatePID > 0 {
            kill(caffeinatePID, SIGTERM)
            caffeinatePID = -1
        }
        caffeinateProcess = nil
    }
}
