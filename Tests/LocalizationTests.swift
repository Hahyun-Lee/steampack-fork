import XCTest
@testable import SteamPack

final class LocalizationTests: XCTestCase {
    private var projectRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    private var koreanLocalizationURL: URL {
        projectRoot
            .appendingPathComponent("Shared/ko.lproj", isDirectory: true)
    }

    private func koreanCatalog() throws -> [String: String] {
        let stringsURL = koreanLocalizationURL.appendingPathComponent("Localizable.strings")
        let data = try Data(contentsOf: stringsURL)
        return try XCTUnwrap(
            try PropertyListSerialization.propertyList(from: data, format: nil)
                as? [String: String]
        )
    }

    func testKoreanCatalogContainsEndToEndUserJourneyCopy() throws {
        let catalog = try koreanCatalog()

        let requiredKeys = [
            "Keep Awake",
            "Closed Lid",
            "SteamPack Closed Lid",
            "Install Closed-Lid Permission…",
            "Keep Working with Lid Closed",
            "Quit & Restore Sleep",
            "SteamPack restored normal sleep",
            "Open SteamPack before using this control."
        ]

        for key in requiredKeys {
            let translation = try XCTUnwrap(catalog[key], "Missing Korean translation for \(key)")
            XCTAssertFalse(translation.isEmpty)
            XCTAssertNotEqual(translation, key)
        }
    }

    func testKoreanBundleFormatsDynamicSafetyCopy() throws {
        let bundle = try XCTUnwrap(Bundle(path: koreanLocalizationURL.path))
        let formatted = SteamPackL10n.format(
            "Battery is at %d%%",
            bundle: bundle,
            20
        )

        XCTAssertEqual(formatted, "배터리가 20% 남음")
    }

    func testEveryExplicitLocalizationKeyHasKoreanTranslation() throws {
        let catalog = try koreanCatalog()
        let patterns = try [
            #"SteamPackL10n\.(?:text|format)\(\s*\"([^\"]+)\""#,
            #"SteamPackL10n\.text\(\s*(?:\([^\n]*\)\s*)?[^?\n]*\?\s*\"([^\"]+)\"\s*:\s*\"([^\"]+)\""#,
            #"LocalizedStringResource\s*=\s*\"([^\"]+)\""#,
            #"@Parameter\(title:\s*\"([^\"]+)\""#,
            #"ControlWidgetToggle\(\s*\"([^\"]+)\""#,
            #"\.displayName\(\s*\"([^\"]+)\""#,
            #"\.description\(\s*\"([^\"]+)\""#
        ].map { try NSRegularExpression(pattern: $0) }
        let sourceDirectories = ["src", "Shared", "Control"]
        var keys = Set<String>()

        for directory in sourceDirectories {
            let root = projectRoot.appendingPathComponent(directory, isDirectory: true)
            guard let enumerator = FileManager.default.enumerator(
                at: root,
                includingPropertiesForKeys: nil
            ) else {
                XCTFail("Could not enumerate \(directory)")
                continue
            }

            for case let fileURL as URL in enumerator where fileURL.pathExtension == "swift" {
                let source = try String(contentsOf: fileURL, encoding: .utf8)
                let range = NSRange(source.startIndex..., in: source)
                for pattern in patterns {
                    for match in pattern.matches(in: source, range: range) {
                        for captureIndex in 1..<match.numberOfRanges {
                            guard let keyRange = Range(
                                match.range(at: captureIndex),
                                in: source
                            ) else { continue }
                            keys.insert(String(source[keyRange]))
                        }
                    }
                }
            }
        }

        for key in keys.sorted() {
            XCTAssertNotNil(catalog[key], "Missing Korean translation for \(key)")
        }
    }
}
