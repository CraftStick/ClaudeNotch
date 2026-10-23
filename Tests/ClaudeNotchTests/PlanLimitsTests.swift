import Foundation
import Testing
@testable import ClaudeNotch

struct PlanLimitsTests {
    @Test func parsesTheLimitsThereAreAndSkipsTheRest() throws {
        let json = #"""
        {"five_hour":{"utilization":100.0,"resets_at":"2026-10-23T20:00:00.123456+00:00"},
         "seven_day":{"utilization":3,"resets_at":"2026-10-30T10:00:00+00:00"},
         "seven_day_opus":null,"seven_day_oauth_apps":null}
        """#
        let limits = try #require(PlanLimit.parse(Data(json.utf8)))
        #expect(limits.map(\.kind) == [.session, .weekly])
        #expect(limits[0].exhausted)
        #expect(!limits[1].exhausted)
        #expect(limits[0].resets != nil)
        #expect(limits[1].resets == Date(timeIntervalSince1970: 1_793_354_400))
        #expect(PlanLimit.parse(Data(#"{"error":"nope"}"#.utf8)) == nil)
    }

    @Test func resetTextSaysHowLongWithinADay() {
        let now = Date(timeIntervalSince1970: 0)
        let limit = PlanLimit(kind: .session, used: 100, resets: now.addingTimeInterval(4 * 3600 + 50 * 60 + 30))
        let text = limit.resetText(from: now)
        #expect(text == "Сброс через 4 ч 51 мин" || text == "Resets in 4 h 51 min")
    }
}
