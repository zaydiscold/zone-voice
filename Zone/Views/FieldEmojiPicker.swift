// by zayd/cold @ zayd.wtf

import Combine
import SwiftUI
import ZoneCore

/// The system keyboard cannot present Zone's suggestion strip. Offer the same catalog
/// in Zone's editors and searches. Check the actual cursor again before inserting.
struct FieldEmojiPicker: ViewModifier {
    func body(content: Content) -> some View {
        content.onAppear { AppEmojiSuggestions.shared.start() }
    }
}

/// Attach the single row to the editing field's own window, including sheets and alerts.
@MainActor
private final class AppEmojiSuggestions: NSObject {
    static let shared = AppEmojiSuggestions()

    private struct Candidate: Equatable {
        weak var field: UIView?
        let literal: String
        let offset: Int

        static func == (lhs: Self, rhs: Self) -> Bool {
            lhs.field === rhs.field && lhs.offset == rhs.offset && lhs.literal == rhs.literal
        }
    }

    private weak var editingField: UIView?
    private weak var watchedControl: UIControl?
    private var search: Task<Void, Never>?
    private var row: UIVisualEffectView?
    private var rowBottom: NSLayoutConstraint?
    private var keyboardFrame: CGRect?
    private weak var keyboardScreen: UIScreen?
    private var subscriptions: Set<AnyCancellable> = []
    private var keyboardObservers: [DarwinObservation] = []
    private var keyboardOffersEmoji = false
    private static let index = Task.detached(priority: .utility) {
        guard let catalog = EmojiCatalog.loadBundled() else { return nil as EmojiSearchIndex? }
        return EmojiSearchIndex.loadBundled(available: Set(catalog.categories.flatMap { $0.emoji.map(\.text) }))
    }

    private static let edits = Publishers.Merge(
        NotificationCenter.default.publisher(for: UITextField.textDidChangeNotification),
        NotificationCenter.default.publisher(for: UITextView.textDidChangeNotification)
    )
    private static let blur = Publishers.Merge(
        NotificationCenter.default.publisher(for: UITextField.textDidEndEditingNotification),
        NotificationCenter.default.publisher(for: UITextView.textDidEndEditingNotification)
    )

    func start() {
        guard subscriptions.isEmpty else { return }
        Self.edits.sink { [weak self] note in
            self?.edited(note.object as? UIView)
        }.store(in: &subscriptions)
        NotificationCenter.default.publisher(for: UITextField.textDidBeginEditingNotification)
            .sink { [weak self] note in self?.watch(note.object as? UIControl) }.store(in: &subscriptions)
        NotificationCenter.default.publisher(for: UIResponder.keyboardDidShowNotification)
            .sink { [weak self] _ in self?.watchFocusedControl() }.store(in: &subscriptions)
        Self.blur.sink { [weak self] note in
            guard let self, note.object as? UIView === editingField else { return }
            editingField = nil
            clear()
        }.store(in: &subscriptions)
        NotificationCenter.default.publisher(for: UITextInputMode.currentInputModeDidChangeNotification)
            .sink { [weak self] _ in self?.refresh() }.store(in: &subscriptions)
        NotificationCenter.default.publisher(for: UIResponder.keyboardWillChangeFrameNotification)
            .sink { [weak self] note in
                self?.keyboardFrame = note.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? CGRect
                self?.keyboardScreen = note.object as? UIScreen
                self?.positionRow()
            }.store(in: &subscriptions)
        NotificationCenter.default.publisher(for: UIResponder.keyboardWillHideNotification)
            .sink { [weak self] _ in
                self?.keyboardFrame = nil
                self?.clear()
            }.store(in: &subscriptions)
        keyboardObservers = [
            DarwinNotifier.observe(.emojiStripVisible) { [weak self] in
                self?.keyboardOffersEmoji = true
                self?.clear()
            },
            DarwinNotifier.observe(.emojiStripHidden) { [weak self] in self?.refresh() }
        ]
    }

    private func watch(_ control: UIControl?) {
        guard watchedControl !== control else { return }
        watchedControl?.removeTarget(self, action: #selector(controlEdited(_:)), for: .editingChanged)
        watchedControl = control
        control?.addTarget(self, action: #selector(controlEdited(_:)), for: .editingChanged)
    }

    private func watchFocusedControl() {
        func focused(in view: UIView) -> UIControl? {
            if view.isFirstResponder, let field = view as? UITextField { return field }
            for child in view.subviews where !child.isHidden {
                if let field = focused(in: child) { return field }
            }
            return nil
        }
        for scene in UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }) where scene.activationState == .foregroundActive {
            for window in scene.windows where window.isKeyWindow {
                if let field = focused(in: window) { watch(field); return }
            }
        }
    }

    @objc private func controlEdited(_ sender: UIControl) { edited(sender) }

    private func edited(_ field: UIView?) {
        guard let field else { return }
        editingField = field
        Task { @MainActor [weak self, weak field] in
            guard let self, let field, editingField === field else { return }
            refresh()
        }
    }

    private func clear() {
        search?.cancel()
        row?.removeFromSuperview()
        row = nil
        rowBottom = nil
    }

    private func positionRow() {
        guard let field = editingField, let window = field.window, let rowBottom else { return }
        let limits = window.bounds.inset(by: window.safeAreaInsets)
        var bottom = limits.maxY
        if let keyboardFrame, keyboardScreen == nil || keyboardScreen === window.screen {
            let covered = window.convert(keyboardFrame, from: window.screen.coordinateSpace).intersection(window.bounds)
            if !covered.isEmpty { bottom = min(bottom, covered.minY) }
        }
        let fieldFrame = field.convert(field.bounds, to: window)
        if fieldFrame.maxY > bottom - 44, fieldFrame.minY >= limits.minY + 44 {
            bottom = min(bottom, fieldFrame.minY)
        }
        rowBottom.constant = max(limits.minY + 44, bottom) - window.bounds.minY
    }

    private func refresh() {
        clear()
        guard let candidate = Self.anchor(in: editingField) else { return }
        keyboardOffersEmoji = false
        DarwinNotifier.post(.queryEmojiStrip)
        search = Task {
            guard let index = await Self.index.value else { return }
            // Give an already visible extension strip time to answer the query.
            try? await Task.sleep(for: .milliseconds(90))
            guard !Task.isCancelled, !keyboardOffersEmoji,
                  candidate == Self.anchor(in: editingField), let window = editingField?.window else { return }
            let matches = index.matches(String(candidate.literal.dropFirst()))
            guard !matches.isEmpty else { return }
            let bar = UIVisualEffectView(effect: UIBlurEffect(style: .systemMaterial))
            let stack = UIStackView()
            for match in matches {
                let button = UIButton(type: .system)
                button.setTitle(match.emoji, for: .normal)
                button.accessibilityLabel = "Insert " + match.name
                button.widthAnchor.constraint(greaterThanOrEqualToConstant: 44).isActive = true
                button.addAction(UIAction { [weak self] _ in
                    self?.insert(match.emoji, at: candidate)
                }, for: .touchUpInside)
                stack.addArrangedSubview(button)
            }
            bar.contentView.addSubview(stack)
            stack.translatesAutoresizingMaskIntoConstraints = false
            bar.translatesAutoresizingMaskIntoConstraints = false
            window.addSubview(bar)
            let bottom = bar.bottomAnchor.constraint(equalTo: window.topAnchor)
            rowBottom = bottom
            positionRow()
            NSLayoutConstraint.activate([
                bar.leadingAnchor.constraint(equalTo: window.leadingAnchor),
                bar.trailingAnchor.constraint(equalTo: window.trailingAnchor),
                bottom,
                bar.heightAnchor.constraint(equalToConstant: 44),
                stack.centerXAnchor.constraint(equalTo: bar.contentView.centerXAnchor),
                stack.topAnchor.constraint(equalTo: bar.contentView.topAnchor),
                stack.bottomAnchor.constraint(equalTo: bar.contentView.bottomAnchor)
            ])
            row = bar
        }
    }

    private static func anchor(in field: UIView?) -> Candidate? {
        guard let field, field.isFirstResponder, let input = field as? UITextInput,
              (field as? UITextInputTraits)?.isSecureTextEntry != true, input.markedTextRange == nil,
              let caret = input.selectedTextRange, caret.isEmpty else { return nil }
        let start = input.position(from: caret.start, offset: -560) ?? input.beginningOfDocument
        guard let left = input.textRange(from: start, to: caret.start).flatMap(input.text(in:)),
              let colon = left.lastIndex(of: ":") else { return nil }
        let end = input.position(from: caret.end, offset: 1) ?? input.endOfDocument
        let right = input.textRange(from: caret.end, to: end).flatMap(input.text(in:))
        guard var code = EmojiShortcode(before: String(left[..<colon]), after: right, selection: nil, hasText: true),
              left[left.index(after: colon)...].allSatisfy({ code.append(String($0)) }), code.isSearchable else { return nil }
        return Candidate(field: field, literal: code.literal,
                         offset: input.offset(from: input.beginningOfDocument, to: caret.start))
    }

    private func insert(_ emoji: String, at candidate: Candidate) {
        defer { clear() }
        guard let current = Self.anchor(in: candidate.field),
              current.offset == candidate.offset, current.literal == candidate.literal,
              let input = current.field as? UITextInput, let caret = input.selectedTextRange,
              let start = input.position(from: caret.start, offset: -current.literal.utf16.count),
              let range = input.textRange(from: start, to: caret.start) else { return }
        input.selectedTextRange = range
        input.insertText(emoji)
    }
}
