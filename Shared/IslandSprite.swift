// by zayd/cold @ zayd.wtf
import SwiftUI

/// A fixed pixel canvas shared by SpringBoard and the gallery. Each pose changes features inside
/// the same silhouette. Nothing rotates the bounding box or moves the baseline of the subject.
struct IslandSprite: View {
    enum Size { case badge, side, stage }
    let look: IslandLook
    let mood: IslandMood
    let tint: Color
    var height: CGFloat
    var size: Size = .badge
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let accent = tint.resolve(in: EnvironmentValues())
        let rgb = UInt32(accent.red * 255) << 16 | UInt32(accent.green * 255) << 8 | UInt32(accent.blue * 255)
        if let image = IslandPixelArt.image(look: look, mood: mood, accent: rgb, side: size == .side, still: reduceMotion) {
            Image(decorative: image, scale: 1, orientation: .up)
                .interpolation(.none).resizable()
                .frame(width: height, height: height)
                .accessibilityHidden(true)
        }
    }
}

enum IslandPixelArt {
    // Rows stay left-aligned in the same 17-cell field. Each material has shadow, body and light.
    private struct Design {
        let rows: [String]
        let shadow: UInt32
        let body: UInt32
        let light: UInt32
        let detail: UInt32
        init(_ palette: (UInt32, UInt32, UInt32, UInt32), _ text: String) {
            (shadow, body, light, detail) = palette
            rows = text.split(separator: "/").map(String.init)
        }
    }

    private static let ghost = Design((0x655986, 0xA8A8CD, 0xD9E5EC, 0xF0A7B8),
        ".....ddd...../...ddllldd.../..dmlllhllm../..mlllllllm../.dmlewllwelm./.dmleelleelm./.dmlclllcllm./.dmllllllllm./.dmmlllmllmd./.dmmmdmmdmdd./..dd..d..dd..")
    private static let cat = Design((0x59466C, 0x857994, 0xBAB1C8, 0x9EE0B8),
        ".ld.......dl./.lmd.....dml./.lcldddddlcl./.dmmmmmlllmd./dmmllllllllmd/dmlccclllcccmd/dmlcewlllewcmd/dmmccmmmccmmd/.dmmlldllmmd./..dmlcsclmd../...ddmmmdd.../.....ddd.....")
    private static let bat = Design((0x55406B,0x9571A5,0xDBA3B3,0xFAD79D),
        ".....ld.dl...../.....lc.cl...../d....dm lmd....d/lmd..lllll..dml/lmlmdleweldmlml/.mlmmlclclmmlm./.dmcmmdmdmmcmd./..ddmdmlmdmdd../....ddmlmdd..../......dmd....../......d.d......")
    private static let batFace = Design((0x534269,0x9A78A4,0xDEAFB9,0xEFD495),
        "..ld.....dl../..lmd...dml../..lcldddlcl../...mlllllm.../..mllewlew lm../..mleeleelm../..lmccsccml../...dmlllmd.../....ddmdd....")
    private static let catEye = Design((0x525E71,0x8BC2AA,0xC2E8BE,0xF0C580),
        "...dddddd..../..dmlllllmd../.dmllewllmmd./.lmll eellmmd./..dmmecmmmd../...ddmmmdd.../.....ddd.....")
    private static let rosebud = Design((0x792F50,0xCD5877,0xF99CAB,0x8B3B52),
        "......lld..../.....lmmlmd../.....lmdmmd../.....mllmmd../......mmmd.../......gGg..../.......g...../.......g..GG./...GG..g.GGg./...gGGGgGgg../.....ggGg..../.......g.....")
    private static let sprout = Design((0x704845,0xBD775D,0xE7AA83,0xC8DCA0),
        "........cG.../.......GGGg../......GGggg../..GG...ggg.../.cGGG...g..../..gGGG.Gg..../...gggGg...../......Gg...../......Gg...../...llllllld../...lmmmmmmm../....mmmmmd.../....dmmlmd.../.....dddd....")
    private static let blossom = Design((0x67447C,0xAC79CC,0xE7B8EF,0x71505A),
        ".....ll.ll.../....lmmdmml../..lllmmmmmmll./..lmmmcccmmml/...dmmcscmmd./...lmmcccmml./..llmmmdmmml./...dmmmdmmd../.....ddgdd.../.......g..GG./...GG..g.GGg./...gGGGgGgg../.....ggGg..../.......g.....")
    private static let rose = Design((0x782D50,0xCC5577,0xFAA1AF,0x88344E),
        ".....llldd.../...llmmmmmld./..lmdllldmmd./..lmlmccdmlmd/..lmmdlmmlmmd/...dmmmddmmd./....dmmmmdd../.....dddG..../.......Gg..../.......g..GG./...GG..g.GGg./...gGGGgGgg../.....ggGg..../.......g.....")
    private static let ember = Design((0x934864,0xED7651,0xFFC680,0xFFEEB2),
        ".......l...../......lm...../.....lmmd..../.....mmml..../...l.mmllm.../...mlmlllmd../..dmlllclmmd./..dmlcccclmd./..dmlcwccmmd./...dmlclmmd../....dmmmd..../...ddd s ddd../..mmsdddsmm..")
    private static let pulse = Design((0x7D425F,0xDD687F,0xF6A4B1,0xA6DACD),
        "..lld...lld../.lmmmd.dmmmd./lmllmmmmmmlmd/lmhwmmmmmmmmd/.lmmlmmcmmmd./.mmccmcmmcmd./..dm mccmmmd../...dmmmmmd.../....dmmmd..../.....dmd...../......d......")
    private static let pip = Design((0x826C77,0xBBA8AC,0xF1DCC8,0xF0A1AA),
        "...ld...ld.../...lcl..lcl../...lcl..lcl../...lmld.lcl../....lllllld../...lllllllll./..llwel llewll/..llee l lleell/..llclllclll./...dllsllld../....dlllmd.../..dddlllmmd../.llmmlmmmllm./..ddd....ddd.")
    private static let wren = Design((0x76534E,0xBE815D,0xEFBE83,0x82B6B0),
        "......ldd..../.....lmlmd.../....lmlwemd../....lmmeemdss/..l.dmllllm../..lmmdcccllm./.dlmmccccllm./..dmccccllmd./...dmclllmd../....dmmmm d../......dgdg.../.....ss.ss...")
    private static let moth = Design((0x59627D,0x9CA9BC,0xDFEAD9,0xF0BA83),
        "...l.....l.../....l...l..../..lmdlldldml./.lmlmlllmlmml/.lcllwe ewlcll/.lmcm e e mcml/..dmclll lcmd./...dmcc ccmd../....dlllld.../....dcllcd.../.....dmd...../....gg.gg....")
    private static let egg = Design((0x777487,0xB0A9B2,0xF0DDCA,0xCAA1B2),
        ".....ldd...../....llllm..../...lllhllm.../...llccllm.../..lllc lllmd../..lc lllllmd../..lmmclllmd../...dmmlmmd.../....ddddd..../...ggGGGgg...")
    private static let synth = Design((0x4F6377,0x889BB0,0xD5D9C6,0x8BE4BE),
        "..ddddddddd../.mlllllllllm./.lmdddddssml./.lmdcccdasml./.lmdddddssml./.lmmmmmmmmml./.lwdewd ewdel./.lwwewwwewwl./..ddddddddd..")
    private static let halo = Design((0x61578B,0x9484B6,0xC9C0EA,0xF2D9A1),
        ".....llld..../...llm..mmd../..lm......md./.lm........m./.l....c....d./.l...ccc...d./.m....c....d./..m.......d../...md...dd.../.....ddd.....")
    private static let recorder = Design((0x635868,0xA68E92,0xE3D1C4,0xF67D66),
        "...lllllld.../..lmmmmmmdm../..lmccwwcmd../..lmcewwemd../..lmmmmm mmd../..lmddddmmd../..lmllllmmd../..lmccmmmmd../...ddddddd...")
    private static let caption = Design((0x68657D,0xA99FB8,0xE8DCEC,0x98CFC4),
        "..lllllllll../.lwwwwwwwwwm./.lwdddddwwwm./.lwwwwwwwwwm./.lwcccwwwcwm./.lwwwwwwwwwm./..mmlmmmmmd../....lm......./....m........")
    private static let writer = Design((0x665976,0xA997AD,0xE7CCB0,0xA0C9C1),
        "........gGG../.......GccG../......Gccg.../.....lcGg..../.....lmg...../....lmm....../....md......./...dm......../..d..ll..lll./...ll..ll....")
    private static let eclipse = Design((0x575769,0x7B7D91,0xC4C8CD,0xCDBC94),
        ".....ddlm..../...dd.....d../..dm........./.dm........../.dm........../.dm........c./..dm......c../...dll..cc.../.....lllc....")

    private static func design(_ look: IslandLook, stage: Int) -> Design {
        switch look {
        case .ghost: ghost
        case .void: cat
        case .nocturne: bat
        case .sprout: sprout
        case .drift: blossom
        case .rose: rose
        case .loop: ember
        case .pulse: pulse
        case .hare: pip
        case .wren: wren
        case .mote: stage == 0 ? egg : moth
        case .synth: synth
        case .halo: halo
        case .recorder: recorder
        case .caption: caption
        case .stream: writer
        case .blackout: eclipse
        case .cube, .sword: halo // These use the projected 3D renderer.
        }
    }

    static func image(look: IslandLook, mood: IslandMood, accent: UInt32, side: Bool, still: Bool) -> CGImage? {
        let art: Design
        if side && look == .nocturne { art = batFace }
        else if side && look == .void { art = catEye }
        else if look == .rose && mood.growth < 0.28 && mood.dailyEnergy < 2 && mood.kind != .happy { art = rosebud }
        else { art = design(look, stage: mood.stage) }
        let n = 19
        var pixels = [UInt8](repeating: 0, count: n * n * 4)
        func dot(_ x: Int, _ y: Int, _ rgb: UInt32) {
            guard (0..<n).contains(x), (0..<n).contains(y) else { return }
            let i = (y * n + x) * 4
            pixels[i] = UInt8((rgb >> 16) & 255)
            pixels[i + 1] = UInt8((rgb >> 8) & 255)
            pixels[i + 2] = UInt8(rgb & 255)
            pixels[i + 3] = 255
        }
        let leaf: UInt32 = 0x519975, leafLight: UInt32 = 0x9BD1A2, gold: UInt32 = 0xEFC37B
        let palette: [Character: UInt32] = ["d": art.shadow, "m": art.body, "l": art.light, "c": art.detail,
            "g": leaf, "G": leafLight, "s": gold, "e": 0x362B42, "w": 0xFFECDB, "h": 0xFFF4C7, "a": accent]
        let live = !still && mood.awake
        let frame = live ? mood.beat % 4 : 0
        let warm = mood.dailyEnergy > 1 || mood.growth > 0.35
        let width = art.rows.map(\.count).max() ?? 13
        let left = (n - width) / 2, top = (n - art.rows.count) / 2
        let botanical = look == .rose || look == .sprout || look == .drift
        for (row, line) in art.rows.enumerated() {
            for (column, code) in line.enumerated() {
                guard var color = palette[code] else { continue }
                var x = column + left, y = row + top
                // Articulate tips about their roots; stems, feet and the pot keep their footing.
                if botanical && row < 6 && (frame == 1 || frame == 2) && column >= width - 3 { y -= 1 }
                if look == .nocturne && abs(column - width / 2) > 3 { y += frame == 2 ? -1 : 0 }
                if look == .hare && row < 4 && column < 7 && frame == 1 { x -= 1 }
                if look == .wren && column < 4 && frame == 2 { y -= 1 }
                if look == .loop && row < 6 { x += frame == 1 ? 1 : 0; y -= frame == 2 ? 1 : 0 }
                if look == .ghost && row >= art.rows.count - 2 { y -= (column + frame) % 4 == 0 ? 1 : 0 }
                if look == .pulse && live && mood.level > 0.42 && row < 3 { y -= 1 }
                if look == .mote && mood.stage > 0 && abs(column - width / 2) > 3 && frame == 1 { y -= 1 }
                if look == .synth && code == "c" && (column + frame) % 3 == 0 { color = accent }
                if (look == .recorder || look == .halo || look == .caption || look == .stream || look == .blackout),
                   code == "c", live, frame == 1 || frame == 2 { color = accent }
                // Closed lids are localized to the face. A wink only occurs for an awake creature.
                if (code == "w" || code == "e") && column > width / 2 && live && mood.wink { color = art.body }
                if code == "w" && (mood.kind == .paused || mood.kind == .asleep || mood.kind == .away) &&
                    [.void, .hare, .wren, .mote, .ghost, .nocturne].contains(look) { color = art.body }
                dot(x, y, color)
            }
        }
        if look == .synth {
            for (index, value) in mood.synthLevels.suffix(7).enumerated() {
                for step in 0..<Int((Double(value) / 15 * 3).rounded()) {
                    dot(5 + index, 9 - step, step == 2 ? gold : 0x81DDB1)
                }
            }
        }
        if botanical && warm {
            dot(13, 12, leafLight); dot(14, 11, leafLight); dot(14, 12, leaf)
            if mood.dailyEnergy == 3 || mood.kind == .happy { dot(15, 10, gold) }
        }
        if look.isPet && mood.stage > 1 {
            dot(6, 4, art.detail); dot(12, 4, art.detail)
            if mood.stage > 2 { dot(5, 3, art.light); dot(13, 3, art.light) }
            if mood.stage > 3 { dot(8, 3, gold); dot(9, 2, gold); dot(10, 3, gold) }
            if mood.stage > 4 { dot(4, 6, 0xFFEDBC); dot(14, 5, 0xFFEDBC) }
        }
        if look.isPet && mood.accessory > 0 {
            dot(10, 12, gold)
            if mood.accessory >= 2 { for x in 7...10 { dot(x, 11, 0x81BBAF) }; dot(11, 12, 0x599D91) }
            if mood.accessory == 3 { dot(12, 10, gold); dot(11, 11, gold); dot(12, 11, 0xFFF2D0); dot(13, 11, gold); dot(12, 12, gold) }
        }
        if live && mood.confetti && !side {
            dot(2, 5, gold); dot(15, 4, art.light); dot(16, 6, accent); dot(3, 3, leafLight)
        }
        guard let provider = CGDataProvider(data: Data(pixels) as CFData) else { return nil }
        return CGImage(width: n, height: n, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: n * 4,
                       space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.last.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
    }
}
