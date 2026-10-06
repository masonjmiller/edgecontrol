import AppKit
import Foundation

/// Reads the camera list from each go2rtc server a Cameras widget points at.
///
/// Widgets register the servers they show with `watch(_:)`. Each server is
/// read as soon as it's watched, and again every minute while the service
/// runs, so a camera added to go2rtc shows up without touching the dashboard.
/// Video never passes through here: each camera tile streams on its own, but
/// they all stop while the displays sleep.
@MainActor
public final class CameraService: ObservableObject {
    public enum ListState: Equatable, Sendable {
        case loading
        case loaded([String])
        case failed(String)
    }

    @Published public private(set) var lists: [URL: ListState] = [:]
    /// False while the displays sleep: nobody is watching, so nothing streams.
    @Published public private(set) var screensAwake = true

    private let transport: CITransport
    private let pollInterval: Duration
    private var watchCounts: [URL: Int] = [:]
    private var inFlight: Set<URL> = []
    private var pollTask: Task<Void, Never>?

    public init(
        transport: CITransport = URLSessionTransport(session: CameraService.session),
        pollInterval: Duration = .seconds(60)
    ) {
        self.transport = transport
        self.pollInterval = pollInterval
        let center = NSWorkspace.shared.notificationCenter
        for (name, awake) in [
            (NSWorkspace.screensDidSleepNotification, false), (NSWorkspace.screensDidWakeNotification, true),
        ] {
            screenObservers.append(
                center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated { self?.screensAwake = awake }
                })
        }
    }

    private var screenObservers: [NSObjectProtocol] = []

    /// Cameras are on the LAN: a server that hasn't answered in ten seconds
    /// isn't going to, and the shared session would wait a full minute.
    nonisolated public static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 10
        configuration.waitsForConnectivity = false
        return URLSession(configuration: configuration)
    }()

    public func watch(_ server: URL) {
        watchCounts[server, default: 0] += 1
        guard watchCounts[server] == 1 else { return }
        if lists[server] == nil { lists[server] = .loading }
        Task { await refresh(server) }
    }

    public func unwatch(_ server: URL) {
        guard let count = watchCounts[server] else { return }
        if count <= 1 {
            watchCounts[server] = nil
        } else {
            watchCounts[server] = count - 1
        }
    }

    /// Reads one server's list now. Settings use this to show the cameras on a
    /// server that was only just typed in.
    public func refresh(_ server: URL) async {
        guard !inFlight.contains(server) else { return }
        inFlight.insert(server)
        defer { inFlight.remove(server) }
        if lists[server] == nil { lists[server] = .loading }

        do {
            let (data, response) = try await transport.get(
                Go2RTC.streamsURL(server: server), headers: ["Accept": "application/json"])
            guard (200..<300).contains(response.statusCode) else {
                throw CIError.httpStatus(response.statusCode)
            }
            lists[server] = .loaded(try Go2RTC.streamNames(from: data))
        } catch let error as CIError {
            lists[server] = .failed(Self.message(for: error))
        } catch {
            lists[server] = .failed(Self.message(for: .unreachable))
        }
    }

    public func start() {
        guard pollTask == nil else { return }
        let interval = pollInterval
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: interval)
                guard let self, !Task.isCancelled else { return }
                for server in self.watchCounts.keys {
                    await self.refresh(server)
                }
            }
        }
    }

    public func stop() {
        pollTask?.cancel()
        pollTask = nil
    }

    /// Short enough for a tile, specific enough to act on.
    static func message(for error: CIError) -> String {
        switch error {
        case .unreachable: return "not reachable"
        case .unauthorized, .httpStatus(401), .httpStatus(403): return "asks for a login, which isn't supported yet"
        case .httpStatus(404): return "no go2rtc API at this address"
        case .httpStatus(let code): return "answered with error \(code)"
        case .rateLimited: return "busy, try again shortly"
        case .decoding: return "didn't answer like go2rtc"
        }
    }
}
