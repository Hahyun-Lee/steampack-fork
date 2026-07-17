import Foundation

enum SteamPackL10n {
    static func text(_ key: String, bundle: Bundle = .main) -> String {
        bundle.localizedString(forKey: key, value: key, table: nil)
    }

    static func format(
        _ key: String,
        bundle: Bundle = .main,
        _ arguments: CVarArg...
    ) -> String {
        String(
            format: text(key, bundle: bundle),
            locale: Locale.current,
            arguments: arguments
        )
    }
}
