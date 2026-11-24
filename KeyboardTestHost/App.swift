// by zayd/cold @ zayd.wtf

import UIKit
import SwiftUI
import Observation
import ZoneCore

/// Test double for the unrelated dictation coordinator. The actual production grid and model
/// below receive UIKit touches; this harness never records audio or requests Full Access.
@MainActor @Observable final class MicController {
    var mode = KeyboardMode.type
    enum HistoryPanel {
        case loading, needsFullAccess, unreachable, off, loaded([TranscriptRecord])
    }
    var history: HistoryPanel? = .loaded([])
    var onClose: (() -> Void)?
    func hideHistory() { onClose?() }
    func reinsert(_ record: TranscriptRecord) {}
    var panelSection: String?
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
        #if targetEnvironment(simulator)
        if let index = args.firstIndex(of: "--zone-panel-fixture"), args.indices.contains(index + 1),
           let container = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: ZoneContract.appGroup) {
            try? args[index + 1].write(to: container.appendingPathComponent("keyboard-fixture.txt"),
                                       atomically: true, encoding: .utf8)
        }
        #endif
        window.rootViewController = args.contains("--prediction-strip") ? UIHostingController(rootView: PredictionStripHarness())
            : args.contains("--provider-sample") ? UIHostingController(rootView: ProviderSampleHarness())
            : args.contains("--apple-oracle") ? AppleOracleHarness()
            : args.contains("--native-proxy") ? NativeSwipeHarness() : Harness()
        window.makeKeyAndVisible()
        self.window = window
        return true
    }
}

/// Runs the production client against a synthetic WAV staged in this test app's own cache.
private struct ProviderSampleHarness: View {
    @State private var status = "Checking provider"

    var body: some View {
        Text(status).accessibilityIdentifier("provider-sample").task {
            let directory = URL.cachesDirectory
            let config = directory.appendingPathComponent("zone-provider-sample-route.json")
            let audio = directory.appendingPathComponent("zone-provider-sample.wav")
            do {
                let route = try JSONDecoder().decode(KeyboardVoiceRoute.self, from: Data(contentsOf: config))
                try FileManager.default.removeItem(at: config)
                let result = try await ComputerSpeechProvider.recognize(audio, using: route, timeout: 40)
                status = result.text
            } catch {
                let error = error as NSError
                status = "Provider check failed (\(error.domain), \(error.code))"
            }
            try? status.write(to: directory.appendingPathComponent("zone-provider-sample-result.txt"), atomically: true, encoding: .utf8)
        }
    }
}

private struct PredictionStripHarness: View {
    @State private var size = DynamicTypeSize.large
    @State private var width: CGFloat = 155

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            SuggestionBar(suggestions: [.init(text: "Mountainside", kind: .prediction),
                                        .init(text: "🍕", kind: .prediction)],
                          theme: KeyboardTheme(isDark: false)) { _ in }
                .environment(\.dynamicTypeSize, size)
                .frame(width: width)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier("prediction-strip")
                .frame(width: 220, height: 44, alignment: .topLeading)
            Button("Normal") { size = .large }
            Button("Large") { size = .xxxLarge }
            Button("Largest") { size = .accessibility5 }
            Button("Wider") { width = 220 }
        }
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
    private var historyHost: UIHostingController<HistoryPanelView>?
    private let recent = UIButton(type: .system)
    private var timer: Timer?
    private let pasteScenario = ProcessInfo.processInfo.arguments.contains("--paste-key")
    private var pasteAppearance: Bool?
    private let pasteSetup = UIStackView()
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
        if pasteScenario {
            pasteAppearance = ProcessInfo.processInfo.arguments.contains("--dark-paste")
            UIPasteboard.general.items = []
            for (title, action): (String, () -> Void) in [
                ("Appearance", { [weak self] in self?.flipPasteAppearance() }),
                ("Copy test text", {
                    if args.contains("--marked-clipboard") {
                        UIPasteboard.general.setItems([["public.utf8-plain-text": "private sample", "org.nspasteboard.ConcealedType": Data()]])
                    } else {
                        UIPasteboard.general.string = "clipboard sample"
                    }
                }),
                ("Clear clipboard", { UIPasteboard.general.items = [] }),
                ("Toggle Paste", { [weak self] in self?.togglePaste() }),
            ] {
                let button = UIButton(type: .system)
                button.setTitle(title, for: .normal)
                button.addAction(UIAction { _ in action() }, for: .touchUpInside)
                pasteSetup.addArrangedSubview(button)
            }
            pasteSetup.axis = .horizontal
            pasteSetup.distribution = .fillEqually
            view.addSubview(pasteSetup)
        }
        model.refreshFullAccess(reloadVocabulary: false)
        model.refreshTraits()
        model.apply(KeyboardPreferences(showSuggestions: true, showsPasteKey: pasteScenario, swipeTypingEnabled: !args.contains("--no-swipe"), swipeLearningEnabled: false))
        grid = KeyGridView(model: model, mic: mic, controller: nil)
        grid.backgroundColor = .systemGray5
        if pasteScenario { applyPasteBackdrop() }
        view.addSubview(grid)
        if args.contains("--clipboard-panel") {
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent("panel-\(UUID().uuidString)")
            let history = ClipboardHistory(directory: directory)
            let savedCopy = ProcessInfo.processInfo.environment["ZONE_TEST_SAVED_COPY"] ?? "older saved copy"
            history.add(savedCopy, route: .saved)
            let suite = "wtf.zayd.zone.KeyboardTestHost.clipboard"
            let settingsStore = UserDefaultsSharedStore(suiteName: suite)
            let preferences = KeyboardPreferences(clipboardHistoryEnabled: true, clipboardSkipsSecrets: true,
                                                  clipboardAutomatic: args.contains("--clipboard-automatic"))
            settingsStore.keyboardPreferences = preferences
            let controller = ClipboardController(source: SystemClipboard(), history: history,
                seen: UserDefaults(suiteName: suite).map(SharedClipboardSeenStore.init(defaults:)),
                settings: { .init(enabled: preferences.clipboardHistoryEnabled, skipsSecrets: preferences.clipboardSkipsSecrets,
                                  automatic: preferences.clipboardAutomatic) },
                field: { .ordinary }, hasOpenAccess: { true })
            // Strong: this closure keeps the test host's controller alive.
            model.pasteSaving = PasteSaving(tap: { controller.pasteTapped() }, keep: { controller.pasted($0, types: $1, token: $2) })
            if args.contains("--clipboard-save") { UIPasteboard.general.string = "new edge copy" }
            let baseline = Self.footprint()
            controller.tab = .clipboard
            controller.keyboardBecameLive()
            recent.setTitle(controller.historyTitle, for: .normal)
            recent.addAction(UIAction { [weak self] _ in
                guard let self else { return }
                let host = UIHostingController(rootView: HistoryPanelView(mic: mic, model: model, clipboard: controller, theme: KeyboardTheme(isDark: false)))
                addChild(host)
                view.addSubview(host.view)
                host.view.frame = grid.frame
                host.didMove(toParent: self)
                historyHost = host
            }, for: .touchUpInside)
            mic.onClose = { [weak self] in
                guard let host = self?.historyHost else { return }
                host.willMove(toParent: nil)
                host.view.removeFromSuperview()
                host.removeFromParent()
                self?.historyHost = nil
                if args.contains("--clipboard-image") {
                    let board = UIPasteboard.general
                    let copied = board.hasImages && board.contains(pasteboardTypes: [ClipboardPolicy.ownType])
                    let end = Self.footprint()
                    let notice = controller.pasteNotice ?? "Missing image notice"
                    self?.output.text = copied ? "\(notice) Baseline \(baseline.current), peak before \(baseline.peak), peak after \(end.peak) bytes." : "Image missing from clipboard"
                }
            }
            view.addSubview(recent)
        }
        timer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.ready.text = self?.model.canSwipe == true ? "Swipe ready" : "Preparing swipe"
            }
        }
    }
    private static func footprint() -> (current: UInt64, peak: Int64) {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout.size(ofValue: info) / MemoryLayout<integer_t>.stride)
        let capacity = Int(count)
        let status = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: capacity) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        return status == KERN_SUCCESS ? (info.phys_footprint, info.ledger_phys_footprint_peak) : (0, 0)
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        output.frame = CGRect(x: 20,y: 140,width:view.bounds.width-40,height:60)
        ready.frame = CGRect(x:20,y:210,width:view.bounds.width-40,height:40)
        caret.frame = CGRect(x:20,y:260,width:view.bounds.width-40,height:40)
        grid.frame = CGRect(x:0,y:view.bounds.height-300,width:view.bounds.width,height:250)
        recent.frame = CGRect(x: 14, y: grid.frame.minY - 44, width: 150, height: 44)
        historyHost?.view.frame = grid.frame
        if pasteScenario {
            let safe = view.safeAreaLayoutGuide.layoutFrame
            pasteSetup.frame = CGRect(x: safe.minX, y: grid.frame.minY - 48, width: safe.width, height: 44)
        }
    }
    private func flipPasteAppearance() {
        pasteAppearance = !(pasteAppearance ?? false)
        applyPasteBackdrop()
        model.refreshTraits()
        grid.sync()
    }

    private func applyPasteBackdrop() {
        let theme = KeyboardTheme(isDark: pasteAppearance == true)
        grid.backgroundColor = UIColor(theme.background)
    }

    private func togglePaste() {
        var preferences = model.preferences
        preferences.showsPasteKey.toggle()
        model.apply(preferences)
        grid.sync()
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
    var hasOpenAccess: Bool { pasteScenario }
    var explicitDarkAppearance: Bool? { pasteAppearance }
    var needsGlobeKey: Bool { false }
    func advanceToNextInputMode() {}
    func playClick() {}
    func open(_ url: URL) {}
}
