import Foundation
import Testing
@testable import EdgeControl

/// The sample numbers come from tracking_number_data
/// (github.com/jkeen/tracking_number_data, MIT): valid ones as each carrier
/// issues them, and invalid ones with a wrong check digit or prefix.
@Suite("Tracking numbers")
struct TrackingNumberTests {
    @Test(
        "recognises each carrier's numbers, spaced or not",
        arguments: [
            ("1Z5R89390357567127", Carrier.ups), ("1Z879E930346834440", .ups), ("1Z410E7W0392751591", .ups),
            ("1Z8V92A70367203024", .ups),
            ("9400111206206406260787", .usps), ("9400 1112 0108 0805 4830 16", .usps),
            ("9405803699300124287899", .usps), ("420787459400111206206406260787", .usps),
            ("4201002334249200190132607600833457", .usps), ("4201028200009261290113185417468510", .usps),
            ("9505 5110 6960 5048 6006 24", .usps), ("0307 1790 0005 2348 3741", .usps),
            ("7112 3456 7891 2345 6787", .usps), ("420 22153 9101026837331000039521", .usps),
            ("9101 1234 5678 9000 0000 13", .usps), ("7196 9010 7560 0307 7385", .usps), ("RB123456785US", .usps),
            ("986578788855", .fedex), ("477179081230", .fedex), ("799531274483", .fedex), ("790535312317", .fedex),
            ("0414 4176 0228 964", .fedex), ("5682 8361 0012 734", .fedex), ("9611020987654312345672", .fedex),
            ("3318810025", .dhl), ("73891051146", .dhl), ("8487135506", .dhl), ("JJD0099999999", .dhl),
            ("JVGL0999999990", .dhl), ("GM2951173225174494", .dhl),
            ("TBA000000000000", .amazon), ("TBC 000000000000", .amazon), ("TBM502887274000", .amazon),
            ("C11031500001879", .ontrac), ("C 110 31 500 00187 9", .ontrac), ("D10011354453707", .ontrac),
            ("LX17635036", .ontrac), ("LI 129 79072", .ontrac), ("1LS717793482164", .ontrac),
            ("1LSCXVE005BUEFX", .ontrac),
            ("0073938000549297", .canadaPost), ("7035114477138472", .canadaPost), ("RB123456785CA", .canadaPost),
            ("RB123456785GB", .royalMail), ("RB123456785CF", .other),
        ])
    func recognises(number: String, carrier: Carrier) {
        #expect(TrackingNumber.carrier(of: number) == carrier)
    }

    @Test(
        "a wrong check digit or prefix is no carrier's number",
        arguments: [
            "2Z5R89390357567127", "1Z1111111111111111", "9434611206206407667131", "0307 1790 0005 2348 3742",
            "996578788855", "5682 8361 0012 732", "9600000000000000000001", "3318810010", "3318810034",
            "C11031500001889", "D10011345983012", "0073938000549292", "RB123456786US", "TBA50288727400A", "XA17635036",
            "",
        ])
    func rejects(number: String) {
        #expect(TrackingNumber.carrier(of: number) == nil)
    }

    @Test("numbers lose their spaces, dashes and case")
    func normalizes() {
        #expect(TrackingNumber.normalize(" 1z 5r8-939 0357 5671 27\n") == "1Z5R89390357567127")
    }

    @Test("each carrier's own tracking page, and 17TRACK for the rest")
    func pages() {
        #expect(
            Carrier.ups.trackingURL("1Z5R89390357567127")?.absoluteString
                == "https://www.ups.com/track?loc=en_US&tracknum=1Z5R89390357567127")
        #expect(
            Carrier.usps.trackingURL("9400111206206406260787")?.absoluteString
                == "https://tools.usps.com/go/TrackConfirmAction?tLabels=9400111206206406260787")
        #expect(
            Carrier.amazon.trackingURL("TBA000000000000")?.absoluteString.hasSuffix("/tracking/TBA000000000000") == true
        )
        #expect(Carrier.other.trackingURL("LP00123456789012")?.host == "t.17track.net")
        #expect(Carrier.allCases.allSatisfy { $0.trackingURL("RB123456785GB") != nil })
    }

    // MARK: - Finding numbers in what was copied

    @Test("a number copied on its own, grouped or not, with or without a label")
    func onItsOwn() {
        #expect(TrackingNumber.find(in: "1Z5R89390357567127").map(\.carrier) == [.ups])
        #expect(TrackingNumber.find(in: "  1Z 5R8 939 03 5756 7127 \n").map(\.number) == ["1Z5R89390357567127"])
        #expect(TrackingNumber.find(in: "Tracking: 986578788855").map(\.carrier) == [.fedex])
    }

    @Test("a number no format knows, copied on its own, is kept for 17TRACK")
    func unknown() {
        #expect(TrackingNumber.find(in: "LP00123456789012").map(\.carrier) == [.other])
        #expect(TrackingNumber.find(in: "12345").isEmpty)
        #expect(TrackingNumber.find(in: "hello world").isEmpty)
    }

    @Test("a shipping email gives its tracking number, not its phone or order number")
    func email() {
        let email = """
            Your order #112-1234567-1234567 has shipped!
            Carrier: UPS
            Tracking number: 1Z 5R8 939 03 5756 7127
            Questions? Call 1-800-555-0199 or 3318810025.
            """
        #expect(TrackingNumber.find(in: email).map(\.number) == ["1Z5R89390357567127"])
    }

    @Test("a bare run of digits counts in a long text only when the text names its carrier")
    func mentions() {
        let fedex = "Good news: your package is on its way with FedEx.\nTrack it with 986578788855."
        #expect(TrackingNumber.find(in: fedex).map(\.carrier) == [.fedex])
        let unnamed = "Good news: your package is on its way.\nReference 986578788855 for support."
        #expect(TrackingNumber.find(in: unnamed).isEmpty)
    }

    @Test("several numbers in one paste, each once")
    func several() {
        let text = """
            Package 1: TBA000000000000
            Package 2: 9400 1112 0620 6406 2607 87
            Package 1 again: TBA000000000000
            """
        #expect(TrackingNumber.find(in: text).map(\.carrier) == [.amazon, .usps])
    }
}
