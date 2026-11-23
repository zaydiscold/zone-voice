// by zayd/cold @ zayd.wtf

#if canImport(CoreImage)
import CoreGraphics
import CoreImage
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Draws one Flash frame as a QR code: byte data, error correction level L.
///
/// Core Image makes the code at one pixel per module. Nothing here ever smooths it: a frame is
/// shown, or written to a file, with every module a crisp square.
public enum LinkFlashQR {
    /// Safe to share between threads.
    private static let context = CIContext(options: [.useSoftwareRenderer: true, .cacheIntermediates: false])

    /// The code at one pixel per module, with the one-module white border Core Image adds.
    public static func modules(_ frame: Data) -> CGImage? {
        guard let filter = CIFilter(name: "CIQRCodeGenerator") else { return nil }
        filter.setValue(frame, forKey: "inputMessage")
        filter.setValue("L", forKey: "inputCorrectionLevel")
        guard let output = filter.outputImage, !output.extent.isEmpty else { return nil }
        return context.createCGImage(output, from: output.extent, format: .L8, colorSpace: CGColorSpaceCreateDeviceGray())
    }

    /// The code enlarged by a whole number, nearest neighbour, on white, with the quiet border
    /// a reader expects (four modules in all).
    public static func image(_ frame: Data, scale: Int = 8, quietModules: Int = 4) -> CGImage? {
        guard let small = modules(frame) else { return nil }
        let scale = max(1, scale)
        // Core Image already left one module of border.
        let extra = max(0, quietModules - 1) * scale
        let side = small.width * scale + 2 * extra
        guard let canvas = CGContext(data: nil, width: side, height: side, bitsPerComponent: 8, bytesPerRow: 0,
                                     space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return nil }
        canvas.setFillColor(gray: 1, alpha: 1)
        canvas.fill(CGRect(x: 0, y: 0, width: side, height: side))
        canvas.interpolationQuality = .none
        canvas.setShouldAntialias(false)
        canvas.draw(small, in: CGRect(x: extra, y: extra, width: small.width * scale, height: small.height * scale))
        return canvas.makeImage()
    }

    public static func png(_ frame: Data, scale: Int = 8) -> Data? {
        guard let image = image(frame, scale: scale) else { return nil }
        return encodePNG(image)
    }

    static func encodePNG(_ image: CGImage) -> Data? {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return data as Data
    }
}

/// Color Flash: three frames in one picture, one in each of red, green and blue.
///
/// In each channel a module takes one of two levels, the palette's light or its dark
/// (`LinkFlashPalette`), so the picture is a mosaic of eight colors: the all-dark color where
/// all three codes are dark (the finder patterns, which line up because every frame of a flash
/// is the same length and so the same QR version), the all-light color where all three are
/// light (the quiet zone), and six between. With the `pure` palette those are black, white,
/// red, green, blue, cyan, magenta and yellow; the app shows a scene's palette instead. A
/// reader that looks at one channel at a time sees an ordinary Flash frame. The frame format
/// does not change; a picture simply carries three of them.
public enum LinkFlashColor {
    /// Frames in one color picture: red, green, blue.
    public static let channels = 3

    /// The color picture of up to three frames, at one pixel per module with Core Image's
    /// one-module border, in red, green, blue order. A missing frame leaves its channel light.
    ///
    /// `colorSpace` is the space the picture is tagged with. On a phone it should be the
    /// display's own (Display P3): tagged sRGB, a pure red would be converted to P3 as about
    /// (0.92, 0.20, 0.14), lighting the green and blue subpixels a little and blurring the
    /// channels together for the camera. Tagged with the display's space, 255 in one channel
    /// lights that subpixel and no other.
    public static func picture(_ frames: [Data], palette: LinkFlashPalette = .pure,
                               colorSpace: CGColorSpace = CGColorSpace(name: CGColorSpace.sRGB)!) -> CGImage? {
        let codes = frames.prefix(channels).map { LinkFlashQR.modules($0) }
        guard !codes.isEmpty, codes.allSatisfy({ $0 != nil }) else { return nil }
        return compose(codes.compactMap { $0 }, palette: palette, colorSpace: colorSpace)
    }

    /// Stacks one-pixel-per-module gray codes into the channels of one picture. Codes of
    /// different sizes (which a flash never makes) are centered on the largest, so each channel
    /// is still a whole code with a light border.
    public static func compose(_ codes: [CGImage], palette: LinkFlashPalette = .pure,
                               colorSpace: CGColorSpace = CGColorSpace(name: CGColorSpace.sRGB)!) -> CGImage? {
        guard !codes.isEmpty, codes.count <= channels else { return nil }
        let side = codes.map(\.width).max() ?? 0
        guard side > 0 else { return nil }
        var pixels = [UInt8](repeating: 255, count: side * side * 4)
        for (channel, code) in codes.enumerated() {
            guard let gray = Self.gray(code) else { return nil }
            let offset = (side - code.width) / 2
            for row in 0..<code.height {
                for column in 0..<code.width {
                    // Core Image draws modules as exactly 0 or 255; anything darker than mid is dark.
                    let value: UInt8 = gray[row * code.width + column] < 128 ? 0 : 255
                    pixels[((row + offset) * side + column + offset) * 4 + channel] = value
                }
            }
        }
        // Drawn pure, then given the palette's levels: the one place a palette is applied, which
        // the Flash screen uses too, on the bytes of a pure picture it has already drawn.
        palette.recolor(&pixels)
        let info = CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue)
        guard let provider = CGDataProvider(data: Data(pixels) as CFData) else { return nil }
        return CGImage(width: side, height: side, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: side * 4,
                       space: colorSpace, bitmapInfo: info, provider: provider, decode: nil,
                       shouldInterpolate: false, intent: .absoluteColorimetric)
    }

    /// One channel of a color picture as a gray picture (0 red, 1 green, 2 blue): what a reader
    /// that separates the channels sees.
    public static func channel(_ picture: CGImage, _ index: Int) -> CGImage? {
        guard (0..<channels).contains(index), let rgba = rgba(picture) else { return nil }
        let count = picture.width * picture.height
        let gray = (0..<count).map { rgba[$0 * 4 + index] }
        guard let provider = CGDataProvider(data: Data(gray) as CFData) else { return nil }
        return CGImage(width: picture.width, height: picture.height, bitsPerComponent: 8, bitsPerPixel: 8,
                       bytesPerRow: picture.width, space: CGColorSpaceCreateDeviceGray(),
                       bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue), provider: provider,
                       decode: nil, shouldInterpolate: false, intent: .defaultIntent)
    }

    /// A picture enlarged by a whole number, nearest neighbour, with a quiet border (four
    /// modules in all) in the picture's all-light color, which is white in the pure palette:
    /// what the screen shows, for tests and the computer side's cross-test.
    public static func image(_ picture: CGImage, scale: Int = 8, quietModules: Int = 4) -> CGImage? {
        let scale = max(1, scale)
        let extra = max(0, quietModules - 1) * scale
        let side = picture.width * scale + 2 * extra
        let space = picture.colorSpace ?? CGColorSpace(name: CGColorSpace.sRGB)!
        let info = CGImageAlphaInfo.noneSkipLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue
        guard let canvas = CGContext(data: nil, width: side, height: side, bitsPerComponent: 8, bytesPerRow: side * 4,
                                     space: space, bitmapInfo: info) else { return nil }
        // The picture's own border is light in every channel, so its corner is the all-light color.
        let corner = rgba(picture).map { Array($0.prefix(3)) } ?? [255, 255, 255]
        let light = corner.map { CGFloat($0) / 255 } + [1]
        canvas.setFillColor(CGColor(colorSpace: space, components: light) ?? CGColor(gray: 1, alpha: 1))
        canvas.fill(CGRect(x: 0, y: 0, width: side, height: side))
        canvas.interpolationQuality = .none
        canvas.setShouldAntialias(false)
        canvas.draw(picture, in: CGRect(x: extra, y: extra, width: picture.width * scale, height: picture.height * scale))
        return canvas.makeImage()
    }

    public static func png(_ frames: [Data], palette: LinkFlashPalette = .pure, scale: Int = 8) -> Data? {
        guard let small = picture(frames, palette: palette), let large = image(small, scale: scale) else { return nil }
        return LinkFlashQR.encodePNG(large)
    }

    /// The bytes of a picture, four a pixel (red, green, blue and one unused), row by row from
    /// the top, with no color conversion: what the Flash screen hands to its shader.
    public static func pixels(_ picture: CGImage) -> [UInt8]? { rgba(picture) }

    /// The bytes of a picture as RGBX, drawn without any color conversion.
    static func rgba(_ picture: CGImage) -> [UInt8]? {
        let space = picture.colorSpace ?? CGColorSpace(name: CGColorSpace.sRGB)!
        guard space.model == .rgb else { return nil }
        var out = [UInt8](repeating: 0, count: picture.width * picture.height * 4)
        let info = CGImageAlphaInfo.noneSkipLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue
        let drawn: Bool = out.withUnsafeMutableBytes { buffer in
            guard let context = CGContext(data: buffer.baseAddress, width: picture.width, height: picture.height,
                                          bitsPerComponent: 8, bytesPerRow: picture.width * 4, space: space,
                                          bitmapInfo: info) else { return false }
            context.interpolationQuality = .none
            context.draw(picture, in: CGRect(x: 0, y: 0, width: picture.width, height: picture.height))
            return true
        }
        return drawn ? out : nil
    }

    /// A one-pixel-per-module gray code's bytes, row by row from the top.
    static func gray(_ code: CGImage) -> [UInt8]? {
        var out = [UInt8](repeating: 0, count: code.width * code.height)
        let drawn: Bool = out.withUnsafeMutableBytes { buffer in
            guard let context = CGContext(data: buffer.baseAddress, width: code.width, height: code.height,
                                          bitsPerComponent: 8, bytesPerRow: code.width,
                                          space: CGColorSpaceCreateDeviceGray(),
                                          bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return false }
            context.interpolationQuality = .none
            context.draw(code, in: CGRect(x: 0, y: 0, width: code.width, height: code.height))
            return true
        }
        return drawn ? out : nil
    }
}
#endif
