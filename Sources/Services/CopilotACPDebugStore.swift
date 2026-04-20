import Combine
import Foundation

enum CopilotACPDebugRequestStatus: String, Equatable, Sendable {
    case running
    case completed
    case failed
}

struct CopilotACPDebugRequest: Identifiable, Equatable, Sendable {
    let id: UUID
    let startedAt: Date
    var endedAt: Date? = nil
    var bridgeBaseURL: String
    var path: String
    var model: String
    var reasoningEffort: String
    var workingDirectoryPath: String
    var configDirectoryPath: String
    var commandLine: String? = nil
    var processID: Int32? = nil
    var status: CopilotACPDebugRequestStatus
    var httpStatus: Int? = nil
    var errorMessage: String? = nil

    var durationText: String {
        let end = endedAt ?? Date()
        return String(format: "%.1fs", end.timeIntervalSince(startedAt))
    }
}

struct CopilotACPDebugEvent: Identifiable, Equatable, Sendable {
    let id: UUID
    let requestID: UUID?
    let timestamp: Date
    let title: String
    let detail: String
    let payloadPreview: String?
}

@MainActor
final class CopilotACPDebugStore: ObservableObject, @unchecked Sendable {
    nonisolated static let defaultRequestLimit = 20
    nonisolated static let defaultEventLimit = 1_000
    nonisolated static let payloadPreviewLimit = 64 * 1_024

    @Published private(set) var requests: [CopilotACPDebugRequest] = []
    @Published private(set) var events: [CopilotACPDebugEvent] = []

    private let requestLimit: Int
    private let eventLimit: Int

    init(
        requestLimit: Int = CopilotACPDebugStore.defaultRequestLimit,
        eventLimit: Int = CopilotACPDebugStore.defaultEventLimit
    ) {
        self.requestLimit = requestLimit
        self.eventLimit = eventLimit
    }

    var activeRequestCount: Int {
        requests.filter { $0.status == .running }.count
    }

    var latestBridgeBaseURL: String? {
        requests.last?.bridgeBaseURL
    }

    var latestCommandLine: String? {
        requests.reversed().compactMap(\.commandLine).first
    }

    func recordRequestStarted(
        id: UUID,
        bridgeBaseURL: String,
        path: String,
        model: String,
        reasoningEffort: String,
        workingDirectoryPath: String,
        configDirectoryPath: String,
        payloadPreview: String?
    ) {
        requests.append(
            CopilotACPDebugRequest(
                id: id,
                startedAt: Date(),
                bridgeBaseURL: bridgeBaseURL,
                path: path,
                model: model,
                reasoningEffort: reasoningEffort,
                workingDirectoryPath: workingDirectoryPath,
                configDirectoryPath: configDirectoryPath,
                status: .running
            )
        )
        appendEvent(
            requestID: id,
            title: L10n.tr("Bridge 请求"),
            detail: "\(path) \(model) \(reasoningEffort)",
            payloadPreview: payloadPreview
        )
        trimRequests()
    }

    func recordRequestFinished(
        id: UUID,
        status: CopilotACPDebugRequestStatus,
        httpStatus: Int?,
        errorMessage: String?
    ) {
        updateRequest(id: id) { request in
            request.status = status
            request.httpStatus = httpStatus
            request.errorMessage = errorMessage
            request.endedAt = Date()
        }
        appendEvent(
            requestID: id,
            title: status == .completed ? L10n.tr("Bridge 完成") : L10n.tr("Bridge 失败"),
            detail: errorMessage ?? (httpStatus.map { "HTTP \($0)" } ?? status.rawValue),
            payloadPreview: nil
        )
    }

    func recordACPCommand(
        requestID: UUID,
        commandLine: String,
        processID: Int32
    ) {
        updateRequest(id: requestID) { request in
            request.commandLine = commandLine
            request.processID = processID
        }
        appendEvent(
            requestID: requestID,
            title: L10n.tr("ACP 启动"),
            detail: "pid=\(processID)",
            payloadPreview: commandLine
        )
    }

    func appendEvent(
        requestID: UUID?,
        title: String,
        detail: String,
        payloadPreview: String?
    ) {
        events.append(
            CopilotACPDebugEvent(
                id: UUID(),
                requestID: requestID,
                timestamp: Date(),
                title: title,
                detail: detail,
                payloadPreview: truncated(payloadPreview)
            )
        )
        trimEvents()
    }

    func clear() {
        requests.removeAll()
        events.removeAll()
    }

    private func updateRequest(id: UUID, mutate: (inout CopilotACPDebugRequest) -> Void) {
        guard let index = requests.firstIndex(where: { $0.id == id }) else { return }
        mutate(&requests[index])
    }

    private func trimRequests() {
        if requests.count > requestLimit {
            requests.removeFirst(requests.count - requestLimit)
        }
    }

    private func trimEvents() {
        if events.count > eventLimit {
            events.removeFirst(events.count - eventLimit)
        }
    }

    private func truncated(_ value: String?) -> String? {
        guard let value else { return nil }
        if value.count <= Self.payloadPreviewLimit {
            return value
        }
        return String(value.prefix(Self.payloadPreviewLimit)) + "\n... truncated ..."
    }
}
