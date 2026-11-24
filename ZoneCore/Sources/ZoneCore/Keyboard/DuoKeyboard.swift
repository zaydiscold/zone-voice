// by zayd/cold @ zayd.wtf

import Foundation

/// Display and input-view bounds are different on Duo. The screen chooses row height;
/// the input view determines how much room the keys can actually use.
public enum DuoKeyboard: Equatable, Sendable {
    case ordinary, coverPortrait, coverLandscape, innerPortrait, innerLandscape

    public init(isDuo: Bool, screen: CGSize) {
        guard isDuo, screen.width > 0, screen.height > 0 else { self = .ordinary; return }
        let landscape = screen.width > screen.height
        if min(screen.width, screen.height) >= 600 {
            self = landscape ? .innerLandscape : .innerPortrait
        } else {
            self = landscape ? .coverLandscape : .coverPortrait
        }
    }

    public var allowsOneHand: Bool { self == .ordinary || self == .coverPortrait }

    public func metrics(width: CGFloat, windowInset: CGFloat) -> KeyGridMetrics {
        switch self {
        case .ordinary: return .standard(width: width)
        case .coverPortrait: return .init(sideInset: max(1, 7.7 - windowInset), keyHeight: 45, rowPitch: 56, bottomInset: 5)
        case .coverLandscape: return .init(sideInset: 4, keyHeight: 27.5, rowPitch: 35.5)
        case .innerPortrait: return .init(sideInset: max(1, 19 - windowInset), keyHeight: 46, rowPitch: 59.7, bottomInset: 5)
        case .innerLandscape: return .init(sideInset: width < 650 ? 6.5 : max(1, 85.3 - windowInset), keyHeight: 39, rowPitch: 51.7, bottomInset: 5)
        }
    }
}

/// Resolves the physical fold in input-view coordinates. A narrow Split View host
/// can lie wholly on one side, or straddle the fold without room for two groups.
public struct DuoKeyPlacement: Equatable {
    public let leading: CGFloat
    public let trailing: CGFloat
    public let offersSplit: Bool
    public let split: Bool
    public let forced: Bool

    public init(pose: DuoKeyboard, width: CGFloat, center: CGFloat, side: CGFloat,
                safeLeft: CGFloat, safeRight: CGFloat, division: CGRect?, prefersSplit: Bool) {
        let left = max(0, safeLeft), right = min(width, width - safeRight)
        let fold = division.flatMap { $0.maxX > left && $0.minX < right ? $0 : nil }
        let axis = fold?.midX ?? center
        let span = min(axis - left, right - axis)
        let innerCapEdge = side + 5.5 * 57 - 10.7
        let fits = pose == .innerLandscape && span >= innerCapEdge + max(20, (fold?.width ?? 0) / 2) + 6
        offersSplit = fits
        forced = fold != nil && fits
        split = fits && (forced || prefersSplit)
        if split {
            leading = axis - span
            trailing = width - axis - span
        } else if let fold {
            let useRight = right - fold.maxX >= fold.minX - left
            leading = useRight ? fold.maxX : left
            trailing = useRight ? width - right : width - fold.minX
        } else {
            leading = left
            trailing = width - right
        }
    }
}

public extension DuoKeyboard {
    static let isCurrentDevice: Bool = {
        #if targetEnvironment(simulator)
        return ProcessInfo.processInfo.environment["SIMULATOR_MODEL_IDENTIFIER"] == "iPhone19,4"
        #else
        var name = utsname()
        uname(&name)
        return withUnsafeBytes(of: &name.machine) {
            String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) == "iPhone19,4"
        }
        #endif
    }()

    static let splitPreferenceKey = "zone.duo.split"

    static var prefersSplit: Bool {
        get {
            let shared = UserDefaults(suiteName: AppGroup.identifier)
            if let saved = shared?.object(forKey: splitPreferenceKey) as? Bool { return saved }
            guard let previous = UserDefaults.standard.object(forKey: splitPreferenceKey) as? Bool else { return false }
            shared?.set(previous, forKey: splitPreferenceKey)
            return previous
        }
        set {
            UserDefaults.standard.set(newValue, forKey: splitPreferenceKey)
            UserDefaults(suiteName: AppGroup.identifier)?.set(newValue, forKey: splitPreferenceKey)
        }
    }
}
