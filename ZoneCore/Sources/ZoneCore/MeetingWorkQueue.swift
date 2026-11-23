// by zayd/cold @ zayd.wtf

import Foundation
import Observation

/// Owns a meeting from enqueue through the real completion of its processing task.
@MainActor
@Observable
public final class MeetingWorkQueue {
    public private(set) var active: UUID?
    public private(set) var pending: [UUID] = []
    private var task: Task<Void, Never>?
    private var suspended = false
    private let process: @MainActor (UUID) async -> Void

    public init(process: @escaping @MainActor (UUID) async -> Void) { self.process = process }

    public func enqueue(_ id: UUID) {
        guard active != id, !pending.contains(id) else { return }
        pending.append(id)
        startNext()
    }

    public func cancel(_ id: UUID) {
        pending.removeAll { $0 == id }
        if active == id { task?.cancel() }
    }

    /// Capture gets priority. An interrupted job resumes from its saved checkpoint afterward.
    public func suspend() {
        suspended = true
        if let active, !pending.contains(active) { pending.insert(active, at: 0) }
        task?.cancel()
    }

    public func resume() { suspended = false; startNext() }

    /// True while a recording holds the queue; a job cancelled now resumes by itself.
    public var isSuspended: Bool { suspended }

    public func drain() async {
        while let task { await task.value }
    }

    private func startNext() {
        guard !suspended, task == nil, !pending.isEmpty else { return }
        let id = pending.removeFirst()
        // Reserve before creating a task: an immediate second tap must see the owner.
        active = id
        task = Task {
            if !Task.isCancelled { await process(id) }
            active = nil
            task = nil
            startNext()
        }
    }
}
