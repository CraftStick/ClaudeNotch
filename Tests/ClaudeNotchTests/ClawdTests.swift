import AppKit
import Testing
@testable import ClaudeNotch

struct ClawdTests {
    // MARK: - Sprite sheets

    /// Two sheets the way Claude.app's bundle writes them: deltas as an array of strings, or as one
    /// string split on "(".
    static let bundle = #"""
        var x={Tiny:{cat:"idle",w:2,h:2,fps:8,palette:["#ff0000","#00ff00"],base:"01.1",deltas:["0.,31"],a0:[0,0,2,2]},Other:{cat:"idle",w:1,h:2,fps:8,palette:["#0000ff"],base:"0.",deltas:"0.(10",a0:[0,0,1,2]},Broken:{cat:"idle",w:1,h:1,fps:8,palette:["#000000"],base:"5",deltas:[]}};
        """#

    @Test func sheetsAreReadFromTheBundle() throws {
        let sheets = ClawdAssets.parse(Self.bundle)
        let tiny = try #require(sheets["Tiny"])
        #expect(tiny.width == 2 && tiny.height == 2)
        #expect(tiny.palette.count == 2)
        #expect(tiny.frames == [[0, 1, 255, 1], [255, 1, 255, 1]])
        #expect(tiny.anchor == CGPoint(x: 1, y: 2))

        let other = try #require(sheets["Other"])
        #expect(other.frames == [[0, 255], [255, 255], [255, 0]])

        // A pixel with no colour in the palette: the sheet is skipped rather than drawn wrong.
        #expect(sheets["Broken"] == nil)
    }

    // MARK: - Props

    /// Every prop is drawn as a rectangle of pixels (PixelArt asserts it in debug builds), with
    /// every pixel in its picture.
    @Test func propsAreWhole() {
        let props = [Props.mug, Props.steam, Props.steamFading, Props.happyEyes, Props.closedEyes, Props.headphones,
                     Props.note, Props.wizardHat, Props.wand, Props.star, Props.sparkle, Props.bigSparkle, Props.wink,
                     Props.chefHat, Props.pan, Props.pancakeFlat, Props.pancakeEdge, Props.book, Props.parachute]
        #expect(Set(props.map(\.name)).count == props.count)
        for art in props {
            #expect(art.width > 0 && art.height > 0, "\(art.name)")
            #expect(art.rgba.count == art.width * art.height * 4, "\(art.name)")
            #expect(art.rgba.contains { $0 != 0 }, "\(art.name)")
        }
    }

    @Test func pixelArtTakesItsColors() {
        let art = PixelArt("test", ["a.", ".b"], ["a": 0x11_22_33_ff, "b": 0xaa_bb_cc_80])
        #expect(art.rgba == [0x11, 0x22, 0x33, 0xff, 0, 0, 0, 0, 0, 0, 0, 0, 0xaa, 0xbb, 0xcc, 0x80])
        #expect(CGImage.pixels(art.rgba, width: 2, height: 2) != nil)
        #expect(CGImage.pixels(art.rgba, width: 3, height: 2) == nil)
    }

    // MARK: - Clock

    @Test func theSameSeedPlaysOutTheSameWay() {
        var a = SeededRandom(seed: 42), b = SeededRandom(seed: 42), c = SeededRandom(seed: 43)
        let first = (0..<5).map { _ in a.next() }
        #expect(first == (0..<5).map { _ in b.next() })
        #expect(first != (0..<5).map { _ in c.next() })
    }

    // MARK: - With Claude.app's sprites

    static let hasSprites = ClawdAssets.laptop != nil && ClawdAssets.waving != nil

    private static func check(_ frame: ClawdAnimator.Frame, _ what: String) {
        #expect(frame.sheet.frames.indices.contains(frame.index), "\(what): frame \(frame.index) of \(frame.sheet.name)")
        #expect(frame.rate > 0, "\(what)")
    }

    /// Every pastime and reaction, a frame every 50 ms from start to end, shows a frame its sheet has.
    @Test(.enabled(if: ClawdTests.hasSprites, "needs Claude.app"))
    func everyPastimeAndReactionHasItsFrames() {
        #expect(ClawdAnimator.pastimes.count >= 10)
        #expect(Set(ClawdAnimator.reactions.keys) == [.idea, .excited, .facepalm, .celebrate, .hello, .arrive])
        let all = ClawdAnimator.pastimes.enumerated().map { ("pastime \($0.offset)", $0.element) }
            + ClawdAnimator.reactions.map { ("reaction \($0.key)", $0.value) }
        for (what, pastime) in all {
            #expect(pastime.duration > 0, "\(what)")
            for t in stride(from: 0, through: pastime.duration, by: 0.05) {
                Self.check(pastime.frame(t), what)
            }
        }
    }

    /// Clawd in every phase, from the moment it starts until long after: through the hops and sighs at the
    /// end of a turn, the fidgets, the doze and the walk off.
    @Test(.enabled(if: ClawdTests.hasSprites, "needs Claude.app"))
    func everyPhaseHasItsFrames() throws {
        let laptop = try #require(ClawdAssets.laptop), waving = try #require(ClawdAssets.waving)
        let start = Date()
        for phase in [Phase.thinking, .tool, .waiting, .done, .stopped, .failed] {
            for cue in [nil, Cue.celebrate, .facepalm] {
                var s = Session(id: "s", turnStart: start, lastEvent: start)
                s.syncMotion(at: start)
                s.phase = phase
                s.syncMotion(at: start)
                if let cue { s.play(cue, at: start) }
                let animator = ClawdAnimator(session: s, laptop: laptop, waving: waving)
                for t in stride(from: 0.0, through: Store.restDuration + 10, by: 0.7) {
                    Self.check(animator.frame(at: start + t), "\(phase) \(cue.map { "\($0)" } ?? "")")
                }
            }
        }
    }
}
