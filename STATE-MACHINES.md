# Runtime state ownership

This is a source map for lifecycle review, not a claim that every device transition has been exercised. Keep asynchronous owners and their cancellation rules here when changing them. Native microphone routes, permissions, background suspension and storage reclamation still need iPhone acceptance.

## Dictation and model lifetime

- `Zone/App/DictationCoordinator.swift` owns `ModelState` (missing, downloading, loading, ready, failed), session standby, dictation `Activity`, recovery retries, model switching and storage deletion. Main-actor reservation happens before an await. Concurrent composer starts share the first start. A keyboard request during recovery is refused before the existing utterance can be retired. Native engine preparation is shared work; cancelling a caller must not invalidate another caller's preparation.
- `armSession` captures the session generation, then checks both task cancellation and that generation after model and permission waits. `endSession` invalidates pending starts, clears queued cold keyboard requests and cancels interruption-driven standby rearming. An explicit subsequent On captures the new generation. Callers treat a superseded start as cancellation rather than a microphone failure.
- A standby card the person clears (`RecordingLiveActivity.lost` with `dismissed`, Zone not in front) ends the session with `SessionEndReason.clearedCard` and posts "Zone is off" (`IslandUpkeep.Response.turnOff`, decided in `checkIsland`). It waits for `microphoneReady`, so a card cleared during a recording or a call turns Zone off when that settles. Unlike `.user` it leaves `userEndedSession` false: opening Zone may arm again (Turn on when Zone opens). A card iOS ends (`ended`) leaves standby on and notifies as before.
- A press that arms from the background goes through `armSessionForPress`: a start refused with `what` or `!act` is tried again up to three times inside the same intent (`PressArmRetry`), under the card `prepareRecordingShortcut` made, and stops as soon as something else arms, records or withdraws the note. Not in front, not on a CarPlay route.
- `modelDeletionBlocker` rejects active recording/transcription, meeting startup/finalization, recovery, diagnostic tests, engine switching, preparation, pending arming and downloads. Idle standby can be ended within the delete confirmation. The deletion reservation prevents new owners until downloader invalidation, native unload/drain and exact-path removal finish.
- `Zone/Engine/ParakeetEngine.swift` detaches the resident manager on unload and chains native cleanup after `SerialRecognitionDecoder.drain()`. `unloadAndWait` is the storage/switching boundary.
- `Zone/Engine/ModelProvisioner.swift` owns background transfers. A persisted `ModelDownloadBarrier` generation invalidates late data/resume callbacks across app restart; a new explicit download receives the current generation. Storage cleanup never deletes a parent directory shared with unrelated assets.

Regression evidence: `ZoneMeetingTests/ModelStorageTests.swift`, `ModelDownloadBarrierTests`, `CompiledModelCacheTests`.

## Notes: the card and the Note saved page

- A note is a recording that `startAppDictation(asNote: true)` begins while `noteRequested` still holds. That flag is set by the press (`beginShortcut(noteMode: true)`) and cleared when the recording begins, when X on the card calls it off (`cancelNoteStart`), or when a keyboard recording won the microphone meanwhile. Nothing on screen sets or reads it: before 2026-11-16 `showsNoteScreen` meant both "the note screen is up" and "this recording is a note", so closing or covering the screen changed what a recording was.
- A button press with standby off first checks installed model files, keyboard ownership, microphone permission and the recording card. It opens one recovery file and connects the tap before starting hardware. Opening the microphone is the only startup phase that can be withdrawn without confirming discard. Once recording, the note card, system controls and island can stop and save while the model is still loading.
- The recording owns its disk writer and one model attachment task. The first nonempty buffer sets the clock. The writer syncs the first block. The model reads committed samples in bounded chunks and switches to live input at an exact sample boundary. Stop seals the capture before finishing the file. A failed model leaves the audio available on Home. An interruption holds the same recording for resume or save. After a process exit, launch checks the file length and surfaces the interrupted recording.
- After a press, `StandbyAfterPress` returns to the existing standby interval, or starts the chosen interval when automatic startup is enabled and the person has not explicitly turned Zone off. The standby card must be available. The car's audio preference still applies.
- `noteCard` is computed, never stored: the note's own recording or recognition (`activeNoteRequestID`), then a start in progress, then `noteOutcome` (no words, or a failure in one sentence, cleared after 3 or 10 seconds, by X, or by the next recording). Every way a note can end without saving sets an outcome (`endNote`).
- `notePage` is set when a note is saved, wherever Zone is. Any new recording, a keyboard dictate URL, a meeting, Done, a swipe, Delete and Added to Notes close it; coming back to Zone drops one older than `notePageFreshness` (10 minutes). A page saved away from Zone and never looked at is carried into the next one as `NotePage.earlier` (`unseenNotes`, at most `unseenNotesLimit`): the page then says how many notes were saved, steps between them and copies them all. Done, a swipe, Added to Notes, a stale page, or coming back to Zone with no page up clear the list; a page that gives way to a new recording, the keyboard or a meeting without having been on screen keeps it. Deleting or emptying one note of several leaves the page on the rest. Closing it acknowledges the finished note. The page's edit in progress is saved by the page as it disappears.
- The card lives in its own window above Zone's (`NoteCardWindow`), which takes touches only inside the card and is hidden whenever there is no card, so it never holds the status bar (Flash hides it). Zone's window makes room for the card at the top (`NoteCardOverlay.reservedHeight`). The page is an overlay in Zone's own view tree, not a presentation, so it can never block the keyboard's dictation screen or a meeting from presenting.
- Notes ignore Finish when quiet, from every start path. Recording identity (`activeNoteRequestID`), never the visible screen, excludes them from the silence detector and rejects queued quiet stops. Note card, island and Lock Screen show no quiet countdown. `testFinishWhenQuietNeverStopsANote` and `testAQuietNoteKeepsRecordingUntilSaved` replace the old auto-save expectations with this behavior. Unpaused notes have no duration cap. An explicit Pause retains the existing save deadline: the session timeout, at least five minutes, or no deadline with Until I turn it off. Keyboard-only limits, interruption handling and recovery saves stay as before.
- While the card shows a recording or saving note, Home's hero does not repeat it: it says "Your note" with the word count and the newest words (`HomeView.heroShowsNote`). The clock, the bars and the buttons are the card's alone.
- Saved notes are shown by id, never by position or by what a row displayed: Home's three (`HomeLibraryView`), the Notes page (`NotesView`) and the read page (`NoteReadView(noteID:)`) each look the note up in `NotesStore` when they draw, so an edit, a delete on another screen or a restored backup cannot leave a page on the wrong note. The read page closes when its note is gone, and keeps an edit in progress when it is taken away (Back, a swipe, the next recording), as the Note saved page does. A search's marks belong to the text it read: the read page drops them the moment the note's words change. Added to Notes lights the note among Home's three, or, for an older note from a page of several, opens the Notes page at it (`NoteReveal`, unchanged).
- Apple's rating prompt never lands on the card or the page: an ask held back by either is asked again once both are gone (`RootView.askForReview`, `reviewOwedAfterNote`).

- A refused note start keeps its reason in `activity.failed` after its small card folds away. In the background it also requests a notification. Before first unlock, `ZoneIntentHost` holds the reason in memory and transfers it to Home when `AppLaunch` builds the graph. No protected preferences are read for that transfer. An ongoing recording is never replaced by the failure of another press.

Regression evidence: `ZoneMeetingTests/NoteCaptureFlowTests.swift` (production coordinator, AVAudioEngine and the Voice note intent), `ZoneUITests/NoteCaptureUITests.swift` (the app on a simulator with `-zoneFakeSpeech`) and `ZoneUITests/NotesReadingUITests.swift` (reading, editing as a second step, search and delete, with `-zoneNotesSeed`).

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
- Recording in the keyboard (`KeyboardPreferences.dictatesInKeyboard`, on by default): a third way a mic tap starts, beside the warm ping and opening Zone. `KeyboardCapture.route` (ZoneCore) allows it only with the switch on (read through `LastKeyboardPreferences`), iOS 26, the microphone allowed, Zone's verified Mini model and worker available, or Apple's speech asset installed (`SharedStore.keyboardSpeechReady`, published by the app at launch, fetched when the person enables the keyboard recording option), no fresh app heartbeat, and fewer than two failed dictations in a row in the last hour. The app stamps that heartbeat while it arms and for as long as it holds or is about to hold the microphone (a recording, a held one, a meeting), not only while audio flows, and answers a request with `starting` before waiting out its own arming. The request is posted as usual; after `KeyboardCapture.probe` (200 ms) an app answer other than silence or `needsApp` belongs to the app: `applyStatus` shows it, and a `starting` gets the warm wait. Otherwise the request and its status are withdrawn and a cancel control is posted, so no app, early or late, can start it.
  - `LocalDictationHost` (process-wide, not per controller) owns the dictation from there: `LocalDictation` records through a hidden web view (`KeyboardCapturePage`, every start and message carrying an epoch, so a cancel then a retap never runs two captures) and sends a temporary WAV to Zone Speech Worker. The worker loads Mini on the CPU and returns words and uncertain matches. If it cannot recognize the audio, the keyboard tries Apple’s on-device speech model. A controller only observes (weak) and asks for stop, pause and cancel; a new controller adopts a recognition in flight and offers its text. While `MicController.localRequest` is set no app status moves the controller's state. A start while the host is busy cancels the old dictation first; Cancel ends it even with no owner; a keyboard leaving before the microphone starts cancels without counting a failure, and one leaving mid-recording stops and recognizes what it has.
  - On text: History first, then the shared store as an ordinary `DictationResult` (under `KeyboardCapture.publishedGeneration`, so another controller's cancel at the same number never reads as this one's) unless a newer request or result is already there (`KeyboardCapture.mayPublish`; the words stay in History), then the result-ready ping; the controller never stays on Transcribing. A failure (no microphone, the web process dying before audio, a capture of pure silence: `KeyboardCapture.isSilent`, a muted track for 2 s or a track iOS ended) counts toward the hold-off and its next tap opens Zone. A failed recognition keeps the WAV as `zone-keyboard-retry-<id>.wav` for one retry on the next appearance; `prepare` sweeps every other leftover `zone-keyboard-*.wav`. Recording stops by itself at `DictationLimits.standard.maximumLength`, or after the person leaves Pause on for five minutes. A dead web content process reloads its page whether busy or idle.
  - `KeyboardRecordingClaim` in the App Group says "the keyboard is recording by itself": written when the keyboard's microphone starts, its heartbeat refreshed every second while it is live (recording or paused), cleared on stop, cancel, failure, a limit and the keyboard leaving. Recognition does not hold it. Meeting and clip starts check the claim too. The app's starts (`clearWayForShortcutStart` for the Action Button in both modes, the island's Dictate and Note, `startAppDictation` for Home and notes, the cold `zone://dictate` link for any other request) refuse with one sentence while it is live; a claim quiet for 8 s is dead, cleared and ignored. Stops, standby Off and everything else never read it. With the route unused no claim is ever written.
  - Added 2026-11-21, from stephancill/ios-keyboard-dictation and anomalyco/hex's fixes after its testers' iPhones. The page ends a capture by itself (`ended` with a reason) when no `zoneBeat` arrives for `KeyboardCapturePage.beatLimit` (3 s; the web view's owner sends one a second), or when the audio context or the audio session is interrupted; the keyboard then recognizes what was said at once. `KeyboardCapture.route` also needs memory (`hasMemory`: 32 MB below the limit before the page is loaded, 24 MB after; short of it the tap opens Zone) and takes the microphone permission from the keyboard's own reading or the app's published one (`SharedStore.appMicrophoneGranted`, written at launch, on every return to the front and after each prompt). Apple fallback tries `SpeechTranscriber`, then `DictationTranscriber` with the same recording, each under the keyboard's own reservation of the locale; the app publishes `keyboardSpeechReady` when either's asset is installed. The page is loaded 450 ms after the keyboard appears (`MicController.preloadCapturePage`) only when a tap would record here and the keyboard's microphone started within the last 14 days (`KeyboardCapture.preloads`); it never opens the microphone. Hold space to talk takes the same path: `zoneListensInPlace` is a live session or `localRoute() == .keyboard`, and a hold with neither still says Zone is not ready. Every dictation, whoever recorded it, is written by `MicController.insert`, so My words, learned fixes, handles, contacts, styles, spoken corrections, times and stutter removal are identical (`LocalDictationFlowTests.testTheSameHeardWordsAreWrittenTheSameWhicheverPathRecordedThem`); the worker can return unsure words and handle spelled letters. The strip: `.requesting`, `.recording`, `.transcribing` and `.error` are `ownsTypingStrip` states, so `KeyboardStripContent.resolve` returns `.dictation` for the keyboard's own recording exactly as for Zone's, and `setDictationOwnsStrip` closes an open emoji picker.
- `ZoneKeyboard/SwipeEngine.swift`: one decoder and scorer per process on one serial queue, one engine per controller. `indexedWords` is the list the shared decoder's personal index was built from; a `configure` or decode with an equal list skips the rebuild. `releaseShared` and a fresh build clear it. Taps wait behind a pending decode, so nothing slow may be queued ahead of one.
- Dictation foreground polling sleeps two seconds and exits on cancellation, loss of foreground ownership or released coordinator before rereading storage. The armed countdown/purge loop, keyboard active-status polling and meeting recording tick have separate owners; preserve their stop paths when changing visibility.

Regression evidence: `InsertionDeciderTests`, `DictationModelsTests`, `KeyboardCaptureTests`, `KeyboardRecordingClaimTests`, `KeyboardCapturePageTests` (the page under JavaScriptCore), `KeyboardTests/LocalDictationFlowTests` (MicController and the host with a fake recorder), `ZoneMeetingTests/KeyboardRecordingClaimFlowTests` (the production coordinator and intents), keyboard test targets. New typing/swipe/cursor work belongs to its own release owners.

## Other stateful boundaries

`LibraryBackupManager.isWorking` serializes export/import/automatic backup and holds security-scoped access for the operation. `AudioRecoveryStore` persists recording/failed/retrying/text-ready states across a crash. Zone Link retains possible recipients of a pending deletion when the same computer asks for a full resend. A replacement database gets fresh delivery state. Watch and Messages delivery have separate owners. Old saved rewrites stay until the person deletes them in Your data.

## Shared plumbing

The app and keyboard read the same App Group. “Both” below means those two processes. A ping carries no text or permission. Its receiver reads the stored request, generation and state again.

| Shared key | Writer | Reader | Lifetime |
|---|---|---|---|
| `zone.request` | Both | Both | One tap. Up to 64 characters of context are cleared after insertion or dismissal, or on the next stale payload check. |
| `zone.status` | Both | Both | Latest phase for one request. Replaced on the next tap. |
| `zone.result` | Both | Keyboard | Pending text until consumed, dismissed or older than 15 minutes at cleanup. |
| `zone.control` | Keyboard, app clears | App | Latest stop, pause, resume or cancel for its generation. |
| `zone.session` | App | Keyboard | Latest standby state and heartbeat. A fresh recording flag holds the microphone for a meeting, clip or app dictation even when a tap goes unanswered. After eight seconds of silence it expires. |
| `zone.ledger` | Keyboard, app resets | Both | Survives restarts so a result already inserted or dropped stays that way. |
| `zone.keyboardPresence` | Keyboard | App | Last appearance and Full Access reading. Refreshed while visible. |
| `zone.level` | No production writer | No production reader | Legacy key. The waveform uses notify state below. |
| `zone.textStyle`, `zone.textStylePickedAt`, `zone.defaultTextStyle` | Keyboard picks, app sets default | Both | Until the next pick or default change. |
| `zone.keyboardPreferences` | App | Keyboard | Last saved settings. The keyboard caches a readable copy. |
| `zone.dictationsInserted`, `zone.keyboardMode` | Keyboard | Keyboard | Count and last selected mode persist between appearances. |
| `zone.keyboardRecordingClaim` | Keyboard | App | One-second beats while recording or paused. Cleared on stop. Expires after eight seconds. |
| `zone.keyboardSpeechReady`, `zone.appMicrophoneGranted` | App | Keyboard | Apply to the current container only. A newer permission reading wins. |
| `verifiedMiniModel`, `zone.modelInstall` | App verifies. Both check install at store startup | Keyboard and speech worker | Until deletion or a change of container. An older install must verify again. |
| `zone.settings.accent` | App | Keyboard and Live Activity | Until changed. Watch gets the choice from its phone. |
| `zone.clipboard.seenChangeCount`, `zone.clipboard.privateChangeCount`, `zone.clipboard.secretFieldOpen` | Both | Both | Clipboard changes and field transitions replace these markers. |
| `zone.reviewPrompt` | App | App | Review history persists between launches. |

| Shared files | Writer | Reader | Lifetime |
|---|---|---|---|
| History/history.json and History/inflight | Both write History. App writes in-flight progress | Both | History retention, explicit deletion or recovery of a cut-off recording. |
| Clipboard/clipboard.json | Both and clipboard shortcut | Both | Age, count and size limits apply. Pinned items stay until deleted. |
| Journal/app.jsonl and keyboard.jsonl | Each writes its own | App | Local rolling recording logs. |
| Vocabulary/words.json and system lexicon | Both update vocabulary. Keyboard writes system lexicon | Both | Saved words persist. A new lexicon replaces the cached one. |
| Models/fluid-speech-mini-coreml | App | App and worker | Downloaded once, excluded from backup, kept until removed. |
| Library/Caches/WorkerAudio | Keyboard | Worker | One WAV per job. A killed process can leave a copy in the cache. |
| Library/Caches/.reach-&lt;pid&gt; | Both | Neither | Removed immediately after the access check. |
| car-widget-state.json and standby-control-state.json | App | Live Activity and controls | Latest state until replaced. Readers check freshness. |
| messages-notes.json | App | Messages | Latest local snapshot, excluded from backup. |
| keyboard-worker-fixture.wav and keyboard-local-speech.txt | Test harness | Simulator debug keyboard | Synthetic test inputs only. |

| Notification or state | Writer | Reader | Lifetime |
|---|---|---|---|
| requestChanged | Keyboard or setup | App | Wake to check a pending tap. |
| controlChanged | Keyboard | App | Wake to read the latest control. |
| statusChanged | App | Keyboard | Wake to read the latest phase. |
| resultReady | App or keyboard host | Keyboard | Wake to read the pending result. |
| payloadConsumed | Keyboard | App | Wake after insertion or dismissal. |
| sessionChanged | App | Keyboard | Wake to read standby changes. |
| keyboardShown | Keyboard | App | One appearance. |
| &lt;group&gt;.session-pulse | App | Keyboard | Most recent heartbeat in notify state. |
| wtf.zayd.zone.level | App | Keyboard | Most recent microphone level in notify state. |

## Repeatable checks

```sh
swift test --package-path ZoneCore
xcodebuild test -project Zone.xcodeproj -scheme Zone \
  -destination 'platform=iOS Simulator,id=<dedicated simulator UUID>' \
  -parallel-testing-enabled NO -only-testing:ZoneMeetingTests \
  CODE_SIGN_IDENTITY=- CODE_SIGN_STYLE=Manual DEVELOPMENT_TEAM=
```

Run the relevant keyboard target when changing MicController/insertion. Release only a clean combined source through the single TestFlight owner; never equate passing simulation with physical-device acceptance.
