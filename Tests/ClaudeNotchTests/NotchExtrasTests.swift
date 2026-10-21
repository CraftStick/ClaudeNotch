import CoreGraphics
import Foundation
import Testing
@testable import ClaudeNotch

struct NotchExtrasTests {
    @Test func theClockIsTheDefault() {
        #expect(NotchExtra(rawValue: "nonsense") == nil)
        #expect(NotchExtra.allCases.map(\.rawValue) == ["clock", "sky", "battery", "wave", "none"])
        #expect(NotchExtra.available.contains(.clock) && NotchExtra.available.contains(.none))
    }

    @Test func theSkyFollowsTheClock() throws {
        func at(_ hour: Int) throws -> (PixelSkyView.Time, Int) {
            let date = try #require(Calendar.current.date(bySettingHour: hour, minute: 30, second: 0, of: Date()))
            let (time, next) = PixelSkyView.time(at: date)
            return (time, next)
        }
        #expect(try at(12) == (.day, 18))
        #expect(try at(6) == (.dusk, 8))
        #expect(try at(19) == (.dusk, 21))
        #expect(try at(23) == (.night, 5))
        #expect(try at(2) == (.night, 5))
    }

    @Test func skyPicturesFitTheirSpace() {
        for art in [PixelSkyView.sun, PixelSkyView.sunset, PixelSkyView.moon, PixelSkyView.star, PixelSkyView.dot] {
            #expect(art.width <= 13 && art.height <= 9, "\(art.name)")
        }
    }

    @Test func theBatteryIsDrawnForAnyLevel() throws {
        for level in [0, 5, 15, 30, 50, 76, 100] {
            for charging in [false, true] {
                let picture = try #require(Battery.picture(level: level, charging: charging))
                #expect(picture.width == 20 && picture.height == 7)
            }
        }
    }
}
