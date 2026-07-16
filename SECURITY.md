# Security Policy

## Supported version

Security fixes are applied to the latest public preview on the default branch.

## Reporting a vulnerability

Please use GitHub Private Vulnerability Reporting from the repository's **Security** tab. Do not open a public issue for a vulnerability involving privilege boundaries, the sudoers rule, Control Center IPC, or watchdog recovery.

Include the affected macOS version, SteamPack commit or version, reproduction steps, and the observed impact. Reports will be acknowledged as soon as practical.

## Privilege boundary

SteamPack's optional sudoers entry allows only the exact commands `/usr/bin/pmset disablesleep 1` and `/usr/bin/pmset disablesleep 0`. It does not grant a shell, wildcard arguments, or password access. Changes that broaden this rule are considered security-sensitive and require explicit review.
