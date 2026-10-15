import Foundation

/// Dates as they appear in the names of files Gruppen makes: fixed, sortable,
/// and the same on every Mac.
///
/// The POSIX locale and Gregorian calendar are the point. Without them a Mac
/// set to the Buddhist calendar names a file `2569-10-15`, which sorts nowhere
/// near anything else.
enum Stamp {
    /// `2026-10-15`
    static func day(_ date: Date = Date()) -> String { dayFormat.string(from: date) }
    /// `2026-10`
    static func month(_ date: Date = Date()) -> String { monthFormat.string(from: date) }
    /// `2026-10-15-134501`
    static func moment(_ date: Date = Date()) -> String { momentFormat.string(from: date) }

    // Shared across threads safely: a DateFormatter only formats once it is
    // configured (thread-safe since macOS 10.9), and these are never changed
    // after they are made.
    nonisolated(unsafe) private static let dayFormat = formatter("yyyy-MM-dd")
    nonisolated(unsafe) private static let monthFormat = formatter("yyyy-MM")
    nonisolated(unsafe) private static let momentFormat = formatter("yyyy-MM-dd-HHmmss")

    private static func formatter(_ format: String) -> DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.dateFormat = format
        return formatter
    }
}
