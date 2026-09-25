/// Metadata keys on the files WatchConnectivity carries between the two apps.
nonisolated enum BridgeKey {
    /// What the file holds. Only reports carry it, since the phone sends nothing else.
    static let kind = "kind"
    static let report = "report"
    /// The report's first day as a raw `DayKey`, readable without opening the file. The
    /// watch reads it off transfers still waiting, to cover their days in the next report.
    static let earliestDay = "earliestDay"
}
