import Foundation

/// The carriers whose tracking numbers can be recognised, and where each
/// one's tracking page is.
public enum Carrier: String, CaseIterable, Codable, Sendable {
    case ups
    case usps
    case fedex
    case dhl
    case amazon
    case ontrac
    case canadaPost
    case royalMail
    /// A number no format here recognises: 17TRACK follows most of the
    /// world's carriers on a public page, with no account.
    case other

    public var name: String {
        switch self {
        case .ups: "UPS"
        case .usps: "USPS"
        case .fedex: "FedEx"
        case .dhl: "DHL"
        case .amazon: "Amazon"
        case .ontrac: "OnTrac"
        case .canadaPost: "Canada Post"
        case .royalMail: "Royal Mail"
        case .other: "Other"
        }
    }

    /// Words a shipping email from this carrier would contain.
    var mentions: [String] {
        switch self {
        case .ups: ["ups"]
        case .usps: ["usps", "postal service"]
        case .fedex: ["fedex"]
        case .dhl: ["dhl"]
        case .amazon: ["amazon"]
        case .ontrac: ["ontrac", "lasership"]
        case .canadaPost: ["canada post", "postes canada"]
        case .royalMail: ["royal mail"]
        case .other: []
        }
    }

    /// The carrier's own tracking page for `number`.
    public func trackingURL(_ number: String) -> URL? {
        let page: String
        switch self {
        case .ups: page = "https://www.ups.com/track?loc=en_US&tracknum="
        case .usps: page = "https://tools.usps.com/go/TrackConfirmAction?tLabels="
        case .fedex: page = "https://www.fedex.com/fedextrack/?trknbr="
        case .dhl: page = "https://www.dhl.com/global-en/home/tracking.html?submit=1&tracking-id="
        case .amazon: page = "https://track.amazon.com/tracking/"
        case .ontrac: page = "https://www.ontrac.com/tracking/?number="
        case .canadaPost: page = "https://www.canadapost-postescanada.ca/track-reperage/en#/search?searchFor="
        case .royalMail: page = "https://www.royalmail.com/track-your-item#/tracking-results/"
        case .other: page = "https://t.17track.net/en#nums="
        }
        let safe = number.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? number
        return URL(string: page + safe)
    }
}

/// Recognises tracking numbers by their formats and check digits.
///
/// The formats and check digits follow tracking_number_data
/// (github.com/jkeen/tracking_number_data, MIT), whose sample numbers the
/// tests use. A number whose check digit is wrong is not recognised, so a
/// mistyped number isn't sent to the wrong carrier.
public enum TrackingNumber {
    struct Match: Equatable {
        let carrier: Carrier
        /// A prefix or shape no other kind of number has ("1Z…", "TBA…").
        /// Bare runs of digits aren't: a phone number passes DHL's check
        /// one time in seven.
        let distinctive: Bool
    }

    /// Uppercased, without the spaces and dashes that emails and people put
    /// into long numbers.
    public static func normalize(_ raw: String) -> String {
        raw.uppercased().filter { $0.isASCII && ($0.isLetter || $0.isNumber) }
    }

    /// The carrier a number belongs to, or nil when no format matches.
    public static func carrier(of raw: String) -> Carrier? {
        match(normalize(raw))?.carrier
    }

    /// The tracking numbers in some text: a number on its own, or a
    /// shipping email someone copied.
    ///
    /// A short text that is a single number counts even when no carrier's
    /// format fits, since that's plainly what was meant. In longer text a
    /// number counts when its format is distinctive, or when it's a bare run
    /// of digits and the text names its carrier, so order numbers and phone
    /// numbers stay out.
    public static func find(in text: String) -> [(number: String, carrier: Carrier)] {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let whole = normalize(trimmed)
        if trimmed.count <= 48, !trimmed.contains(where: \.isNewline),
            trimmed.split(whereSeparator: \.isWhitespace).allSatisfy({ $0.contains(where: \.isNumber) })
        {
            if let match = match(whole) { return [(whole, match.carrier)] }
            if looksLikeTrackingNumber(whole) { return [(whole, .other)] }
        }

        // A single short line ("Tracking: 986578788855") is about one number,
        // so any format counts there.
        let oneLine = trimmed.count <= 48 && !trimmed.contains(where: \.isNewline)
        let lowered = text.lowercased()
        var found: [(number: String, carrier: Carrier)] = []
        // Numbers are often printed in groups: "1Z 5R8 939 03 5756 7127".
        // Runs of up to eight words on a line are tried longest first, so a
        // grouped number is read whole.
        for line in text.split(whereSeparator: \.isNewline) {
            let words = line.split { !($0.isLetter || $0.isNumber) }.map(String.init)
            var start = 0
            while start < words.count {
                var next = start + 1
                for end in stride(from: min(words.count, start + 8), to: start, by: -1) {
                    let candidate = normalize(words[start..<end].joined())
                    guard (10...34).contains(candidate.count), let match = match(candidate),
                        match.distinctive || oneLine || match.carrier.mentions.contains(where: lowered.contains)
                    else { continue }
                    if !found.contains(where: { $0.number == candidate }) { found.append((candidate, match.carrier)) }
                    next = end
                    break
                }
                start = next
            }
        }
        return found
    }

    /// 8 to 35 letters and digits, at least half of them digits: worth
    /// keeping for a carrier not recognised here when pasted on its own.
    static func looksLikeTrackingNumber(_ number: String) -> Bool {
        (8...35).contains(number.count) && number.filter(\.isNumber).count >= max(6, (number.count + 1) / 2)
    }

    // MARK: - Formats

    static func match(_ number: String) -> Match? {
        let chars = Array(number)
        guard !chars.isEmpty else { return nil }
        if isUPS(chars) { return Match(carrier: .ups, distinctive: true) }
        if let country = s10(chars) { return Match(carrier: country, distinctive: true) }
        if isAmazon(chars) { return Match(carrier: .amazon, distinctive: true) }
        if isOnTrac(chars) || isLaserShip(chars) { return Match(carrier: .ontrac, distinctive: true) }
        if isDHLPrefixed(chars) { return Match(carrier: .dhl, distinctive: true) }

        let digits = chars.compactMap(\.wholeNumberValue)
        guard digits.count == chars.count else { return nil }
        if let usps = usps(digits) { return usps }
        if digits.count == 22, digits.starts(with: [9, 6]), checks(Array(digits[7...]), evens: 1, odds: 3) {
            return Match(carrier: .fedex, distinctive: true)
        }
        switch digits.count {
        case 12 where fedexExpress(digits): return Match(carrier: .fedex, distinctive: false)
        case 15 where checks(digits, evens: 1, odds: 3): return Match(carrier: .fedex, distinctive: false)
        case 16 where checks(digits, evens: 3, odds: 1): return Match(carrier: .canadaPost, distinctive: false)
        case 10...11 where dhlExpress(digits): return Match(carrier: .dhl, distinctive: false)
        default: return nil
        }
    }

    /// UPS: "1Z", fifteen letters and digits, and a check digit.
    private static func isUPS(_ chars: [Character]) -> Bool {
        guard chars.count == 18, chars[0] == "1", chars[1] == "Z" else { return false }
        return checks(chars[2...].map(digitValue), evens: 1, odds: 2)
    }

    /// USPS IMpb: 22 or 26 digits starting 91–95, perhaps after "420" and the
    /// ZIP or ZIP+4 (which can make 34 digits either way, so both are tried).
    /// Older 20-digit numbers are checked with and without the "91" that was
    /// later put in front of them.
    private static func usps(_ digits: [Int]) -> Match? {
        var candidates = [digits]
        if digits.starts(with: [4, 2, 0]) {
            candidates += [Array(digits.dropFirst(8)), Array(digits.dropFirst(12))]
        }
        for number in candidates where number.count == 22 || number.count == 26 {
            if number[0] == 9, (1...5).contains(number[1]), checks(number, evens: 3, odds: 1) {
                return Match(carrier: .usps, distinctive: true)
            }
        }
        if digits.count == 20, checks(digits, evens: 3, odds: 1) || checks([9, 1] + digits, evens: 3, odds: 1) {
            return Match(carrier: .usps, distinctive: false)
        }
        return nil
    }

    /// The Universal Postal Union's S10 format, "RR123456785GB": two letters,
    /// eight digits, a check digit and the country. It goes to that
    /// country's post when it has a page here.
    private static func s10(_ chars: [Character]) -> Carrier? {
        guard chars.count == 13, chars[0...1].allSatisfy(\.isLetter), chars[11...12].allSatisfy(\.isLetter),
            chars[2...10].allSatisfy(\.isNumber)
        else { return nil }
        let serial = chars[2...9].compactMap(\.wholeNumberValue)
        let sum = zip(serial, [8, 6, 4, 2, 3, 5, 9, 7]).map(*).reduce(0, +)
        var check = 11 - sum % 11
        if check == 10 { check = 0 }
        if check == 11 { check = 5 }
        guard check == chars[10].wholeNumberValue else { return nil }
        switch String(chars[11...12]) {
        case "US": return .usps
        case "CA": return .canadaPost
        case "GB": return .royalMail
        default: return .other
        }
    }

    /// Amazon Logistics: "TBA", "TBC" or "TBM" and twelve digits.
    private static func isAmazon(_ chars: [Character]) -> Bool {
        chars.count == 15 && chars[0] == "T" && chars[1] == "B" && "ACM".contains(chars[2])
            && chars[3...].allSatisfy(\.isNumber)
    }

    /// OnTrac: C or D and fourteen digits. The check digit covers the serial
    /// with 4 (for C) or 5 (for D) in front.
    private static func isOnTrac(_ chars: [Character]) -> Bool {
        guard chars.count == 15, chars[0] == "C" || chars[0] == "D" else { return false }
        let digits = chars.dropFirst().compactMap(\.wholeNumberValue)
        guard digits.count == 14 else { return false }
        let lead = chars[0] == "C" ? 4 : 5
        return checks((digits.first == lead ? [] : [lead]) + digits, evens: 1, odds: 2)
    }

    /// LaserShip, now part of OnTrac, has no check digit; its prefixes are
    /// distinctive enough on their own.
    private static func isLaserShip(_ chars: [Character]) -> Bool {
        if chars.count == 10, chars[0] == "L", "AIEHNX".contains(chars[1]), "123".contains(chars[2]),
            chars[3...].allSatisfy(\.isNumber)
        {
            return true
        }
        let text = String(chars)
        if chars.count == 15, text.hasPrefix("1LS7"), "12".contains(chars[4]), chars[5...].allSatisfy(\.isNumber) {
            return true
        }
        return chars.count == 15 && text.hasPrefix("1LSCX")
    }

    /// DHL Express piece IDs ("JJD…", "JVGL…") and DHL eCommerce numbers
    /// ("GM…"): no check digit, but prefixes nothing else uses.
    private static func isDHLPrefixed(_ chars: [Character]) -> Bool {
        if chars[0] == "J", let digitsStart = chars.firstIndex(where: \.isNumber), (3...4).contains(digitsStart),
            chars[1..<digitsStart].allSatisfy(\.isLetter), (9...10).contains(chars.count - digitsStart),
            chars[digitsStart...].allSatisfy(\.isNumber)
        {
            return true
        }
        return chars.count >= 12 && chars.count <= 41 && chars[0] == "G" && chars[1] == "M"
            && chars[2...].contains(where: \.isNumber)
    }

    /// DHL Express waybills: ten or eleven digits, the last the remainder of
    /// the rest divided by seven.
    private static func dhlExpress(_ digits: [Int]) -> Bool {
        digits.dropLast().reduce(0) { $0 * 10 + $1 } % 7 == digits.last
    }

    /// FedEx Express: twelve digits, weighted 3, 1, 7 from the left, then
    /// modulo 11 and 10.
    private static func fedexExpress(_ digits: [Int]) -> Bool {
        let weights = [3, 1, 7]
        let sum = digits.dropLast().enumerated().map { $0.element * weights[$0.offset % 3] }.reduce(0, +)
        return sum % 11 % 10 == digits.last
    }

    // MARK: - Check digits

    /// tracking_number_data's mod 10: the serial's digits, counted from 0 on
    /// the left, are multiplied by `evens` or `odds` in turn, and the last
    /// digit is what brings the total to a multiple of ten.
    static func checks(_ digits: [Int], evens: Int, odds: Int) -> Bool {
        guard let check = digits.last else { return false }
        let sum = digits.dropLast().enumerated().map { $0.element * ($0.offset % 2 == 0 ? evens : odds) }
            .reduce(0, +)
        return (10 - sum % 10) % 10 == check
    }

    /// UPS counts letters as digits: A is 2, B is 3, and so on, wrapping
    /// every ten.
    private static func digitValue(_ char: Character) -> Int {
        char.wholeNumberValue ?? (Int(char.asciiValue ?? 48) - 3) % 10
    }
}
