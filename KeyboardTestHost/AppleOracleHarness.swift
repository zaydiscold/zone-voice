// by zayd/cold @ zayd.wtf

import UIKit

/// A plain text view on Apple's own keyboard, for measuring what the system does to typed
/// punctuation. Zone's keyboard is not involved. Launch with `--apple-oracle`; `--quotes-no`,
/// `--dashes-no` and `--autocorrect-no` set the matching field traits; `--kbd-url`, `--kbd-email`,
/// `--kbd-search` and `--kbd-twitter` set the keyboard type.
@MainActor final class AppleOracleHarness: UIViewController {
    private let field = UITextView()
    private let clear = UIButton(type: .system)
    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground
        let args = ProcessInfo.processInfo.arguments
        field.accessibilityIdentifier = "oracle"
        field.font = .systemFont(ofSize: 20)
        field.autocapitalizationType = .none
        field.spellCheckingType = .no
        field.autocorrectionType = args.contains("--autocorrect-no") ? .no : .default
        field.smartQuotesType = args.contains("--quotes-no") ? .no : .default
        field.smartDashesType = args.contains("--dashes-no") ? .no : .default
        let keyboards: [String: UIKeyboardType] = ["--kbd-url": .URL, "--kbd-email": .emailAddress,
                                                   "--kbd-search": .webSearch, "--kbd-twitter": .twitter]
        for (flag, type) in keyboards where args.contains(flag) { field.keyboardType = type }
        if args.contains("--keyboard-accessory") {
            let accessory = UILabel(frame: CGRect(x: 0, y: 0, width: 320, height: 44))
            accessory.autoresizingMask = .flexibleWidth
            accessory.text = "Host accessory"
            accessory.textAlignment = .center
            accessory.backgroundColor = .systemYellow
            accessory.accessibilityIdentifier = "oracle.accessory"
            field.inputAccessoryView = accessory
        }
        field.layer.borderWidth = 1
        clear.setTitle("Clear", for: .normal)
        clear.accessibilityIdentifier = "clear"
        clear.addAction(UIAction { [weak self] _ in self?.field.text = "" }, for: .touchUpInside)
        view.addSubview(field); view.addSubview(clear)
    }
    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        clear.frame = CGRect(x: 20, y: 70, width: 100, height: 44)
        field.frame = CGRect(x: 20, y: 120, width: view.bounds.width - 40, height: 160)
    }
    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        field.becomeFirstResponder()
    }
}
