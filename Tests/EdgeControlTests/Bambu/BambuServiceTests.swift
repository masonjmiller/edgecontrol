import CoreGraphics
import Foundation
import Testing
@testable import EdgeControl

/// Stands in for a network connection: records what it was opened with and
/// lets the test speak for the printer.
private final class FakeLink: BambuLink, @unchecked Sendable {
    let host: String
    let accessCode: String
    private(set) var cancelled = false

    init(host: String, accessCode: String) {
        self.host = host
        self.accessCode = accessCode
    }

    func cancel() { cancelled = true }
}

@MainActor
private final class FakeNetwork {
    var reports: [(link: FakeLink, send: @MainActor @Sendable (BambuMQTTSession.Event) -> Void)] = []
    var cameras: [(link: FakeLink, send: @MainActor @Sendable (BambuCameraSession.Event) -> Void)] = []

    func service(secrets: CISecretStore) -> BambuService {
        BambuService(
            secrets: secrets, retryDelays: [.milliseconds(1)],
            makeReportLink: { host, code, handler in
                let link = FakeLink(host: host, accessCode: code)
                self.reports.append((link, handler))
                return link
            },
            makeCameraLink: { host, code, handler in
                let link = FakeLink(host: host, accessCode: code)
                self.cameras.append((link, handler))
                return link
            })
    }
}

@MainActor
@Suite("Bambu service")
struct BambuServiceTests {
    private let host = "192.168.1.50"

    private func secrets(code: String? = "12345678") throws -> InMemorySecretStore {
        let store = InMemorySecretStore()
        if let code { try store.write(code, for: host) }
        return store
    }

    @Test("watching a printer connects with its saved access code")
    func connects() throws {
        let network = FakeNetwork()
        let service = network.service(secrets: try secrets())

        service.watch(host)

        #expect(network.reports.map(\.link.host) == [host])
        #expect(network.reports.first?.link.accessCode == "12345678")
        #expect(service.printers[host]?.connection == .connecting)

        network.reports[0].send(.connected(serial: "01P00A000000000"))
        #expect(service.printers[host]?.connection == .connected)
        #expect(service.printers[host]?.model == "P1S")
    }

    @Test("without an access code nothing connects, and the widget says what's missing")
    func needsCode() throws {
        let network = FakeNetwork()
        let service = network.service(secrets: try secrets(code: nil))

        service.watch(host)

        #expect(network.reports.isEmpty)
        #expect(service.printers[host]?.connection == .needsAccessCode)

        try service.setAccessCode(" 87654321 ", for: host)
        #expect(network.reports.map(\.link.accessCode) == ["87654321"])
    }

    @Test("a full report, then a delta laid over it")
    func reports() throws {
        let network = FakeNetwork()
        let service = network.service(secrets: try secrets())
        service.watch(host)

        network.reports[0].send(.report(try bambuFixture("bambu-p1s-pushall"), complete: true))
        network.reports[0].send(.report(try bambuJSON(#"{"mc_percent":8,"layer_num":2}"#), complete: false))

        let status = try #require(service.printers[host]?.status)
        #expect(status.progress == 8)
        #expect(status.layer == 2)
        #expect(status.filaments.count == 4)
    }

    @Test("a lost printer keeps its last status and is tried again")
    func retries() async throws {
        let network = FakeNetwork()
        let service = network.service(secrets: try secrets())
        service.watch(host)
        network.reports[0].send(.report(try bambuFixture("bambu-p1s-pushall"), complete: true))

        network.reports[0].send(.failed("Not reachable"))

        #expect(service.printers[host]?.connection == .failed("Not reachable"))
        #expect(service.printers[host]?.status?.progress == 7)
        try await Task.sleep(for: .milliseconds(50))
        #expect(network.reports.count == 2)
    }

    @Test("a wrong access code isn't retried until a new one is entered")
    func wrongCode() async throws {
        let network = FakeNetwork()
        let service = network.service(secrets: try secrets())
        service.watch(host)

        network.reports[0].send(.failed("Wrong access code"))
        try await Task.sleep(for: .milliseconds(50))

        #expect(network.reports.count == 1)
        #expect(service.printers[host]?.connection == .failed("Wrong access code"))
    }

    @Test("two widgets share one connection, which closes when the last one goes")
    func sharing() throws {
        let network = FakeNetwork()
        let service = network.service(secrets: try secrets())

        service.watch(host)
        service.watch(host)
        #expect(network.reports.count == 1)

        service.unwatch(host)
        #expect(network.reports[0].link.cancelled == false)
        service.unwatch(host)
        #expect(network.reports[0].link.cancelled)
    }

    @Test("events from a dropped connection are ignored")
    func staleEvents() throws {
        let network = FakeNetwork()
        let service = network.service(secrets: try secrets())
        service.watch(host)
        let old = network.reports[0]

        service.reconnect(host)
        old.send(.connected(serial: "01P00A000000000"))

        #expect(old.link.cancelled)
        #expect(service.printers[host]?.connection == .connecting)
    }

    @Test("the camera streams only while watched, and drops its picture when unwatched")
    func camera() throws {
        let network = FakeNetwork()
        let service = network.service(secrets: try secrets())

        service.watchCamera(host)
        #expect(network.cameras.count == 1)

        let image = try #require(
            CGContext(
                data: nil, width: 2, height: 2, bitsPerComponent: 8, bytesPerRow: 0,
                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            )?.makeImage())
        network.cameras[0].send(.frame(BambuCameraFrame(image: image)))
        #expect(service.frames[host] != nil)

        service.unwatchCamera(host)
        #expect(network.cameras[0].link.cancelled)
        #expect(service.frames[host] == nil)
    }
}

@Suite("Bambu camera framing")
struct BambuFrameReaderTests {
    private func frame(_ jpeg: [UInt8]) -> Data {
        var header = [UInt8](repeating: 0, count: 16)
        let length = UInt32(jpeg.count)
        for index in 0..<4 { header[index] = UInt8(length >> (8 * UInt32(index)) & 0xFF) }
        header[8] = 1
        return Data(header + jpeg)
    }

    @Test("the login packet is 80 bytes: header, then user and code padded to 32")
    func auth() {
        let packet = [UInt8](BambuFrameReader.authPacket(accessCode: "12345678"))
        #expect(packet.count == 80)
        #expect(Array(packet.prefix(8)) == [0x40, 0, 0, 0, 0, 0x30, 0, 0])
        #expect(Array(packet[16..<20]) == Array("bblp".utf8))
        #expect(packet[20..<48].allSatisfy { $0 == 0 })
        #expect(Array(packet[48..<56]) == Array("12345678".utf8))
    }

    @Test("pictures split across reads come out whole")
    func frames() throws {
        let jpeg: [UInt8] = [0xFF, 0xD8, 1, 2, 3, 0xFF, 0xD9]
        let stream = frame(jpeg) + frame(jpeg)
        var reader = BambuFrameReader()
        reader.append(stream.prefix(10))
        #expect(try reader.next() == nil)
        reader.append(stream.dropFirst(10))
        #expect(try reader.next() == Data(jpeg))
        #expect(try reader.next() == Data(jpeg))
        #expect(try reader.next() == nil)
    }

    @Test("a stream that has lost its place is an error")
    func lostPlace() {
        var reader = BambuFrameReader()
        reader.append(frame([1, 2, 3, 4]))
        #expect(throws: BambuFrameReader.DecodingError.malformed) { try reader.next() }

        var huge = BambuFrameReader()
        huge.append(Data([0xFF, 0xFF, 0xFF, 0x7F] + [UInt8](repeating: 0, count: 12)))
        #expect(throws: BambuFrameReader.DecodingError.malformed) { try huge.next() }
    }
}
