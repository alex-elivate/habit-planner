import Foundation

/// Why a stored record could not be read back as a domain value.
///
/// Every case names the record and the field, because the alternative — returning `nil` and
/// moving on — is the exact failure shape this project keeps finding: something is wrong, the
/// numbers are quietly a little off, and nothing anywhere says so. A record that cannot be
/// mapped is a bug in whatever wrote it, and it should be findable.
public enum StoreMappingError: Error, Hashable, CustomStringConvertible {

    /// A `DayKey.rawValue` that does not name a real calendar day.
    ///
    /// Overwhelmingly likely to be `0`, which is what a missing or zeroed CloudKit `Int64`
    /// reads as. Its ordinal is -719560, so folding a habit that started then allocates a
    /// 740,000 element array inside a widget extension. Worth failing on.
    case invalidDayKey(record: String, field: String, raw: Int)

    /// A raw string with no matching case, meaning a record written by a newer version.
    case unknownRawValue(record: String, field: String, raw: String)

    /// A weekday bitmask with bits set outside the seven that exist, or with none set at all.
    ///
    /// An empty set is rejected rather than stored. A habit due on no day accrues no
    /// scheduled occurrences, so the lock-in gate can never see enough history and the
    /// routine it belongs to stays shut permanently, with nothing on screen explaining why.
    case malformedScheduleMask(record: String, raw: Int)

    /// A record written by a newer version of the app than this one understands.
    ///
    /// Reported rather than read. The danger is not failing to show it, it is reading it
    /// through a mapping that does not know about its newer fields and then writing that
    /// loss back over the original. A record this build cannot represent is one it must not
    /// touch. `schemaVersion` existed for this from the first commit and did nothing.
    case recordIsNewerThanThisBuild(record: String, recordVersion: Int, understood: Int)

    /// A stored identifier that disagrees with the content it is supposed to address.
    ///
    /// Deduplication rests entirely on that identifier being derivable from the record, so a
    /// row where the two disagree has already broken it. Reported rather than repaired: the
    /// damage is in whatever wrote the row, and silently recomputing the identifier would
    /// hide it while leaving the duplicate in place.
    case identifierMismatch(record: String, stored: String, derived: String)

    public var description: String {
        switch self {
        case .invalidDayKey(let record, let field, let raw):
            return "\(record).\(field): \(raw) is not a valid yyyyMMdd day"
        case .unknownRawValue(let record, let field, let raw):
            return "\(record).\(field): '\(raw)' has no matching case"
        case .malformedScheduleMask(let record, let raw):
            return "\(record).scheduleDayMask: \(raw) is empty or has bits outside the seven weekdays"
        case .recordIsNewerThanThisBuild(let record, let recordVersion, let understood):
            return "\(record): written by schema version \(recordVersion), this build understands \(understood)"
        case .identifierMismatch(let record, let stored, let derived):
            return "\(record): stored id '\(stored)' does not address its content '\(derived)'"
        }
    }
}
