// by zayd/cold @ zayd.wtf

import Foundation

/// Where the sun and the moon are, ported line for line from real-shadows 1.2 (`ephemeris.ts`):
/// Paul Schlyter's low-precision method. Against astronomy-engine the package measures the sun
/// within 0.05 degrees and the moon within 0.2, far finer than a shadow a few points long.
/// `SunShadowTests` pins this port to the package's own output.
enum SkyEphemeris {
    struct Horizontal: Equatable, Sendable {
        /// Degrees above the horizon, negative below.
        var altitude: Double
        /// Degrees clockwise from true north: 90 east, 180 south.
        var azimuth: Double
    }

    private struct Sun {
        var ra, dec, dist, lon, meanAnomaly, perihelion, obliquity: Double
    }

    private struct Moon {
        var ra, dec, dist, lon: Double
    }

    private static let d2r = Double.pi / 180
    private static let r2d = 180 / Double.pi
    private static func rev(_ x: Double) -> Double { (x.truncatingRemainder(dividingBy: 360) + 360).truncatingRemainder(dividingBy: 360) }
    private static func sind(_ d: Double) -> Double { sin(d * d2r) }
    private static func cosd(_ d: Double) -> Double { cos(d * d2r) }
    private static func atan2d(_ y: Double, _ x: Double) -> Double { atan2(y, x) * r2d }

    static func julian(_ date: Date) -> Double { date.timeIntervalSince1970 / 86_400 + 2_440_587.5 }

    static func sun(_ date: Date, latitude: Double, longitude: Double) -> Horizontal {
        let jd = julian(date)
        let sun = solveSun(jd)
        return horizontal(jd, ra: sun.ra, dec: sun.dec, latitude: latitude, longitude: longitude)
    }

    /// The moon as the observer sees it: parallax lowers it by up to a degree, the difference
    /// between "risen" and "not yet".
    static func moon(_ date: Date, latitude: Double, longitude: Double) -> Horizontal {
        let jd = julian(date)
        let moon = solveMoon(jd, solveSun(jd))
        var position = horizontal(jd, ra: moon.ra, dec: moon.dec, latitude: latitude, longitude: longitude)
        position.altitude -= asin(1 / moon.dist) * r2d * cosd(position.altitude)
        return position
    }

    /// How much of the moon's disc is lit, 0 new to 1 full, from the sun-earth-moon geometry.
    static func moonLitFraction(_ date: Date) -> Double {
        let jd = julian(date)
        let sun = solveSun(jd)
        let moon = solveMoon(jd, sun)
        let sunDist = sun.dist * 23_454.8 // earth radii
        let cosElong = sind(sun.dec) * sind(moon.dec) + cosd(sun.dec) * cosd(moon.dec) * cosd(sun.ra - moon.ra)
        let elong = acos(max(-1, min(1, cosElong)))
        let phaseAngle = atan2(sunDist * sin(elong), moon.dist - sunDist * cos(elong))
        return (1 + cos(phaseAngle)) / 2
    }

    private static func solveSun(_ jd: Double) -> Sun {
        let d = jd - 2_451_543.5
        let w = 282.9404 + 4.70935e-5 * d
        let e = 0.016709 - 1.151e-9 * d
        let M = rev(356.047 + 0.9856002585 * d)
        let obliquity = 23.4393 - 3.563e-7 * d
        let E = M + r2d * e * sind(M) * (1 + e * cosd(M))
        let xv = cosd(E) - e
        let yv = sqrt(1 - e * e) * sind(E)
        let lon = rev(atan2d(yv, xv) + w)
        let xs = cosd(lon), ys = sind(lon)
        let ye = ys * cosd(obliquity), ze = ys * sind(obliquity)
        return Sun(ra: rev(atan2d(ye, xs)), dec: atan2d(ze, sqrt(xs * xs + ye * ye)), dist: sqrt(xv * xv + yv * yv),
                   lon: lon, meanAnomaly: M, perihelion: w, obliquity: obliquity)
    }

    private static func solveMoon(_ jd: Double, _ sun: Sun) -> Moon {
        let d = jd - 2_451_543.5
        let N = rev(125.1228 - 0.0529538083 * d)
        let i = 5.1454
        let w = rev(318.0634 + 0.1643573223 * d)
        let a = 60.2666
        let e = 0.0549
        let M = rev(115.3654 + 13.0649929509 * d)

        var E = M + r2d * e * sind(M) * (1 + e * cosd(M))
        E = E - (E - r2d * e * sind(E) - M) / (1 - e * cosd(E))

        let xv = a * (cosd(E) - e)
        let yv = a * (sqrt(1 - e * e) * sind(E))
        let v = atan2d(yv, xv)
        let r = sqrt(xv * xv + yv * yv)

        let xh = r * (cosd(N) * cosd(v + w) - sind(N) * sind(v + w) * cosd(i))
        let yh = r * (sind(N) * cosd(v + w) + cosd(N) * sind(v + w) * cosd(i))
        let zh = r * (sind(v + w) * sind(i))

        var lon = rev(atan2d(yh, xh))
        var lat = atan2d(zh, sqrt(xh * xh + yh * yh))

        let Ls = rev(sun.meanAnomaly + sun.perihelion)
        let Lm = rev(N + w + M)
        let D = rev(Lm - Ls)
        let F = rev(Lm - N)
        let Ms = sun.meanAnomaly

        // Split in two: one expression this long is slow for the type checker.
        var dLon = -1.274 * sind(M - 2 * D) + 0.658 * sind(2 * D) - 0.186 * sind(Ms)
        dLon += -0.059 * sind(2 * M - 2 * D) - 0.057 * sind(M - 2 * D + Ms) + 0.053 * sind(M + 2 * D)
        dLon += 0.046 * sind(2 * D - Ms) + 0.041 * sind(M - Ms) - 0.035 * sind(D)
        dLon += -0.031 * sind(M + Ms) - 0.015 * sind(2 * F - 2 * D) + 0.011 * sind(M - 4 * D)
        lon += dLon

        var dLat = -0.173 * sind(F - 2 * D) - 0.055 * sind(M - F - 2 * D) - 0.046 * sind(M + F - 2 * D)
        dLat += 0.033 * sind(F + 2 * D) + 0.017 * sind(2 * M + F)
        lat += dLat

        let dist = r - 0.58 * cosd(M - 2 * D) - 0.46 * cosd(2 * D)
        lon = rev(lon)

        let obl = sun.obliquity
        let cosLat = cosd(lat)
        let xg = cosd(lon) * cosLat, yg = sind(lon) * cosLat, zg = sind(lat)
        let ye = yg * cosd(obl) - zg * sind(obl)
        let ze = yg * sind(obl) + zg * cosd(obl)
        return Moon(ra: rev(atan2d(ye, xg)), dec: atan2d(ze, sqrt(xg * xg + ye * ye)), dist: dist, lon: lon)
    }

    private static func horizontal(_ jd: Double, ra: Double, dec: Double, latitude: Double, longitude: Double) -> Horizontal {
        let d = jd - 2_451_545.0
        let t = d / 36_525
        let lst = rev(280.46061837 + 360.98564736629 * d + 0.000387933 * t * t + longitude)
        let H = rev(lst - ra)
        let sinAlt = sind(latitude) * sind(dec) + cosd(latitude) * cosd(dec) * cosd(H)
        let altitude = asin(max(-1, min(1, sinAlt))) * r2d
        let azimuth = rev(atan2d(-cosd(dec) * sind(H), sind(dec) * cosd(latitude) - cosd(dec) * sind(latitude) * cosd(H)))
        return Horizontal(altitude: altitude, azimuth: azimuth)
    }
}
