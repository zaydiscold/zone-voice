// by zayd/cold @ zayd.wtf

import Messages
import notify
import SwiftUI
import UIKit

final class MessagesViewController: MSMessagesAppViewController {
    private let model = MessagesNotesModel()
    private var cacheToken: Int32 = -1
    deinit {
        if cacheToken >= 0 { notify_cancel(cacheToken) }
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        let controller = UIHostingController(rootView: MessagesNotesView(model: model, insert: { [weak self] item in
            self?.insert(item)
        }, openZone: { [weak self] in
            self?.openZone()
        }))
        addChild(controller)
        controller.view.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(controller.view)
        NSLayoutConstraint.activate([
            controller.view.topAnchor.constraint(equalTo: view.topAnchor),
            controller.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            controller.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            controller.view.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        ])
        controller.didMove(toParent: self)
        notify_register_dispatch(CompanionShareCache.clearedNotification, &cacheToken, .main) { [weak self] _ in
            self?.model.reload()
        }
        model.reload()
    }
    override func willBecomeActive(with conversation: MSConversation) { model.reload() }
    private func openZone() {
        guard let context = extensionContext, let url = URL(string: "zone://home") else { return }
        context.open(url) { [weak self] opened in
            DispatchQueue.main.async {
                if !opened { self?.model.message = "Open Zone from your Home Screen to create a note, then return to Messages." }
            }
        }
    }
    private func insert(_ item: CompanionShareItem) {
        guard !model.isInserting else { return }
        model.reload()
        guard model.items.contains(item) else { return }
        guard let conversation = activeConversation else {
            model.message = "Open a conversation, then choose a note."
            return
        }
        model.isInserting = true
        conversation.insertText(item.text) { [weak self] error in
            DispatchQueue.main.async {
                guard let self else { return }
                self.model.isInserting = false
                if let error { self.model.message = "Could not insert this note. \(error.localizedDescription)" }
                else {
                    self.model.message = "Added to your draft. Edit it and tap Send when ready."
                    self.requestPresentationStyle(.compact)
                }
            }
        }
    }
}

@MainActor
final class MessagesNotesModel: ObservableObject {
    @Published var items: [CompanionShareItem] = []
    @Published var message: String?
    @Published var isInserting = false
    @Published private(set) var accent = LastAccentChoice.current
    func reload() {
        accent = LastAccentChoice.current
        do {
            guard let url = CompanionShareCache.url else { throw CompanionNoteError.invalidPayload }
            let cache = try CompanionShareCache.read(from: url)
            items = cache.items
            message = cache.omittedCount > 0 ? "Showing recent notes. Open Zone for your full library." : nil
        } catch {
            items = []
            message = "Open Zone once to refresh your notes, then return here."
        }
    }
}

private struct MessagesNotesView: View {
    @ObservedObject var model: MessagesNotesModel
    @Environment(\.colorScheme) private var scheme
    let insert: (CompanionShareItem) -> Void
    let openZone: () -> Void
    @State private var search = ""
    @State private var source = 0
    private var filtered: [CompanionShareItem] {
        model.items.filter { (source == 0 || ($0.source == .note) == (source == 1))
            && (search.isEmpty || $0.text.localizedCaseInsensitiveContains(search)) }
    }
    var body: some View {
        VStack(spacing: 10) {
            HStack {
                Text("zone.").font(.system(.title2, design: .serif).weight(.semibold))
                Spacer()
                Button("Open Zone", systemImage: "square.and.pencil", action: openZone)
                    .labelStyle(.iconOnly)
                Button("Refresh", systemImage: "arrow.clockwise") { model.reload() }
                    .labelStyle(.iconOnly)
            }
            HStack {
                Image(systemName: "magnifyingglass").foregroundStyle(Color(uiColor: .secondaryLabel))
                TextField("", text: $search, prompt: Text("Find a note").foregroundStyle(Color(uiColor: .secondaryLabel)))
                    .textFieldStyle(.plain)
                    .foregroundStyle(Color(uiColor: .label))
                    .accessibilityLabel("Find a note")
                    .accessibilityIdentifier("findMessageNote")
            }
            .padding(10)
            .background(Color(uiColor: .secondarySystemFill), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            Picker("Show", selection: $source) {
                Text("All").tag(0)
                Text("Notes").tag(1)
                Text("Dictations").tag(2)
            }.pickerStyle(.segmented)
            if let message = model.message { Text(message).font(.footnote).foregroundStyle(.secondary) }
            List {
                ForEach(filtered) { item in
                    Button { insert(item) } label: {
                        VStack(alignment: .leading, spacing: 6) {
                            Text(item.text).lineLimit(4).foregroundStyle(.primary)
                            Text(item.createdAt, style: .date).font(.caption).foregroundStyle(.secondary)
                        }.frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .buttonStyle(.plain)
                    .disabled(model.isInserting)
                    .accessibilityLabel("Insert \(item.source == .note ? "note" : "dictation"): \(item.text)")
                }
                if filtered.isEmpty { Text("Recent notes and dictations show up here.").foregroundStyle(.secondary) }
            }
            .listStyle(.plain)
            Text("Inserts into your draft without sending.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .tint(Color(hex: scheme == .dark ? model.accent.darkHex : model.accent.lightHex))
    }
}
