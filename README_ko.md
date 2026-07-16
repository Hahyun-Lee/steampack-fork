<div align="right">

[![English](https://img.shields.io/badge/lang-English-blue?style=flat-square)](README.md)

</div>

<div align="center">

# SteamPack

**macOS Tahoe용 네이티브 Keep Awake·닫힌 덮개 컨트롤**

</div>

SteamPack은 메뉴 막대와 macOS 제어 센터에서 사용할 수 있는 두 개의 연동 토글을 제공합니다.

- **Keep Awake**: 덮개를 연 상태에서 유휴·화면·디스크 잠자기를 방지합니다.
- **Clamshell Mode**: 배터리 사용 중에도 덮개를 닫은 채 작업을 계속합니다.

Clamshell은 Keep Awake의 하위 옵션입니다. Clamshell을 켜면 Keep Awake도 켜지고, Keep Awake를 끄면 모든 잠자기 방지가 해제됩니다. 두 컨트롤 모두 제어 센터 또는 메뉴 막대에 직접 배치할 수 있습니다.

> **공개 프리뷰:** 현재는 소스 빌드용입니다. Developer ID 서명과 Apple 공증이 준비된 뒤에만 DMG를 배포합니다. 서명되지 않은 공개 바이너리는 의도적으로 제공하지 않습니다.

## 안전 설계

닫힌 덮개 상태는 발열과 배터리 소모를 일으킬 수 있으므로 다음 보호 장치를 기본 적용합니다.

- **강제 종료 복구:** Clamshell 세션마다 별도 watchdog이 붙습니다. 앱 crash·SIGKILL 시에도 정상 잠자기를 복구합니다.
- **세션 소유권:** 이전 watchdog이 새 세션을 끌 수 없으며, 다른 앱이 만든 `SleepDisabled` 상태를 SteamPack 상태로 오인하지 않습니다.
- **배터리 보호:** 배터리 사용 중 20%가 되면 Clamshell을 자동 해제합니다.
- **온도 보호:** macOS thermal state가 serious 또는 critical이면 즉시 해제합니다.
- **타이머·종료 복구:** 타이머 만료와 **Quit & Restore Sleep** 시 정상 잠자기로 돌아갑니다.
- **정직한 제어 센터 상태:** 요청값이 아니라 실제 적용값만 표시하며, 메뉴 막대 앱이 죽어 있으면 컨트롤은 자동으로 OFF를 표시합니다.
- **최소 권한:** 관리자 승인은 아래 두 명령만 비밀번호 없이 허용합니다.

```text
/usr/bin/pmset disablesleep 1
/usr/bin/pmset disablesleep 0
```

관리자 비밀번호는 저장하지 않습니다. Clamshell 권한은 앱 메뉴에서 언제든 제거할 수 있습니다.

## 요구 사항

- macOS Tahoe 26.0 이상
- 소스 빌드 시 Xcode 26, [XcodeGen](https://github.com/yonaskolb/XcodeGen)
- 제어 센터 컨트롤 렌더링을 위한 무료 Apple Development 팀

## 빌드

```bash
git clone https://github.com/Hahyun-Lee/steampack-fork.git
cd steampack-fork
brew install xcodegen
xcodegen generate
DEVELOPMENT_TEAM=YOUR_TEAM_ID scripts/build.sh
open build/SteamPack.app
```

또는 `SteamPack.xcodeproj`를 Xcode에서 열고 두 앱 target에 개발 팀을 선택한 뒤 `SteamPack` scheme을 실행합니다.

Clamshell을 처음 사용할 때 **Install Clamshell Permission…**을 선택하면 macOS가 관리자 승인을 한 번 요청합니다. 일반 Keep Awake에는 이 권한이 필요하지 않습니다.

## 제어 센터에 추가

1. macOS 제어 센터에서 **컨트롤 편집**을 엽니다.
2. **SteamPack Keep Awake**와 **SteamPack Clamshell**을 추가합니다.
3. 필요하면 각 컨트롤을 메뉴 막대에 고정합니다.

## 테스트

```bash
xcodegen generate
xcodebuild \
  -project SteamPack.xcodeproj \
  -scheme SteamPack \
  -derivedDataPath /tmp/steampack-tests \
  CODE_SIGNING_ALLOWED=NO \
  test
```

배터리·온도 정책, watchdog 세션 소유권과 race, 제어 센터 heartbeat 및 실제 상태 동기화를 검증합니다.

빌드와 Clamshell 권한 설치 후 아래 통합 검증을 선택적으로 실행할 수 있습니다. `SleepDisabled`를 잠깐 변경하고 앱 crash와 같은 watchdog 연결 종료를 만든 다음 정상 잠자기 복구를 확인합니다. 이미 잠자기가 비활성화된 상태에서는 실행을 거부합니다.

```bash
scripts/verify-crash-recovery.sh
```

## 한계와 주의

- `pmset disablesleep`은 문서화되지 않은 macOS 동작이므로 향후 바뀔 수 있습니다.
- 보호 장치가 있어도 고부하 작업 중인 MacBook을 닫아 가방에 넣는 행동이 안전해지는 것은 아닙니다. 통풍을 확보해야 합니다.
- 제어 센터 동작에는 메뉴 막대 앱이 실행 중이어야 합니다.
- 동일한 전역 `SleepDisabled` 값을 바꾸는 다른 도구와는 안전하게 소유권을 공유할 수 없습니다. SteamPack은 외부 상태를 감지하면 이를 차지하지 않습니다.

## 개인정보·보안

텔레메트리, 분석, 계정, 네트워크 요청, 비밀번호 저장이 없습니다. 자세한 내용은 [PRIVACY.md](PRIVACY.md)와 [SECURITY.md](SECURITY.md)를 참고하세요.

## 원작 표시

SteamPack은 MIT 라이선스 프로젝트 [tykimos/steampack](https://github.com/tykimos/steampack)의 fork입니다. 원저작권과 라이선스를 그대로 보존합니다.
