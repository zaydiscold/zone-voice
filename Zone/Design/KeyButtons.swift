// by zayd/cold @ zayd.wtf

import SwiftUI
import UIKit

extension Zone {
    /// The keyboard's key corner (`KeyboardTheme.cornerRadius`), for app controls drawn as keys.
    static let keyRadius: CGFloat = 8
}

/// A button drawn as a keyboard key: a rounded box with the sun's hard shadow, not a capsule.
/// The navigation bar's Back, Save, Done and Cancel use it, and so do small inline actions.
/// `prominent` is the screen's one confirming action, in ink.
struct ZoneKeyButtonStyle: ButtonStyle {
    @Environment(\.colorScheme) private var scheme
    @Environment(\.isEnabled) private var isEnabled
    var prominent = false

    func makeBody(configuration: Configuration) -> some View {
        let shape = RoundedRectangle(cornerRadius: Zone.keyRadius, style: .continuous)
        configuration.label
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(prominent ? Zone.onInk(scheme) : Zone.ink(scheme))
            .lineLimit(1)
            .padding(.horizontal, 12)
            .frame(minWidth: 36, minHeight: 36)
            .background { shape.fill(prominent ? Zone.ink(scheme) : Zone.card(scheme)).sunShadow(scale: 0.6) }
            .overlay(shape.strokeBorder(Zone.rule(scheme), lineWidth: prominent ? 0 : 1))
            .opacity(isEnabled ? (configuration.isPressed ? 0.7 : 1) : 0.4)
            .scaleEffect(configuration.isPressed ? 0.96 : 1)
            .animation(Zone.motion, value: configuration.isPressed)
            // The key is 36 pt tall; the touch target is the full 44.
            .frame(minWidth: 44, minHeight: 44)
            .contentShape(Rectangle())
    }
}

/// A navigation bar item without the system's glass capsule behind it, so a `ZoneKeyButtonStyle`
/// button stands as its own rounded box. Before iOS 26 the bar draws no background to remove.
struct ZoneBarItem<Content: View>: ToolbarContent {
    let placement: ToolbarItemPlacement
    let prominent: Bool
    @ViewBuilder let content: () -> Content

    /// - Parameter prominent: the screen's confirming action (Save, Done), drawn in ink.
    init(_ placement: ToolbarItemPlacement, prominent: Bool = false, @ViewBuilder content: @escaping () -> Content) {
        self.placement = placement
        self.prominent = prominent
        self.content = content
    }

    var body: some ToolbarContent {
        if #available(iOS 26.0, *) {
            ToolbarItem(placement: placement) { keys }.sharedBackgroundVisibility(.hidden)
        } else {
            ToolbarItem(placement: placement) { keys }
        }
    }

    /// Every button inside is a key; several sit side by side. Sized to its words: on iOS 26
    /// the bar offers `.cancellationAction` an icon-sized slot, which cut "Cancel" to "...".
    private var keys: some View {
        HStack(spacing: 8) { content() }
            .buttonStyle(ZoneKeyButtonStyle(prominent: prominent))
            .fixedSize()
    }
}

/// Replaces the system's round glass Back button with a key. Safe on any screen: the key shows
/// only when the screen was pushed, and swiping back from the edge keeps working.
private struct ZoneBackButtonModifier: ViewModifier {
    @Environment(\.dismiss) private var dismiss
    @State private var pushed = false

    func body(content: Content) -> some View {
        content
            .background(PushedProbe(pushed: $pushed).frame(width: 0, height: 0).accessibilityHidden(true))
            .navigationBarBackButtonHidden(true)
            .toolbar {
                if pushed {
                    ZoneBarItem(.topBarLeading) {
                        Button { dismiss() } label: {
                            Image(systemName: "chevron.left").font(.body.weight(.semibold))
                        }
                        .buttonStyle(ZoneKeyButtonStyle())
                        .accessibilityLabel("Back")
                        .accessibilityIdentifier("nav.back")
                    }
                }
            }
    }
}

extension View {
    func zoneBackButton() -> some View { modifier(ZoneBackButtonModifier()) }
}

/// Reports whether its screen sits above another in a navigation stack, and keeps the
/// edge-swipe back gesture alive (hiding the system Back button turns it off).
private struct PushedProbe: UIViewRepresentable {
    @Binding var pushed: Bool

    func makeUIView(context: Context) -> ProbeView {
        let view = ProbeView()
        view.isUserInteractionEnabled = false
        view.report = { value in
            if pushed != value { DispatchQueue.main.async { pushed = value } }
        }
        return view
    }
    func updateUIView(_ view: ProbeView, context: Context) {}

    final class ProbeView: UIView {
        var report: ((Bool) -> Void)?

        override func didMoveToWindow() {
            super.didMoveToWindow()
            guard window != nil else { return }
            // The hosting controller joins its navigation controller around the same moment
            // the view joins the window; look now and once more on the next turn.
            check()
            DispatchQueue.main.async { [weak self] in self?.check() }
        }

        private func check() {
            var responder: UIResponder? = self
            var navigation: UINavigationController?
            while let current = responder {
                if let controller = current as? UIViewController, let nav = controller.navigationController {
                    navigation = nav
                    break
                }
                responder = current.next
            }
            guard let navigation else { return }
            BackSwipe.keepAlive(on: navigation)
            // The screen that holds this view is the one nearest the top that contains it.
            let index = navigation.viewControllers.lastIndex { isDescendant(of: $0.view) }
            report?((index ?? 0) > 0)
        }
    }
}

/// Lets a swipe pop a screen whose system Back button is hidden, and never at the root, where
/// a begun pop gesture freezes the stack. iOS 26 has two recognizers, the edge swipe and a
/// swipe from anywhere in the content; the edge one waits on the other, so both need this.
private final class BackSwipe: NSObject, UIGestureRecognizerDelegate {
    static let shared = BackSwipe()

    static func keepAlive(on navigation: UINavigationController) {
        guard let recognizer = navigation.interactivePopGestureRecognizer, recognizer.delegate !== shared else { return }
        recognizer.delegate = shared
        recognizer.isEnabled = true
        if #available(iOS 26.0, *), let content = navigation.interactiveContentPopGestureRecognizer {
            content.delegate = shared
            content.isEnabled = true
        }
    }

    func gestureRecognizerShouldBegin(_ recognizer: UIGestureRecognizer) -> Bool {
        var responder: UIResponder? = recognizer.view
        while let current = responder {
            if let navigation = current as? UINavigationController { return navigation.viewControllers.count > 1 }
            responder = current.next
        }
        return false
    }
}

/// Lays children out left to right and wraps to the next line, like words in a paragraph.
struct FlowLayout: Layout {
    var spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = arrange(subviews, width: proposal.width ?? .infinity)
        return CGSize(width: proposal.width ?? rows.map(\.width).max() ?? 0, height: rows.last.map { $0.y + $0.height } ?? 0)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        for row in arrange(subviews, width: bounds.width) {
            for item in row.items {
                subviews[item.index].place(at: CGPoint(x: bounds.minX + item.x, y: bounds.minY + row.y),
                                           proposal: ProposedViewSize(width: item.width, height: row.height))
            }
        }
    }

    private struct Row {
        var y: CGFloat = 0
        var width: CGFloat = 0
        var height: CGFloat = 0
        var items: [(index: Int, x: CGFloat, width: CGFloat)] = []
    }

    private func arrange(_ subviews: Subviews, width: CGFloat) -> [Row] {
        var rows: [Row] = []
        var row = Row()
        for (index, subview) in subviews.enumerated() {
            // A word longer than the line is squeezed to it and truncates instead of overflowing.
            let size = subview.sizeThatFits(ProposedViewSize(width: width, height: nil))
            let itemWidth = min(size.width, width)
            if !row.items.isEmpty, row.width + spacing + itemWidth > width {
                rows.append(row)
                row = Row(y: row.y + row.height + spacing)
            }
            let x = row.items.isEmpty ? 0 : row.width + spacing
            row.items.append((index, x, itemWidth))
            row.width = x + itemWidth
            row.height = max(row.height, size.height)
        }
        if !row.items.isEmpty { rows.append(row) }
        return rows
    }
}
