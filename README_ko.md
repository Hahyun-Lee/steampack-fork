<div align="right">

[![English](https://img.shields.io/badge/lang-English-blue?style=flat-square)](README.md)

</div>

<div align="center">

<img src="assets/hero-ko.png" width="100%" alt="완전히 닫힌 MacBook에서도 업로드, 빌드, 원격 작업을 계속하는 SteamPack">

# SteamPack

**덮개를 닫아도 업로드·빌드·원격 작업을 멈추지 않습니다.**

[![MIT License](https://img.shields.io/badge/license-MIT-blue?style=flat-square)](LICENSE)
[![macOS 26+](https://img.shields.io/badge/macOS-26%2B-black?style=flat-square&logo=apple)](https://www.apple.com/macos/)
[![English + 한국어](https://img.shields.io/badge/UI-English%20%2B%20한국어-orange?style=flat-square)](README.md)

[소스에서 설치](#소스에서-설치하기) · [릴리스](https://github.com/Hahyun-Lee/steampack-fork/releases)

</div>

SteamPack은 **잠자기 방지**와 **덮개 닫고 계속** 두 가지 기능을 제공하는 macOS 메뉴 막대 앱입니다. 앱과 제어 센터, 메뉴 막대에서 바로 켜고 끌 수 있습니다.

## 두 가지 모드

| 모드 | 하는 일 | 권한 |
|---|---|---|
| **잠자기 방지** | 덮개를 연 동안 유휴·화면·디스크 잠자기를 막습니다 | 필요 없음 |
| **덮개 닫고 계속** | 배터리 사용 중에도 덮개를 닫은 뒤 작업을 계속합니다 | 관리자 승인 1회 |

**덮개 닫고 계속**을 켜면 **잠자기 방지**도 함께 켜집니다. 덮개 닫기를 끄면 잠자기 방지 상태로 내려가고, 잠자기 방지를 끄면 정상 잠자기 동작으로 돌아갑니다. 메뉴와 제어 센터의 전환 규칙은 같습니다.

전원 연결 없이 배터리가 20% 이하이거나, 전원 정보를 확인할 수 없거나, macOS가 심각하거나 위험한 발열 상태를 알리거나, 자동 종료 타이머가 끝나면 덮개 닫기 모드를 켜지 않거나 자동으로 끕니다. SteamPack이 예기치 않게 멈추면 별도 감시 프로세스가 정상 잠자기 복구를 시도하며, 실패한 복구는 알리고 다시 시도할 수 있도록 기록을 보존합니다.

> 이번 프리뷰에는 DMG가 없습니다. 자신의 Apple Development 팀으로 소스에서 빌드해야 합니다. Developer ID 서명과 Apple 공증이 준비되면 공개 설치 파일을 제공할 예정입니다.

## 소스에서 설치하기

macOS Tahoe 26+, Xcode 26, [Homebrew](https://brew.sh), XcodeGen, Apple Development 팀이 필요합니다. 무료 Apple ID 팀도 사용할 수 있습니다.

```bash
git clone https://github.com/Hahyun-Lee/steampack-fork.git
cd steampack-fork
brew install xcodegen
DEVELOPMENT_TEAM=YOUR_10_CHARACTER_TEAM_ID scripts/build.sh
ditto build/SteamPack.app /Applications/SteamPack.app
open /Applications/SteamPack.app
```

Xcode에서 빌드하려면 `xcodegen generate`를 실행하고 `SteamPack.xcodeproj`를 엽니다. **Signing & Capabilities**에서 두 타깃의 팀을 선택한 뒤 **SteamPack** 스킴을 실행하세요.

## 사용하기

메뉴 막대에서 SteamPack 아이콘을 누르고 필요한 모드를 선택합니다.

- 덮개를 연 채 다운로드·발표·빌드를 할 때는 **잠자기 방지 켜기**를 선택합니다.
- 덮개를 닫으려면 **덮개 닫기 권한 설치…**를 한 번 선택하고 macOS 승인 창을 확인합니다. 이후 **덮개 닫고 계속 사용**을 선택합니다.
- 작업이 끝나면 **잠자기 방지**를 끕니다. 두 모드가 모두 꺼지고 정상 잠자기 동작으로 돌아갑니다.

덮개 닫기 권한은 아래 명령 두 개만 허용합니다.

```text
/usr/bin/pmset disablesleep 1
/usr/bin/pmset disablesleep 0
```

SteamPack은 관리자 비밀번호를 저장하거나 다른 명령에 전달하지 않습니다.

권한 파일은 버전과 현재 계정의 숫자 사용자 ID별로 분리되고, 허용된 정확한 명령마다 1초 관리자 timeout이 적용됩니다. **덮개 닫기 권한 설치…**는 과거의 계정별·공용 SteamPack 규칙 전체가 이전 배포본의 내용과 정확히 일치할 때만 이전합니다. 계정별 규칙이 수정되어 있으면 그대로 보존하고 수동 검토를 위해 이전을 중단합니다. **덮개 닫기 권한 제거…**는 다른 계정의 규칙을 삭제하지 않습니다.

## 제어 센터에 추가하기

1. macOS **제어 센터**를 열고 **컨트롤 편집**을 선택합니다.
2. **SteamPack 잠자기 방지**와 **SteamPack 덮개 닫고 계속**을 추가합니다.
3. 자주 쓰는 컨트롤은 메뉴 막대에 고정할 수 있습니다.

SteamPack 앱은 실행 중이어야 합니다. 실제 적용 상태를 확인할 수 없으면 검증되지 않은 OFF를 표시하지 않고 상태를 확인할 수 없음을 알립니다. 컨트롤을 사용하면 SteamPack을 열라는 안내가 나타납니다.

## 덮개를 닫고 사용할 때

MacBook은 통풍되는 단단한 바닥에 두세요. **덮개 닫고 계속**이 켜진 MacBook을 가방에 넣으면 안 됩니다.

다음 상황에서는 덮개 닫기 모드를 켜지 않거나 이미 켜진 모드를 끕니다.

- 전원 연결 없이 배터리가 20% 이하일 때
- macOS가 전원 연결 상태를 확인하지 못하거나, 배터리 사용 중 잔량을 읽지 못할 때
- macOS가 심각하거나 위험한 발열 상태를 알렸을 때
- 자동 종료 타이머가 끝났을 때
- **종료하고 정상 잠자기로 복구**를 선택했을 때

앱이 예기치 않게 멈추면 별도 감시 프로세스가 정상 잠자기 복구를 시도합니다. 복구하지 못하면 잠자기 방지가 아직 켜져 있을 수 있음을 알리고, 권한이 준비된 뒤 다시 시도할 수 있도록 소유권 기록을 보존합니다. 각 세션은 고유한 토큰을 사용하므로 이전 감시 프로세스가 새 세션을 끌 수 없습니다. 다른 도구가 만든 `SleepDisabled` 상태도 SteamPack이 가져오지 않습니다.

제어 센터 provider는 macOS에 실제로 적용된 상태를 읽습니다. 각 요청에 revision을 붙이고, 앱이 완전히 검증한 결과를 게시할 때까지 성공을 보고하지 않습니다. SteamPack은 사용자가 누른 제어 센터 source를 macOS가 갱신하게 하고, 함께 값이 바뀐 컨트롤은 즉시 갱신한 뒤 0.5초 뒤 한 번만 대상별로 재요청합니다. SteamPack 상태 메뉴에서 상태를 바꿀 때도 같은 방식으로 해당 컨트롤만 즉시 갱신하고 한 번 재요청하여, 변경 직후 제어 센터를 열어도 이전 표시가 남지 않게 합니다. 주기적인 갱신이나 제어 센터 전체를 반복해서 갱신하는 loop는 없습니다. 적용 상태 기록이 없거나 만료되면 검증되지 않은 OFF가 아니라 확인 불가 상태로 처리합니다. 바이너리 배포 전에는 **제어 항목 편집**이 아닌 정상 제어 센터에서 화면 수렴과 반응 속도가 [설치 앱 점검표](LIVE_E2E_CHECKLIST_ko.md)를 통과해야 합니다.

## 제거하기

1. SteamPack 메뉴에서 **덮개 닫기 권한 제거…**를 선택합니다.
2. **종료하고 정상 잠자기로 복구**를 선택합니다.
3. 응용 프로그램 폴더의 `SteamPack.app`을 휴지통으로 옮깁니다.

## 언어 바꾸기

SteamPack은 macOS 언어 설정을 따릅니다. SteamPack에만 다른 언어를 지정하려면 **시스템 설정 → 일반 → 언어 및 지역 → 응용 프로그램**에서 SteamPack을 추가하고 한국어 또는 영어를 선택하세요.

## 문제 해결

| 문제 | 확인할 내용 |
|---|---|
| 제어 센터에 컨트롤이 없음 | macOS 26+인지 확인하고 SteamPack을 한 번 실행한 뒤 **컨트롤 편집**을 다시 엽니다. |
| 앱을 열라는 메시지가 표시됨 | `/Applications/SteamPack.app`을 실행합니다. |
| 덮개 닫기 기능이 켜지지 않음 | 앱 메뉴에서 덮개 닫기 권한을 설치합니다. |
| 덮개 닫기 메뉴를 누를 수 없음 | 다른 앱이나 명령이 전역 `SleepDisabled` 상태를 사용 중입니다. 해당 도구에서 먼저 정상 상태로 복구하세요. |
| 한국어 UI가 표시되지 않음 | **언어 및 지역 → 응용 프로그램**에서 SteamPack 언어를 한국어로 지정하고 다시 실행합니다. |

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

빌드하고 덮개 닫기 권한을 설치한 뒤 `scripts/verify-crash-recovery.sh`를 실행하면 감시 프로세스의 복구 동작을 확인할 수 있습니다. 이미 잠자기가 비활성화된 상태에서는 스크립트가 실행되지 않습니다.

Apple Development identity 없이 로컬 제어 센터를 테스트하려면 `scripts/build-local-adhoc.sh`를 사용하세요. 번들 전체가 올바르게 봉인된 로컬 전용 앱을 `build/adhoc/SteamPack.app`에 만듭니다. 배포용은 아니며, `CODE_SIGNING_ALLOWED=NO`로 만든 테스트 산출물로 제어 센터 확장을 검증하면 안 됩니다.

서명된 빌드를 배포하기 전에는 [설치 앱·제어 센터 실기기 점검표](LIVE_E2E_CHECKLIST_ko.md)를 완료해야 합니다. 단위 테스트로 볼 수 없는 설치 앱·내장 확장 버전, 서명, sandbox entitlement, PlugInKit 등록, 화면의 타일 전환을 확인합니다.

`scripts/release.sh`는 서명 검증·공증·stapling·Gatekeeper 평가를 모두 통과하기 전에는 공개 설치 파일을 만들지 않습니다.

## 알려진 제한

- `pmset disablesleep`은 문서화되지 않은 macOS 동작이므로 향후 바뀔 수 있습니다.
- 보호 기능은 위험을 줄일 뿐, 작동 중인 닫힌 MacBook을 가방에 넣어도 안전하게 만들지는 않습니다.
- 전역 `SleepDisabled` 값을 바꾸는 다른 도구와는 상태 소유권을 공유할 수 없습니다.

SteamPack에는 텔레메트리, 분석, 계정, 네트워크 요청, 저장된 비밀번호가 없습니다. 자세한 내용은 [개인정보 보호](PRIVACY_ko.md)와 [보안 정책](SECURITY_ko.md)을 참고하세요.

SteamPack은 [tykimos/steampack](https://github.com/tykimos/steampack)을 기반으로 한 MIT 라이선스 fork입니다. 원저작권과 라이선스를 보존합니다.
