#!/bin/bash
# SteamPack Clamshell Mode용 sudoers 규칙 설치 (1회만 실행, sudo 비밀번호 필요)
set -euo pipefail
TEMPLATE="$(cd "$(dirname "$0")" && pwd)/steampack-pmset-sudoers"
TMP="$(mktemp)"
trap 'rm -f "$TMP"' EXIT

# 현재 사용자명으로 치환 (repo에 username 하드코딩 방지 + 이식성)
sed "s/__USER__/$(whoami)/" "$TEMPLATE" > "$TMP"

# visudo 문법 검증 후 설치 — 문법 오류 sudoers는 시스템 전체 sudo를 망가뜨림
sudo visudo -cf "$TMP"
sudo install -m 0440 -o root -g wheel "$TMP" /etc/sudoers.d/steampack-pmset
echo "✓ /etc/sudoers.d/steampack-pmset 설치 완료 (user=$(whoami))"
sudo -n /usr/bin/pmset disablesleep 0 && echo "✓ NOPASSWD 동작 확인"
