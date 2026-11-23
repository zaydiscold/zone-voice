// by zayd/cold @ zayd.wtf

import UIKit
import Observation
import ZoneCore

/// Test double for the unrelated dictation coordinator. The actual production grid and model
/// below receive UIKit touches; this harness never records audio or requests Full Access.
@MainActor @Observable final class MicController {
    var mode = KeyboardMode.type
    var showsHistory = false
    func userTypedKey() {}
    /// Hold space to talk: off unless a test turns it on, and counted.
    var talkAvailable = false
    var spaceTalkPhase = SpaceTalk.Phase.none
    private(set) var holdsBegan = 0
    private(set) var holdsEnded = 0
    /// The strip explains (Zone not ready): the hold is talking's, with no dictation.
    var explainsInsteadOfTalking = false
    func spaceHoldBegan() -> Bool {
        holdsBegan += 1
        if talkAvailable, !explainsInsteadOfTalking { spaceTalkPhase = .starting }
        return talkAvailable
    }
    func spaceHoldEnded() {
        holdsEnded += 1
        spaceTalkPhase = .none
    }
}

@main @MainActor final class App: UIResponder, UIApplicationDelegate {
    var window: UIWindow?
    func application(_ app: UIApplication, didFinishLaunchingWithOptions options: [UIApplication.LaunchOptionsKey: Any]?) -> Bool {
        let window = UIWindow(frame: UIScreen.main.bounds)
        let args = ProcessInfo.processInfo.arguments
        window.rootViewController = args.contains("--apple-oracle") ? AppleOracleHarness()
            : args.contains("--native-proxy") ? NativeSwipeHarness() : Harness()
        window.makeKeyAndVisible()
        self.window = window
        return true
    }
}

@MainActor final class Harness: UIViewController, TextProxyActions {
    private let output = UILabel()
    private let ready = UILabel()
    private let caret = UILabel()
    private var tail = ""
    private var text = ""
    private let mic = MicController()
    private var model: KeyboardModel!
    private var grid: KeyGridView!
    private var timer: Timer?
    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground
        output.accessibilityIdentifier = "output"
        output.font = .systemFont(ofSize: 28)
        ready.accessibilityIdentifier = "ready"
        caret.accessibilityIdentifier = "caret"
        view.addSubview(output); view.addSubview(ready); view.addSubview(caret)
        let args = ProcessInfo.processInfo.arguments
        // Launch arguments end at a newline, so tests write line breaks as a literal "\\n".
        if let seed = args.firstIndex(of: "--text"), args.indices.contains(seed + 1) {
            text = args[seed + 1].replacingOccurrences(of: "\\n", with: "\n")
        }
        refreshOutput()
        model = KeyboardModel(proxy: self)
        model.refreshTraits()
        model.apply(KeyboardPreferences(showSuggestions: true, swipeTypingEnabled: !args.contains("--no-swipe"), swipeLearningEnabled: false))
        grid = KeyGridView(model: model, mic: mic, controller: nil)
        grid.backgroundColor = .systemGray5
        view.addSubview(grid)
        timer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.ready.text = self?.model.canSwipe == true ? "Swipe ready" : "Preparing swipe"
            }
        }
    }
    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        output.frame = CGRect(x: 20,y: 140,width:view.bounds.width-40,height:60)
        ready.frame = CGRect(x:20,y:210,width:view.bounds.width-40,height:40)
        caret.frame = CGRect(x:20,y:260,width:view.bounds.width-40,height:40)
        grid.frame = CGRect(x:0,y:view.bounds.height-300,width:view.bounds.width,height:250)
    }
    func userTouchedKeyboard() {}
    private func refreshOutput() { output.text = text + tail; caret.text = "Cursor: \(text.count)" }
    func insert(_ text: String) { self.text += text; refreshOutput() }
    func adjustTextPosition(byCharacterOffset offset: Int) {
        let joined = (text + tail) as NSString
        let position = min(joined.length, max(0, text.utf16.count + offset))
        text = joined.substring(to: position); tail = joined.substring(from: position)
        refreshOutput()
    }
    func deleteBackward() { if !text.isEmpty { text.removeLast() }; refreshOutput() }
    func contextBefore() -> String? { text }
    func contextAfter() -> String? { tail }
    func fieldHasText() -> Bool { !text.isEmpty || !tail.isEmpty }
    func selectedText() -> String? { nil }
    func currentInputSession() -> String? { "harness" }
    var returnKeyLabel: String { "return" }
    var autocapitalizesSentences: Bool { false }
    var fieldNeverCapitalizes: Bool { true }
    var allowsAutocorrection: Bool { true }
    var allowsSwipeTyping: Bool { true }
    var allowsSmartQuotes: Bool { true }
    var allowsSmartDashes: Bool { true }
    var prefersNumbers: Bool { false }
    var fieldKeys: [String] { [] }
    var capitalization: FieldCapitalization { .none }
    var isSearchField: Bool { false }
    var dimsReturnWhenEmpty: Bool { false }
    var hasOpenAccess: Bool { false }
    var explicitDarkAppearance: Bool? { nil }
    var needsGlobeKey: Bool { false }
    func advanceToNextInputMode() {}
    func playClick() {}
    func open(_ url: URL) {}
}
