import Foundation

private let isSpanish = Locale.preferredLanguages.first?.hasPrefix("es") ?? false

/// Tiny two-language helper. The app has a handful of strings, so a full
/// .strings setup would be more ceremony than content.
func L(_ english: String, _ spanish: String) -> String {
    isSpanish ? spanish : english
}
