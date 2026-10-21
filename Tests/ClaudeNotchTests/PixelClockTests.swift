import CoreGraphics
import Foundation
import Testing
@testable import ClaudeNotch

struct PixelClockTests {
    @Test func theTimeIsDigitsAndAColon() {
        let text = PixelClockView.text(Date())
        #expect(text.allSatisfy { $0.isNumber || $0 == ":" })
        #expect(text.filter { $0 == ":" }.count == 1)
        #expect((4...5).contains(text.count))
    }

    @Test func theWidestTimeFits() {
        #expect(PixelClockView.width("12:59") == 17)
        #expect(PixelClockView.width("9:41") == 13)
        #expect(CGFloat(PixelClockView.width("23:59")) * PixelClockView.pixel <= PixelClockView.size.width)
    }

    @Test func digitsAreDrawnInPixels() throws {
        let picture = try #require(PixelClockView.picture("14 07"))
        #expect(picture.width == 17 && picture.height == 5)
        #expect(PixelClockView.picture("") == nil)
    }
}
