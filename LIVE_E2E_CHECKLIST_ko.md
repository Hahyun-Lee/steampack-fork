# 설치 앱·제어 센터 실기기 점검표

서명된 빌드를 공개하기 전에 반드시 실시합니다. 단위 테스트는 상태 모델을 검증하지만, macOS가 이미 설치된 제어 센터 확장과 화면의 타일 캐시를 실제로 갱신했는지는 증명하지 못합니다.

## 정확한 후보 빌드 설치 확인

1. 기존 앱을 올바르게 서명된 후보로 교체하고 한 번 실행합니다. `CODE_SIGNING_ALLOWED=NO`로 만든 산출물은 제어 센터 검증에 사용하지 않습니다. 개발 서명이 없으면 `bash scripts/build-local-adhoc.sh`로 번들 전체가 봉인된 로컬 전용 ad-hoc 후보를 만듭니다. 이 결과는 동작 진단용이며 공개 바이너리 승인 근거가 아닙니다.
2. `bash scripts/verify-installed-versions.sh`를 실행합니다. 로컬 전용 ad-hoc 후보는 `ALLOW_ADHOC_SIGNING=1 bash scripts/verify-installed-versions.sh /Applications/SteamPack.app build/adhoc/SteamPack.app`로 설치 코드와 원본 후보를 대조합니다. 앱·확장 버전, bundle identifier, 중첩 strict 서명, 동일 signing team, sandbox entitlement, architecture, CDHash, 단 하나의 PlugInKit 등록 경로가 모두 맞아야 합니다. plist 버전만 맞는 것은 통과가 아닙니다.
3. 이전 빌드에서 추가한 제어 센터 타일을 그대로 둡니다. 업그레이드가 기존 타일을 갱신해야 하므로, 타일을 지웠다가 다시 추가해서 캐시 문제를 숨기지 않습니다.
4. 실제 상태를 판정하기 전에 **제어 항목 편집**을 종료합니다. 편집기·갤러리는 preview 또는 캐시 표현을 보여줄 수 있으므로, `currentValue()`의 판정 기준은 정상 제어 센터 화면입니다.

## 전환 행렬

종료 행을 제외하고 메뉴 막대 아이콘·문구, `pmset -g`의 `SleepDisabled`, 로컬 `applied-state.json`, 화면의 제어 센터 타일 두 개를 모두 대조합니다. 종료 행에서는 프로세스가 사라졌는지, `pmset`이 복구됐는지, applied-state 기록이 삭제됐는지, 제어 센터 provider가 확인 불가 상태를 보고하는지 확인합니다.

| 전환 | 통과 조건 |
|---|---|
| 정상 잠자기로 실행 | `SleepDisabled=0`, atomic applied state가 OFF/OFF, 타일 두 개가 OFF입니다. |
| 정상 → 잠자기 방지 → 정상 | 잠자기 방지만 켜졌다가 모든 화면이 OFF로 돌아옵니다. |
| 정상 → 덮개 닫고 계속 → 정상 | 두 컨트롤이 ON이고, 잠자기 방지를 끄면 `SleepDisabled=0`과 두 타일 OFF로 돌아옵니다. |
| 덮개 닫고 계속 → 덮개 닫기 OFF → 정상 | 덮개 닫기를 끄면 메뉴와 제어 센터 모두 잠자기 방지는 ON으로 남고, 잠자기 방지를 끄면 두 컨트롤이 OFF로 돌아옵니다. |
| 정상 제어 센터 → 덮개 닫고 계속 ON/OFF | 전체 모드가 실제로 적용된 뒤에만 성공을 확인합니다. 정상 제어 센터에서 누른 타일과 함께 바뀐 타일이 1초 안에 일치해야 합니다. 클릭, applied-state, 화면 수렴 시각을 따로 기록합니다. |
| 제어 센터를 닫은 채 앱·메뉴에서 변경 → 즉시 제어 센터 열기 | 즉시 요청과 1초 뒤 한 번뿐인 대상별 재요청 안에 바뀐 타일이 일치해야 합니다. 10초 runtime refresh를 기다리면 실패입니다. |
| 덮개 닫고 계속 → 외부 `pmset disablesleep 0` | 10초 안에 더 새로운 OFF 요청을 기록하고 자동 종료 카운트다운을 취소하며, 예전 ON 요청을 되살리지 않고 타일도 OFF가 됩니다. |
| 덮개 닫고 계속 → 감시 프로세스/앱 실패 | 정상 잠자기를 복구하거나 복구 실패를 화면에 알리며, 오래된 ON을 현재 상태로 표시하지 않습니다. |
| 임의 모드 실행 중 → 종료하고 정상 잠자기로 복구 | 정상 잠자기를 복구하고 applied-state 기록을 제거합니다. 6초 안에 두 컨트롤은 OFF가 아니라 확인 불가 상태가 되며, 누르면 SteamPack을 열라는 안내가 나옵니다. |
| 종료·실패 뒤 재실행 | 실행 도중 이전 ON 상태가 다시 나타나지 않습니다. |

각 행에서 관찰한 화면의 시각 표시 스크린샷과 명령·상태 파일 로그를 보존합니다. 새 applied OFF 기록은 OFF로 보여야 하고, 종료·실패 뒤 기록이 없거나 만료된 상태는 어떤 Boolean도 현재값처럼 표시하지 않고 확인 불가로 알려야 합니다. 로그에 `reloadAllControls`나 주기적 reload loop가 없어야 하며, 앱·메뉴 변경에는 즉시 요청과 지연된 대상별 요청 한 번까지만 있어야 합니다. 짧은 화면 녹화는 선택 사항입니다. 정상 제어 센터가 행별 제한 시간 안에 검증된 로컬 상태와 일치하지 않으면 배포를 차단하고 설치 앱·확장 버전, 서명·등록 receipt, macOS 빌드를 기록합니다. 단위 테스트나 **제어 항목 편집** 화면만으로 통과 처리하면 안 됩니다.

공개 바이너리 배포 전에는 최종 공증 DMG에서 직접 설치한 앱으로 전체 행렬을 다시 실행합니다. 소스 commit·release tag, DMG 파일명·SHA-256, 앱·확장 version/build/ID, signing team, architecture별 CDHash, 정확한 PlugInKit 경로, macOS build, 시각을 기록합니다. ad-hoc 결과를 공증 배포 결과로 올려서 기록하면 안 됩니다.

[English](LIVE_E2E_CHECKLIST.md)
