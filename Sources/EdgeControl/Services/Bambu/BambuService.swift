import AppKit
import Foundation

/// Keeps a connection to each Bambu Lab printer a widget shows.
///
/// A printer is reached at the address typed into its widget, with the
/// access code from the printer's own network screen; the code lives in the
/// Keychain, not in the layout file. Status arrives over MQTT about once a
/// second for as long as a widget watches the printer. The camera streams
/// only while a widget showing it is on screen and the displays are awake.
///
/// Everything here reads: the printer is never sent a command that would move
/// or heat it, so it works in Bambu's standard LAN mode without Developer
/// Mode.
@MainActor
public final class BambuService: ObservableObject {
    public enum Connection: Equatable, Sendable {
        case connecting
        case connected
        case needsAccessCode
        case failed(String)
    }

    public struct Printer: Equatable, Sendable {
        public var connection: Connection
        public var serial: String?
        public var status: BambuStatus?

        public var model: String? { serial.flatMap(BambuStatus.model) }
    }

    typealias ReportLinkFactory =
        @MainActor (
            _ host: String, _ accessCode: String,
            _ handler: @escaping @MainActor @Sendable (BambuMQTTSession.Event) -> Void
        ) -> BambuLink
    typealias CameraLinkFactory =
        @MainActor (
            _ host: String, _ accessCode: String,
            _ handler: @escaping @MainActor @Sendable (BambuCameraSession.Event) -> Void
        ) -> BambuLink

    @Published public private(set) var printers: [String: Printer] = [:]
    @Published public private(set) var frames: [String: BambuCameraFrame] = [:]

    private let secrets: CISecretStore
    private let makeReportLink: ReportLinkFactory
    private let makeCameraLink: CameraLinkFactory
    private let retryDelays: [Duration]

    private var reports: [String: BambuJSON] = [:]
    private var watchCounts: [String: Int] = [:]
    private var cameraCounts: [String: Int] = [:]
    private var links: [String: BambuLink] = [:]
    private var cameraLinks: [String: BambuLink] = [:]
    /// Bumped on every connect, so a dropped connection's late events are ignored.
    private var generations: [String: Int] = [:]
    private var cameraGenerations: [String: Int] = [:]
    private var failures: [String: Int] = [:]
    private var cameraFailures: [String: Int] = [:]
    private var retries: [String: Task<Void, Never>] = [:]
    private var cameraRetries: [String: Task<Void, Never>] = [:]
    private var screensAwake = true
    private var screenObservers: [NSObjectProtocol] = []

    public convenience init() {
        self.init(
            secrets: KeychainSecretStore(service: "ai.pakslab.edgecontrol.bambu"),
            retryDelays: [.seconds(2), .seconds(5), .seconds(15), .seconds(30), .seconds(60)],
            makeReportLink: { BambuMQTTSession(host: $0, accessCode: $1, handler: $2) },
            makeCameraLink: { BambuCameraSession(host: $0, accessCode: $1, handler: $2) })
    }

    init(
        secrets: CISecretStore, retryDelays: [Duration], makeReportLink: @escaping ReportLinkFactory,
        makeCameraLink: @escaping CameraLinkFactory
    ) {
        self.secrets = secrets
        self.retryDelays = retryDelays
        self.makeReportLink = makeReportLink
        self.makeCameraLink = makeCameraLink
        let center = NSWorkspace.shared.notificationCenter
        for (name, awake) in [
            (NSWorkspace.screensDidSleepNotification, false), (NSWorkspace.screensDidWakeNotification, true),
        ] {
            screenObservers.append(
                center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated { self?.setScreensAwake(awake) }
                })
        }
    }

    // MARK: - Lifecycle

    public func start() {
        for host in watchCounts.keys where links[host] == nil { connect(host) }
        for host in cameraCounts.keys where cameraLinks[host] == nil { connectCamera(host) }
    }

    public func stop() {
        for host in Array(links.keys) { disconnect(host) }
        for host in Array(cameraLinks.keys) { disconnectCamera(host) }
    }

    // MARK: - Watching

    public func watch(_ host: String) {
        guard !host.isEmpty else { return }
        watchCounts[host, default: 0] += 1
        if watchCounts[host] == 1 { connect(host) }
    }

    public func unwatch(_ host: String) {
        guard let count = watchCounts[host] else { return }
        if count > 1 {
            watchCounts[host] = count - 1
        } else {
            watchCounts[host] = nil
            disconnect(host)
        }
    }

    public func watchCamera(_ host: String) {
        guard !host.isEmpty else { return }
        cameraCounts[host, default: 0] += 1
        if cameraCounts[host] == 1 { connectCamera(host) }
    }

    public func unwatchCamera(_ host: String) {
        guard let count = cameraCounts[host] else { return }
        if count > 1 {
            cameraCounts[host] = count - 1
        } else {
            cameraCounts[host] = nil
            disconnectCamera(host)
            frames[host] = nil
        }
    }

    // MARK: - Access codes

    public func hasAccessCode(for host: String) -> Bool {
        secrets.read(host) != nil
    }

    /// Saves the code and connects with it straight away, so settings can
    /// show whether it was right.
    public func setAccessCode(_ code: String, for host: String) throws {
        let code = code.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !host.isEmpty, !code.isEmpty else { return }
        try secrets.write(code, for: host)
        reconnect(host)
    }

    /// Tries again now rather than after the retry delay.
    public func reconnect(_ host: String) {
        failures[host] = 0
        cameraFailures[host] = 0
        if watchCounts[host] != nil {
            disconnect(host)
            connect(host)
        }
        if cameraCounts[host] != nil {
            disconnectCamera(host)
            connectCamera(host)
        }
    }

    // MARK: - Status

    private func connect(_ host: String) {
        retries[host]?.cancel()
        retries[host] = nil
        guard let code = secrets.read(host) else {
            update(host) { $0.connection = .needsAccessCode }
            return
        }
        update(host) { $0.connection = .connecting }
        let generation = generations[host, default: 0] + 1
        generations[host] = generation
        links[host] = makeReportLink(host, code) { [weak self] event in
            guard let self, self.generations[host] == generation else { return }
            self.handle(event, from: host)
        }
    }

    private func disconnect(_ host: String) {
        retries[host]?.cancel()
        retries[host] = nil
        generations[host, default: 0] += 1
        links.removeValue(forKey: host)?.cancel()
    }

    private func handle(_ event: BambuMQTTSession.Event, from host: String) {
        switch event {
        case .connected(let serial):
            failures[host] = 0
            update(host) {
                $0.serial = serial
                $0.connection = .connected
            }
        case .report(let print, let complete):
            let merged = complete ? print : (reports[host]?.merging(print) ?? print)
            reports[host] = merged
            let status = BambuStatus(merged)
            if printers[host]?.status != status { update(host) { $0.status = status } }
        case .failed(let problem):
            links[host] = nil
            update(host) { $0.connection = .failed(problem) }
            // A wrong code stays wrong until somebody types a new one.
            guard problem != "Wrong access code", watchCounts[host] != nil else { return }
            let attempt = failures[host, default: 0]
            failures[host] = attempt + 1
            let delay = retryDelays[min(attempt, retryDelays.count - 1)]
            retries[host] = Task { [weak self] in
                try? await Task.sleep(for: delay)
                guard !Task.isCancelled, let self, self.watchCounts[host] != nil else { return }
                self.connect(host)
            }
        }
    }

    private func update(_ host: String, _ change: (inout Printer) -> Void) {
        var printer = printers[host] ?? Printer(connection: .connecting)
        change(&printer)
        if printers[host] != printer { printers[host] = printer }
    }

    // MARK: - Camera

    private func connectCamera(_ host: String) {
        cameraRetries[host]?.cancel()
        cameraRetries[host] = nil
        guard screensAwake, let code = secrets.read(host) else { return }
        let generation = cameraGenerations[host, default: 0] + 1
        cameraGenerations[host] = generation
        cameraLinks[host] = makeCameraLink(host, code) { [weak self] event in
            guard let self, self.cameraGenerations[host] == generation else { return }
            switch event {
            case .frame(let frame):
                self.cameraFailures[host] = 0
                self.frames[host] = frame
            case .failed:
                self.cameraLinks[host] = nil
                self.retryCamera(host)
            }
        }
    }

    private func disconnectCamera(_ host: String) {
        cameraRetries[host]?.cancel()
        cameraRetries[host] = nil
        cameraGenerations[host, default: 0] += 1
        cameraLinks.removeValue(forKey: host)?.cancel()
    }

    /// Printers without this camera (X1, H2) refuse it every time, so the
    /// wait grows to a minute and stays there.
    private func retryCamera(_ host: String) {
        guard cameraCounts[host] != nil else { return }
        let attempt = cameraFailures[host, default: 0]
        cameraFailures[host] = attempt + 1
        let delay = retryDelays[min(attempt, retryDelays.count - 1)]
        cameraRetries[host] = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled, let self, self.cameraCounts[host] != nil else { return }
            self.connectCamera(host)
        }
    }

    private func setScreensAwake(_ awake: Bool) {
        screensAwake = awake
        if awake {
            for host in cameraCounts.keys where cameraLinks[host] == nil { connectCamera(host) }
        } else {
            for host in Array(cameraLinks.keys) { disconnectCamera(host) }
        }
    }
}
