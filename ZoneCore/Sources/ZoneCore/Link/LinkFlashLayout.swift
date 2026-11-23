// by zayd/cold @ zayd.wtf

import Foundation

/// Where a Flash code sits on the screen, in whole screen pixels.
///
/// The code lies on a light square, its portal: the code with four light modules on every side
/// of it (the quiet zone a reader expects). Every module is a whole number of pixels, and a
/// module is never smaller than in the first Flash screen, which drew the code as wide as the
/// screen less 20 points a side, on white.
///
/// In black and white the portal is part of a white band as wide as the screen. In color the
/// portal is a window in the scene: the art comes right up to its edge, so the four modules of
/// quiet zone are all inside it (`portalQuiet`).
public struct LinkFlashLayout: Equatable, Sendable {
    /// Light modules required around the code on every side.
    public static let quietModules = 4

    /// Pixels per module.
    public let module: Int
    /// The white band: full width, `bandHeight` tall, its top at `bandY`.
    public let bandY: Int
    public let bandHeight: Int
    /// The code picture as drawn by `LinkFlashQR.modules` (with its own one-module border).
    public let codeX: Int
    public let codeY: Int
    public let codeSide: Int

    /// - Parameters:
    ///   - width, height: the screen in pixels.
    ///   - top, bottom: pixels kept clear for text at the top and the bottom.
    ///   - modules: the side of the code picture in modules, its one-module border included
    ///     (63 for the usual version 11 frame).
    ///   - minimumArt: pixels kept clear above and below the band when the height allows.
    public init(width: Int, height: Int, top: Int, bottom: Int, modules: Int, minimumArt: Int = 0) {
        let modules = max(1, modules)
        // The picture already has one light module a side; the band adds the rest.
        let span = modules + 2 * (Self.quietModules - 1)
        let room = max(1, height - top - bottom)
        let tall = max(span, room - 2 * minimumArt)
        let module = max(1, min(width / span, tall / span))
        let bandHeight = span * module
        let bandY = top + max(0, (room - bandHeight) / 2)
        self.module = module
        self.bandHeight = bandHeight
        self.bandY = bandY
        self.codeSide = modules * module
        self.codeX = (width - codeSide) / 2
        self.codeY = bandY + (Self.quietModules - 1) * module
    }

    /// Whole light modules between the code's data area and the screen's side (horizontal)
    /// or the band's edge (vertical). The picture's own one-module border counts.
    public var quietZone: (horizontal: Int, vertical: Int) {
        ((codeX + module) / module, (codeY - bandY + module) / module)
    }

    /// The portal: the square of code and quiet zone, `portalSide` on a side, its top left at
    /// (`portalX`, `bandY`). Everything outside it may be art.
    public var portalSide: Int { bandHeight }
    public var portalX: Int { codeX - (Self.quietModules - 1) * module }

    /// Whole light modules between the code's data area and the nearest edge of the portal,
    /// on any side. The picture's own one-module border counts.
    public var portalQuiet: Int {
        min(codeX - portalX, codeY - bandY, portalX + portalSide - (codeX + codeSide),
            bandY + portalSide - (codeY + codeSide)) / module + 1
    }

    /// Pixels between the portal and the nearer side of the screen: room for a frame around it.
    public func portalMargin(width: Int) -> Int {
        max(0, min(portalX, width - portalX - portalSide))
    }

    /// The module size of the first Flash screen: the code as large as fits in the width
    /// less 20 points a side, a whole number of pixels per module.
    public static func previousModule(width: Int, scale: Int, codeAreaHeight: Int, modules: Int) -> Int {
        let available = min(width - 40 * scale, codeAreaHeight)
        return max(1, available / max(1, modules))
    }
}
