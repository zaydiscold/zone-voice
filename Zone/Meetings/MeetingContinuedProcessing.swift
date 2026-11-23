// by zayd/cold @ zayd.wtf

import BackgroundTasks
import Foundation
import UIKit
import ZoneCore

/// iOS 26 can keep a user-started transcript running after Zone leaves the screen. A denied
/// request falls back to the existing checkpointed worker and normal background grace time.
@MainActor
final class MeetingContinuedProcessing {
    private var identifier: String?
    private var meetingID: UUID?
    private var active: BGTask?
    private var progress = MeetingOverallProgress()
    var onExpiration: (@MainActor () -> Void)?

    func begin(meeting: UUID, title: String?) {
        guard #available(iOS 26.0, *), UIApplication.shared.applicationState == .active,
              identifier == nil else { return }
        // A new identifier per attempt avoids registering one handler twice after a retry.
        let id = (Bundle.main.bundleIdentifier ?? "wtf.zayd.zone") + ".meeting-transcript." + UUID().uuidString
        guard BGTaskScheduler.shared.register(forTaskWithIdentifier: id, using: nil, launchHandler: { [weak self] task in
            Task { @MainActor in
                guard let self, self.identifier == id else { task.setTaskCompleted(success: false); return }
                self.active = task
                task.expirationHandler = { [weak self] in
                    Task { @MainActor in
                        guard let self, self.identifier == id else { return }
                        self.onExpiration?()
                    }
                }
                if let continued = task as? BGContinuedProcessingTask {
                    continued.progress.totalUnitCount = 1_000
                    continued.progress.completedUnitCount = Int64(self.progress.value * 1_000)
                }
            }
        }) else {
            Journal.log("meetingBackgroundUnavailable", ["reason": "task identifier not permitted"])
            return
        }
        identifier = id
        meetingID = meeting
        progress = MeetingOverallProgress()
        let request = BGContinuedProcessingTaskRequest(identifier: id,
            title: "Transcribing meeting", subtitle: title ?? "Zone meeting")
        request.strategy = .fail
        do { try BGTaskScheduler.shared.submit(request) }
        catch {
            identifier = nil
            meetingID = nil
            Journal.log("meetingBackgroundUnavailable", ["error": JournalFormat.error(error)])
        }
    }

    func report(meeting: UUID, phase: String, fraction: Double) {
        guard #available(iOS 26.0, *), meetingID == meeting else { return }
        let value = progress.update(phase: phase, fraction: fraction)
        guard let task = active as? BGContinuedProcessingTask else { return }
        task.progress.completedUnitCount = Int64(value * 1_000)
    }

    func finish(meeting: UUID, success: Bool) {
        guard #available(iOS 26.0, *), meetingID == meeting else { return }
        if let id = identifier { BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: id) }
        active?.setTaskCompleted(success: success)
        active = nil
        identifier = nil
        meetingID = nil
    }
}
