// by zayd/cold @ zayd.wtf

#if DEBUG
import Foundation
import ZoneCore

/// Debug builds only: `-zoneKeyboardStandIn` plays the Zone keyboard during the terminal setup
/// on a simulator, where a UI test cannot reach into the real extension. It writes what
/// `MicController` writes, to the same App Group store, with the same pings: its presence when
/// the practice box takes focus (the keyboard stamps it when it appears there), a request on the
/// dictate step, and Stop once the words have stopped coming. Everything on the app's side is
/// the real path. With `-zoneFakeSpeech` the words come from the script.
@MainActor
final class SetupKeyboardStandIn {
    static func ifRequested() -> SetupKeyboardStandIn? {
        ProcessInfo.processInfo.arguments.contains("-zoneKeyboardStandIn") ? SetupKeyboardStandIn() : nil
    }

    private let store = UserDefaultsSharedStore()
    private var task: Task<Void, Never>?

    private var began = false

    /// Starts as a keyboard that has never run, whatever an earlier run left in the store. Once
    /// per launch, from the screen's appearance: SwiftUI makes the `@State` value more than once.
    func begin() {
        guard !began else { return }
        began = true
        store.keyboardPresence = nil
    }

    func keyboardAppeared() {
        store.keyboardPresence = KeyboardPresence(lastSeen: Date(), hasFullAccess: true)
        DarwinNotifier.post(.keyboardShown)
    }

    /// Taps the mic a moment after the step is asked, stops 1.5 s after the last new word, and
    /// hands the result to `insert` as the keyboard would type it.
    func dictate(coordinator: DictationCoordinator, insert: @escaping (String) -> Void) {
        guard task == nil else { return }
        let store = store
        task = Task {
            try? await Task.sleep(for: .seconds(1.5))
            let generation = store.ledger.droppedGeneration + 1
            let request = DictationRequest(id: UUID(), generation: generation, createdAt: Date(),
                                           inputSession: "setup-stand-in", contextBefore: "")
            store.control = nil
            store.keyboardPresence = KeyboardPresence(lastSeen: Date(), hasFullAccess: true)
            store.request = request
            store.status = DictationStatus(requestID: request.id, generation: generation, phase: .requested,
                                           updatedAt: Date(), message: nil)
            DarwinNotifier.post(.requestChanged)

            let began = Date()
            var heard = "", steadySince = Date(), lastStamp = Date()
            while !Task.isCancelled, Date().timeIntervalSince(began) < 20 {
                try? await Task.sleep(for: .milliseconds(200))
                if Date().timeIntervalSince(lastStamp) >= 1 {
                    store.keyboardPresence = KeyboardPresence(lastSeen: Date(), hasFullAccess: true)
                    lastStamp = Date()
                }
                guard case .recording = coordinator.activity else { continue }
                let words = coordinator.liveTranscript
                if words != heard { heard = words; steadySince = Date() }
                if !words.isEmpty, Date().timeIntervalSince(steadySince) > 1.5 { break }
            }
            store.control = DictationControl(requestID: request.id, generation: generation, action: .stop, issuedAt: Date())
            DarwinNotifier.post(.controlChanged)
            for _ in 0..<150 {
                try? await Task.sleep(for: .milliseconds(100))
                if let result = store.result, result.requestID == request.id {
                    guard store.claimInsertion(result, explicitlyRequested: false, now: Date()) else { return }
                    insert(result.text)
                    store.acknowledgeInsertion(request.id)
                    DarwinNotifier.post(.payloadConsumed)
                    return
                }
            }
        }
    }
}
#endif
