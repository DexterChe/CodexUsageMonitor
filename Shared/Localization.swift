import Foundation

enum L10n {
    static func text(_ key: String) -> String {
        NSLocalizedString(key, bundle: .main, comment: "")
    }

    static func status(_ status: MonitorStatus) -> String {
        text(status.rawValue)
    }
}
