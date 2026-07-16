import Cocoa
import Foundation

enum ClamshellAuthorization {
    private static let sudoersPath = "/etc/sudoers.d/steampack-pmset"

    static func isInstalled() -> Bool {
        canRun(arguments: ["-n", "-l", "/usr/bin/pmset", "disablesleep", "1"])
            && canRun(arguments: ["-n", "-l", "/usr/bin/pmset", "disablesleep", "0"])
    }

    static func install() -> Result<Void, Error> {
        do {
            let user = NSUserName()
            guard user.range(of: #"^[A-Za-z0-9._-]+$"#, options: .regularExpression) != nil else {
                throw AuthorizationError.invalidUserName
            }

            let rule = "\(user) ALL=(root) NOPASSWD: /usr/bin/pmset disablesleep 1, /usr/bin/pmset disablesleep 0\n"
            let temporaryURL = FileManager.default.temporaryDirectory
                .appendingPathComponent("steampack-sudoers-\(UUID().uuidString)")
            try rule.write(to: temporaryURL, atomically: true, encoding: .utf8)
            defer { try? FileManager.default.removeItem(at: temporaryURL) }

            guard validateSudoersFile(at: temporaryURL) else {
                throw AuthorizationError.invalidRule
            }

            let command = "/usr/bin/install -m 0440 -o root -g wheel "
                + shellQuote(temporaryURL.path) + " " + shellQuote(sudoersPath)
            try runPrivileged(command)

            guard isInstalled() else { throw AuthorizationError.installationFailed }
            return .success(())
        } catch {
            return .failure(error)
        }
    }

    static func remove() -> Result<Void, Error> {
        do {
            try runPrivileged("/bin/rm -f " + shellQuote(sudoersPath))
            guard !isInstalled() else { throw AuthorizationError.removalFailed }
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
            try process.run()
            process.waitUntilExit()
            return process.terminationStatus == 0
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
            try process.run()
            process.waitUntilExit()
            return process.terminationStatus == 0
        } catch {
            return false
        }
    }

    private static func runPrivileged(_ shellCommand: String) throws {
        let source = "do shell script \(appleScriptLiteral(shellCommand)) with administrator privileges"
        var errorInfo: NSDictionary?
        guard let script = NSAppleScript(source: source) else {
            throw AuthorizationError.promptFailed("Could not create authorization prompt")
        }
        script.executeAndReturnError(&errorInfo)
        if let errorInfo {
            let message = errorInfo[NSAppleScript.errorMessage] as? String ?? "Authorization was cancelled"
            throw AuthorizationError.promptFailed(message)
        }
    }

    private static func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
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
            case .invalidUserName: return "The current macOS account name is not supported."
            case .invalidRule: return "The restricted sudo rule did not pass validation."
            case .promptFailed(let message): return message
            case .installationFailed: return "The restricted Clamshell permission was not installed."
            case .removalFailed: return "The restricted Clamshell permission could not be removed."
            }
        }
    }
}
