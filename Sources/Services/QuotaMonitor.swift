import Foundation

final class QuotaMonitor: NSObject {
    private let sessionScanner: SessionQuotaScanner
    private let logReader: SQLiteLogReader
    private var timer: Timer?
    private var lastSignalDate: Date = .distantPast
    private var activeAccountID: UUID?
    private var snapshotHandler: ((UUID, QuotaSnapshot) -> Void)?
    private var signalHandler: ((UUID, Date) -> Void)?

    init(sessionScanner: SessionQuotaScanner, logReader: SQLiteLogReader) {
        self.sessionScanner = sessionScanner
        self.logReader = logReader
    }

    func bootstrapSnapshot() -> QuotaSnapshot? {
        sessionScanner.latestExistingSnapshot()
    }

    func start(
        onSnapshot: @escaping (UUID, QuotaSnapshot) -> Void,
        onSignal: @escaping (UUID, Date) -> Void
    ) {
        sessionScanner.seedOffsets()
        timer?.invalidate()
        snapshotHandler = onSnapshot
        signalHandler = onSignal

        timer = Timer.scheduledTimer(
            timeInterval: 3,
            target: self,
            selector: #selector(tick),
            userInfo: nil,
            repeats: true
        )
        timer?.tolerance = 0.5
    }

    func setActiveAccountID(_ accountID: UUID?) {
        activeAccountID = accountID
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    @objc
    private func tick() {
        guard let activeAccountID else { return }

        for snapshot in sessionScanner.pollNewSnapshots() {
            snapshotHandler?(activeAccountID, snapshot)
        }

        if let signal = logReader.latestRelevantSignal(after: lastSignalDate) {
            lastSignalDate = signal.date
            signalHandler?(activeAccountID, signal.date)
        }
    }
}

extension QuotaMonitor: QuotaMonitoring {}
