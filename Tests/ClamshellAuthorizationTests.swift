import XCTest
import Darwin
@testable import SteamPack

final class ClamshellAuthorizationTests: XCTestCase {
    func testSudoersPathAndRuleAreScopedToNumericUID() {
        let first = ClamshellAuthorizationLayout(userID: 501)
        let second = ClamshellAuthorizationLayout(userID: 502)

        XCTAssertEqual(first.sudoersPath, "/etc/sudoers.d/steampack-pmset-v2-501")
        XCTAssertEqual(second.sudoersPath, "/etc/sudoers.d/steampack-pmset-v2-502")
        XCTAssertNotEqual(first.sudoersPath, second.sudoersPath)
        XCTAssertEqual(first.previousScopedSudoersPath, "/etc/sudoers.d/steampack-pmset-501")
        XCTAssertEqual(
            first.rule,
            "#501 ALL=(root) TIMEOUT=1s NOPASSWD: /usr/bin/pmset disablesleep 1, "
                + "TIMEOUT=1s NOPASSWD: /usr/bin/pmset disablesleep 0\n"
        )
        XCTAssertEqual(first.rule.components(separatedBy: "TIMEOUT=1s").count - 1, 2)
        XCTAssertFalse(first.rule.contains("Defaults!"))
        XCTAssertEqual(first.previousScopedRules.count, 2)
    }

    func testLegacyRuleRejectsShellAndSudoersMetacharacters() {
        XCTAssertEqual(
            ClamshellAuthorizationLayout.legacyRules(userName: "safe.user-1")?.count,
            2
        )
        XCTAssertNil(ClamshellAuthorizationLayout.legacyRules(
            userName: "user ALL=(ALL) ALL"
        ))
        XCTAssertNil(ClamshellAuthorizationLayout.legacyRules(userName: "user;rm"))
    }

    func testInstallAndRemovalCommandsTouchOnlyCurrentUIDAndExactLegacyRules() throws {
        let layout = ClamshellAuthorizationLayout(userID: 501)
        let ruleURL = URL(fileURLWithPath: "/tmp/current rule")
        let legacyRules = try XCTUnwrap(
            ClamshellAuthorizationLayout.legacyRules(userName: "current-user")
        )
        let install = layout.installCommand(
            ruleURL: ruleURL,
            rootTemporaryPath: "/etc/sudoers.d/.steampack-pmset-v2-501-test",
            expectedLegacyRules: legacyRules
        )
        let remove = layout.removalCommand(expectedLegacyRules: legacyRules)

        for command in [install, remove] {
            XCTAssertTrue(command.contains("'/etc/sudoers.d/steampack-pmset-v2-501'"))
            XCTAssertTrue(command.contains("'/etc/sudoers.d/steampack-pmset-501'"))
            XCTAssertFalse(command.contains("steampack-pmset-502"))
            XCTAssertFalse(command.contains("steampack-pmset-*"))
            XCTAssertTrue(command.contains("/usr/bin/shasum -a 256"))
            XCTAssertTrue(command.contains("'/etc/sudoers.d/steampack-pmset'"))
            XCTAssertFalse(command.contains("current-user ALL=(root)"))
            XCTAssertNotNil(command.range(
                of: #"[0-9a-f]{64}"#,
                options: .regularExpression
            ))
        }
        XCTAssertTrue(install.contains("'/tmp/current rule'"))
        XCTAssertTrue(install.contains("'/etc/sudoers.d/.steampack-pmset-v2-501-test'"))
        XCTAssertTrue(install.contains("/usr/bin/cmp -s -"))
        XCTAssertTrue(install.contains("/usr/sbin/visudo -cf"))
        XCTAssertTrue(install.contains("/bin/mv -f"))
        XCTAssertEqual(
            install.components(separatedBy: "&& { if [ -e").count - 1,
            2
        )
    }

    func testPreviousScopedCleanupRemovesOnlyExactSteamPackV1Rules() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("steampack-v1-cleanup-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: directory) }

        let layout = ClamshellAuthorizationLayout(userID: 501)
        for (index, contents) in layout.previousScopedRules.enumerated() {
            let path = directory.appendingPathComponent("exact-\(index)")
            try contents.write(to: path, atomically: true, encoding: .utf8)
            try runCleanup(
                layout,
                expected: layout.previousScopedRules,
                path: path,
                mismatchIsFailure: true
            )
            XCTAssertFalse(FileManager.default.fileExists(atPath: path.path))
        }

        let modified = directory.appendingPathComponent("modified")
        try (layout.previousScopedRules[1] + "# administrator note\n")
            .write(to: modified, atomically: true, encoding: .utf8)
        try runCleanup(
            layout,
            expected: layout.previousScopedRules,
            path: modified,
            mismatchIsFailure: true,
            expectedStatus: 1
        )
        XCTAssertTrue(FileManager.default.fileExists(atPath: modified.path))
    }

    func testGeneratedPrivilegedCommandsParseAsPOSIXShell() throws {
        let layout = ClamshellAuthorizationLayout(userID: 501)
        let legacyRules = try XCTUnwrap(
            ClamshellAuthorizationLayout.legacyRules(userName: "current-user")
        )
        let commands = [
            layout.installCommand(
                ruleURL: URL(fileURLWithPath: "/tmp/current rule"),
                rootTemporaryPath: "/etc/sudoers.d/.steampack-pmset-v2-501-test",
                expectedLegacyRules: legacyRules
            ),
            layout.removalCommand(expectedLegacyRules: legacyRules),
        ]

        for command in commands {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/sh")
            process.arguments = ["-n", "-c", command]
            try process.run()
            process.waitUntilExit()
            XCTAssertEqual(process.terminationStatus, 0, command)
        }
    }

    func testShellTemplateRendersByteIdenticalRule() throws {
        let repository = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let template = try String(
            contentsOf: repository.appendingPathComponent("scripts/steampack-pmset-sudoers"),
            encoding: .utf8
        )
        let rendered = template.replacingOccurrences(of: "__UID__", with: "501")

        XCTAssertEqual(rendered, ClamshellAuthorizationLayout(userID: 501).rule)
    }

    func testLegacyCleanupRemovesOnlyAnExactCurrentUserRule() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("steampack-legacy-cleanup-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: directory) }

        let layout = ClamshellAuthorizationLayout(userID: 501)
        let expectedRules = try XCTUnwrap(
            ClamshellAuthorizationLayout.legacyRules(userName: "current-user")
        )
        let matching = directory.appendingPathComponent("matching rule")
        let anotherUser = directory.appendingPathComponent("another user")
        try expectedRules[1].write(to: matching, atomically: true, encoding: .utf8)
        try "another-user ALL=(root) NOPASSWD: /usr/bin/pmset disablesleep 1, /usr/bin/pmset disablesleep 0\n"
            .write(to: anotherUser, atomically: true, encoding: .utf8)

        var cleanupCommands: [String] = []
        for path in [matching, anotherUser] {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/sh")
            let command = layout.legacyCleanupCommand(
                expectedLegacyRules: expectedRules,
                legacyPath: path.path
            )
            cleanupCommands.append(command)
            process.arguments = ["-c", command]
            try process.run()
            process.waitUntilExit()
            XCTAssertEqual(process.terminationStatus, 0)
        }

        XCTAssertFalse(
            FileManager.default.fileExists(atPath: matching.path),
            cleanupCommands.joined(separator: "\n---\n")
        )
        XCTAssertTrue(FileManager.default.fileExists(atPath: anotherUser.path))
    }

    func testNumericUIDRulePassesLocalVisudoSyntaxCheck() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("steampack-visudo-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: directory) }
        let ruleURL = directory.appendingPathComponent("rule")
        try ClamshellAuthorizationLayout(userID: getuid()).rule.write(
            to: ruleURL,
            atomically: true,
            encoding: .utf8
        )

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/visudo")
        process.arguments = ["-cf", ruleURL.path]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()

        XCTAssertEqual(process.terminationStatus, 0)
    }

    private func runCleanup(
        _ layout: ClamshellAuthorizationLayout,
        expected: [String],
        path: URL,
        mismatchIsFailure: Bool = false,
        expectedStatus: Int32 = 0
    ) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = [
            "-c",
            layout.exactCleanupCommand(
                expectedRules: expected,
                path: path.path,
                mismatchIsFailure: mismatchIsFailure
            ),
        ]
        try process.run()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, expectedStatus)
    }
}
