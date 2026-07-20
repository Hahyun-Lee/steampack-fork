import Cocoa
import Foundation
import Darwin
import CryptoKit

struct ClamshellAuthorizationLayout {
    static let legacySudoersPath = "/etc/sudoers.d/steampack-pmset"
    static let commandTimeoutSeconds = 1

    let userID: uid_t

    var sudoersPath: String {
        "/etc/sudoers.d/steampack-pmset-v2-\(userID)"
    }

    var previousScopedSudoersPath: String {
        "/etc/sudoers.d/steampack-pmset-\(userID)"
    }

    var rule: String {
        // TIMEOUT is attached to each exact command, so this account's two
        // SteamPack grants cannot leave a privileged pmset child behind. Do not
        // use a Defaults!/usr/bin/pmset rule: that would also alter unrelated
        // pmset grants. Keep this byte-identical to the rendered shell template.
        "#\(userID) ALL=(root) "
            + "TIMEOUT=\(Self.commandTimeoutSeconds)s NOPASSWD: /usr/bin/pmset disablesleep 1, "
            + "TIMEOUT=\(Self.commandTimeoutSeconds)s NOPASSWD: /usr/bin/pmset disablesleep 0\n"
    }

    var previousScopedRules: [String] {
        let commandRule = "#\(userID) ALL=(root) NOPASSWD: "
            + "/usr/bin/pmset disablesleep 1, /usr/bin/pmset disablesleep 0\n"
        return [
            commandRule,
            "Defaults!/usr/bin/pmset command_timeout=5\n" + commandRule,
        ]
    }

    static func legacyRules(userName: String) -> [String]? {
        guard userName.range(
            of: #"^[A-Za-z0-9._-]+$"#,
            options: .regularExpression
        ) != nil else { return nil }
        let rule = "\(userName) ALL=(root) NOPASSWD: /usr/bin/pmset disablesleep 1, /usr/bin/pmset disablesleep 0\n"
        let helperRule = "# SteamPack Clamshell Mode (Battery) — pmset disablesleep 전용 NOPASSWD\n"
            + "# 정확한 인자 2개만 허용 (와일드카드 금지 — 다른 pmset 조작 차단)\n"
            + "# \(userName) 는 install-sudoers.sh가 설치 시점에 $(whoami)로 치환한다.\n"
            + rule
        return [rule, helperRule]
    }

    func installCommand(
        ruleURL: URL,
        rootTemporaryPath: String,
        expectedLegacyRules: [String]
    ) -> String {
        let quotedRootTemporaryPath = Self.shellQuote(rootTemporaryPath)
        return "status=0; /usr/bin/install -m 0440 -o root -g wheel "
            + Self.shellQuote(ruleURL.path) + " " + quotedRootTemporaryPath
            + " && /usr/bin/printf %s " + Self.shellQuote(rule)
            + " | /usr/bin/cmp -s - " + quotedRootTemporaryPath
            + " && /usr/sbin/visudo -cf " + quotedRootTemporaryPath
            + " >/dev/null"
            + " && /bin/mv -f " + quotedRootTemporaryPath + " "
            + Self.shellQuote(sudoersPath)
            + " && " + exactCleanupCommand(
                expectedRules: previousScopedRules,
                path: previousScopedSudoersPath,
                mismatchIsFailure: true
            )
            + " && " + legacyCleanupCommand(expectedLegacyRules: expectedLegacyRules)
            + " || status=$?; if [ \"$status\" -ne 0 ]; then /bin/rm -f "
            + Self.shellQuote(sudoersPath) + "; fi; /bin/rm -f " + quotedRootTemporaryPath
            + "; exit $status"
    }

    func removalCommand(expectedLegacyRules: [String]) -> String {
        "/bin/rm -f " + Self.shellQuote(sudoersPath)
            + " && " + exactCleanupCommand(
                expectedRules: previousScopedRules,
                path: previousScopedSudoersPath,
                mismatchIsFailure: true
            )
            + " && " + legacyCleanupCommand(expectedLegacyRules: expectedLegacyRules)
    }

    func legacyCleanupCommand(
        expectedLegacyRules: [String],
        legacyPath: String = Self.legacySudoersPath
    ) -> String {
        exactCleanupCommand(expectedRules: expectedLegacyRules, path: legacyPath)
    }

    func exactCleanupCommand(
        expectedRules: [String],
        path: String,
        mismatchIsFailure: Bool = false
    ) -> String {
        guard !expectedRules.isEmpty else { return ":" }
        let quotedPath = Self.shellQuote(path)
        let comparisons = expectedRules.map { expected in
            "[ \"$actual\" = " + Self.shellQuote(Self.sha256Hex(expected)) + " ]"
        }.joined(separator: " || ")
        let mismatchCommand = mismatchIsFailure ? "false" : ":"
        return "{ if [ -e " + quotedPath + " ]; then actual=$(/usr/bin/shasum -a 256 "
            + quotedPath + " 2>/dev/null | /usr/bin/awk '{print $1}'); if "
            + comparisons + "; then /bin/rm -f "
            + quotedPath + "; else " + mismatchCommand + "; fi; fi; }"
    }

    private static func sha256Hex(_ value: String) -> String {
        SHA256.hash(data: Data(value.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
    }

    private static func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}

enum ClamshellAuthorization {
    static func isInstalled() -> Bool {
        let layout = ClamshellAuthorizationLayout(userID: getuid())
        guard FileManager.default.fileExists(atPath: layout.sudoersPath),
              !FileManager.default.fileExists(
                atPath: layout.previousScopedSudoersPath
              ) else {
            // Shared and v1 account-scoped rules are deliberately not accepted:
            // choosing Install migrates to the per-command-timeout v2 rule.
            return false
        }
        return canRun(arguments: ["-n", "-l", "/usr/bin/pmset", "disablesleep", "1"])
            && canRun(arguments: ["-n", "-l", "/usr/bin/pmset", "disablesleep", "0"])
    }

    static func install() -> Result<Void, Error> {
        do {
            let userID = getuid()
            let layout = ClamshellAuthorizationLayout(userID: userID)
            guard let user = accountName(for: userID),
                  let legacyRules = ClamshellAuthorizationLayout
                    .legacyRules(userName: user) else {
                throw AuthorizationError.invalidUserName
            }

            let temporaryURL = FileManager.default.temporaryDirectory
                .appendingPathComponent("steampack-sudoers-\(UUID().uuidString)")
            try layout.rule.write(to: temporaryURL, atomically: true, encoding: .utf8)
            defer { try? FileManager.default.removeItem(at: temporaryURL) }

            guard validateSudoersFile(at: temporaryURL) else {
                throw AuthorizationError.invalidRule
            }

            try runPrivileged(layout.installCommand(
                ruleURL: temporaryURL,
                rootTemporaryPath: "/etc/sudoers.d/.steampack-pmset-v2-\(userID)-\(UUID().uuidString)",
                expectedLegacyRules: legacyRules
            ))

            guard FileManager.default.fileExists(atPath: layout.sudoersPath),
                  isInstalled() else { throw AuthorizationError.installationFailed }
            return .success(())
        } catch {
            return .failure(error)
        }
    }

    static func remove() -> Result<Void, Error> {
        do {
            let userID = getuid()
            let layout = ClamshellAuthorizationLayout(userID: userID)
            guard let user = accountName(for: userID),
                  let legacyRules = ClamshellAuthorizationLayout
                    .legacyRules(userName: user) else {
                throw AuthorizationError.invalidUserName
            }

            try runPrivileged(layout.removalCommand(
                expectedLegacyRules: legacyRules
            ))
            guard !FileManager.default.fileExists(atPath: layout.sudoersPath) else {
                throw AuthorizationError.removalFailed
            }
            return .success(())
        } catch {
            return .failure(error)
        }
    }

    private static func canRun(arguments: [String]) -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/sudo")
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            return try SteamPackProcessTimeout.run(
                process,
                timeout: SteamPackProcessTimeout.statusQuery
            ) == 0
        } catch {
            return false
        }
    }

    private static func validateSudoersFile(at url: URL) -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/visudo")
        process.arguments = ["-cf", url.path]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            return try SteamPackProcessTimeout.run(
                process,
                timeout: SteamPackProcessTimeout.validation
            ) == 0
        } catch {
            return false
        }
    }

    private static func runPrivileged(_ shellCommand: String) throws {
        let source = "do shell script \(appleScriptLiteral(shellCommand)) with administrator privileges"
        var errorInfo: NSDictionary?
        guard let script = NSAppleScript(source: source) else {
            throw AuthorizationError.promptFailed(
                SteamPackL10n.text("Could not create authorization prompt")
            )
        }
        script.executeAndReturnError(&errorInfo)
        if let errorInfo {
            let message = errorInfo[NSAppleScript.errorMessage] as? String
                ?? SteamPackL10n.text("Authorization was cancelled")
            throw AuthorizationError.promptFailed(message)
        }
    }

    private static func accountName(for userID: uid_t) -> String? {
        guard let record = getpwuid(userID),
              let name = record.pointee.pw_name else { return nil }
        return String(cString: name)
    }

    private static func appleScriptLiteral(_ value: String) -> String {
        "\"" + value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }

    enum AuthorizationError: LocalizedError {
        case invalidUserName
        case invalidRule
        case promptFailed(String)
        case installationFailed
        case removalFailed

        var errorDescription: String? {
            switch self {
            case .invalidUserName:
                return SteamPackL10n.text("The current macOS account name is not supported.")
            case .invalidRule:
                return SteamPackL10n.text("The restricted sudo rule did not pass validation.")
            case .promptFailed(let message): return message
            case .installationFailed:
                return SteamPackL10n.text("The restricted Closed-Lid permission was not installed.")
            case .removalFailed:
                return SteamPackL10n.text("The restricted Closed-Lid permission could not be removed.")
            }
        }
    }
}
