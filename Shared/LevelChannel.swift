// by zayd/cold @ zayd.wtf

import Foundation
import notify

/// The live microphone level, app to keyboard, at 20 Hz while the keyboard dictates.
///
/// A Darwin notification with 64 bits of state, not the shared defaults file: a defaults write
/// is a cfprefsd round trip and an eventual disk write (measured on the M4 Mac: about 77 us a
/// write, against about 8 us for set plus post), and the keyboard polled it on its own 20 Hz timer,
/// which drifted against the app's and doubled or dropped samples. Here the app sets the state
/// and posts; the keyboard reads it in the post's handler, one sample per post, and wakes only
/// when one exists. If the keyboard's main thread stalls, the handlers it owes run late and all
/// read the newest level, which is the right thing for a meter. The level is the low 32 bits,
/// a Float's bit pattern, clamped to 0...1 on read.
enum LevelChannel {
    static let name = "wtf.zayd.zone.level"

    static func encode(_ level: Float) -> UInt64 { UInt64(level.bitPattern) }

    static func decode(_ state: UInt64) -> Float {
        let level = Float(bitPattern: UInt32(truncatingIfNeeded: state))
        return level.isFinite ? min(max(level, 0), 1) : 0
    }

    /// The app's end. One token for the process; registering is the expensive part.
    @MainActor
    final class Publisher {
        private var token: Int32 = NOTIFY_TOKEN_INVALID

        init() {
            if notify_register_check(LevelChannel.name, &token) != NOTIFY_STATUS_OK {
                token = NOTIFY_TOKEN_INVALID
            }
        }

        func send(_ level: Float) {
            guard token != NOTIFY_TOKEN_INVALID else { return }
            notify_set_state(token, LevelChannel.encode(level))
            notify_post(LevelChannel.name)
        }
    }

    /// The keyboard's end: calls `onLevel` on the main queue for every level the app posts,
    /// until `cancel()` or deinit.
    final class Subscription {
        private var token: Int32 = NOTIFY_TOKEN_INVALID

        init(onLevel: @escaping @MainActor (Float) -> Void) {
            let status = notify_register_dispatch(LevelChannel.name, &token, .main) { token in
                var state: UInt64 = 0
                notify_get_state(token, &state)
                let level = LevelChannel.decode(state)
                MainActor.assumeIsolated { onLevel(level) }
            }
            if status != NOTIFY_STATUS_OK { token = NOTIFY_TOKEN_INVALID }
        }

        var isActive: Bool { token != NOTIFY_TOKEN_INVALID }

        func cancel() {
            guard token != NOTIFY_TOKEN_INVALID else { return }
            notify_cancel(token)
            token = NOTIFY_TOKEN_INVALID
        }

        deinit { cancel() }
    }
}
