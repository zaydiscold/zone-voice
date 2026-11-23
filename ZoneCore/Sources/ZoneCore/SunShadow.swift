// by zayd/cold @ zayd.wtf

import Foundation

/// The shadow a raised control casts if the light comes from where the sun or the moon really
/// is: real-shadows 1.2's `shadowVector` (front view, twilight on), in points instead of pixels.
///
/// No location permission. The clock is exact (the moment itself, not a wall-clock guess);
/// longitude is the time zone's standard meridian and latitude defaults to the Bay Area. That
/// moves sunrise and sunset by minutes, not the way a shadow a few points long leans.
///
/// The page is a wall the viewer faces, looking toward the equator. The morning sun is in the
/// east, on the left, so shadows fall to the right; they shorten toward noon and rake left
/// through the afternoon. After sunset the afterglow keeps casting from where the sun went down
/// and fades through civil twilight while the moon, if it is up, takes over at a strength set
/// by its phase. With nothing up the shadow settles to a short neutral one. Edges stay hard.
public struct SunShadow: Equatable, Sendable {
    public enum Source: String, Sendable { case sun, moon, none }

    public var dx: Double
    public var dy: Double
    public var alpha: Double
    /// The sun's own altitude in degrees, whatever is casting.
    public var sunAltitude: Double
    /// Which body is casting. Through twilight this is the moon when it is up, as in the package.
    public var source: Source

    public init(dx: Double, dy: Double, alpha: Double, sunAltitude: Double, source: Source = .sun) {
        self.dx = dx
        self.dy = dy
        self.alpha = alpha
        self.sunAltitude = sunAltitude
        self.source = source
    }

    /// Shadow length in points with the light overhead, and with it on the horizon. The package
    /// draws 3.8 to 11.4 px under web cards; keys and cards here are smaller and closer together.
    public static let defaultMinLength = 1.5
    public static let defaultMaxLength = 4.0
    /// The faintest a shadow gets. The package's 0.17 vanished on Zone's dark paper, which read
    /// as no shadow at all, so nothing here drops below half strength.
    public static let defaultMinAlpha = 0.5

    /// - Parameters:
    ///   - latitude: north positive. South of the equator the viewer faces north and the lean flips.
    ///   - longitude: east positive; nil takes the time zone's standard meridian.
    ///   - minLength: shadow length with the light overhead, in points.
    ///   - maxLength: shadow length with the light on the horizon.
    ///   - minAlpha: opacity with the light on the horizon, and the floor for moonlight and night.
    public static func at(_ date: Date = Date(), timeZone: TimeZone = .current, latitude: Double = 37.5,
                          longitude: Double? = nil, minLength: Double = defaultMinLength,
                          maxLength: Double = defaultMaxLength, minAlpha: Double = defaultMinAlpha) -> SunShadow {
        let lon = longitude ?? Double(timeZone.secondsFromGMT(for: date) - Int(timeZone.daylightSavingTimeOffset(for: date))) / 3600 * 15
        let sun = SkyEphemeris.sun(date, latitude: latitude, longitude: lon)
        let sunUp = sun.altitude >= sunset

        // How much of the shadow still belongs to the sun. Below the horizon it is the afterglow
        // casting, from the sun's own azimuth, gone by the end of civil twilight.
        let sunWeight = sunUp ? 1 : 1 - smoothstep((sunset - sun.altitude) / (sunset - civilDusk))

        var moon: SkyEphemeris.Horizontal?
        var moonIntensity = 0.0
        if !sunUp {
            let position = SkyEphemeris.moon(date, latitude: latitude, longitude: lon)
            if position.altitude > 0 {
                moon = position
                moonIntensity = fullMoonIntensity * moonBrightness(litFraction: SkyEphemeris.moonLitFraction(date))
            }
        }
        // A rising or setting moon eases in and out over its first four degrees.
        let moonWeight = moon.map { (1 - sunWeight) * smoothstep($0.altitude / moonEase) } ?? 0
        let ambientWeight = 1 - sunWeight - moonWeight

        // Blend whatever is casting. In full day and full night exactly one term survives; in
        // between the vector travels continuously instead of snapping across the page.
        var dx = ambientWeight * minLength
        var dy = ambientWeight * minLength
        var alpha = ambientWeight * minAlpha
        let facing: Double = latitude >= 0 ? 1 : -1
        func add(_ body: SkyEphemeris.Horizontal, intensity: Double, weight: Double) {
            let elevation = min(max(body.altitude, 0), 90)
            let overhead = sin(elevation * .pi / 180)
            // The package's curve: a low light stretches the shadow more than a linear map would.
            let length = minLength + (maxLength - minLength) * pow(1 - elevation / 90, 1.45)
            dx += weight * facing * sin(body.azimuth * .pi / 180) * length
            // A screen can only show the light's east or west lean; shadows always fall down the
            // page, deepest when the light is highest.
            dy += weight * (0.4 + 0.6 * overhead) * length
            alpha += weight * min(1, max((minAlpha + (1 - minAlpha) * overhead) * intensity, minAlpha))
        }
        if sunWeight > 0 { add(sun, intensity: 1, weight: sunWeight) }
        if let moon, moonWeight > 0 { add(moon, intensity: moonIntensity, weight: moonWeight) }
        return SunShadow(dx: dx, dy: dy, alpha: alpha, sunAltitude: sun.altitude,
                         source: sunUp ? .sun : moon != nil ? .moon : .none)
    }

    /// The refracted horizon: sunset as the eye sees it.
    static let sunset = -0.833
    /// The end of civil twilight.
    static let civilDusk = -6.0
    static let moonEase = 4.0
    /// A full moon's shadow against the sun's at the same altitude. Real moonlight is five orders
    /// of magnitude fainter, which would leave nothing on screen.
    static let fullMoonIntensity = 0.7

    static func smoothstep(_ u: Double) -> Double {
        let x = min(max(u, 0), 1)
        return x * x * (3 - 2 * x)
    }

    /// The lunar phase law (Allen), compressed by a fourth root into a range a screen can show:
    /// full 1, half about 0.55, crescent about 0.44. A linear ramp in the lit fraction is wrong;
    /// a half moon is 9 percent as bright as a full one.
    static func moonBrightness(litFraction: Double) -> Double {
        let f = min(max(litFraction, 0), 1)
        let a = acos(2 * f - 1) / .pi * 180
        let magnitudeDrop = 0.026 * a + 4e-9 * pow(a, 4)
        return pow(pow(10, -0.4 * magnitudeDrop), 0.25)
    }
}
