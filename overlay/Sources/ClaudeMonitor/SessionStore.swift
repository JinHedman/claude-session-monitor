import Foundation
import Combine

@MainActor
final class SessionStore: ObservableObject {

    static let shared = SessionStore()

    @Published var sessions: [Session] = []

    private var wsTask: URLSessionWebSocketTask?
    private var pollTimer: Timer?
    private var isWSConnected = false
    private var isReconnecting = false

    private let baseURL = "http://localhost:9147"
    private let wsURL  = "ws://localhost:9147/ws"

    private init() {}

    // MARK: - Public API

    func startMonitoring() {
        connectWebSocket()
        startPollingFallback()
    }

    // MARK: - WebSocket

    private func connectWebSocket() {
        guard !isReconnecting else { return }
        wsTask?.cancel(with: .goingAway, reason: nil)

        guard let url = URL(string: wsURL) else { return }
        let session = URLSession(configuration: .default)
        wsTask = session.webSocketTask(with: url)
        wsTask?.resume()
        receiveNextWSMessage()
    }

    private func receiveNextWSMessage() {
        wsTask?.receive { [weak self] result in
            Task { @MainActor [weak self] in
                guard let self else { return }
                switch result {
                case .success(let message):
                    self.isWSConnected = true
                    self.isReconnecting = false
                    if case .string(let text) = message {
                        self.decodeSessions(from: text)
                    }
                    self.receiveNextWSMessage()

                case .failure:
                    self.isWSConnected = false
                    guard !self.isReconnecting else { return }
                    self.isReconnecting = true
                    // Wait 5 seconds then reconnect
                    try? await Task.sleep(nanoseconds: 5_000_000_000)
                    self.isReconnecting = false
                    self.connectWebSocket()
                }
            }
        }
    }

    // MARK: - HTTP Polling Fallback

    private func startPollingFallback() {
        pollTimer = Timer.scheduledTimer(withTimeInterval: 3.0, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, !self.isWSConnected else { return }
                await self.fetchSessionsHTTP()
            }
        }
    }

    private func fetchSessionsHTTP() async {
        guard let url = URL(string: "\(baseURL)/api/sessions") else { return }
        do {
            let (data, _) = try await URLSession.shared.data(from: url)
            if let text = String(data: data, encoding: .utf8) {
                decodeSessions(from: text)
            }
        } catch {
            // Silently ignore — backend may not be running yet
        }
    }

    // MARK: - Clear All

    func clearAllSessions() async {
        guard let url = URL(string: "\(baseURL)/api/sessions") else { return }
        var request = URLRequest(url: url)
        request.httpMethod = "DELETE"
        _ = try? await URLSession.shared.data(for: request)
    }

    // MARK: - Decoding

    private func decodeSessions(from json: String) {
        guard let data = json.data(using: .utf8) else { return }
        if let decoded = try? JSONDecoder().decode([Session].self, from: data) {
            sessions = decoded
        }
    }
}
