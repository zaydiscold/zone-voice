# Runtime state ownership

This is a source map for lifecycle review, not a claim that every device transition has been exercised. Keep asynchronous owners and their cancellation rules here when changing them. Native microphone routes, permissions, background suspension and storage reclamation still need iPhone acceptance.

## Dictation and model lifetime

- `Zone/App/DictationCoordinator.swift` owns `ModelState` (missing, downloading, loading, ready, failed), session standby, dictation `Activity`, recovery retries, model switching and storage deletion. Main-actor reservation happens before an await. Concurrent composer starts share the first start. A keyboard request during recovery is refused before the existing utterance can be retired. Native engine preparation is shared work; cancelling a caller must not invalidate another caller's preparation.
- `armSession` captures the session generation, then checks both task cancellation and that generation after model and permission waits. `endSession` invalidates pending starts, clears queued cold keyboard requests and cancels interruption-driven standby rearming. An explicit subsequent On captures the new generation. Callers treat a superseded start as cancellation rather than a microphone failure.
- `modelDeletionBlocker` rejects active recording/transcription, meeting startup/finalization, recovery, diagnostic tests, engine switching, preparation, pending arming and downloads. Idle standby can be ended within the delete confirmation. The deletion reservation prevents new owners until downloader invalidation, native unload/drain and exact-path removal finish.
- `Zone/Engine/ParakeetEngine.swift` detaches the resident manager on unload and chains native cleanup after `SerialRecognitionDecoder.drain()`. `unloadAndWait` is the storage/switching boundary.
- `Zone/Engine/ModelProvisioner.swift` owns background transfers. A persisted `ModelDownloadBarrier` generation invalidates late data/resume callbacks across app restart; a new explicit download receives the current generation. Storage cleanup never deletes a parent directory shared with unrelated assets.

Regression evidence: `ZoneMeetingTests/ModelStorageTests.swift`, `ModelDownloadBarrierTests`, `CompiledModelCacheTests`.

## Notes: the card and the Note saved page

- A note is a recording that `startAppDictation(asNote: true)` begins while `noteRequested` still holds. That flag is set by the press (`beginShortcut(noteMode: true)`) and cleared when the recording begins, when X on the card calls it off (`cancelNoteStart`), or when a keyboard recording won the microphone meanwhile. Nothing on screen sets or reads it: before 2026-11-16 `showsNoteScreen` meant both "the note screen is up" and "this recording is a note", so closing or covering the screen changed what a recording was.
- An Action Button press that has to turn the microphone or the speech engine on first runs `prepareRecordingShortcut(noteMode: true)`, which sets `preparingNote`; X then sets `noteStartWithdrawn`, and `runRecordingShortcut` ends the press without recording. `settleRecordingShortcut` releases the audio as for any press.
- `noteCard` is computed, never stored: the note's own recording or recognition (`activeNoteRequestID`), then a start in progress, then `noteOutcome` (no words, or a failure in one sentence, cleared after 3 or 10 seconds, by X, or by the next recording). Every way a note can end without saving sets an outcome (`endNote`).
- `notePage` is set when a note is saved, wherever Zone is. Any new recording, a keyboard dictate URL, a meeting, Done, a swipe, Delete and Added to Notes close it; coming back to Zone drops one older than `notePageFreshness` (10 minutes). Closing it acknowledges the finished note. The page's edit in progress is saved by the page as it disappears.
- The card lives in its own window above Zone's (`NoteCardWindow`), which takes touches only inside the card and is hidden whenever there is no card, so it never holds the status bar (Flash hides it). Zone's window makes room for the card at the top (`NoteCardOverlay.reservedHeight`). The page is an overlay in Zone's own view tree, not a presentation, so it can never block the keyboard's dictation screen or a meeting from presenting.
- Apple's rating prompt never lands on the card or the page: an ask held back by either is asked again once both are gone (`RootView.askForReview`, `reviewOwedAfterNote`).

Regression evidence: `ZoneMeetingTests/NoteCaptureFlowTests.swift` (production coordinator, AVAudioEngine and the Voice note intent) and `ZoneUITests/NoteCaptureUITests.swift` (the app on a simulator with `-zoneFakeSpeech`).

## Microphone and interruptions

- `Zone/Audio/AudioCaptureEngine.swift` owns stopped → armed → recording. Main actor changes AVAudioSession/engine state; the audio callback receives samples.
- Recording admission, last-buffer uptime, sink and converter cross the audio/main boundary through `Locked<SharedWithAudioThread>`. The callback snapshots admission and sink together. Conversion, signal processing, and sink calls run outside the mutex. Heartbeat/level posts recheck the current main-actor state before delivery.
- Heartbeat/level accumulation fields are audio-callback-owned; do not write them from the main actor without adding synchronization. The stall watchdog reads synchronized uptime, retries a stalled route, then hands recording to the interruption policy rather than silently losing it.
- `ZoneCore/Sources/ZoneCore/InterruptionPolicy.swift` and dictation hold/resume handling distinguish permission/session interruption from completed capture. Ending an interrupted meeting clears a stopped standby. Held dictations use the interruption timeout and resume with a fresh keyboard visibility grace period. Physical route changes and audio callback timing are not proven by fake-engine unit tests.

Regression evidence: `RecordingInterruptionTests`; app compilation and coordinator tests. Real-device route and latency acceptance remains necessary.

## Recognition and queued work

- `ZoneCore/Sources/ZoneCore/SerialRecognitionDecoder.swift`: one FIFO task chain per loaded native decoder. Caller cancellation cancels that job; successors wait for actual completion, including a native call that is slow to stop. Warm-up is admitted only while idle. Drain joins the tail.
- `ZoneCore/Sources/ZoneCore/RollingRecognitionSession.swift`: open → finishing/closed, with sticky backlog failure/cancellation. A large feed searches for a pause inside the same first 24 seconds as a live feed. Acceptance of decoded text and doubts is serialized with cancellation. Input is segmented; one chain serializes decoding and bounds queued audio. Cancellation invalidates results and cancels the active decode.
- `ZoneCore/Sources/ZoneCore/RecognitionBacklog.swift`: mutex-protected bounded pending samples and sticky failure. Overflow must be reported, never presented as a complete successful transcript.
- `ZoneCore/Sources/ZoneCore/ShortcutActionQueue.swift`: accepted request token plus FIFO actions. Recovery must still own the current token. A delayed open-app response cannot supersede a newer Off.
- `ZoneCore/Sources/ZoneCore/SingleFlight.swift`: one shared operation and generation-scoped completion. Cancel releases waiters and invalidates late completion; restarting uses a new generation.

Regression evidence: `SerialRecognitionDecoderTests`, `RollingRecognitionSessionTests`, `ShortcutActionQueueTests`, `SingleFlightTests` and backlog tests.

## Meetings and playback

- `Zone/Meetings/MeetingCoordinator.swift`: recovery/start permission → recording/paused/interrupted → finishing/save. Startup and finishing reserve ownership before suspension; Stop during permission invalidates startup. A closed writer rejects old audio callbacks. Speaker download has a separate `SingleFlight` owner and stalled-progress timeout.
- `ZoneCore/Sources/ZoneCore/MeetingWorkQueue.swift`: pending FIFO, at most one active job. Suspend cancels current processing and queues its checkpoint for later; resume never overlaps the cancelled job's actual completion. A missing speech model stops queued transcription rather than silently redownloading deleted assets.
- `Zone/Meetings/MeetingPlayback.swift`: generation-scoped loading/playing/stopped. Stop invalidates old file reads and buffer-completion callbacks. PCM is read in bounded chunks with at most three scheduled buffers; playback does not load an entire long meeting.

Regression evidence: `ZoneMeetingTests/MeetingCoordinatorTests.swift` and shared queue tests. Playback was source-reviewed; this pass did not run new audio playback/device tests.

## Keyboard handoff and periodic work

- `ZoneKeyboard/MicController.swift`: idle/requesting/recording/transcribing/in-app/pending-insert/recovery/inserted/undone/error. Owned request ID + generation + insertion ledger gate delivery. Host-field changes must not cause automatic insertion into another destination. Polling and level subscriptions stop when the keyboard is hidden or no longer in the relevant state.
- `ZoneCore/Sources/ZoneCore/InsertionDecider.swift` and shared dictation/control models define cross-process admission. The mounted keyboard releases stale controls after both active status and heartbeat age past 30 seconds. A paused recording can intentionally go quiet. Late results require explicit insertion. Darwin notifications are hints to reread shared state, not proof that an operation succeeded.
- `ZoneKeyboard/SwipeEngine.swift`: one decoder and scorer per process on one serial queue, one engine per controller. `indexedWords` is the list the shared decoder's personal index was built from; a `configure` or decode with an equal list skips the rebuild. `releaseShared` and a fresh build clear it. Taps wait behind a pending decode, so nothing slow may be queued ahead of one.
- Dictation foreground polling sleeps two seconds and exits on cancellation, loss of foreground ownership or released coordinator before rereading storage. The armed countdown/purge loop, keyboard active-status polling and meeting recording tick have separate owners; preserve their stop paths when changing visibility.

Regression evidence: `InsertionDeciderTests`, `DictationModelsTests`, keyboard test targets. New typing/swipe/cursor work belongs to its own release owners.

## Other stateful boundaries

`LibraryBackupManager.isWorking` serializes export/import/automatic backup and holds security-scoped access for the operation. `AudioRecoveryStore` persists recording/failed/retrying/text-ready states across a crash. Zone Link retains possible recipients of a pending deletion when the same computer asks for a full resend. A replacement database gets fresh delivery state. Watch/Messages delivery and new text-cleanup runtimes have separate owners; this review does not establish their complete state coverage. Cleanup model lifecycle must integrate through its owning actor, and never delete CleanupHistory with weights.

## Repeatable checks

```sh
swift test --package-path ZoneCore
xcodebuild test -project Zone.xcodeproj -scheme Zone \
  -destination 'platform=iOS Simulator,id=<dedicated simulator UUID>' \
  -parallel-testing-enabled NO -only-testing:ZoneMeetingTests \
  CODE_SIGN_IDENTITY=- CODE_SIGN_STYLE=Manual DEVELOPMENT_TEAM=
```

Run the relevant keyboard target when changing MicController/insertion. Release only a clean combined source through the single TestFlight owner; never equate passing simulation with physical-device acceptance.
