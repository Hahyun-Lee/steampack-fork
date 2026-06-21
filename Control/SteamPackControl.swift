import WidgetKit
import AppIntents
import SwiftUI

/// Control Center 토글 탭 시 실행. 시스템 주입 value는 신뢰하지 않고
/// "토글 요청"만 보낸다 — 실제 flip은 앱이 현재 상태 기준으로 수행.
struct ToggleKeepAwakeIntent: SetValueIntent {
    static let title: LocalizedStringResource = "Keep Awake"

    @Parameter(title: "Keep Awake")
    var value: Bool

    init() {}

    func perform() async throws -> some IntentResult {
        // 새 값을 *동기적으로* 직접 기록 → 시스템이 provider 재조회 시 즉시 반영(레이스 제거).
        // (상태 파일은 익스텐션 자기 컨테이너에 있어 쓰기 가능)
        let newVal = !SteamPackShared.readKeepAwake()
        SteamPackShared.writeKeepAwake(newVal)
        SteamPackShared.postToggleRequest()   // 앱이 실제 caffeinate/pmset 적용
        return .result()
    }
}

/// 컨트롤의 현재 상태 공급자. reloadControls(ofKind:) 호출 시 시스템이
/// currentValue()를 다시 호출 → 토글 아이콘이 실제 상태로 갱신된다.
/// (inline isOn 정적 방식은 reload 시 재평가되지 않아 아이콘이 고정됨)
struct KeepAwakeValueProvider: ControlValueProvider {
    var previewValue: Bool { false }

    func currentValue() async throws -> Bool {
        SteamPackShared.readKeepAwake()
    }
}

/// Control Center "잠자기 억제" 토글 — 값 공급자로 동적 상태 표시.
struct KeepAwakeControl: ControlWidget {
    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(
            kind: SteamPackShared.controlKind,
            provider: KeepAwakeValueProvider()
        ) { value in
            ControlWidgetToggle(
                "Keep Awake",
                isOn: value,
                action: ToggleKeepAwakeIntent()
            ) { isOn in
                Label(isOn ? "Awake" : "Sleep OK",
                      systemImage: isOn ? "eye.fill" : "eye.slash")
            }
        }
        .displayName("SteamPack Keep Awake")
        .description("Prevent your Mac from sleeping.")
    }
}

@main
struct SteamPackControlBundle: WidgetBundle {
    var body: some Widget {
        KeepAwakeControl()
    }
}
