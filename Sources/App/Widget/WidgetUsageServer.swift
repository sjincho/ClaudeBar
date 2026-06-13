import Foundation
import Network
import Infrastructure
import WidgetShared

/// Serves the latest widget usage payload over loopback HTTP (`GET /usage`) so
/// the sandboxed widget can read it with a plain `network.client` connection —
/// no App Group, no provisioning profile. In-memory; updated on each refresh.
final class WidgetUsageServer: @unchecked Sendable {
    static let shared = WidgetUsageServer()

    private let queue = DispatchQueue(label: "com.tddworks.claudebar.widgetserver")
    private var listener: NWListener?
    private var latestPayload: Data?

    private init() {}

    /// Replaces the payload served to the widget.
    func update(_ data: Data) {
        queue.async { self.latestPayload = data }
    }

    /// Starts the loopback server (idempotent).
    func start() {
        queue.async {
            guard self.listener == nil,
                  let port = NWEndpoint.Port(rawValue: WidgetUsageEndpoint.port) else { return }

            let params = NWParameters.tcp
            params.requiredLocalEndpoint = NWEndpoint.hostPort(host: .ipv4(.loopback), port: port)

            guard let listener = try? NWListener(using: params) else {
                AppLog.ui.warning("Widget usage server: could not bind 127.0.0.1:\(WidgetUsageEndpoint.port)")
                return
            }
            listener.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    AppLog.ui.info("Widget usage server listening on 127.0.0.1:\(WidgetUsageEndpoint.port)")
                case .failed(let error):
                    AppLog.ui.error("Widget usage server failed: \(error.localizedDescription)")
                default:
                    break
                }
            }
            listener.newConnectionHandler = { [weak self] connection in
                self?.handle(connection)
            }
            listener.start(queue: self.queue)
            self.listener = listener
        }
    }

    private func handle(_ connection: NWConnection) {
        connection.start(queue: queue)
        connection.receive(minimumIncompleteLength: 1, maximumLength: 8192) { [weak self] data, _, _, _ in
            guard let self else { connection.cancel(); return }

            let isUsageGet: Bool = {
                guard let data, let request = String(data: data, encoding: .utf8) else { return false }
                return request.hasPrefix("GET \(WidgetUsageEndpoint.path)")
            }()

            let body = isUsageGet ? (self.latestPayload ?? Data("{\"accounts\":[],\"updatedAt\":\"1970-01-01T00:00:00Z\"}".utf8)) : Data()
            let status = isUsageGet ? "200 OK" : "404 Not Found"

            var response = Data(
                "HTTP/1.1 \(status)\r\nContent-Type: application/json\r\nContent-Length: \(body.count)\r\nConnection: close\r\n\r\n".utf8
            )
            response.append(body)

            connection.send(
                content: response,
                contentContext: .finalMessage,
                isComplete: true,
                completion: .contentProcessed { _ in connection.cancel() }
            )
        }
    }
}
