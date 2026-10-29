/// Coalesces capture reconfiguration requests across device notifications and
/// watchdog recovery. Protected by CameraEngine's state lock in production.
struct CaptureConfigurationGate {
    struct Ticket: Equatable { fileprivate let revision: UInt64 }
    private var revision: UInt64 = 0
    private(set) var active: Ticket?

    mutating func begin() -> Ticket? {
        guard active == nil else { return nil }
        revision &+= 1
        let ticket = Ticket(revision: revision)
        active = ticket
        return ticket
    }
    func isValid(_ ticket: Ticket) -> Bool { ticket.revision == revision }
    mutating func finish(_ ticket: Ticket) {
        if active == ticket { active = nil }
    }
    mutating func invalidate() { revision &+= 1; active = nil }
}
