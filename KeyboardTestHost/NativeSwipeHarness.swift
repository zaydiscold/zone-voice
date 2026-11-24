// by zayd/cold @ zayd.wtf

import SwiftUI
import UIKit
import ZoneCore

/// Real UIKit host + input controller, to exercise UITextDocumentProxy rather than infer
/// its touch and callback behavior from the test double. This target is never embedded in Zone.
@MainActor final class NativeSwipeHarness: UIViewController, UITextViewDelegate {
    private let field = SwipeTextView()
    private let caret = UILabel()
    private let cursorAudit = UILabel()
    private let selectWord = UIButton(type: .system)
    private var replacedDuringCursor = false
    private var readyForCursorReplacement = false
    override func viewDidLoad() {
        super.viewDidLoad()
        let args = ProcessInfo.processInfo.arguments
        if args.contains("--dark") { overrideUserInterfaceStyle = .dark }
        view.backgroundColor = .systemBackground
        field.accessibilityIdentifier = "native-field"
        field.font = .systemFont(ofSize: 24)
        if PromoCapture.enabled {
            view.backgroundColor = PromoCapture.paper
            field.backgroundColor = .clear
            field.textColor = PromoCapture.ink
            field.tintColor = UIColor(KeyboardTheme.accent)
            field.font = .systemFont(ofSize: 33, weight: .medium)
            caret.isHidden = true
        }
        field.autocorrectionType = .no
        field.autocapitalizationType = .none
        field.delegate = self
        // Launch arguments end at a newline, so tests write line breaks as a literal "\\n".
        if let i = args.firstIndex(of: "--text"), args.indices.contains(i + 1) {
            field.text = args[i + 1].replacingOccurrences(of: "\\n", with: "\n")
        }
        caret.accessibilityIdentifier = "caret"
        view.addSubview(field); view.addSubview(caret)
        // `--select WORD`: a button that selects that word the way a double tap would, so a test
        // reaches the keyboard through the real selection callbacks.
        if let i = args.firstIndex(of: "--select"), args.indices.contains(i + 1) {
            let word = args[i + 1]
            selectWord.setTitle("Select", for: .normal)
            selectWord.accessibilityIdentifier = "select-word"
            selectWord.addAction(UIAction { [weak self] _ in
                guard let self else { return }
                let range = (self.field.text as NSString).range(of: word)
                if range.location != NSNotFound { self.field.selectedRange = range }
            }, for: .touchUpInside)
            view.addSubview(selectWord)
        }
        if ProcessInfo.processInfo.arguments.contains("--audit-cursor") {
            cursorAudit.accessibilityIdentifier = "cursor-requests"
            NativeCursorAudit.label = cursorAudit
            NativeCursorAudit.reset()
            view.addSubview(cursorAudit)
        }

    }
    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        field.frame = CGRect(x: 20, y: PromoCapture.enabled ? view.bounds.height - 425 : 100, width: view.bounds.width - 40, height: 180)
        caret.frame = CGRect(x: 20, y: 290, width: view.bounds.width - 40, height: 40)
        selectWord.frame = CGRect(x: 20, y: 56, width: 120, height: 40)
        cursorAudit.frame = CGRect(x: 20, y: 330, width: view.bounds.width - 40, height: 40)
    }
    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        field.becomeFirstResponder()
        field.selectedRange = NSRange(location: field.text.utf16.count, length: 0)
        textViewDidChangeSelection(field)
        readyForCursorReplacement = true
    }
    func textViewDidChangeSelection(_ textView: UITextView) {
        caret.text = "UTF16: \(textView.selectedRange.location)"
        NativeCursorAudit.observedSelection(textView.selectedRange.location)
        if ProcessInfo.processInfo.arguments.contains("--replace-during-cursor"),
           readyForCursorReplacement, !replacedDuringCursor, textView.isFirstResponder,
           textView.selectedRange.location < textView.text.utf16.count {
            replacedDuringCursor = true
            // Model an editor/autofill changing the document while a finger is scrubbing.
            // No synthetic model callback: the next movement must validate fresh context.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.03) { [weak self] in
                guard let self else { return }
                NativeCursorAudit.beginReplacement()
                let notify = ProcessInfo.processInfo.arguments.contains("--notify-input-delegate")
                if notify {
                    self.field.inputDelegate?.textWillChange(self.field)
                    self.field.inputDelegate?.selectionWillChange(self.field)
                }
                self.field.text = "replacement"
                self.field.selectedRange = NSRange(location: 11, length: 0)
                if notify {
                    self.field.inputDelegate?.selectionDidChange(self.field)
                    self.field.inputDelegate?.textDidChange(self.field)
                }
                self.caret.text = "UTF16: \(self.field.selectedRange.location)"
            }
        }
    }
}

@MainActor private final class SwipeTextView: UITextView {
    private let keyboard = SwipeInputController()
    override var inputViewController: UIInputViewController? { keyboard }
}

@MainActor private final class SwipeInputController: UIInputViewController, TextProxyActions {
    private var model: KeyboardModel!
    private let mic = MicController()
    /// `--suggestions`: the model's suggestions as plain buttons above the keys, since this
    /// harness hosts the key grid without Zone's strip.
    private let suggestionRow = UIStackView()
    private var shownSuggestions: [Suggestion] = []
    private var showsEmojiPredictions: Bool { ProcessInfo.processInfo.arguments.contains("--emoji-predictions") }
    private var showsEmojiShortcodes: Bool { ProcessInfo.processInfo.arguments.contains("--emoji-shortcodes") }
    private var showsSuggestions: Bool { ProcessInfo.processInfo.arguments.contains("--suggestions") || showsEmojiShortcodes || showsEmojiPredictions }
    override func loadView() {
        let input = UIInputView(frame: CGRect(x: 0, y: 0, width: 402, height: showsSuggestions ? 294 : 250), inputViewStyle: .keyboard)
        input.allowsSelfSizing = true
        input.backgroundColor = .systemGray5
        view = input
    }
    override func viewDidLoad() {
        super.viewDidLoad()
        model = KeyboardModel(proxy: self)
        model.apply(KeyboardPreferences(autocorrectEnabled: ProcessInfo.processInfo.arguments.contains("--autocorrect"),
            showSuggestions: showsSuggestions,
            swipeTypingEnabled: !ProcessInfo.processInfo.arguments.contains("--no-swipe"), swipeLearningEnabled: PromoCapture.enabled,
            smartPunctuation: ProcessInfo.processInfo.arguments.contains("--smart-punctuation")))
        let grid = KeyGridView(model: model, mic: mic, controller: self)
        let dark = ProcessInfo.processInfo.arguments.contains("--dark")
        model.setSystemDark(dark)
        grid.backgroundColor = showsEmojiShortcodes || showsEmojiPredictions || PromoCapture.enabled ? UIColor(KeyboardTheme(isDark: dark).background) : .systemGray5
        grid.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(grid)
        NSLayoutConstraint.activate([
            grid.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            grid.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            grid.topAnchor.constraint(equalTo: view.topAnchor, constant: showsSuggestions ? 44 : 0),
            grid.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            grid.heightAnchor.constraint(equalToConstant: 250)
        ])
    }
    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        model.refreshTraits()
        if PromoCapture.enabled {
            guard children.isEmpty else { return }
            let theme = KeyboardTheme(isDark: ProcessInfo.processInfo.arguments.contains("--dark"))
            let row = UIHostingController(rootView: PromoSuggestionRow(model: model, theme: theme))
            addChild(row)
            row.view.frame = CGRect(x: 0, y: 0, width: view.bounds.width, height: 44)
            row.view.autoresizingMask = .flexibleWidth
            view.addSubview(row.view)
            row.didMove(toParent: self)
            let touches = PromoTouchIndicator()
            touches.cancelsTouchesInView = false
            touches.delaysTouchesEnded = false
            view.addGestureRecognizer(touches)
            return
        }
        if showsEmojiShortcodes || showsEmojiPredictions {
            guard children.isEmpty else { return }
            let theme = KeyboardTheme(isDark: ProcessInfo.processInfo.arguments.contains("--dark"))
            let row = UIHostingController(rootView: NativeEmojiRow(model: model, theme: theme, words: showsEmojiPredictions)
                .padding(.horizontal, 75).frame(height: 44).background(theme.background))
            addChild(row)
            row.view.frame = CGRect(x: 0, y: 0, width: view.bounds.width, height: 44)
            row.view.autoresizingMask = .flexibleWidth
            view.addSubview(row.view)
            row.didMove(toParent: self)
            return
        }
        guard showsSuggestions, suggestionRow.superview == nil else { return }
        suggestionRow.distribution = .fillEqually
        suggestionRow.frame = CGRect(x: 0, y: 0, width: view.bounds.width, height: 44)
        suggestionRow.autoresizingMask = .flexibleWidth
        view.addSubview(suggestionRow)
        Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshSuggestionRow() }
        }
    }
    private func refreshSuggestionRow() {
        guard model.suggestions != shownSuggestions else { return }
        shownSuggestions = model.suggestions
        suggestionRow.arrangedSubviews.forEach { $0.removeFromSuperview() }
        for suggestion in shownSuggestions {
            let button = UIButton(type: .system)
            button.setTitle(suggestion.text, for: .normal)
            button.accessibilityIdentifier = "suggestion-" + suggestion.text
            button.addAction(UIAction { [weak self] _ in self?.model.choose(suggestion) }, for: .touchUpInside)
            suggestionRow.addArrangedSubview(button)
        }
    }
    override func textDidChange(_ textInput: UITextInput?) { model?.hostTextDidChange() }
    override func selectionDidChange(_ textInput: UITextInput?) { model?.hostSelectionDidChange() }
    func userTouchedKeyboard() {}
    func insert(_ text: String) { textDocumentProxy.insertText(text) }
    func adjustTextPosition(byCharacterOffset offset: Int) {
        NativeCursorAudit.submitted(offset)
        textDocumentProxy.adjustTextPosition(byCharacterOffset: offset)
    }
    func deleteBackward() { textDocumentProxy.deleteBackward() }
    func contextBefore() -> String? { textDocumentProxy.documentContextBeforeInput }
    func contextAfter() -> String? { textDocumentProxy.documentContextAfterInput }
    func fieldHasText() -> Bool { textDocumentProxy.hasText }
    func selectedText() -> String? { textDocumentProxy.selectedText }
    func currentInputSession() -> String? { "native-field" }
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
    func playClick() {}
    func open(_ url: URL) {}
}

/// Test-only audit of request submission, distinct from UIKit applying a queued movement.
@MainActor private enum NativeCursorAudit {
    static weak var label: UILabel?
    private static var replaced = false
    private static var before = 0
    private static var after = 0
    private static var pending: [Int] = []
    private static var lastSelection: Int?
    static func reset() {
        replaced = false; before = 0; after = 0; pending = []; lastSelection = nil; render()
    }
    static func beginReplacement() { guard label != nil else { return }; replaced = true; render() }
    static func submitted(_ offset: Int) {
        guard label != nil else { return }
        if replaced { after += 1 } else { before += 1 }
        pending.append(offset)
        render()
    }
    static func observedSelection(_ location: Int) {
        guard label != nil else { return }
        if let previous = lastSelection, previous != location {
            // The ASCII fixture's actual UITextView selection changes acknowledge
            // submissions, including multiple deltas coalesced into one notification.
            var delta = 0
            for (index, offset) in pending.enumerated() {
                delta += offset
                if delta == location - previous { pending.removeFirst(index + 1); break }
            }
        }
        lastSelection = location
        render()
    }
    private static func render() {
        label?.text = "\(before),\(after),\(pending.count),\(replaced ? "replaced" : "waiting")"
    }
}

private struct NativeEmojiRow: View {
    let model: KeyboardModel
    let theme: KeyboardTheme
    let words: Bool

    var body: some View {
        if words {
            SuggestionBar(suggestions: model.suggestions, theme: theme, onChoose: model.choose)
        } else {
            EmojiSuggestionBar(model: model, theme: theme)
        }
    }
}
