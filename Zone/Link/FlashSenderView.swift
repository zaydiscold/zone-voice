// by zayd/cold @ zayd.wtf

import Observation
import SwiftUI
import UIKit
import ZoneCore

/// Send by Flash: the phone shows a rapid sequence of QR codes and the computer's camera reads
/// them. No network is involved, so this works where everything else is blocked.
///
/// It opens on a short guide (what to open on the computer, how to hold the phone, when to tap
/// Done) where the person also chooses what to send. In color (the default) Start opens a
/// full-screen scene with the code as a window in it (`FlashArtStageUIView`): every picture
/// carries three frames, one in each of red, green and blue, in the scene's palette, and every
/// couple of seconds the scene takes the window over for a moment. Black and white, for older
/// cameras, is plain: one frame a picture on a white band (`FlashStageUIView`).
/// While the codes show, the display is at full brightness and the phone stays awake. Nothing
/// counts as sent until the person says the computer received it: a flash goes one way, so the
/// phone cannot know.
struct FlashSenderView: View {
    let computer: PairedComputer
    @Environment(LinkCoordinator.self) private var link
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var scheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase
    @State private var everything = Self.startsWithEverything
    @State private var counts: LinkCoordinator.FlashCounts?
    @State private var plan: LinkFlashPlan?
    /// The choice `plan` was made for. Made again for the same choice (the library changed),
    /// the codes or the guide's numbers already up stay up until the new ones are ready.
    @State private var planChoice: FlashChoice?
    @State private var frames: FlashFrames?
    @State private var problem: String?
    @State private var progress = FlashProgress()
    @State private var asking = false
    /// What the open question is about: the flash on screen when Done was tapped. Yes confirms
    /// that flash, whatever is made after.
    @State private var question: FlashQuestion?
    @State private var started = false
    /// When the codes on screen now first showed. Nil before Start.
    @State private var shownSince: Date?
    /// When the codes were last made again while showing, because the library changed.
    @State private var remadeAt: Date?
    /// The art screen's shader, compiled while the guide shows. Nil in black and white, and on
    /// a device that cannot draw it, where color shows on the plain screen.
    @State private var renderer: FlashArtRenderer?
    /// Done was tapped: the code is resolving into the wordmark before the question appears.
    @State private var ending = false
    /// The person answered the question: the screen is going away, so nothing starts again.
    @State private var leaving = false
    /// One black and white code a picture, for cameras that mix up the colors. Kept for next time.
    @AppStorage("zone.link.flashBlackAndWhite") private var blackAndWhite = false
    /// Counts up when what the codes carry has changed, to make them again.
    @State private var generation = 0
    #if DEBUG
    /// `-zoneLinkFlashChangeAfter` has changed the library once.
    @State private var debugChanged = false
    #endif
    /// Screen points kept clear of the art for the text at the top and the bottom.
    @State private var headerBottom: CGFloat = 120
    @State private var footerTop: CGFloat = 700

    var body: some View {
        ZStack {
            (started && usesArt ? Color.black : Zone.paper(scheme)).ignoresSafeArea()
            if started, let frames {
                // No fade: the first code appears whole, as every code after it does.
                showing(frames)
                    .transition(.identity)
            } else {
                guide
                    .transition(.opacity)
            }
        }
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.35), value: started)
        .statusBarHidden(started)
        .persistentSystemOverlays(started ? .hidden : .automatic)
        .task(id: LoadKey(choice: choice, generation: generation)) { await load() }
        .task(id: link.flashRevision) {
            // The library, a deletion, a Link sync or the clips changed while this screen is up
            // (a Watch recording landing, a retried dictation). A burst of changes, such as a
            // dictation saved and then marked inserted, is one check.
            try? await Task.sleep(for: .milliseconds(800))
            guard !Task.isCancelled else { return }
            if !started, plan != nil {
                // Both choices' numbers on the guide, even when only the other one changed.
                let fresh = await link.flashCounts(for: computer.endpointID)
                guard !Task.isCancelled else { return }
                counts = fresh
            }
            await remakeIfStale()
        }
        .onChange(of: scenePhase) { before, now in
            // Back from another app, where the library may have changed while nothing here ran.
            if now == .active, before != .active { Task { await remakeIfStale() } }
        }
        .onChange(of: started) { _, now in
            if now {
                shownSince = Date()
                remadeAt = nil
            }
        }
        .confirmationDialog("Did \(computer.name) receive it?", isPresented: $asking, titleVisibility: .visible,
                            presenting: question) { question in
            // Only when a camera could have read this flash by now: until then, a Done on the
            // page is an earlier flash's.
            if !question.tooSoon {
                Button("Yes, it has them") {
                    leaving = true
                    link.confirmFlash(question.plan, everything: question.everything, to: computer.endpointID)
                    dismiss()
                }
            }
            Button("No, not yet") {
                leaving = true
                dismiss()
            }
            Button("Keep showing", role: .cancel) {}
        } message: { question in
            Text(question.words)
        }
        .onChange(of: asking) { _, showing in
            // Keep showing, or a tap outside the question: the wordmark turns back into the code,
            // and codes held back while the question was up are made now.
            if !showing, !leaving {
                ending = false
                question = nil
                Task { await remakeIfStale() }
            }
        }
    }

    private var choice: FlashChoice { FlashChoice(everything: everything, blackAndWhite: blackAndWhite) }

    /// True when the codes show in the art screen: color, on a device that can draw it.
    private var usesArt: Bool { renderer != nil && (plan?.codesPerPicture ?? 1) > 1 }

    /// Done. In the art screen the code first resolves into the wordmark; then, as everywhere,
    /// the question, about the flash that was on screen when Done was tapped.
    private func finish() {
        if !ending, !asking, let plan {
            question = FlashQuestion(plan: plan, everything: planChoice?.everything ?? everything,
                                     shownFor: shownSince.map { Date().timeIntervalSince($0) } ?? 0, remadeAt: remadeAt)
        }
        guard question != nil else { return }
        guard usesArt, !reduceMotion, !ending else {
            asking = true
            return
        }
        ending = true
        Task {
            try? await Task.sleep(for: .seconds(LinkFlashSchedule.endingSeconds))
            if ending { asking = true }
        }
    }

    // MARK: The guide

    private var guide: some View {
        VStack(spacing: 0) {
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .font(.body.weight(.medium))
                    .foregroundStyle(Zone.ink(scheme))
                    .frame(minWidth: 44, minHeight: 44)
                    .accessibilityIdentifier("flash.cancel")
            }
            .padding(.horizontal, 12)

            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    FlashGuideArt(accent: Zone.accent, ink: Zone.ink(scheme), paper: Zone.paper(scheme),
                                  scene: blackAndWhite ? nil : LinkFlashScene(session: plan?.encoder.session ?? 0),
                                  animated: !reduceMotion)
                        .frame(maxWidth: .infinity)
                        .frame(height: 136)
                        .accessibilityHidden(true)

                    VStack(alignment: .leading, spacing: 6) {
                        Text("Send by Flash").font(.zoneEyebrow).foregroundStyle(Zone.muted(scheme))
                        Text(computer.name)
                            .font(.zoneHeadline)
                            .foregroundStyle(Zone.ink(scheme))
                            .lineLimit(2)
                            .minimumScaleFactor(0.6)
                            .accessibilityIdentifier("flash.name")
                        Text("For flights or restricted networks where your iPhone can't reach the computer. While connected, Zone syncs automatically.")
                            .font(.subheadline)
                            .foregroundStyle(Zone.muted(scheme))
                            .fixedSize(horizontal: false, vertical: true)
                            .accessibilityIdentifier("flash.when")
                    }

                    VStack(alignment: .leading, spacing: 16) {
                        FlashGuideStep(number: 1, symbol: "laptopcomputer",
                                       title: "On your computer, open Zone and choose **Flash** (or run `zone open`).",
                                       detail: "Default local address: 127.0.0.1:47813/flash.")
                        FlashGuideStep(number: 2, symbol: "viewfinder",
                                       title: "Hold your iPhone steady so the code fills the camera frame.",
                                       detail: "Skipping a few frames is fine.")
                        FlashGuideStep(number: 3, symbol: "checkmark.circle",
                                       title: "When your computer says **Done**, tap **Done** here.",
                                       detail: "The page shows how many new items arrived.")
                    }
                    .accessibilityIdentifier("flash.steps")

                    Label {
                        Text("Screen stays awake at full brightness during transfer, then restores automatically.")
                            .fixedSize(horizontal: false, vertical: true)
                    } icon: {
                        Image(systemName: "sun.max.fill").foregroundStyle(Zone.accentText(scheme))
                    }
                    .font(.footnote)
                    .foregroundStyle(Zone.muted(scheme))

                    VStack(alignment: .leading, spacing: 8) {
                        Picker("What to send", selection: $everything) {
                            Text(label("Not sent yet", counts?.notYetSent)).tag(false)
                            Text(label("Everything", counts?.everything)).tag(true)
                        }
                        .pickerStyle(.segmented)
                        .accessibilityIdentifier("flash.what")
                        Toggle("Black and white codes (for older cameras)", isOn: $blackAndWhite)
                            .font(.subheadline)
                            .foregroundStyle(Zone.ink(scheme))
                            .accessibilityIdentifier("flash.blackAndWhite")
                        Text(guideDetail)
                            .font(.footnote)
                            .foregroundStyle(problem == nil ? Zone.muted(scheme) : Zone.ink(scheme))
                            .fixedSize(horizontal: false, vertical: true)
                            .accessibilityIdentifier(problem == nil ? "flash.detail" : "flash.problem")
                        if everything, counts?.everythingGoesOn == true {
                            Button("Start Everything from the first item") {
                                link.restartFlashEverything(computer.endpointID)
                                generation += 1
                            }
                            .font(.footnote.weight(.medium))
                            .frame(minHeight: 44)
                            .accessibilityIdentifier("flash.restartEverything")
                        }
                    }
                }
                .padding(.horizontal, 24)
                .padding(.bottom, 16)
            }
            .scrollBounceBehavior(.basedOnSize)

            // Beside Start, not in the scrolling text, so it is on screen whenever Start is.
            Label {
                Text(Self.flashingWarning)
                    .fixedSize(horizontal: false, vertical: true)
            } icon: {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Zone.accentText(scheme))
            }
            .font(.footnote)
            .foregroundStyle(Zone.ink(scheme))
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 24)
            .padding(.top, 10)
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("flash.sensitivity")

            Button {
                started = true
            } label: {
                if plan == nil && problem == nil {
                    ProgressView().tint(Zone.onInk(scheme))
                } else {
                    Label("Start Flash", systemImage: "bolt.fill")
                }
            }
            .buttonStyle(ZonePrimaryButtonStyle())
            .disabled(plan == nil)
            .padding(.horizontal, 24)
            .padding(.top, 8)
            .padding(.bottom, 12)
            .accessibilityIdentifier("flash.start")
        }
        .tint(Zone.accentText(scheme))
    }

    /// For people whom flashing light can harm. Black and white is no safer: it changes as
    /// fast, at higher contrast. Reduce Motion stills the art, not the codes.
    static let flashingWarning = "The codes change 20 times a second at full brightness, in color and in black and white. If flashing lights can affect you, as with photosensitive epilepsy, do not use Flash: Zone sends everything on its own once this iPhone can reach the computer."

    private var guideDetail: String {
        if let problem { return problem }
        guard let plan else { return "Getting the codes ready…" }
        let count = plan.items.count
        // In the art screen the opening and the interludes take time too, with motion allowed.
        let schedule = usesArt && !reduceMotion ? LinkFlashSchedule.color : .dataOnly
        var line = "\(count.formatted()) \(count == 1 ? "item" : "items"), \(Self.duration(schedule.seconds(for: plan))) if the camera catches every code."
        if plan.leftOut > 0 {
            // True for both choices: what a confirmed flash carried is not sent again, and
            // Everything goes on after the last record it carried.
            line += " \(plan.leftOut.formatted()) more go in the next flash."
        }
        if planChoice?.everything == true, let counts, counts.everythingGoesOn {
            let sent = counts.everythingFromTheStart - counts.everything
            line += " This goes on from your last Everything flash, which sent the first \(sent.formatted()) of \(counts.everythingFromTheStart.formatted())."
        }
        line += blackAndWhite ? " One code a picture: a third as fast, and any camera can read it."
            : " Three codes in every picture, one in each color. If the page reads few, try black and white."
        return line
    }

    // MARK: The codes

    private func showing(_ frames: FlashFrames) -> some View {
        // Over the art the words are always light on dark, whatever the app's appearance.
        let scheme: ColorScheme = usesArt ? .dark : self.scheme
        return ZStack {
            Group {
                if let renderer, usesArt {
                    FlashArtStage(renderer: renderer, frames: frames, progress: progress, calm: reduceMotion,
                                  ending: ending, clearTop: headerBottom + 10, clearBottom: footerTop - 10)
                } else {
                    FlashStage(frames: frames, progress: progress,
                               palette: FlashPalette(paper: UIColor(Zone.paper(scheme)), ink: UIColor(Zone.ink(scheme)),
                                                     accent: UIColor(Zone.accent)),
                               calm: reduceMotion, clearTop: headerBottom + 10, clearBottom: footerTop - 10)
                }
            }
                .ignoresSafeArea()
                .accessibilityLabel("Flash code for \(computer.name)")
                .accessibilityIdentifier("flash.code")

            VStack(spacing: 0) {
                HStack(alignment: .firstTextBaseline) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Flash to").font(.zoneEyebrow).foregroundStyle(Zone.muted(scheme))
                        Text(computer.name).font(.zoneTitle).foregroundStyle(Zone.ink(scheme))
                            .lineLimit(1).minimumScaleFactor(0.7)
                    }
                    Spacer(minLength: 12)
                    Button("Done") { finish() }
                        .font(.body.weight(.semibold))
                        .foregroundStyle(Zone.onInk(scheme))
                        .padding(.horizontal, 18)
                        .frame(minHeight: 40)
                        .background(Zone.ink(scheme), in: Zone.keyShape)
                        .accessibilityIdentifier("flash.done")
                }
                .padding(.horizontal, 20)
                .padding(.top, 8)
                .onGeometryChange(for: CGFloat.self) { $0.frame(in: .global).maxY } action: { headerBottom = $0 }

                Spacer(minLength: 0)

                VStack(spacing: 4) {
                    if let plan {
                        // The name the page on the computer shows for the flash it is reading.
                        Text("Flash \(plan.name)")
                            .font(.footnote.weight(.semibold).monospaced())
                            .foregroundStyle(Zone.ink(scheme))
                            // Read out a character at a time, to compare with the page.
                            .accessibilityLabel("Flash \(plan.name.filter { $0 != " " }.map { String($0) }.joined(separator: " "))")
                            .accessibilityValue(plan.name)
                            .accessibilityIdentifier("flash.id")
                    }
                    FlashProgressLine(progress: progress, placeholder: "Pass 1")
                        .font(.body.weight(.medium).monospacedDigit())
                        .foregroundStyle(Zone.ink(scheme))
                        .accessibilityIdentifier("flash.progress")
                    Text(showingDetail)
                        .font(.footnote)
                        .foregroundStyle(Zone.muted(scheme))
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("flash.detail")
                }
                .padding(.horizontal, 24)
                .padding(.bottom, 12)
                .onGeometryChange(for: CGFloat.self) { $0.frame(in: .global).minY } action: { footerTop = $0 }
            }
            // Words over a moving scene need an edge to stay readable.
            .shadow(color: .black.opacity(usesArt ? 0.6 : 0), radius: 6, y: 1)
        }
    }

    private var showingDetail: String {
        guard let plan else { return " " }
        let count = plan.items.count
        let pieces = plan.encoder.chunkCount
        let codes = plan.codesPerPicture > 1 ? ", three codes in every picture" : ""
        var line = ""
        if let remadeAt {
            line = "Your library changed, so these codes were made again at \(remadeAt.formatted(date: .omitted, time: .shortened)). "
        }
        // The page counts the same pieces, so the two can be compared.
        line += "\(count.formatted()) \(count == 1 ? "item" : "items") in \(pieces.formatted()) \(pieces == 1 ? "piece" : "pieces")\(codes). Hold the code up to the camera. When the page on your computer says Done for this flash, tap Done."
        return line
    }

    private func label(_ title: String, _ count: Int?) -> String {
        guard let count else { return title }
        return "\(title) (\(count.formatted()))"
    }

    private static var startsWithEverything: Bool {
        #if DEBUG
        return ProcessInfo.processInfo.arguments.contains("-zoneLinkFlashEverything")
        #else
        return false
        #endif
    }

    static func duration(_ seconds: Double) -> String {
        let whole = Int(seconds.rounded(.up))
        if whole < 90 { return "about \(max(1, whole)) \(whole <= 1 ? "second" : "seconds")" }
        let minutes = Int((seconds / 60).rounded())
        return "about \(minutes) minutes"
    }

    /// Makes the codes again when what they carry is out of date.
    ///
    /// While the codes show, only a change to something this flash carries counts
    /// (`LinkFlashPlan.isCurrent`): new codes make the computer start reading again, so
    /// something new since, which can go in the next flash, does not. On the guide nobody is
    /// reading yet, so any change to what the choice would send makes the numbers new.
    private func remakeIfStale() async {
        guard let shown = plan, !leaving, !ending, !asking else { return }
        let state = await link.flashPlanState(shown, for: computer.endpointID, everything: planChoice?.everything ?? everything)
        // The question may have opened, the screen gone, or other codes come while that was read.
        guard !Task.isCancelled, !leaving, !ending, !asking, plan?.encoder.session == shown.encoder.session else { return }
        switch state {
        case .same: return
        case .current where started: return
        case .current, .stale: generation += 1
        }
    }

    private func load() async {
        let choice = choice
        // Made again for the same choice: what is up stays up until the new codes are ready.
        let remaking = plan != nil && planChoice == choice
        if !remaking {
            plan = nil
            planChoice = nil
            frames = nil
            progress.playhead = nil
        }
        problem = nil
        // Compiled off the main thread, once for the app, while the guide is being read.
        renderer = blackAndWhite ? nil : await Task.detached(priority: .userInitiated) { FlashArtRenderer.shared }.value
        let fresh = await link.flashCounts(for: computer.endpointID)
        guard !Task.isCancelled else { return }
        counts = fresh
        do {
            let made = try await link.flashPlan(for: computer.endpointID, everything: choice.everything,
                                                mode: choice.blackAndWhite ? .blackAndWhite : .color)
            guard !Task.isCancelled else { return }
            // Done was tapped while these were made: the question is about the codes on screen,
            // so they stay. Keep showing checks again.
            if remaking, ending || asking || leaving { return }
            let showing = started && frames != nil
            plan = made
            planChoice = choice
            frames = FlashFrames(plan: made)
            if showing {
                shownSince = Date()
                remadeAt = Date()
            }
            #if DEBUG
            if ProcessInfo.processInfo.arguments.contains("-zoneLinkFlashStart"), !started {
                // After this screen has finished sliding up, so a recording has the whole opening.
                try? await Task.sleep(for: .milliseconds(900))
                guard !Task.isCancelled else { return }
                started = true
            }
            // `-zoneLinkFlashDoneAfter 9`: taps Done that many seconds after the codes start, for recordings.
            let doneAfter = UserDefaults.standard.double(forKey: "zoneLinkFlashDoneAfter")
            if started, !showing, doneAfter > 0 {
                Task {
                    try? await Task.sleep(for: .seconds(doneAfter))
                    finish()
                }
            }
            // `-zoneLinkFlashChangeAfter 3`: a dictation in this flash is transcribed again that
            // many seconds after the codes start, as a retried dictation would be.
            let changeAfter = UserDefaults.standard.double(forKey: "zoneLinkFlashChangeAfter")
            if started, !debugChanged, changeAfter > 0 {
                debugChanged = true
                Task {
                    try? await Task.sleep(for: .seconds(changeAfter))
                    LinkDebug.transcribeAgain(made.items)
                }
            }
            #endif
        } catch let failure as LinkCoordinator.FlashFailure {
            if remaking {
                started = false
                plan = nil
                planChoice = nil
                frames = nil
            }
            problem = failure == .nothingToSend && !choice.everything
                ? "\(computer.name) has been sent everything in your library. Choose Everything to send it all again."
                : failure.plainMessage
        } catch {
            if remaking {
                started = false
                plan = nil
                planChoice = nil
                frames = nil
            }
            problem = LinkCoordinator.FlashFailure.tooLarge.plainMessage
        }
    }
}

/// What the person chose on the guide. Changing it makes new codes from scratch.
private struct FlashChoice: Equatable {
    var everything: Bool
    var blackAndWhite: Bool
}

/// The question Done asks, about the flash on screen when Done was tapped.
private struct FlashQuestion {
    let plan: LinkFlashPlan
    let everything: Bool
    /// How long its codes had been showing.
    let shownFor: TimeInterval
    /// When its codes were made again while showing, if they were.
    let remadeAt: Date?

    /// No camera could have read every piece yet: a Done on the page is for an earlier flash.
    var tooSoon: Bool { shownFor < plan.minimumSeconds }

    var words: String {
        if tooSoon {
            let pieces = plan.encoder.chunkCount
            return "These codes went up \(Self.span(shownFor, up: false)) ago, and the page needs at least \(Self.span(plan.minimumSeconds, up: true)) to read all \(pieces.formatted()) pieces. A Done on the page now is for an earlier flash: keep showing until it says Done for flash \(plan.name)."
        }
        let count = plan.items.count
        let items = count == 1 ? "1 item" : "\(count.formatted()) items"
        let ask = "Say yes only when the page on your computer says Done for flash \(plan.name), with \(items)"
        guard let remadeAt else {
            return "\(ask). A Done for another flash does not count. Zone will not send these items again."
        }
        return "Your library changed, so the codes were made again at \(remadeAt.formatted(date: .omitted, time: .shortened)). \(ask): a Done from before then was for the earlier flash. Zone will not send these items again."
    }

    /// "under a second", "7 seconds", "3 minutes". `up` rounds up, for a least time.
    static func span(_ seconds: Double, up: Bool) -> String {
        let whole = Int(up ? seconds.rounded(.up) : seconds.rounded(.down))
        if whole < 1 { return "under a second" }
        if whole < 90 { return whole == 1 ? "1 second" : "\(whole) seconds" }
        let minutes = Int((seconds / 60).rounded(up ? .up : .down))
        return "\(minutes) minutes"
    }
}

/// What the codes are made from: changing either makes new ones.
private struct LoadKey: Equatable {
    var choice: FlashChoice
    var generation: Int
}

/// One numbered step of the guide.
private struct FlashGuideStep: View {
    @Environment(\.colorScheme) private var scheme
    let number: Int
    let symbol: String
    let title: String
    let detail: String

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            Text("\(number)")
                .font(.subheadline.weight(.semibold).monospacedDigit())
                .foregroundStyle(Zone.accentText(scheme))
                .frame(width: 30, height: 30)
                .background(Zone.accent.opacity(scheme == .dark ? 0.18 : 0.14), in: Circle())
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Text(LocalizedStringKey(title))
                    .font(.body)
                    .foregroundStyle(Zone.ink(scheme))
                    .fixedSize(horizontal: false, vertical: true)
                Text(detail)
                    .font(.footnote)
                    .foregroundStyle(Zone.muted(scheme))
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
            Image(systemName: symbol)
                .font(.system(size: 20, weight: .regular))
                .foregroundStyle(Zone.muted(scheme))
                .frame(width: 28)
                .accessibilityHidden(true)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Step \(number). \(title.replacingOccurrences(of: "**", with: "").replacingOccurrences(of: "`", with: "")) \(detail)")
    }
}

/// The guide's picture: a small phone showing its code, beside the computer it is held up to.
/// The little code is drawn, not a real one: a mosaic in the scene's eight colors on a dark
/// screen (or black and white on a white band) that changes a few times a second the way the
/// real pictures do.
private struct FlashGuideArt: View {
    let accent: Color
    let ink: Color
    let paper: Color
    /// The scene the flash will open in. Nil in black and white.
    let scene: LinkFlashScene?
    let animated: Bool

    var body: some View {
        TimelineView(.periodic(from: .now, by: animated ? 1.0 / 6 : 3600)) { context in
            let tick = animated ? Int(context.date.timeIntervalSinceReferenceDate * 6) : 0
            HStack(spacing: 22) {
                Canvas { graphics, size in draw(&graphics, size: size, tick: tick) }
                    .frame(width: 76, height: 136)
                Image(systemName: "chevron.right.2")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(accent.opacity(0.85))
                    .symbolEffect(.pulse, options: .repeating, isActive: animated)
                ZStack {
                    Image(systemName: "laptopcomputer")
                        .font(.system(size: 72, weight: .light))
                        .foregroundStyle(ink.opacity(0.8))
                    Image(systemName: "viewfinder")
                        .font(.system(size: 22, weight: .regular))
                        .foregroundStyle(accent)
                        .offset(y: -6)
                }
            }
        }
    }

    private static func color(_ levels: [UInt8], scale: Double = 1) -> Color {
        Color(.displayP3, red: Double(levels[0]) / 255 * scale, green: Double(levels[1]) / 255 * scale,
              blue: Double(levels[2]) / 255 * scale)
    }

    private func draw(_ graphics: inout GraphicsContext, size: CGSize, tick: Int) {
        let body = CGRect(origin: .zero, size: size).insetBy(dx: 1.5, dy: 1.5)
        let outline = Path(roundedRect: body, cornerRadius: 16)
        var seed = UInt64(truncatingIfNeeded: tick &* 2_654_435_761 &+ 97)
        func next() -> UInt64 {
            seed = seed &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            return seed >> 33
        }
        let palette = scene?.palette
        let colors = palette?.colors.map { Self.color($0) } ?? []
        let light = colors.last ?? .white
        let dark: GraphicsContext.Shading = .color(colors.first ?? Color(white: 0.08))
        let side: CGFloat = 60
        let window = CGRect(x: body.midX - side / 2 - 4, y: body.midY - side / 2 - 4, width: side + 8, height: side + 8)
        if let palette {
            // The scene: the palette's dark, deepening toward the top and the bottom, and a
            // soft light around the window.
            graphics.fill(outline, with: .linearGradient(
                Gradient(colors: [Self.color(palette.dark, scale: 0.25), Self.color(palette.dark, scale: 0.9),
                                  Self.color(palette.dark, scale: 0.3)]),
                startPoint: CGPoint(x: 0, y: body.minY), endPoint: CGPoint(x: 0, y: body.maxY)))
            graphics.fill(Path(roundedRect: window.insetBy(dx: -5, dy: -5), cornerRadius: 9), with: .color(light.opacity(0.22)))
            graphics.fill(Path(roundedRect: window, cornerRadius: 5), with: .color(light))
        } else {
            graphics.fill(outline, with: .color(paper))
            graphics.fill(Path(CGRect(x: body.minX, y: window.minY, width: body.width, height: window.height)), with: .color(.white))
        }

        // A pretend code: three finder squares and a mosaic that changes each tick.
        let grid = 17
        let cell = side / CGFloat(grid)
        let origin = CGPoint(x: body.midX - side / 2, y: body.midY - side / 2)
        for row in 0..<grid {
            for column in 0..<grid {
                let inFinder = (row < 5 && column < 5) || (row < 5 && column >= grid - 5) || (row >= grid - 5 && column < 5)
                if inFinder { continue }
                let pick = Int(next() % 8)
                let shade: GraphicsContext.Shading = colors.isEmpty ? (pick < 4 ? dark : .color(.white)) : .color(colors[pick])
                graphics.fill(Path(CGRect(x: origin.x + CGFloat(column) * cell, y: origin.y + CGFloat(row) * cell,
                                          width: cell + 0.3, height: cell + 0.3)), with: shade)
            }
        }
        for (row, column) in [(0, 0), (0, grid - 5), (grid - 5, 0)] {
            let outer = CGRect(x: origin.x + CGFloat(column) * cell, y: origin.y + CGFloat(row) * cell,
                               width: cell * 5, height: cell * 5)
            graphics.fill(Path(outer), with: dark)
            graphics.fill(Path(outer.insetBy(dx: cell, dy: cell)), with: .color(light))
            graphics.fill(Path(outer.insetBy(dx: cell * 2, dy: cell * 2)), with: dark)
        }
        graphics.stroke(outline, with: .color(ink.opacity(0.85)), lineWidth: 2.5)
        graphics.fill(Path(roundedRect: CGRect(x: body.midX - 13, y: body.minY + 6, width: 26, height: 7), cornerRadius: 3.5),
                      with: .color(ink.opacity(0.85)))
    }
}

/// The frame on screen, kept apart from the screen's own state so twenty changes a second
/// redraw one line of text and nothing else.
@MainActor
@Observable
final class FlashProgress {
    var playhead: LinkFlashPlayhead?
}

private struct FlashProgressLine: View {
    let progress: FlashProgress
    let placeholder: String

    var body: some View {
        Text(progress.playhead?.line ?? placeholder)
    }
}

/// The colors of the plain Flash screen around the code. The code and its band are always black on white.
struct FlashPalette: Equatable {
    var paper: UIColor
    var ink: UIColor
    var accent: UIColor
}

/// The pictures of one flash, drawn ahead of the one on screen and kept.
///
/// In color a picture is three frames, one in each of red, green and blue (`LinkFlashColor`);
/// in black and white it is one frame. Either way it is the QR code at one pixel per module
/// (103 by 103 for the usual frame, about 42 kB in color), drawn by the same code that writes
/// the cross-test PNG files, tagged with the display's own color space so a level in one
/// channel lights only that subpixel. Color pictures are kept in pure 0 and 255; the art
/// screen gives each the palette of the scene it is shown in (`LinkFlashPalette.recolor`). A
/// background queue stays a few seconds ahead, so showing a picture is handing finished bytes
/// to the screen. A flash of ordinary size keeps every picture, so the second pass and later
/// draw nothing at all; a very large one keeps only those around the one on screen.
final class FlashFrames: @unchecked Sendable {
    struct Picture {
        let image: CGImage
        /// The color the glow around the plain band takes for this picture: one of the six the
        /// mosaic is made of, chosen by the picture's bytes. Nil in black and white.
        let glow: (red: Bool, green: Bool, blue: Bool)?
    }

    let plan: LinkFlashPlan
    /// Pictures before the phone starts again from frame 0.
    let cycleLength: Int
    private let keepsAll: Bool
    private let lock = NSLock()
    private var pictures: [Int: Picture] = [:]
    private var drawing = false
    private let queue = DispatchQueue(label: "wtf.zayd.zone.flash-frames", qos: .userInitiated)
    private static let displaySpace = CGColorSpace(name: CGColorSpace.displayP3) ?? CGColorSpaceCreateDeviceRGB()

    /// Pictures drawn ahead of the one on screen: three seconds at twenty a second.
    private static let ahead = 60
    /// Up to this many pictures (about 50 MB in color) are all kept.
    private static let keepLimit = 1_200

    init(plan: LinkFlashPlan) {
        self.plan = plan
        self.cycleLength = plan.pictureCycle
        self.keepsAll = plan.pictureCycle <= Self.keepLimit
        prepare(after: -1)
    }

    private func draw(_ index: Int) -> Picture? {
        let frames = plan.frames(inPicture: index).map { plan.encoder.frame($0) }
        if frames.count == 1 {
            guard let image = LinkFlashQR.modules(frames[0]) else { return nil }
            return Picture(image: image, glow: nil)
        }
        guard let image = LinkFlashColor.picture(frames, colorSpace: Self.displaySpace) else { return nil }
        // A light module in a channel is a 1 bit there; the last body byte of each frame
        // (ciphertext, so as good as random) chooses on or off for each channel. Black and
        // white are not colors to glow in, so those two fall back to the first frame's choice.
        var bits = frames.map { ($0.last ?? 0) & 1 == 1 }
        if bits.allSatisfy({ $0 }) || bits.allSatisfy({ !$0 }) {
            let pick = Int(frames[0].dropLast().last ?? 0) % 3
            bits = (0..<3).map { $0 == pick }
        }
        return Picture(image: image, glow: (bits[0], bits[1], bits[2]))
    }

    /// The picture at `index`. Drawn on the spot only when the queue has not reached it yet,
    /// which happens for the very first picture.
    func picture(_ index: Int) -> Picture? {
        lock.lock()
        let ready = pictures[index]
        lock.unlock()
        if let ready { return ready }
        guard let drawn = draw(index) else { return nil }
        lock.lock()
        pictures[index] = drawn
        lock.unlock()
        return drawn
    }

    /// Draws the pictures that follow `index`, off the main thread.
    func prepare(after index: Int) {
        lock.lock()
        let busy = drawing
        drawing = true
        lock.unlock()
        guard !busy else { return }
        queue.async { [self] in
            let wanted = (1...Self.ahead).map { (index + $0) % cycleLength }
            for picture in wanted {
                lock.lock()
                let have = pictures[picture] != nil
                lock.unlock()
                if have { continue }
                guard let drawn = draw(picture) else { continue }
                lock.lock()
                pictures[picture] = drawn
                lock.unlock()
            }
            lock.lock()
            if !keepsAll {
                let keep = Set(wanted + [max(0, index)])
                pictures = pictures.filter { keep.contains($0.key) }
            }
            drawing = false
            lock.unlock()
        }
    }
}

private struct FlashStage: UIViewRepresentable {
    let frames: FlashFrames
    let progress: FlashProgress
    let palette: FlashPalette
    let calm: Bool
    /// Screen points from the top that the text uses, and where the text at the bottom begins.
    let clearTop: CGFloat
    let clearBottom: CGFloat

    func makeUIView(context: Context) -> FlashStageUIView {
        let view = FlashStageUIView()
        updateUIView(view, context: context)
        return view
    }

    func updateUIView(_ view: FlashStageUIView, context: Context) {
        view.configure(palette: palette, calm: calm, clearTop: clearTop, clearBottom: clearBottom)
        view.show(frames, progress: progress)
    }

    static func dismantleUIView(_ view: FlashStageUIView, coordinator: ()) {
        view.stop()
    }
}

/// The plain Flash screen: the pictures, twenty a second, on a white band as wide as the
/// screen. This is what black and white codes look like, and what color falls back to on a
/// device that cannot draw the art (`FlashArtStageUIView` is the color screen everywhere else).
/// The code is the whole show: as large as fits with every module a whole number of screen
/// pixels and four light modules around it (`LinkFlashLayout`), each picture replacing the last
/// in a single screen refresh. Around it only a soft glow and a thin progress line under the
/// band. While it is on screen the display is at full brightness and the phone does not sleep
/// (`FlashScreenHold`).
final class FlashStageUIView: UIView {
    private let band = CALayer()
    private let code = CALayer()
    private let glowAbove = CAGradientLayer()
    private let glowBelow = CAGradientLayer()
    private let track = CALayer()
    private let fill = CALayer()
    private let hold = FlashScreenHold()
    private var frames: FlashFrames?
    private weak var progress: FlashProgress?
    private var link: CADisplayLink?
    private var started: CFTimeInterval = 0
    private var shown = -1
    private var rate = LinkFlashFormat.framesPerSecond
    private var clockSet = false
    private var modules = 103
    private var calm = false
    private var palette = FlashPalette(paper: .black, ink: .white, accent: .systemPurple)
    private var clearTop: CGFloat = 0
    private var clearBottom: CGFloat = 0

    /// How far the glow reaches from the band, in points.
    private static let glowReach: CGFloat = 150

    override init(frame: CGRect) {
        super.init(frame: frame)
        isOpaque = true
        for glow in [glowAbove, glowBelow] {
            glow.startPoint = CGPoint(x: 0.5, y: 0)
            glow.endPoint = CGPoint(x: 0.5, y: 1)
            layer.addSublayer(glow)
        }
        band.backgroundColor = UIColor.white.cgColor
        layer.addSublayer(band)
        code.magnificationFilter = .nearest
        code.minificationFilter = .nearest
        code.contentsGravity = .resize
        layer.addSublayer(code)
        layer.addSublayer(track)
        layer.addSublayer(fill)
        // The code and its band never animate: a picture is replaced whole, in one refresh.
        for still in [band, code, track, fill] {
            still.actions = ["contents": NSNull(), "bounds": NSNull(), "position": NSNull(), "frame": NSNull(),
                             "backgroundColor": NSNull(), "hidden": NSNull()]
        }
        // The glow alone eases from one picture's color to the next.
        for glow in [glowAbove, glowBelow] {
            glow.actions = ["bounds": NSNull(), "position": NSNull(), "frame": NSNull()]
        }
        isAccessibilityElement = true
        accessibilityTraits = .image
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    func configure(palette: FlashPalette, calm: Bool, clearTop: CGFloat, clearBottom: CGFloat) {
        backgroundColor = palette.paper
        if palette != self.palette {
            self.palette = palette
            track.backgroundColor = palette.ink.withAlphaComponent(0.12).cgColor
            fill.backgroundColor = palette.accent.cgColor
            setGlow(nil, animated: false)
        }
        if calm != self.calm {
            self.calm = calm
            setGlow(nil, animated: false)
        }
        if clearTop != self.clearTop || clearBottom != self.clearBottom {
            self.clearTop = clearTop
            self.clearBottom = clearBottom
            setNeedsLayout()
        }
    }

    func show(_ next: FlashFrames, progress: FlashProgress) {
        self.progress = progress
        guard frames !== next else { return }
        frames = next
        rate = max(1, next.plan.framesPerSecond)
        shown = -1
        started = CACurrentMediaTime()
        clockSet = false
        if let first = next.picture(0) {
            modules = first.image.width
            code.contents = first.image
            shown = 0
            setGlow(first.glow, animated: false)
            progress.playhead = LinkFlashPlayhead(elapsed: 0, cycleLength: next.cycleLength, framesPerSecond: rate)
        }
        setNeedsLayout()
        if window != nil { run() }
    }

    func stop() {
        link?.invalidate()
        link = nil
        hold.end()
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window == nil {
            stop()
        } else {
            run()
        }
    }

    override func willMove(toWindow newWindow: UIWindow?) {
        super.willMove(toWindow: newWindow)
        // Leaving: restore while the window is still known.
        if newWindow == nil { hold.lower() }
    }

    /// Only the code changes on a refresh: twice its rate is plenty, and a whole number of
    /// refreshes per picture at 60 Hz.
    private static let frameRates = CAFrameRateRange(minimum: 20, maximum: 60, preferred: 60)

    private func run() {
        guard frames != nil else { return }
        hold.begin { [weak self] in self?.window?.windowScene?.screen }
        guard link == nil else { return }
        // The refresh only wakes this view; which picture shows comes from the clock.
        let link = CADisplayLink(target: FlashTick(self), selector: #selector(FlashTick.tick(_:)))
        link.preferredFrameRateRange = Self.frameRates
        link.add(to: .main, forMode: .common)
        self.link = link
    }

    /// `shownAt` is when the coming screen refresh appears (the display link's target time).
    /// The picture is chosen for that moment, so every picture stays up for the same whole
    /// number of refreshes and changes in one refresh, never partway through one.
    fileprivate func tick(shownAt: CFTimeInterval) {
        guard let frames else { return }
        if !clockSet {
            // The first refresh is picture 0's: start the clock there.
            started = shownAt
            clockSet = true
        }
        let playhead = LinkFlashPlayhead(elapsed: shownAt - started + 0.001 / Double(rate), cycleLength: frames.cycleLength,
                                         framesPerSecond: rate)
        guard playhead.frame != shown || progress?.playhead?.pass != playhead.pass else { return }
        shown = playhead.frame
        if let picture = frames.picture(playhead.frame) {
            if picture.image.width != modules {
                modules = picture.image.width
                setNeedsLayout()
            }
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            code.contents = picture.image
            fill.frame.size.width = bounds.width * CGFloat(playhead.frame + 1) / CGFloat(max(1, playhead.cycleLength))
            CATransaction.commit()
            setGlow(picture.glow, animated: true)
        }
        progress?.playhead = playhead
        frames.prepare(after: playhead.frame)
    }

    /// A faint wash of light from the band's edges. In color it takes one of the current
    /// picture's colors and eases between them; with Reduce Motion, or in black and white, it
    /// holds still in the accent.
    private func setGlow(_ glow: (red: Bool, green: Bool, blue: Bool)?, animated: Bool) {
        let color: UIColor
        if let glow, !calm {
            color = UIColor(displayP3Red: glow.red ? 1 : 0, green: glow.green ? 1 : 0, blue: glow.blue ? 1 : 0, alpha: 1)
        } else if animated {
            return
        } else {
            color = palette.accent
        }
        let strong = color.withAlphaComponent(calm || glow == nil ? 0.22 : 0.34).cgColor
        let none = color.withAlphaComponent(0).cgColor
        CATransaction.begin()
        CATransaction.setAnimationDuration(animated ? 0.3 : 0)
        CATransaction.setDisableActions(!animated)
        glowAbove.colors = [none, strong]
        glowBelow.colors = [strong, none]
        CATransaction.commit()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let scale = window?.screen.scale ?? traitCollection.displayScale
        let pixels = { (points: CGFloat) in Int((points * scale).rounded()) }
        let layout = LinkFlashLayout(width: pixels(bounds.width), height: pixels(bounds.height),
                                     top: pixels(clearTop), bottom: max(0, pixels(bounds.height - clearBottom)),
                                     modules: modules, minimumArt: pixels(12))
        let point = { (pixels: Int) in CGFloat(pixels) / scale }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        band.frame = CGRect(x: 0, y: point(layout.bandY), width: bounds.width, height: point(layout.bandHeight))
        code.frame = CGRect(x: point(layout.codeX), y: point(layout.codeY), width: point(layout.codeSide), height: point(layout.codeSide))
        let reachAbove = min(Self.glowReach, max(0, band.frame.minY - clearTop + 40))
        let reachBelow = min(Self.glowReach, max(0, clearBottom - band.frame.maxY + 40))
        glowAbove.frame = CGRect(x: 0, y: band.frame.minY - reachAbove, width: bounds.width, height: reachAbove)
        glowBelow.frame = CGRect(x: 0, y: band.frame.maxY, width: bounds.width, height: reachBelow)
        track.frame = CGRect(x: 0, y: band.frame.maxY, width: bounds.width, height: 3)
        let done = progress?.playhead.map { CGFloat($0.frame + 1) / CGFloat(max(1, $0.cycleLength)) } ?? 0
        fill.frame = CGRect(x: 0, y: band.frame.maxY, width: bounds.width * done, height: 3)
        CATransaction.commit()
    }
}

/// A display link keeps its target alive. This holds the view weakly so the view can go.
@MainActor
private final class FlashTick: NSObject {
    private weak var view: FlashStageUIView?
    init(_ view: FlashStageUIView) { self.view = view }
    @objc func tick(_ link: CADisplayLink) { view?.tick(shownAt: link.targetTimestamp) }
}
