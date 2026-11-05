import CoreGraphics
import Foundation

enum DecorationLayout: String, CaseIterable, Identifiable {
    case none, christmasTree, newYork, alpineVillage, winterMarket

    var id: String { rawValue }

    var title: String {
        switch self {
        case .none: "None"
        case .christmasTree: "Christmas Tree"
        case .newYork: "New York"
        case .alpineVillage: "Alpine Village"
        case .winterMarket: "Winter Market"
        }
    }

    var detail: String {
        switch self {
        case .none: "Just the snow."
        case .christmasTree: "A dressed-up fir and gifts tied with ribbon."
        case .newYork: "A brownstone, a wreath, and a corner streetlamp."
        case .alpineVillage: "A snug chalet under the pines."
        case .winterMarket: "Hot cocoa and warm lights under a striped awning."
        }
    }

    var pieces: [DecorationPiece] {
        switch self {
        case .none: []
        case .christmasTree: PixelCatalog.christmasTree
        case .newYork: PixelCatalog.newYork
        case .alpineVillage: PixelCatalog.alpineVillage
        case .winterMarket: PixelCatalog.winterMarket
        }
    }
}

struct DecorationPiece: Identifiable {
    /// These names also identify assets in saved scenes. Keep them stable.
    var id: String { name }
    let name: String
    let image: CGImage
    let movesByDefault: Bool
    /// Exact source silhouette in row-major, top-down order.
    let alpha: [UInt8]
    let solidBottom: Int
    var width: Int { image.width }
    var height: Int { image.height }
}

enum DecorationCatalog {
    static let all = DecorationLayout.allCases.flatMap(\.pieces) + PixelCatalog.extras
    private static let byID = Dictionary(uniqueKeysWithValues: all.map { ($0.id, $0) })

    static func piece(_ id: String) -> DecorationPiece? { byID[id] }
}

private enum PixelCatalog {
    static let christmasTree: [DecorationPiece] = [
        present("Red present", width: 15, height: 13, box: 0xB83B48, edge: 0x732837, ribbon: 0xF7CE79),
        tree(),
        present("Blue present", width: 19, height: 15, box: 0x4E829D, edge: 0x345971, ribbon: 0xF0C996),
    ]

    static let newYork: [DecorationPiece] = [streetlamp(), brownstone(), hydrant()]
    static let alpineVillage: [DecorationPiece] = [pine(), chalet(), snowman()]
    static let winterMarket: [DecorationPiece] = [menuBoard(), marketStall(), cocoaCrate()]
    static let extras: [DecorationPiece] = [
        candyCane(), sled(), bench(), mailbox(), lantern(), gingerbread(), pineBundle()
    ]

    private static func present(_ name: String, width: Int, height: Int,
                                box: UInt32, edge: UInt32, ribbon: UInt32) -> DecorationPiece {
        var p = PixelSprite(width, height)
        let center = width / 2
        p.fill(center - 4, 0, 3, 2, ribbon)
        p.fill(center + 2, 0, 3, 2, ribbon)
        p.fill(center - 3, 2, 7, 2, ribbon)
        p.fill(1, 5, width - 2, height - 5, edge)
        p.fill(2, 6, width - 5, height - 7, box)
        p.fill(0, 4, width, 4, edge)
        p.fill(0, 4, width - 2, 3, box)
        p.fill(center - 1, 4, 3, height - 4, ribbon)
        p.fill(center + 1, 5, 1, height - 5, 0xC79353)
        return p.piece(name)
    }

    private static func tree() -> DecorationPiece {
        var p = PixelSprite(39, 49)
        p.fill(15, 41, 9, 8, 0x65432F)
        p.fill(16, 43, 3, 5, 0xAD7950)
        p.polygon([(19, 8), (27, 20), (24, 20), (33, 31), (30, 31),
                   (39, 44), (0, 44), (9, 31), (6, 31), (15, 20), (12, 20)], 0x163F39)
        p.polygon([(19, 10), (23, 17), (22, 20), (28, 29), (25, 30),
                   (33, 41), (4, 41), (12, 30), (10, 29), (17, 20), (14, 19)], 0x237252)
        p.polygon([(19, 11), (17, 22), (21, 21), (16, 30), (21, 29),
                   (13, 40), (6, 40), (13, 30), (11, 29), (17, 20), (15, 19)], 0x399168)
        p.polygon([(20, 17), (25, 20), (23, 21), (30, 30), (26, 30),
                   (35, 41), (29, 42), (20, 32), (23, 30), (19, 24)], 0x245A46)
        for (x, y) in [(15, 19), (18, 20), (21, 21), (25, 23), (11, 29), (15, 31),
                       (20, 33), (25, 34), (30, 35), (8, 38), (13, 40), (20, 41), (27, 41)] {
            p.fill(x, y, 3, 1, 0xB8AA65)
        }
        for (x, y, color): (Int, Int, UInt32) in [
            (20, 16, 0xEC5964), (15, 24, 0xFFCD79), (23, 26, 0x79C0C6),
            (11, 33, 0xEC5964), (19, 35, 0xFFD489), (27, 37, 0xEC5964),
        ] {
            p.fill(x, y, 3, 3, color)
            p.fill(x, y, 1, 1, 0xFFF2D4)
        }
        p.polygon([(19, 0), (21, 4), (26, 5), (22, 8), (23, 12),
                   (19, 10), (15, 12), (16, 8), (12, 5), (17, 4)], 0xFFD881)
        p.fill(18, 4, 3, 3, 0xFFF1B0)
        return p.piece("Decorated fir")
    }

    private static func streetlamp() -> DecorationPiece {
        var p = PixelSprite(14, 38)
        p.fill(3, 35, 8, 3, 0x293846)
        p.fill(5, 14, 4, 21, 0x334758)
        p.fill(6, 15, 1, 19, 0x6D8491)
        p.fill(4, 33, 6, 2, 0x4D6472)
        p.polygon([(0, 6), (4, 2), (6, 2), (6, 0), (8, 0), (8, 2), (10, 2), (14, 6)], 0x34465B)
        p.fill(2, 6, 10, 9, 0x2E3D50)
        p.fill(3, 6, 8, 7, 0xF6B76A)
        p.fill(4, 7, 4, 6, 0xFFDB8F)
        p.fill(6, 6, 2, 8, 0xB98047)
        p.fill(3, 3, 4, 1, 0xDCECF6)
        p.fill(1, 4, 7, 1, 0xF0F9FD)
        return p.piece("Corner streetlamp", movesByDefault: false)
    }

    private static func brownstone() -> DecorationPiece {
        var p = PixelSprite(45, 50)
        p.fill(3, 5, 39, 44, 0x784E49)
        p.fill(4, 6, 34, 40, 0xA66A59)
        p.fill(38, 6, 4, 40, 0x88594C)
        for y in stride(from: 8, to: 46, by: 3) {
            p.fill(4, y, 38, 1, 0x945C50)
            let offset = y.isMultiple(of: 2) ? 0 : 3
            for x in stride(from: 8 + offset, to: 42, by: 6) {
                p.fill(x, y - 2, 1, 2, 0x9A6253)
            }
        }
        p.fill(1, 3, 43, 4, 0x543E46)
        p.fill(0, 2, 45, 2, 0x9E756F)
        p.fill(1, 1, 43, 2, 0xE0EEF5)
        p.fill(4, 0, 15, 1, 0xF0F9FD)
        p.fill(29, 0, 8, 1, 0xF0F9FD)
        p.fill(2, 21, 41, 2, 0x734B47)
        p.fill(2, 35, 41, 2, 0x734B47)
        for y in [10, 24] {
            for x in [8, 19, 30] {
                p.fill(x - 1, y, 8, 10, 0x654645)
                p.fill(x, y, 6, 8, 0xF1AB65)
                p.fill(x + 1, y + 1, 4, 6, 0xFFD192)
                p.fill(x + 2, y, 1, 8, 0x8E614F)
                p.fill(x, y + 3, 6, 1, 0x8E614F)
                p.fill(x - 1, y + 8, 8, 1, 0xB78874)
                if x != 19 || y == 10 {
                    p.fill(x, y + 9, 6, 1, 0x416D58)
                    p.fill(x + 1, y + 9, 1, 1, 0xDE6A64)
                    p.fill(x + 4, y + 9, 1, 1, 0xF4C27C)
                }
            }
        }
        p.fill(17, 36, 11, 11, 0x69454A)
        p.fill(18, 37, 9, 10, 0x355753)
        p.fill(19, 38, 7, 5, 0x466C61)
        p.fill(21, 39, 3, 3, 0x78A267)
        p.fill(22, 40, 1, 1, 0x3C6955)
        p.fill(22, 42, 1, 1, 0xDF756D)
        p.fill(25, 44, 1, 1, 0xFFC97A)
        p.fill(15, 46, 15, 2, 0x9D9190)
        p.fill(13, 48, 19, 2, 0xBAB1A9)
        p.fill(3, 48, 9, 2, 0x756D72)
        p.fill(33, 48, 9, 2, 0x756D72)
        return p.piece("Holiday brownstone", movesByDefault: false)
    }

    private static func hydrant() -> DecorationPiece {
        var p = PixelSprite(13, 14)
        p.fill(3, 3, 7, 10, 0x973E46)
        p.fill(4, 4, 3, 8, 0xD36D61)
        p.fill(1, 5, 11, 4, 0xA64749)
        p.fill(0, 6, 2, 2, 0x713541)
        p.fill(11, 6, 2, 2, 0x713541)
        p.fill(5, 6, 3, 3, 0xA0474A)
        p.fill(2, 2, 9, 2, 0xAD4C4D)
        p.fill(4, 0, 5, 2, 0xE3F1F6)
        p.fill(2, 12, 9, 2, 0x783B43)
        return p.piece("Red fire hydrant", movesByDefault: false)
    }

    private static func pine() -> DecorationPiece {
        var p = PixelSprite(28, 41)
        p.fill(11, 33, 6, 8, 0x6E4B3C)
        p.fill(12, 34, 2, 6, 0xA7805E)
        p.polygon([(14, 0), (21, 14), (18, 14), (25, 24), (21, 24), (28, 36),
                   (0, 36), (7, 24), (3, 24), (10, 14), (7, 14)], 0x2E6259)
        p.polygon([(14, 1), (18, 11), (13, 10), (11, 12), (8, 13)], 0xE0EEF0)
        p.polygon([(12, 15), (17, 16), (22, 22), (16, 21), (14, 19), (7, 22)], 0xB9D6D7)
        p.polygon([(8, 25), (13, 26), (15, 28), (19, 27), (25, 33),
                   (19, 32), (16, 34), (10, 30), (3, 33)], 0xBED9D9)
        p.fill(8, 29, 4, 1, 0xE1EEEE)
        p.fill(13, 17, 3, 1, 0xE1EEEE)
        return p.piece("Frosted pine")
    }

    private static func chalet() -> DecorationPiece {
        var p = PixelSprite(49, 34)
        p.fill(35, 3, 7, 13, 0x8B6358)
        p.fill(34, 2, 9, 2, 0xCBDED9)
        p.fill(4, 15, 41, 18, 0x8F5E4A)
        p.fill(5, 17, 38, 14, 0xBD8762)
        for y in [20, 24, 28] { p.fill(5, y, 38, 1, 0xA87456) }
        p.fill(3, 32, 43, 2, 0x665A58)
        p.polygon([(0, 19), (24, 0), (49, 19), (45, 21), (24, 7), (4, 21)], 0x46536C)
        p.polygon([(0, 17), (24, 0), (49, 17), (46, 18), (24, 5), (3, 19)], 0xE2F2F6)
        p.polygon([(24, 6), (38, 16), (10, 16)], 0xAA7457)
        p.fill(21, 10, 6, 5, 0x745351)
        p.fill(22, 11, 4, 3, 0xFAD390)
        p.fill(21, 22, 8, 10, 0x6D4B42)
        p.fill(22, 23, 6, 9, 0x59675E)
        p.fill(26, 28, 1, 1, 0xF9CB7C)
        for x in [9, 33] {
            p.fill(x - 1, 21, 8, 8, 0x805244)
            p.fill(x, 22, 6, 6, 0xFFCC85)
            p.fill(x + 2, 22, 1, 6, 0xA26D4C)
            p.fill(x, 24, 6, 1, 0xA26D4C)
            p.fill(x - 1, 28, 8, 1, 0xDEEBEA)
        }
        p.fill(18, 32, 14, 2, 0x9A8272)
        return p.piece("Alpine chalet", movesByDefault: false)
    }

    private static func snowman() -> DecorationPiece {
        var p = PixelSprite(19, 26)
        p.polygon([(0, 20), (4, 15), (15, 15), (19, 20), (17, 25), (14, 26),
                   (5, 26), (2, 25)], 0xBEDBE8)
        p.polygon([(2, 20), (5, 16), (13, 16), (16, 20), (14, 24), (5, 24)], 0xF3F9FA)
        p.polygon([(3, 7), (6, 4), (13, 4), (16, 7), (16, 12), (13, 16), (6, 16), (3, 12)], 0xDCECF0)
        p.fill(5, 7, 8, 6, 0xFAFEFD)
        p.fill(6, 0, 7, 5, 0x344357)
        p.fill(6, 3, 7, 2, 0xA55058)
        p.fill(3, 5, 13, 2, 0x43576A)
        p.fill(7, 8, 1, 1, 0x344357)
        p.fill(11, 8, 1, 1, 0x344357)
        p.fill(9, 10, 4, 1, 0xE79B63)
        p.fill(5, 14, 10, 2, 0xBE515E)
        p.fill(12, 15, 3, 5, 0xA94354)
        p.fill(9, 18, 1, 1, 0x627588)
        p.fill(9, 22, 1, 1, 0x627588)
        return p.piece("Snowman")
    }

    private static func menuBoard() -> DecorationPiece {
        var p = PixelSprite(15, 20)
        p.fill(1, 2, 2, 18, 0x98735E)
        p.fill(12, 2, 2, 18, 0x98735E)
        p.fill(0, 1, 15, 15, 0xAF815E)
        p.fill(1, 0, 13, 2, 0xD4E9EC)
        p.fill(2, 3, 11, 11, 0x3C554F)
        p.fill(4, 7, 6, 4, 0xE6D9B9)
        p.fill(5, 11, 4, 1, 0xE6D9B9)
        p.fill(10, 7, 2, 3, 0xE6D9B9)
        p.fill(10, 8, 1, 1, 0x3C554F)
        p.fill(6, 5, 1, 1, 0xC5D6C2)
        p.fill(8, 4, 1, 2, 0xC5D6C2)
        return p.piece("Cocoa chalkboard")
    }

    private static func marketStall() -> DecorationPiece {
        var p = PixelSprite(50, 34)
        p.fill(4, 10, 42, 24, 0x704C40)
        p.fill(8, 10, 34, 12, 0x99664C)
        p.fill(9, 12, 32, 9, 0xBF895F)
        p.fill(9, 13, 32, 1, 0xD7A170)
        p.fill(10, 14, 2, 7, 0xA57658)
        p.fill(37, 14, 2, 7, 0xA57658)
        p.fill(4, 25, 42, 8, 0xA97452)
        for x in stride(from: 7, to: 46, by: 5) { p.fill(x, 25, 1, 8, 0x885C46) }
        p.fill(2, 22, 46, 3, 0xC19266)
        p.fill(2, 24, 46, 1, 0x73503F)
        p.fill(3, 21, 44, 1, 0xD8E9EA)
        for (x, color): (Int, UInt32) in [(12, 0xF1D3A0), (16, 0xE4B487), (31, 0x9EBDAF), (36, 0xEEE1C4)] {
            p.fill(x, 17, 3, 4, color)
            p.fill(x + 3, 18, 1, 2, color)
        }
        p.fill(23, 15, 5, 6, 0x6D5048)
        p.fill(22, 16, 7, 1, 0xE5B67E)
        p.polygon([(0, 10), (5, 1), (45, 1), (50, 10), (49, 13), (1, 13)], 0xAA4F54)
        for x in [9, 21, 33] {
            p.polygon([(x, 1), (x + 5, 1), (x + 6, 10), (x + 6, 12),
                       (x - 2, 12), (x - 2, 10)], 0xEACDB0)
        }
        p.fill(0, 10, 50, 1, 0x763F48)
        p.fill(4, 0, 42, 2, 0xDDEEEF)
        p.fill(7, 0, 15, 1, 0xF7FCF9)
        for x in stride(from: 5, to: 48, by: 7) {
            p.fill(x, 12, 2, 1, 0x674838)
            p.fill(x, 13, 2, 2, 0xFFCE79)
        }
        return p.piece("Cocoa stall", movesByDefault: false)
    }

    private static func cocoaCrate() -> DecorationPiece {
        var p = PixelSprite(19, 15)
        p.fill(3, 4, 4, 5, 0xC5D9D6)
        p.fill(5, 3, 2, 2, 0xEAF6EE)
        p.fill(9, 2, 4, 7, 0xC38470)
        p.fill(9, 1, 4, 2, 0xE9D5B1)
        p.fill(14, 3, 3, 6, 0xE7C18B)
        p.fill(1, 7, 17, 8, 0x74544B)
        p.fill(0, 6, 19, 3, 0xB48A63)
        p.fill(2, 10, 14, 2, 0xAD805B)
        p.fill(2, 13, 14, 1, 0xAD805B)
        p.fill(3, 9, 1, 6, 0xC4A07C)
        p.fill(14, 9, 1, 6, 0x9A6E52)
        return p.piece("Cocoa supplies")
    }

    private static func candyCane() -> DecorationPiece {
        var p = PixelSprite(15, 27)
        p.fill(2, 3, 5, 4, 0x9D404C)
        p.fill(4, 1, 8, 4, 0x9D404C)
        p.fill(10, 4, 5, 20, 0x9D404C)
        p.fill(3, 4, 3, 4, 0xF9E9D6)
        p.fill(5, 2, 6, 3, 0xF9E9D6)
        p.fill(11, 4, 3, 20, 0xF9E9D6)
        p.fill(6, 2, 3, 3, 0xD95660)
        for y in [6, 11, 16, 21] {
            p.fill(11, y, 3, 2, 0xD95660)
            p.fill(11, y + 2, 1, 1, 0xE87579)
        }
        p.fill(6, 24, 9, 3, 0x99B4C4)
        p.fill(7, 23, 7, 2, 0xEFF5EF)
        return p.piece("Candy cane")
    }

    private static func sled() -> DecorationPiece {
        var p = PixelSprite(30, 13)
        p.fill(3, 4, 4, 7, 0x66534C)
        p.fill(21, 4, 4, 7, 0x66534C)
        p.fill(2, 3, 22, 3, 0x8E4E46)
        p.fill(1, 2, 24, 2, 0xD27D62)
        p.fill(7, 2, 13, 1, 0xF4BE94)
        p.fill(24, 3, 3, 2, 0xB47855)
        p.fill(28, 6, 2, 4, 0xD9B176)
        p.fill(25, 9, 4, 2, 0xAB815A)
        p.fill(2, 10, 24, 3, 0x795A4B)
        p.fill(3, 10, 21, 1, 0xE8B57D)
        p.fill(0, 9, 3, 3, 0xAE8A6E)
        return p.piece("Wooden sled")
    }

    private static func bench() -> DecorationPiece {
        var p = PixelSprite(35, 19)
        for x in [2, 30] {
            p.fill(x, 2, 3, 16, 0x3B5057)
            p.fill(x - 1, 17, 6, 2, 0x263B42)
        }
        for y in [3, 7, 11] {
            p.fill(0, y, 35, 3, 0x794E49)
            p.fill(1, y, 33, 1, 0xAE7662)
        }
        p.fill(2, 2, 31, 2, 0xDAE9E9)
        p.fill(6, 1, 21, 2, 0xEFF7F6)
        p.fill(6, 11, 22, 1, 0xD4E2E4)
        return p.piece("Snowy park bench", movesByDefault: false)
    }

    private static func mailbox() -> DecorationPiece {
        var p = PixelSprite(21, 28)
        p.fill(8, 10, 5, 18, 0x69524E)
        p.fill(9, 13, 2, 15, 0xB48064)
        p.fill(5, 25, 11, 3, 0x8AA3B1)
        p.fill(6, 25, 9, 1, 0xE4EDF0)
        p.polygon([(1, 11), (1, 6), (5, 2), (17, 2), (20, 6), (20, 11), (18, 13), (3, 13)], 0x6D3541)
        p.fill(3, 5, 15, 6, 0xB95156)
        p.fill(6, 2, 11, 3, 0xDA7372)
        p.fill(4, 6, 3, 4, 0xE2BE82)
        p.fill(13, 3, 2, 5, 0x683C3E)
        p.fill(13, 1, 5, 3, 0xF4CC77)
        p.fill(5, 1, 7, 2, 0xEDF3EC)
        return p.piece("Holiday mailbox", movesByDefault: false)
    }

    private static func lantern() -> DecorationPiece {
        var p = PixelSprite(15, 21)
        p.fill(6, 0, 3, 1, 0x655F58)
        p.fill(5, 1, 1, 3, 0x655F58)
        p.fill(9, 1, 1, 3, 0x655F58)
        p.polygon([(3, 5), (6, 3), (9, 3), (12, 5), (13, 7), (2, 7)], 0x3C4F50)
        p.fill(3, 7, 9, 11, 0x5C5046)
        p.fill(5, 8, 5, 9, 0xDEA260)
        p.fill(6, 12, 3, 4, 0xFFF2B3)
        p.fill(7, 10, 1, 3, 0xFFE290)
        p.fill(7, 8, 1, 3, 0xA36E54)
        p.fill(2, 17, 11, 4, 0x374749)
        p.fill(3, 18, 8, 1, 0x948876)
        return p.piece("Candle lantern")
    }

    private static func gingerbread() -> DecorationPiece {
        var p = PixelSprite(21, 26)
        p.polygon([(6, 2), (8, 0), (13, 0), (15, 2), (15, 9), (20, 11),
                   (21, 15), (17, 17), (15, 15), (15, 25), (11, 26), (10, 20),
                   (9, 26), (5, 25), (5, 15), (2, 17), (0, 14), (1, 11), (6, 9)], 0x986043)
        p.fill(7, 2, 7, 7, 0xC5895A)
        p.fill(6, 11, 9, 8, 0xBE8051)
        p.fill(8, 3, 1, 2, 0xF5E0B9)
        p.fill(12, 3, 1, 2, 0xF5E0B9)
        p.fill(9, 7, 3, 1, 0xF5E0B9)
        p.fill(5, 9, 11, 2, 0xCC6059)
        p.fill(10, 11, 2, 3, 0xCC6059)
        p.fill(10, 15, 1, 1, 0xF7D27E)
        p.fill(10, 18, 1, 1, 0xE7ECD0)
        p.fill(5, 23, 4, 1, 0xF5E0B9)
        p.fill(11, 23, 4, 1, 0xF5E0B9)
        return p.piece("Gingerbread friend")
    }

    private static func pineBundle() -> DecorationPiece {
        var p = PixelSprite(22, 24)
        p.polygon([(4, 8), (5, 3), (10, 10), (12, 0), (15, 8), (21, 5),
                   (18, 14), (14, 18), (8, 18), (0, 10)], 0x315B51)
        p.polygon([(5, 7), (11, 13), (12, 4), (15, 12), (18, 9), (16, 15), (8, 17)], 0x4B8069)
        p.fill(11, 4, 2, 3, 0xC4DCD5)
        p.fill(5, 8, 2, 2, 0xE3EAE0)
        p.fill(16, 9, 2, 2, 0xD6E1D4)
        p.fill(5, 14, 13, 3, 0xA16755)
        p.fill(6, 16, 11, 8, 0x83534A)
        p.fill(7, 17, 8, 5, 0xB97C62)
        p.fill(10, 16, 3, 2, 0xDFC18B)
        return p.piece("Potted evergreen")
    }
}

/// Small, opaque-color drawing primitives keep the original pixel grid intact.
/// Both the desktop layers and previews scale the resulting images with nearest-neighbor filtering.
private struct PixelSprite {
    let width: Int
    let height: Int
    private var bytes: [UInt8]

    init(_ width: Int, _ height: Int) {
        self.width = width
        self.height = height
        bytes = [UInt8](repeating: 0, count: width * height * 4)
    }

    mutating func fill(_ x: Int, _ y: Int, _ w: Int, _ h: Int, _ color: UInt32) {
        let left = max(0, x), right = min(width, x + w)
        let top = max(0, y), bottom = min(height, y + h)
        guard left < right, top < bottom else { return }
        let red = UInt8(truncatingIfNeeded: color >> 16)
        let green = UInt8(truncatingIfNeeded: color >> 8)
        let blue = UInt8(truncatingIfNeeded: color)
        for row in top..<bottom {
            for column in left..<right {
                let index = (row * width + column) * 4
                bytes[index] = red
                bytes[index + 1] = green
                bytes[index + 2] = blue
                bytes[index + 3] = 255
            }
        }
    }

    mutating func polygon(_ vertices: [(x: Int, y: Int)], _ color: UInt32) {
        let edges = zip(vertices, vertices.dropFirst() + vertices.prefix(1))
        for row in 0..<height {
            let y = Double(row) + 0.5
            var crossings: [Double] = []
            for (start, end) in edges {
                guard (Double(start.y) > y) != (Double(end.y) > y) else { continue }
                let progress = (y - Double(start.y)) / Double(end.y - start.y)
                crossings.append(Double(start.x) + Double(end.x - start.x) * progress)
            }
            crossings.sort()
            for index in stride(from: 0, to: crossings.count - 1, by: 2) {
                let left = Int(ceil(crossings[index] - 0.5))
                let right = Int(ceil(crossings[index + 1] - 0.5))
                fill(left, row, right - left, 1, color)
            }
        }
    }

    func piece(_ name: String, movesByDefault: Bool = true) -> DecorationPiece {
        let alpha = stride(from: 3, to: bytes.count, by: 4).map { bytes[$0] }
        // The sizes, pixel format and storage all come from the artwork above.
        let image = CGImage(
            width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
            bytesPerRow: width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
            provider: CGDataProvider(data: Data(bytes) as CFData)!,
            decode: nil, shouldInterpolate: false, intent: .defaultIntent
        )!
        let solidBottom = alpha.lastIndex(where: { $0 != 0 }).map { $0 / width + 1 } ?? height
        return DecorationPiece(name: name, image: image, movesByDefault: movesByDefault,
                               alpha: alpha, solidBottom: solidBottom)
    }
}
