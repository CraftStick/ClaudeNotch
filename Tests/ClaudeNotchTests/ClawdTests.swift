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
                     Props.chefHat, Props.pan, Props.pancakeFlat, Props.pancakeEdge, Props.book, Props.bookClosed, Props.bookOpening, Props.bookFront, Props.eyesReadingStart, Props.eyesReadingEnd, Props.parachute,
                     Props.arm, Props.headphonesFolded, Props.wizardHatTucked, Props.heart, Props.heartFading, Props.smallHeart,
                     Props.blush, Props.squeezedEyes, Props.eyesDown, Props.breath, Props.breathFading, Props.broom,
                     Props.wideEyes, Props.exclamation, Props.thumbUp, Props.winkShut, Props.nightcap, Props.nightcapOtherWay, Props.teaMug]
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

    /// A rest's fidgets: never one twice in a row, all of them over a rest, and not in one set order.
    @Test func fidgetsComeInNoSetOrder() {
        let rest = (0..<30).map { ClawdAnimator.pick($0, of: 4, seed: 7) }
        #expect(zip(rest, rest.dropFirst()).allSatisfy { $0 != $1 })
        #expect(Set(rest) == [0, 1, 2, 3])
        #expect(rest == (0..<30).map { ClawdAnimator.pick($0, of: 4, seed: 7) })
        #expect(rest != (0..<30).map { ClawdAnimator.pick($0, of: 4, seed: 8) })
        #expect(ClawdAnimator.pick(5, of: 1, seed: 7) == 0)
    }

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
        #expect(Set(ClawdAnimator.moodReactions.keys) == [.despair, .shrug, .sparkler, .rocket, .thanks, .flinch, .phew, .proud, .sweep, .surprise, .thumbs, .stretch])
        let moods = [("compacting", ClawdAnimator.compacting), ("rate limit", ClawdAnimator.rateLimit), ("searching", ClawdAnimator.searching)].compactMap { name, pastime in
            pastime.map { (name, $0) }
        }
        #expect(moods.count == 3)
        let all = ClawdAnimator.pastimes.enumerated().map { ("pastime \($0.offset)", $0.element) }
            + ClawdAnimator.reactions.map { ("reaction \($0.key)", $0.value) }
            + ClawdAnimator.moodReactions.map { ("mood \($0.key)", $0.value) } + moods
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
        // Also compacting, after the rate limit, with the context nearly full, and late at night.
        let late = Calendar.current.date(bySettingHour: 2, minute: 0, second: 0, of: start)!
        for (phase, extra) in [(Phase.thinking, ""), (.tool, ""), (.waiting, ""), (.done, ""), (.stopped, ""), (.failed, ""),
                               (.tool, "compacting"), (.failed, "rate limit"), (.tool, "full"), (.thinking, "full"), (.tool, "search")] {
            for cue in [nil, Cue.celebrate, .facepalm, .despair, .rocket] {
                let start = extra == "full" ? late : start
                var s = Session(id: "s", turnStart: start, lastEvent: start)
                s.syncMotion(at: start)
                s.phase = phase
                if extra == "compacting" { s.activity = .compacting }
                if extra == "search" { s.activity = Describe.tool("Grep", ["pattern": "TODO"]) }
                if extra == "rate limit" { s.rateLimited = true }
                if extra == "full" { s.contextTokens = 196_000 }
                s.syncMotion(at: start)
                if let cue { s.play(cue, at: start) }
                let animator = ClawdAnimator(session: s, laptop: laptop, waving: waving)
                for t in stride(from: 0.0, through: Store.restDuration + 10, by: 0.7) {
                    Self.check(animator.frame(at: start + t), "\(phase) \(extra) \(cue.map { "\($0)" } ?? "")")
                }
            }
        }
    }

    /// A rate limit right after you ask, while the light bulb is still up: the hourglass once it's down.
    @Test(.enabled(if: ClawdTests.hasSprites, "needs Claude.app"))
    func theHourglassComesAfterTheLightBulb() throws {
        let laptop = try #require(ClawdAssets.laptop), waving = try #require(ClawdAssets.waving)
        let start = Date()
        var s = Session(id: "s", turnStart: start, lastEvent: start)
        s.phase = .thinking
        s.syncMotion(at: start)
        s.play(.idea, at: start)
        s.phase = .failed
        s.rateLimited = true
        s.syncMotion(at: start + 1)
        let animator = ClawdAnimator(session: s, laptop: laptop, waving: waving)
        let idea = try #require(ClawdAnimator.reactions[.idea])
        let frames = stride(from: idea.duration, through: idea.duration + 6, by: 0.5).map { animator.frame(at: start + $0) }
        #expect(frames.contains { $0.decals.contains { $0.art.name.hasPrefix("hourglass") } })
    }

    /// A poke on the notch makes Clawd hop and wave, but not in the middle of a reaction.
    @Test(.enabled(if: ClawdTests.hasSprites, "needs Claude.app"))
    func aReactionKeepsHimBusy() throws {
        let laptop = try #require(ClawdAssets.laptop), waving = try #require(ClawdAssets.waving)
        let start = Date()
        var s = Session(id: "s", turnStart: start, lastEvent: start)
        s.play(.hello, at: start)
        let animator = ClawdAnimator(session: s, laptop: laptop, waving: waving)
        #expect(animator.frame(at: start + 0.2).busy)
        let reaction = try #require(ClawdAnimator.reactions[.hello])
        #expect(!animator.frame(at: start + reaction.duration + 1).busy)
    }

    @Test func aPastimeComesBackOnlyAfterSixOthers() {
        var random = SeededRandom(seed: 42)
        var recent: [Int] = []
        let picks = (0..<200).map { _ in ClawdAnimator.nextPastime(after: &recent, of: 16, using: &random) }
        for i in picks.indices.dropFirst(ClawdAnimator.pastimeGap) {
            #expect(!picks[(i - ClawdAnimator.pastimeGap)..<i].contains(picks[i]))
        }
        #expect(Set(picks).count == 16)  // every one of them, in time
    }

    // MARK: - Cut short

    /// Work starting mid-pastime: what he had is put away first; nothing to put away without props.
    @Test(.enabled(if: ClawdTests.hasSprites, "needs Claude.app"))
    func propsArePutAwayWhenWorkCutsIn() throws {
        let pointing = try #require(ClawdAssets.pointing), hula = try #require(ClawdAssets.hula)
        #expect(ClawdAnimator.putAway(after: ClawdAnimator.Frame(hula, 20)) != nil)
        #expect(ClawdAnimator.putAway(after: ClawdAnimator.Frame(pointing, 0, decals: [Decal(Props.mug, 24, 8)])) != nil)
        #expect(ClawdAnimator.putAway(after: ClawdAnimator.Frame(pointing, 0, decals: [Decal(Props.happyEyes, 5, 7)])) == nil)
        #expect(ClawdAnimator.putAway(after: ClawdAnimator.Frame(pointing, 0)) == nil)
    }
}
