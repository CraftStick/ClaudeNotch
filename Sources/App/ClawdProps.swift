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
        self.name = name
        width = rows.map(\.count).max() ?? 0
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
    let art: PixelArt
    let x: Int
    let y: Int

    init(_ art: PixelArt, _ x: Int, _ y: Int) {
        self.art = art
        self.x = x
        self.y = y
    }
}

/// Props for Clawd's pastimes, drawn after pictures of him with a mug of coffee, in headphones, as a
/// wizard and as a chef, and under a parachute. Clawd himself is always his own sprites from Claude.app;
/// the props are placed for the frames they go on, which the comments name.
enum Props {
    private static let body: UInt32 = 0xd9_77_57_ff
    private static let eye: UInt32 = 0x14_14_13_ff

    // MARK: Standing (Laptop frame 0): head x 4–19 from y 7, eyes at x 6–7 and 16–17, y 9–10,
    // arms at y 11–14 out to x 0 and x 23.

    /// Held by its handle in the hand at x 23: put at (24, 10), or (23, 8) for a sip.
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

    /// Eyes shut in a smile, "^ ^": at (5, 9).
    static let happyEyes = PixelArt("happyEyes", [
        "bxxb......bxxb",
        "xbbx......xbbx",
    ], ["b": body, "x": eye])

    /// Eyes shut, "— —": at (5, 9).
    static let closedEyes = PixelArt("closedEyes", [
        ".bb........bb.",
        "xxx........xxx",
    ], ["b": body, "x": eye])

    /// Over the head and on both ears: at (1, 5).
    static let headphones = PixelArt("headphones", [
        "....BBBBBBBBBBBBBB....",
        "..BB..............BB..",
        "CCC................CCC",
        "CHC................CHC",
        "CHC................CHC",
        "CCC................CCC",
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

    /// At (2, -5): the brim rests on the head.
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

    /// At (4, -4): sits on the head.
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
}
