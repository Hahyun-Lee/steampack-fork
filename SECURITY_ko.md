# 보안 정책

## 지원 버전

보안 수정은 기본 브랜치의 최신 공개 프리뷰에 적용합니다.

## 취약점 신고

권한 경계, sudoers 규칙, 제어 센터 통신, 강제 종료 복구와 관련된 취약점은 공개 issue로 올리지 말고 저장소 **Security** 탭의 비공개 취약점 신고 기능을 이용해 주세요.

영향받는 macOS 버전, SteamPack commit 또는 버전, 재현 단계, 확인된 영향을 포함해 주세요.

## 권한 경계

SteamPack의 선택적 sudoers 항목은 `/usr/bin/pmset disablesleep 1`과 `/usr/bin/pmset disablesleep 0`이라는 정확한 명령 두 개만 허용합니다. shell, 와일드카드 인자, 비밀번호 접근 권한은 제공하지 않습니다. 이 규칙을 넓히는 변경은 보안상 민감한 변경으로 취급하며 명시적인 검토가 필요합니다.

[English](SECURITY.md)
