import Foundation
import Testing
@testable import EdgeControl

@Suite("Tracked packages")
struct TrackedPackageTests {
    private let added = Date(timeIntervalSince1970: 1_791_475_200)

    @Test("a package is stored in the config and read back as it was")
    func roundTrip() {
        let packages = [
            TrackedPackage(number: "1z5r 8939 0357 5671 27", name: " Desk lamp ", added: added),
            TrackedPackage(number: "LP00123456789012", carrier: .dhl, added: added),
        ]
        let stored = TrackedPackage.encode(packages)
        #expect(TrackedPackage.decode(stored) == packages)
        #expect(packages[0].number == "1Z5R89390357567127")
        #expect(packages[0].name == "Desk lamp")
        #expect(packages[0].carrier == .ups)
        #expect(packages[1].carrier == .dhl)
    }

    @Test("entries that don't read are skipped, not the whole list")
    func damaged() {
        let good = TrackedPackage.encode([TrackedPackage(number: "TBA000000000000", added: added)])
        #expect(TrackedPackage.decode(["{", "null"] + good).map(\.carrier) == [.amazon])
    }

    @Test("a number nobody recognises goes to Other, and a package without a name is named for its carrier")
    func defaults() {
        let unknown = TrackedPackage(number: "LP00123456789012", added: added)
        #expect(unknown.carrier == .other)
        #expect(unknown.title == "Other package")
        #expect(TrackedPackage(number: "TBA000000000000", added: added).title == "Amazon package")
        #expect(TrackedPackage(number: "1Z5R89390357567127", name: "Lamp").title == "Lamp")
    }

    @Test("numbers read in fours")
    func spaced() {
        #expect(TrackedPackage(number: "1Z5R89390357567127").spacedNumber == "1Z5R 8939 0357 5671 27")
        #expect(TrackedPackage(number: "TBA000000000000").spacedNumber == "TBA0 0000 0000 000")
    }

    @Test("new numbers go on top, and ones already listed aren't added again")
    func adding() {
        let list = [TrackedPackage(number: "TBA000000000000", added: added)]
        let (updated, new) = TrackedPackage.adding(
            [("1Z5R89390357567127", .ups), ("TBA000000000000", .amazon), ("986578788855", .fedex)], to: list,
            now: added)
        #expect(new.map(\.number) == ["1Z5R89390357567127", "986578788855"])
        #expect(updated.map(\.number) == ["986578788855", "1Z5R89390357567127", "TBA000000000000"])
    }

    @Test("packages leave the list once they're older than it keeps them")
    func pruning() {
        let now = added
        let day: TimeInterval = 86_400
        let list = [
            TrackedPackage(number: "TBA000000000000", added: now.addingTimeInterval(-3 * day)),
            TrackedPackage(number: "1Z5R89390357567127", added: now.addingTimeInterval(-20 * day)),
            TrackedPackage(number: "986578788855", added: now.addingTimeInterval(-40 * day)),
        ]
        #expect(TrackedPackage.pruned(list, keep: .forever, now: now).count == 3)
        #expect(TrackedPackage.pruned(list, keep: .month, now: now).map(\.carrier) == [.amazon, .ups])
        #expect(TrackedPackage.pruned(list, keep: .twoWeeks, now: now).map(\.carrier) == [.amazon])
    }

    @Test("when a package was added reads the way people say it")
    func addedDay() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/New_York")!
        let english = Locale(identifier: "en_US")
        let day: TimeInterval = 86_400
        let say = { (date: Date) in AddedDay.name(date, now: added, calendar: calendar, locale: english) }
        #expect(say(added) == "today")
        #expect(say(added.addingTimeInterval(-day)) == "yesterday")
        #expect(say(added.addingTimeInterval(-3 * day)) == "Monday")
        #expect(say(added.addingTimeInterval(-10 * day)) == "Sep 28")
    }
}
