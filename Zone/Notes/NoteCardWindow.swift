// by zayd/cold @ zayd.wtf

import Observation
import SwiftUI
import UIKit

/// The note card lives in a window of its own, just above Zone's. When the Action Button
/// starts a note, Zone may be showing a sheet (a note being edited, What's New), a
/// pushed screen or the Note saved page; a card drawn inside Zone's window would sit under a
/// sheet, and a cover presented for it could fail to present at all. This window is on top of
/// all of them and takes touches only on the card, so everything around it keeps working.
///
/// The window is shown only while there is a card: a visible window above Zone's speaks for
/// the status bar, and Flash hides the status bar while it runs.
@MainActor
final class NoteCardWindow: UIWindow {
    /// The card's frame in this window, kept up to date by the card.
    var cardFrame: CGRect = .zero

    override func point(inside point: CGPoint, with event: UIEvent?) -> Bool {
        // The discard question is presented from this window and covers the screen.
        if rootViewController?.presentedViewController != nil { return super.point(inside: point, with: event) }
        return cardFrame.contains(point)
    }
}

/// Mirrors the status bar Zone's own window asks for, so the card never changes it.
final class NoteCardHostingController: UIHostingController<AnyView> {
    weak var appWindow: UIWindow?

    private var appTop: UIViewController? {
        var top = appWindow?.rootViewController
        while let presented = top?.presentedViewController, !presented.isBeingDismissed { top = presented }
        return top
    }

    override var preferredStatusBarStyle: UIStatusBarStyle {
        let top = appTop
        return (top?.childForStatusBarStyle ?? top)?.preferredStatusBarStyle ?? .default
    }

    override var prefersStatusBarHidden: Bool {
        let top = appTop
        return (top?.childForStatusBarHidden ?? top)?.prefersStatusBarHidden ?? false
    }
}

@MainActor
@Observable
final class NoteCardOverlay {
    static let shared = NoteCardOverlay()
    /// The card's height plus a gap, last seen. Zone's own window makes this much room at the
    /// top while a card is up (RootView), so the card covers nothing on the page under it.
    private(set) var reservedHeight: CGFloat = 0
    @ObservationIgnored private(set) var window: NoteCardWindow?
    @ObservationIgnored private weak var appWindow: UIWindow?
    @ObservationIgnored private weak var coordinator: DictationCoordinator?
    @ObservationIgnored private var hideTask: Task<Void, Never>?
    @ObservationIgnored private var observing = false

    /// Called once Zone's own window exists. A second scene (never on iPhone) moves the card.
    func install(in appWindow: UIWindow, coordinator: DictationCoordinator, settings: AppSettings) {
        guard let scene = appWindow.windowScene, window?.windowScene !== scene || self.coordinator !== coordinator else { return }
        self.appWindow = appWindow
        self.coordinator = coordinator
        let window = NoteCardWindow(windowScene: scene)
        window.windowLevel = UIWindow.Level(rawValue: UIWindow.Level.normal.rawValue + 1)
        window.backgroundColor = .clear
        let host = NoteCardHostingController(rootView: AnyView(
            NoteCardLayer(onFrame: { [weak self, weak window] frame in
                window?.cardFrame = frame
                // 2 pt above the card, 8 below it: the gap the strip keeps too.
                if frame.height > 0, abs(frame.height + 10 - (self?.reservedHeight ?? 0)) > 0.5 {
                    self?.reservedHeight = frame.height + 10
                }
            })
                .environment(coordinator)
                .environment(settings)))
        host.appWindow = appWindow
        host.view.backgroundColor = .clear
        window.rootViewController = host
        window.isHidden = true
        self.window?.isHidden = true
        self.window = window
        update()
        if !observing {
            observing = true
            observe()
        }
    }

    /// Follows the card: the window comes up with it and goes a moment after it, once the card
    /// has animated away.
    private func observe() {
        guard let coordinator else { return }
        withObservationTracking {
            _ = coordinator.noteCard != nil
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                self?.update()
                self?.observe()
            }
        }
    }

    private func update() {
        guard let window, let coordinator else { return }
        hideTask?.cancel()
        if coordinator.noteCard != nil {
            if window.isHidden {
                window.isHidden = false
                window.rootViewController?.setNeedsStatusBarAppearanceUpdate()
            }
        } else {
            hideTask = Task { [weak self] in
                try? await Task.sleep(for: .milliseconds(450))
                guard !Task.isCancelled, let self, self.coordinator?.noteCard == nil,
                      self.window?.rootViewController?.presentedViewController == nil else { return }
                self.window?.cardFrame = .zero
                self.window?.isHidden = true
                self.returnKeyToApp()
            }
        }
    }

    /// An alert presented from the card's window can leave it key; typing belongs in Zone's.
    func returnKeyToApp() {
        guard let appWindow, window?.isKeyWindow == true else { return }
        appWindow.makeKey()
    }
}

/// Puts the card's window up once Zone's window exists. Lives in RootView's background.
struct NoteCardWindowInstaller: UIViewRepresentable {
    let coordinator: DictationCoordinator
    let settings: AppSettings

    func makeUIView(context: Context) -> InstallerView {
        let view = InstallerView()
        view.install = { [coordinator, settings] window in
            NoteCardOverlay.shared.install(in: window, coordinator: coordinator, settings: settings)
        }
        view.isUserInteractionEnabled = false
        view.isAccessibilityElement = false
        return view
    }

    func updateUIView(_ uiView: InstallerView, context: Context) {}

    final class InstallerView: UIView {
        var install: ((UIWindow) -> Void)?
        override func didMoveToWindow() {
            super.didMoveToWindow()
            if let window, !(window is NoteCardWindow) { install?(window) }
        }
    }
}

/// The card's window content: the card at the top, nothing anywhere else.
private struct NoteCardLayer: View {
    @Environment(DictationCoordinator.self) private var coordinator
    @Environment(AppSettings.self) private var settings
    @Environment(\.colorScheme) private var systemScheme
    let onFrame: (CGRect) -> Void

    var body: some View {
        VStack(spacing: 0) {
            if let phase = coordinator.noteCard {
                NoteCard(phase: phase)
                    .frame(maxWidth: 520)
                    .padding(.horizontal, 12)
                    .padding(.top, 2)
                    .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { onFrame($0) }
                    .onDisappear { onFrame(.zero) }
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .animation(.spring(response: 0.36, dampingFraction: 0.86), value: coordinator.noteCard?.kind)
        .tint(Zone.inlineInk(settings.appearance.colorScheme ?? systemScheme))
        .toggleStyle(SwitchToggleStyle(tint: Zone.accentTone(settings.appearance.colorScheme ?? systemScheme)))
        .preferredColorScheme(settings.appearance.colorScheme)
    }
}
