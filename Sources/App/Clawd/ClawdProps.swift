import Foundation

/// A little picture drawn here in code, one character per pixel ("." for none) with a color for each
/// character.
struct PixelArt: Hashable {
    let name: String
    let width: Int
    let height: Int
    /// RGBA, row by row from the top.
    let rgba: [UInt8]

    init(_ name: String, _ rows: [String], _ colors: [Character: UInt32]) {
        let width = rows.map(\.count).max() ?? 0
        assert(rows.allSatisfy { $0.count == width }, "\(name): rows of different lengths")
        self.name = name
        self.width = width
        height = rows.count
        var rgba = [UInt8](repeating: 0, count: width * height * 4)
        for (y, row) in rows.enumerated() {
            for (x, char) in row.enumerated() {
                guard let color = colors[char] else { continue }
                let at = (y * width + x) * 4
                rgba[at] = UInt8(color >> 24 & 0xff)
                rgba[at + 1] = UInt8(color >> 16 & 0xff)
                rgba[at + 2] = UInt8(color >> 8 & 0xff)
                rgba[at + 3] = UInt8(color & 0xff)
            }
        }
        self.rgba = rgba
    }

    static func == (a: PixelArt, b: PixelArt) -> Bool { a.name == b.name }
    func hash(into hasher: inout Hasher) { hasher.combine(name) }
}

/// A prop on Clawd: `art` with its top-left corner at (`x`, `y`) of the sheet frame it's drawn over, in
/// that sheet's own pixels and orientation (the notch mirrors it along with him). It may reach outside
/// the sheet: a hat above it, a frying pan beside it.
struct Decal: Hashable {
    /// In front of him; behind him, showing only where he isn't; or cutting him away where the art has
    /// pixels, for an arm that's behind his back.
    enum Layer: Hashable { case front, behind, cut }

    let art: PixelArt
    let x: Int
    let y: Int
    let layer: Layer

    init(_ art: PixelArt, _ x: Int, _ y: Int, _ layer: Layer = .front) {
        self.art = art
        self.x = x
        self.y = y
        self.layer = layer
    }

    func moved(_ dx: Int, _ dy: Int) -> Decal { Decal(art, x + dx, y + dy, layer) }

    func on(_ layer: Layer) -> Decal { Decal(art, x, y, layer) }
}

/// Props for Clawd's pastimes, drawn after pictures of him with a mug of coffee, in headphones, as a
/// wizard and as a chef, and under a parachute. Clawd himself is always his own sprites from Claude.app;
/// the props are placed for the frames they go on, which the comments name.
enum Props {
    private static let body: UInt32 = 0xd9_77_57_ff
    private static let eye: UInt32 = 0x14_14_13_ff

    // MARK: Standing (Pointing frame 0): head x 4–19 from y 5, eyes at x 6–7 and 16–17, y 7–8,
    // arms at y 9–12 out to x 0 and x 23. Raised (7–14), the hands' top row is y 0.

    /// An arm, to cut away while its hand is behind his back: at (0, 9) or (20, 9).
    static let arm = PixelArt("arm", Array(repeating: "xxxx", count: 4), ["x": 0xff_ff_ff_ff])

    /// Held by its handle in the hand at x 23: put at (24, 8), or (23, 6) for a sip.
    static let mug = PixelArt("mug", [
        "..rkkkkr",
        "hhwwwwww",
        "h.wwwwww",
        "hhwwwwww",
        "..swwwws",
        "...ssss.",
    ], ["r": 0xe2_cb_a3_ff, "k": 0x4a_2c_1d_ff, "w": 0xf6_e7_cc_ff, "s": 0xd2_b9_8f_ff, "h": 0xe2_cb_a3_ff])

    static let steam = PixelArt("steam", ["s"], ["s": 0xdd_dd_dd_ff])
    static let steamFading = PixelArt("steamFading", ["s"], ["s": 0x80_80_80_ff])

    /// Eyes shut in a smile, "^ ^": at (5, 7).
    static let happyEyes = PixelArt("happyEyes", [
        "bxxb......bxxb",
        "xbbx......xbbx",
    ], ["b": body, "x": eye])

    /// Eyes shut, "— —": at (5, 7).
    static let closedEyes = PixelArt("closedEyes", [
        ".bb........bb.",
        "xxx........xxx",
    ], ["b": body, "x": eye])

    /// Over the head and on both ears: at (1, 3); (1, -1), held by the band, on his raised hands.
    static let headphones = PixelArt("headphones", [
        "....BBBBBBBBBBBBBB....",
        "..BB..............BB..",
        "CCC................CCC",
        "CHC................CHC",
        "CHC................CHC",
        "CCC................CCC",
    ], ["B": 0x2d_4f_9e_ff, "C": 0x23_40_8a_ff, "H": 0x4f_78_d0_ff])

    /// The headphones folded up, narrow enough to be out of sight behind him: at (5, y).
    static let headphonesFolded = PixelArt("headphonesFolded", [
        "..BBBBBBBBBB..",
        ".B..........B.",
        "CCC........CCC",
        "CHC........CHC",
        "CHC........CHC",
        "CCC........CCC",
    ], ["B": 0x2d_4f_9e_ff, "C": 0x23_40_8a_ff, "H": 0x4f_78_d0_ff])

    /// "♪" the right way round once mirrored.
    static let note = PixelArt("note", [
        "nn.",
        ".n.",
        ".n.",
        ".nn",
        ".nn",
    ], ["n": 0xf2_df_b5_ff])

    // MARK: Pointing (frame 24): turned, head x 4–19 from y 5, eyes at x 8–9 and 18–19, y 7–8,
    // the near arm out at y 8–11 to x 26.

    /// At (2, -5): the brim rests on the head; (2, -10) on his raised hands.
    static let wizardHat = PixelArt("wizardHat", [
        "............DD......",
        "...........BD.......",
        "..........BBD.......",
        ".........BBBD.......",
        "........BBBBBD......",
        ".......BBBBBBD......",
        "......YYYYYYYYY.....",
        "......BBBBBBBBBD....",
        ".....BBBBBBBBBBBD...",
        "DBBBBBBBBBBBBBBBBBBD",
    ], ["B": 0x2f_4f_9a_ff, "D": 0x1c_32_68_ff, "Y": 0xf2_df_b5_ff])

    /// The wizard's hat held behind him, the brim's tips out of sight: at (2, y) like the hat.
    static let wizardHatTucked = PixelArt("wizardHatTucked", [
        "............DD......",
        "...........BD.......",
        "..........BBD.......",
        ".........BBBD.......",
        "........BBBBBD......",
        ".......BBBBBBD......",
        "......YYYYYYYYY.....",
        "......BBBBBBBBBD....",
        ".....BBBBBBBBBBBD...",
        "..DBBBBBBBBBBBBBBD..",
    ], ["B": 0x2f_4f_9a_ff, "D": 0x1c_32_68_ff, "Y": 0xf2_df_b5_ff])

    /// From the hand up and away: at (27, 4).
    static let wand = PixelArt("wand", [
        "...w",
        "..w.",
        ".w..",
        "w...",
    ], ["w": 0x8b_5a_34_ff])

    /// The wand's star: at (30, 1).
    static let star = PixelArt("star", [
        ".y.",
        "yYy",
        ".y.",
    ], ["y": 0xff_d2_3f_ff, "Y": 0xff_f3_b0_ff])

    static let sparkle = PixelArt("sparkle", ["y"], ["y": 0xff_e0_6a_ff])
    static let bigSparkle = PixelArt("bigSparkle", [
        ".y.",
        "yyy",
        ".y.",
    ], ["y": 0xff_e0_6a_ff])

    /// One eye shut: at (18, 7).
    static let wink = PixelArt("wink", ["bb"], ["b": body])

    /// At (4, -4): sits on the head; (4, -9) on his raised hands.
    static let chefHat = PixelArt("chefHat", [
        "....WW....WW....",
        "..WWWWW..WWWWW..",
        ".WWWWWWWWWWWWWW.",
        ".WWWWWWWWWWWWWW.",
        "..WWWWWWWWWWWW..",
        "..SWWWWWWWWWWS..",
        "..WWWWWWWWWWWW..",
        "..WWWWWWWWWWWW..",
        "..SSSSSSSSSSSS..",
    ], ["W": 0xf4_f1_ea_ff, "S": 0xd6_d0_c2_ff])

    /// Held out by the handle: at (27, 8). Grey rather than black, or it would melt into the notch.
    static let pan = PixelArt("pan", [
        "...RRRRRRRRR",
        "HHHPPPPPPPPP",
        "....PPPPPPP.",
    ], ["R": 0x9a_9f_a8_ff, "P": 0x5c_5f_66_ff, "H": 0x8b_5a_34_ff])

    static let pancakeFlat = PixelArt("pancakeFlat", ["fFFf"], ["f": 0xe0_a8_30_ff, "F": 0xf5_c5_42_ff])
    static let pancakeEdge = PixelArt("pancakeEdge", ["F", "f"], ["f": 0xe0_a8_30_ff, "F": 0xf5_c5_42_ff])

    // MARK: Sitting (Meditating frames 8–51): head x 4–19 from y 1 or 2, as he breathes.

    /// An open book spread over his head while he dozes: its cover on the head's top row, at x 2.
    static let book = PixelArt("book", [
        "...wwwwww..wwwwww...",
        "..wwwwwwwsswwwwwww..",
        ".pwwwwwwwsswwwwwwwp.",
        "cppppppppssppppppppc",
        "cccccccccCCccccccccc",
    ], ["w": 0xf6_e9_cc_ff, "p": 0xe6_cf_a0_ff, "s": 0xd8_b9_8a_ff, "c": 0xb8_74_2e_ff, "C": 0x8f_55_20_ff])

    // MARK: Arms up (JumpingHappy frame 8): arms x 5–8 and 15–18 from y 0.

    /// The canopy and its lines down to both hands: at (-1, -10). Low enough that all of it fits in
    /// the notch once he's down.
    static let parachute = PixelArt("parachute", [
        "......BBBBBBBBBBBBBB......",
        "...BBBBBCCCCCCCCCCBBBBB...",
        ".BBBBBBCCCCCCCCCCCCBBBBBB.",
        "BBBBBBBBBBBBBBBBBBBBBBBBBB",
        "DDD....DDD......DDD....DDD",
        "..l.....l........l.....l..",
        "...l....l........l....l...",
        "....l...l........l...l....",
        ".....l..l........l..l.....",
        "......l.l........l.l......",
    ], ["B": 0x2f_5a_a8_ff, "C": 0xf3_e3_c4_ff, "D": 0x1e_3c_78_ff, "l": 0xc8_cc_d2_ff])

    // MARK: Turned aside (Turning frame 8): eyes at x 9–10 and 17–18, y 3–4.

    /// Eyes shut in a smile, "^ ^": at (8, 3).
    static let happyEyesTurned = PixelArt("happyEyesTurned", [
        "bxxb....bxxb",
        "xbbx....xbbx",
    ], ["b": body, "x": eye])

    /// Eyes shut, "— —": at (9, 3).
    static let closedEyesTurned = PixelArt("closedEyesTurned", [
        "bb......bb",
        "xx......xx",
    ], ["b": body, "x": eye])

    /// Eyes down, on something on the ground beside him: at (9, 3).
    static let eyesDownTurned = PixelArt("eyesDownTurned", [
        "bb......bb",
        "xx......xx",
        "xx......xx",
    ], ["b": body, "x": eye])

    /// Eyes up, after something rising beside him: at (9, 2).
    static let eyesUpTurned = PixelArt("eyesUpTurned", [
        "xx......xx",
        "xx......xx",
        "bb......bb",
    ], ["b": body, "x": eye])

    // MARK: Moods (the eyes on Pointing frame 0, standing; the rest beside him turned, on the ground at y 16)

    /// His eyes turned up, at something above him: at (6, 7).
    static let eyesUp = PixelArt("eyesUp", [
        "xx........xx",
        "bb........bb",
    ], ["b": body, "x": eye])

    /// A drop of sweat running down the back of his head while the context fills up.
    static let sweat = PixelArt("sweat", [
        ".h.",
        "hld",
        "lld",
        ".d.",
    ], ["h": 0xf4_fb_ff_ff, "l": 0x9a_d8_ff_ff, "d": 0x5a_a8_e0_ff])

    private static let cardboard: [Character: UInt32] = [
        "B": 0xc9_96_5b_ff, "b": 0xd9_a8_6a_ff, "d": 0x9c_68_36_ff, "k": 0x4a_30_18_ff, "F": 0xe0_b4_78_ff, "t": 0xec_dc_b4_ff,
    ]

    /// An open cardboard box on the ground beside him, his papers going into it: at (25, 9).
    static let box = PixelArt("box", [
        "F.........F",
        ".F.......F.",
        "dkkkkkkkkkb",
        "dBBBBBBBBBb",
        "dBBBttBBBBb",
        "dBBBBBBBBBb",
        "dBBBBBBBBBb",
        "ddddddddddd",
    ], cardboard)

    /// The box shut with them in it: at (25, 9).
    static let boxShut = PixelArt("boxShut", [
        "...........",
        "...........",
        "FFFFFFFFFFF",
        "dBBBBttBBBb",
        "dBBBttBBBBb",
        "dBBBBBBBBBb",
        "dBBBBBBBBBb",
        "ddddddddddd",
    ], cardboard)

    /// A sheet of paper with lines on it, flat and tumbling, flying into the box.
    static let paper = PixelArt("paper", [
        "wwww",
        "wllw",
        "wwww",
        "wllw",
        "wwwW",
    ], ["w": 0xfa_f7_ef_ff, "l": 0xa8_b4_c4_ff, "W": 0xd8_d2_c4_ff])
    static let paperTumbling = PixelArt("paperTumbling", [
        "wwwww",
        "wlllw",
        "wwwwW",
    ], ["w": 0xfa_f7_ef_ff, "l": 0xa8_b4_c4_ff, "W": 0xd8_d2_c4_ff])

    /// A puff of dust where something lands: small, then spreading and thinning out.
    static let puff = PixelArt("puff", ["p.p", ".p."], ["p": 0xd8_cf_c0_ff])
    static let puffWide = PixelArt("puffWide", ["p...p", ".p.p."], ["p": 0xb8_b0_a4_ff])

    /// "?" over his head: at (12, -4). Drawn the wrong way round, as the notch mirrors it with him.
    static let question = PixelArt("question", [
        ".qqq",
        "q..Q",
        "...q",
        "..q.",
        ".q..",
        "....",
        ".q..",
    ].map { String($0.reversed()) }, ["q": 0xfa_f7_ef_ff, "Q": 0xd8_d2_c4_ff])

    /// An hourglass beside him: two glass bulbs meeting at a narrow neck between wooden caps, `level` of
    /// its 9 grains of sand run down, a stream through the neck while they fall: at (25, 6).
    static func hourglass(_ level: Int, running: Bool) -> PixelArt {
        let level = max(0, min(9, level))
        var rows = ["DWWWWWWWW",
                    ".DWWWWWW.",
                    ".G.....g.",
                    "..G...g..",
                    "...G.g...",
                    "....g....",
                    "...G.g...",
                    "..G...g..",
                    ".G.....g.",
                    ".DWWWWWW.",
                    "DWWWWWWWW"]
        func put(_ row: Int, _ column: Int, _ c: Character) {
            var chars = Array(rows[row])
            chars[column] = c
            rows[row] = String(chars)
        }
        // The top bulb's sand from its surface down; the bottom's heaped up from the floor.
        let top = [(2, 2), (2, 6), (2, 3), (2, 5), (2, 4), (3, 3), (3, 5), (3, 4), (4, 4)]
        let bottom = [(8, 4), (8, 3), (8, 5), (8, 2), (8, 6), (7, 4), (7, 3), (7, 5), (6, 4)]
        for (i, cell) in top.enumerated() where i >= level { put(cell.0, cell.1, "s") }
        for (i, cell) in bottom.enumerated() where i < level { put(cell.0, cell.1, "s") }
        if running, level < 9 {
            put(5, 4, "s")
            if level < 6 { put(6, 4, "s") }  // falling on through the bottom bulb's empty top
        }
        return PixelArt("hourglass\(level)\(running ? "r" : "")", rows,
                        ["W": 0xb8_74_2e_ff, "D": 0x8f_55_20_ff, "g": 0xc4_e0_ec_ff, "G": 0x9c_b8_c6_ff, "s": 0xf1_c8_77_ff])
    }

    /// A rocket, white with a blue nose and fins and a porthole, standing beside him: at (27, 2), its
    /// nozzle on y 12.
    static let rocket = PixelArt("rocket", [
        "....n....",
        "...nnn...",
        "..nnnNn..",
        "..swwww..",
        "..wpppw..",
        "..wpLpw..",
        "..wpppw..",
        "..swwww..",
        "f.swwww.f",
        "ffswwwwff",
        "ff.kkk.ff",
    ], ["n": 0x3a_64_b8_ff, "N": 0x7a_a4_e8_ff, "w": 0xf6_f6_f2_ff, "s": 0xc8_cc_d4_ff, "p": 0x2c_4c_94_ff,
        "L": 0xc8_e8_ff_ff, "f": 0x2c_4c_94_ff, "k": 0x2a_2a_2e_ff])
    /// Its flame, in two flickers, under the nozzle.
    static let flame = PixelArt("flame", [".y.", "yYy", ".o."], ["y": 0xff_d0_4a_ff, "Y": 0xff_f6_c8_ff, "o": 0xf5_8a_2a_ff])
    static let flameLong = PixelArt("flameLong", ["yYy", "yYy", ".y.", ".o."], ["y": 0xff_d0_4a_ff, "Y": 0xff_f6_c8_ff, "o": 0xf5_8a_2a_ff])
    static let spark = PixelArt("spark", ["y"], ["y": 0xff_d0_4a_ff])

    /// The launch button in his hand: at (21, 5); pressed, the red button down and lit.
    static let remote = PixelArt("remote", ["..r..", "kkkkk", "kKKKk"], ["r": 0xd8_3a_2a_ff, "k": 0x26_26_2a_ff, "K": 0x3c_3c_44_ff])
    static let remotePressed = PixelArt("remotePressed", [".....", "kkRkk", "kKKKk"], ["R": 0xff_5a_3a_ff, "k": 0x26_26_2a_ff, "K": 0x3c_3c_44_ff])

    // MARK: Searching (turned, Turning frame 8)

    private static let tweed: [Character: UInt32] = [
        "o": 0x2e_26_22_ff, "h": 0x7a_6a_5e_ff, "H": 0x5e_50_48_ff, "l": 0x94_84_76_ff, "b": 0x6a_5a_4e_ff,
    ]

    /// A deerstalker, its brim on the top of his head, ear flaps tied up on top: at (2, -6).
    static let deerstalker = PixelArt("deerstalker", [
        "......oo....oo......",
        ".......oooooo.......",
        ".....ohhlhhHhho.....",
        "....ohhlhhhHhhhho...",
        "...ohhlhhhhHhhhhho..",
        "..oooooooooooooooo..",
        "obbbbbbbbbbbbbbbbbbo",
        ".oooooooooooooooooo.",
    ], tweed)

    /// A big magnifying glass held up beside his narrowed eye, a glint on the glass, its handle down to
    /// his hand: at (19, -1).
    static let magnifier = PixelArt("magnifier", [
        "..kkkk..",
        ".kggwwk.",
        "kGgggwwk",
        "kGggggwk",
        "kGgggggk",
        "kGGggggk",
        ".kGGGGk.",
        "..kkkk..",
        "...hh...",
        "...hh...",
        "..hh....",
    ], ["k": 0x26_26_2a_ff, "w": 0xff_ff_ff_ff, "g": 0xd8_e2_e8_ff, "G": 0xa8_b6_c0_ff, "h": 0x5a_3a_22_ff])

    /// The eye behind the glass narrowed to a slit: at (17, 3).
    static let squint = PixelArt("squint", ["bb", "xx"], ["b": body, "x": eye])

    // MARK: Standing (Laptop frame 0): eyes at x 6–7 and 16–17, y 9–10.

    /// Both eyes a pixel towards his near side, or his far side: at (5, 9).
    static let eyesAsideNear = PixelArt("eyesAsideNear", [
        "bbxxbbbbbbbbxx",
        "bbxxbbbbbbbbxx",
    ], ["b": body, "x": eye])
    static let eyesAsideFar = PixelArt("eyesAsideFar", [
        "xxbbbbbbbbxxbb",
        "xxbbbbbbbbxxbb",
    ], ["b": body, "x": eye])

    // MARK: Moods (Pointing frame 0 again)

    /// A heart rising over his head when you say thanks: at about (8, -2), full, then fading.
    static let heart = PixelArt("heart", [
        ".rr.rr.",
        "rRrrrrr",
        "rrrrrrr",
        ".rrrrr.",
        "..rrr..",
        "...r...",
    ], ["r": 0xe8_4a_5f_ff, "R": 0xff_b0_bc_ff])
    static let heartFading = PixelArt("heartFading", [
        ".rr.rr.",
        "rrrrrrr",
        "rrrrrrr",
        ".rrrrr.",
        "..rrr..",
        "...r...",
    ], ["r": 0x8a_3a_46_ff])
    static let smallHeart = PixelArt("smallHeart", ["r.r", "rrr", ".r."], ["r": 0xe8_4a_5f_ff])

    /// Pink cheeks, just under the eyes: at (5, 9).
    static let blush = PixelArt("blush", [
        "pp..........pp",
    ], ["p": 0xf2_9a_a0_ff])

    /// Eyes squeezed shut, "> <": over both eyes, at (5, 6).
    static let squeezedEyes = PixelArt("squeezedEyes", [
        "xbb........bbx",
        "bxx........xxb",
        "xbb........bbx",
    ], ["b": body, "x": eye])

    /// Eyes down, sheepish: at (6, 7).
    static let eyesDown = PixelArt("eyesDown", [
        "bb........bb",
        "xx........xx",
        "xx........xx",
    ], ["b": body, "x": eye])

    /// A breath out in front of him: "~" at (24, 8).
    static let breath = PixelArt("breath", [".ww.w", "w..w."], ["w": 0xe6_ee_f4_ff])
    static let breathFading = PixelArt("breathFading", [".ww.w", "w..w."], ["w": 0x8c_94_9a_ff])

    /// A broom held in the hand at x 23, its bristles on the ground: at (19, 7), moved a pixel or two to sweep.
    static let broom = PixelArt("broom", [
        "..h..",
        "..h..",
        "..h..",
        "..h..",
        "..h..",
        "..h..",
        "..h..",
        "..h..",
        "..h..",
        "..h..",
        ".ttt.",
        "sSsSs",
        "sSsSs",
        "s.s.s",
    ], ["h": 0x9a_62_32_ff, "t": 0xc0_3a_2e_ff, "s": 0xe0_bc_5a_ff, "S": 0xc8_9c_3c_ff])

    /// Eyes wide in surprise, round and a pixel bigger each way: over both eyes, at (5, 6).
    static let wideEyes = PixelArt("wideEyes", [
        "bxxb......bxxb",
        "xxxx......xxxx",
        "xxxx......xxxx",
        "bxxb......bxxb",
    ], ["b": body, "x": eye])

    /// "!" over his head: at (11, -5).
    static let exclamation = PixelArt("exclamation", [
        "ee",
        "ee",
        "ee",
        "ee",
        "..",
        "ee",
    ], ["e": 0xff_d0_4a_ff])

    /// A thumb up in the hand at the end of his arm: at (21, 3), over the arm at y 9.
    static let thumbUp = PixelArt("thumbUp", [
        ".bb.",
        ".bb.",
        "bbbb",
        "bbbs",
        "bbbs",
        "bbbs",
    ], ["b": body, "s": 0xb8_5f_44_ff])

    /// One eye shut, a wink: over the eye at x 16–17, at (16, 7).
    static let winkShut = PixelArt("winkShut", ["bb", "xx"], ["b": body, "x": eye])

    /// A nightcap on top of his head, its tip drooping behind him with a pompom: at (head x, head top − 4).
    static let nightcap = PixelArt("nightcap", [
        "p...............",
        ".bbbb...........",
        "...bbbbbbbb.....",
        "..bbbbbbbbbbbbb.",
        "wwwwwwwwwwwwwwww",
    ], ["b": 0x3a_4f_9a_ff, "w": 0xf4_f0_e6_ff, "p": 0xf4_f0_e6_ff])

    /// The coffee mug with tea in it instead, its tag hanging over the rim: late at night.
    static let teaMug = PixelArt("teaMug", [
        "..roooor.",
        "hhwwwwwwt",
        "h.wwwwwwT",
        "hhwwwwww.",
        "..swwwws.",
        "...ssss..",
    ], ["r": 0xe2_cb_a3_ff, "o": 0xb8_6a_1c_ff, "w": 0xf6_e7_cc_ff, "s": 0xd2_b9_8f_ff, "h": 0xe2_cb_a3_ff,
        "t": 0xc8_c8_c0_ff, "T": 0x6a_9a_4a_ff])
}
