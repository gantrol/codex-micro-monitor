import Foundation
func tr(_ key: String) -> String { Bundle.main.localizedString(forKey: key, value: key, table: nil) }
