import Foundation

/// A tracking number someone added to a Packages widget.
///
/// Kept in the widget's config as one JSON string each, like the Cameras
/// widget's list, so it travels with the layout.
public struct TrackedPackage: Codable, Equatable, Identifiable, Sendable {
    public var number: String
    public var name: String
    public var carrier: Carrier
    public var added: Date

    public var id: String { number }
    /// What it was called, or "UPS package" when it wasn't given a name.
    public var title: String { name.isEmpty ? carrier.name + " package" : name }
    public var trackingURL: URL? { carrier.trackingURL(number) }

    public init(number: String, name: String = "", carrier: Carrier? = nil, added: Date = Date()) {
        self.number = TrackingNumber.normalize(number)
        self.name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        self.carrier = carrier ?? TrackingNumber.carrier(of: number) ?? .other
        self.added = added
    }

    /// "1Z5R 8939 0357 5671 27": in fours, the way carriers print them.
    public var spacedNumber: String {
        stride(from: 0, to: number.count, by: 4).map { offset in
            let start = number.index(number.startIndex, offsetBy: offset)
            return String(
                number[start..<(number.index(start, offsetBy: 4, limitedBy: number.endIndex) ?? number.endIndex)])
        }.joined(separator: " ")
    }

    // MARK: - In the config

    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = .sortedKeys
        return encoder
    }()

    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()

    /// The packages in a config's list; entries that don't read are skipped.
    public static func decode(_ entries: [String]) -> [TrackedPackage] {
        entries.compactMap { try? decoder.decode(TrackedPackage.self, from: Data($0.utf8)) }
    }

    public static func encode(_ packages: [TrackedPackage]) -> [String] {
        packages.compactMap { try? encoder.encode($0) }.compactMap { String(data: $0, encoding: .utf8) }
    }

    // MARK: - Changing the list

    /// The list with any numbers it doesn't already have added to the top,
    /// and how many were new.
    public static func adding(
        _ found: [(number: String, carrier: Carrier)], to list: [TrackedPackage], now: Date = Date()
    ) -> (list: [TrackedPackage], added: [TrackedPackage]) {
        var known = Set(list.map(\.number))
        var added: [TrackedPackage] = []
        for (number, carrier) in found where !known.contains(number) {
            known.insert(number)
            added.append(TrackedPackage(number: number, carrier: carrier, added: now))
        }
        return (added.reversed() + list, added)
    }

    /// How long a package stays on the list. A link can't tell when a
    /// package arrives, so the widget clears them out by age instead.
    public enum Keep: String, CaseIterable, Sendable {
        case forever
        case twoWeeks = "2 weeks"
        case month = "1 month"

        var days: Int? {
            switch self {
            case .forever: nil
            case .twoWeeks: 14
            case .month: 30
            }
        }
    }

    /// The list without packages older than `keep` allows.
    public static func pruned(
        _ list: [TrackedPackage], keep: Keep, now: Date = Date(), calendar: Calendar = .current
    ) -> [TrackedPackage] {
        guard let days = keep.days, let cutoff = calendar.date(byAdding: .day, value: -days, to: now) else {
            return list
        }
        return list.filter { $0.added >= cutoff }
    }
}
