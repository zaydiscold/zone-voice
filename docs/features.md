# Everything Zone does

Zone is a free dictation keyboard and voice notes app for iPhone. Speech recognition runs on the phone. There is no account, no server and no analytics. Speech and speaker models download when needed; normal recognition then works offline.

This guide describes the source included in **1.0.1 (2026110805)**, not necessarily the build currently offered to every tester. See the [changelog](../CHANGELOG.md) for build-specific changes. Report a mismatch with your installed build number to zayd@zayd.wtf.

As checked on November 8, 2026 at 11:25 UTC, 0805 was processed and available to internal TestFlight testers. It was assigned to External testers but still **Ready for Beta Submission**, because an earlier build was already in Beta App Review. This is a dated observation, not a live status indicator. The [public invitation](https://testflight.apple.com/join/cStumGN1) stays the same across builds; public availability and App Store submission are separate steps.

## Dictation in any app

- Tap the mic on the Zone keyboard, talk, tap Stop. The words land at the cursor in whatever app you are in: Messages, Mail, Notes, Slack, a browser.
- Undo and Redo after every dictation. The strip says how many words landed.
- The first dictation opens Zone once to turn the microphone on. After that the keyboard works on its own for as long as you choose in Settings (Keep microphone ready; it never ends a recording), and Zone can turn itself on whenever you open it.
- Stop to text is under a second on an iPhone 15 Pro with Fluid Speech Mini (then labeled Heavy) warm: 0.17 to 0.59 s measured, including 11 to 15 second clips.
- Recent dictations are one tap away inside the keyboard, so a dictation that went into the wrong field can be pasted into the right one.

## It writes the way you want

- Text styles per dictation: automatic, casual, very casual, formal, excited. Casual drops the final full stop; very casual drops punctuation; formal and excited do what they say.
- Dictation follows Shift: with Shift off the text starts lowercase. Turn it off in Settings if you prefer.
- A dictation that continues a sentence starts lowercase: "I went to" then "the store". Names, "I" and acronyms keep their capitals, and the Shift key still decides when Follow Shift is on. A recording stopped on "the", "my", "and" or a similar word gets no period, so the next one carries on. "Oh my." and "plan A." keep theirs.
- The speech model's unknown-character marker is never typed. Where it stood for an apostrophe or an ampersand, that is written instead ("I'll", "R&D").
- A doubled "I I" or "the the" keeps one copy, and times are written "4:30".
- Spoken corrections (Beta, off by default, Settings > Dictation options): "Let's meet Tuesday, scratch that, Wednesday" types "Let's meet Wednesday". "Strike that", "delete that" and "no wait" work too ("at 3, no wait, 4"). Say "Scratch that" on its own to take back the last dictation, unless you have typed after it; Redo (for 20 seconds) or Recent dictations brings it back. History keeps the words as said.
- California Mode (Beta, off by default, Settings > Dictation options): takes the filler "like" out of dictation. Light removes the clear ones ("it was, like, so good" types "it was so good", "I was like really tired" types "I was really tired"); Aggressive also drops loose ones ("it took like five minutes" types "it took five minutes", "and like we went home" types "and we went home"). A "like" that means something stays: "I like pizza", "looks like rain", "I was like, no way", "someone like you". Only the word "like" is ever removed. History keeps the words as said.
- Say the punctuation and it is typed: "comma", "period", "question mark", "exclamation mark", "colon", "semicolon", "new line", "new paragraph", "open quote" and "close quote" (or "quote ... quote", "quote ... unquote"), "open parenthesis", "bullet point" and "next bullet", and more.
- Faces: in casual and very casual, "smiley face", "winky face" and "sad face" write :) ;) and :( . Settings, Dictation options, Faces turns it off.
- My words: names and terms spelled your way, including sound-alikes, so "Zayd" never comes out as "Zaid". A saved word does not replace an everyday word or a common first name that sounds like it. Built-in names and texting spellings ("imma", "yall") are known on every phone.
- Learn names (Settings > My words): words already in the field you are dictating into help the speech model spell them.

## @ Handles: "at sign" and Smart @

Settings > Say “at” to tag names controls the shorter command. Saved handles are in My words.

- **At sign (always on, not experimental).** “At sign Kevin” writes @kevin and “at sign T X M” writes @txm, in every app and text style, whatever the Smart @ setting. Saved handles are used here too, so “at sign snake byte” joins to @snakebyte and a spelling that lost a repeated letter finds a saved handle. The speech model’s mishearings of the command (“Absign”, “Add sine”, “At signs”) count only before letters it wrote in capitals, the way it writes a spelling; “add sign ups” stays words. “The at sign” names the symbol. “At sign um” keeps um as the handle.
- **Say “at” to tag names (default on).** Also writes a bare “at Kevin” as @kevin, for common first names, My words and saved handles. Filters keep phrases such as “throwing at zade”, “look at Kevin”, “at Kevin’s” and “leave at will” as words, and where something happens: “grab it at Chase”, “see him at Grace”, “my jacket at Ashley”, “wait for you at Lincoln”, “going to be late at Mike”. Greetings and thanks still address someone (“thank you at Kevin”, “happy birthday at Kevin”). These are language heuristics and can still misfire or miss a handle. Check the text before sending.
- Smart @ also recovers a saved handle when the speech model loses “at” or hears it as other words (“D-A-A-N.”, “TXM.”, “That ANNA”, “It's signed D A N”): only a saved handle, only spelled in capitals, only at the start of a sentence and alone or before words said to that person. The trade-off: a saved handle spelled alone on purpose is also tagged.
- Spelling: formatting preserves the letters the speech model supplies and leaves following words out of the handle. Uncertain mixed spelling such as “D AN” and spellings longer than 32 letters stay as words unless they can only be one saved handle. Zone never adds a letter on its own; only when a saved handle such as daan is the single handle the spelling can be with one repeat restored (“D A N”, “DAN” or “D AN”) does it write that handle. An exact saved match wins, two candidates mean no guess, and a spoken “Dan” is not a spelling.
- Stays words: "at sign" plus one letter or a number ("I'm at sign B", "meet me at sign 4"), "at sign" after a place phrase unless it names a saved handle, times and numbers before a place ("tonight at Madison", "at 5 at Chase"), the end of a sentence begun in an earlier dictation ("I'm looking" + "at Kevin"), and talk about the symbol ("type at sign followed by their name"), which also teaches nothing. A handle needs a letter and two characters. Spoken marks ("new line", "comma") start a new clause, so the next "at" can still address someone.
- Accented names are matched and written without accents, as the list saves them: “at José” writes @jose.
- “At everyone” and “at here” never generate broad mentions automatically, even if saved or spelled. The explicit “at sign everyone” / “at sign here” command is available, and is never saved to Saved @handles.
- While Smart @ is on, an explicit “at sign” command can remember a new handle that actually appears in the output. View, add or delete handles in My words > Saved @handles. The list stays in the local shared vocabulary store and keeps the 200 most recently added or taught handles. Turning Smart @ off stops bare recognition and learning; existing preferences are preserved.
- Zone inserts text; it does not look up accounts, select recipients, submit messages or guarantee a ping.
- Recognition limits (measured on Fluid Speech Mini, `scripts/handle-eval` clips): with nothing saved, explicit “at sign” is right on 12 of 24 clips and bare “at” on 6 of 24. With the handle saved, most names reach 8 of 8. Fluid Speech takes no vocabulary hints today; FluidAudio 0.18.1+ CTC vocabulary boosting is the candidate fix.

## Recording and recovery

- Dictation has interruption/recovery handling when another app takes the microphone. Meetings show an interrupted state and offer Resume after the interruption. Only audio actually captured can be recovered; system interruptions are not a guarantee of continuous capture.
- Saved audio supports retry after recognition failures. Meeting safety notices remain attached to the recording. Recovery cannot restore audio that was never captured or successfully written.
- New meetings stop and save at six hours of captured audio. Keyboard-origin dictation has its own two-hour safety ceiling; other app-origin dictation does not use that keyboard-only guard. Neither is a promise of unlimited endurance. The Settings idle-readiness timeout is separate from these recording limits.
- While recording, a Live Activity sits in the Dynamic Island and on the Lock Screen so you can see it is on and stop it from there.
- A recording log (no words in it, only timings and events) helps track down a problem.

## Voice notes without leaving what you were doing

- Dictate a note from the keyboard, the Action Button, Control Center, the Lock Screen or a Shortcut. Zone records in the background and saves the note.
- Notes can be edited, searched, copied, shared and deleted.
- Dictation history keeps the text of finished dictations until you delete them by default; choose 7 days, 30 days or Off in History to have them removed automatically. History entries contain text; the explicit library backup includes dictation history. Saved recording audio is managed separately.
- Hold Zone's Home Screen icon for Voice note, Dictate and copy, Record a meeting and Share Zone with a friend. The items are declared in Info.plist, so they work from install.
- Home's word count carries a comparison ("That's 1.2 Great Gatsbys."). Tapping it cycles through texts from the Gettysburg Address to the Library of Alexandria and Wikipedia, ending on the fact that recognition happens on the phone. The comparison showing goes on the share card. Word counts and sources are in `ZoneCore/Sources/ZoneCore/WordScale.swift`.
- History's footer shows the words and bytes kept, next to the roughly 2.4 GB the Library of Alexandria would take.
- Holding the gear on Home opens My words, Speech model, Keyboard, Appearance or Backup and export directly. Holding Share Zone with a friend in Settings offers a QR code (App Store or beta) or either link alone.

## Meetings (alpha)

- Record up to six hours of captured audio and transcribe it on the phone after stopping. Meeting Home shows the length that fits in free storage when that is under six hours. The recorder and the Lock Screen count down the last ten minutes; if Zone stops a meeting itself, the Lock Screen keeps the reason. Low storage or capture trouble can stop it earlier.
- Optional speaker labels use an on-device model (about 21.6 MB). Name speakers afterward. If two voices collapse into one, More → Transcribe again offers a speaker-count hint for that recording. It replaces transcript edits/names, keeps audio, and does not guarantee perfect labels. Speaker processing is limited to two hours of audio per pass, and the recorder says so once a meeting passes two hours; longer audio is still transcribed without labels.
- Playback, editing and export of the transcript.
- A meeting cannot be taken over by a stray keyboard dictation. System alerts can be quieted while it runs, and a Focus filter plus Start and Stop meeting Shortcuts give you a one-tap Do Not Disturb meeting.
- Saved meeting audio is retained for recovery/retry. Duplicate Transcribe requests are deduplicated, work is queued serially, and pending Start/Stop/Discard actions are guarded against races.
- Settings → Meeting appearance has a simulated live preview, Animate numbers, Gentle/Brisk pacing, and Flow/Breathe/Still glow. The minimal timer transitions smoothly into hours; Reduce Motion overrides movement. The same settings are linked from Meeting Home and persist after reopening.
- Synthetic 10–15-hour files verified parts of file/chunk handling. They do not establish 10–15-hour phone recording, transcription, or speaker-label quality. Physical-device endurance and interruptions remain validation work. [Instructions and limits](../README.md#meeting-recording-limits-and-appearance).

## Private by construction

- Recognition happens on your iPhone after models are downloaded. Sharing/export, an optional iCloud Drive backup, and Watch-to-phone note transfer move data only through those features; offline recognition does not mean exported data can never leave the phone.
- Zone does not upload recordings to a transcription service. Model downloads require network access; optional cloud-backed Files destinations are handled by their provider.
- No account. No analytics. App Privacy on the App Store: Data Not Collected.
- The keyboard needs Allow Full Access only so it can hand your words to the Zone app on the same phone through a shared container. It makes no network requests.

## Your data stays yours

- Backup and export: one package with notes, dictations, meeting transcripts, speaker names and the original audio. Importing is additive and safe to repeat.
- Optional backup folder in Files or iCloud Drive.
- Delete data: start the word count over, delete the history, delete everything.

## Speech models

- The product choices are Light (Moonshine Tiny Streaming, about 45.2 MB) and Medium (Fluid Speech Mini, about 253 MB). A17 Pro and newer phones default to Medium; earlier phones default to Light. Change it in Settings → Speech model. Historical reports may call Fluid Speech Mini Heavy.
- Models run offline once downloaded. Remove all speech models or Remove old models frees model files and identifiable compiled caches without deleting recordings; active work must finish first. Moonshine Small/Medium and Parakeet 110M are retired product choices.
- Each model shows its own size (Medium: 259 MB on disk). Downloads can be cancelled and resume later; a re-downloaded model in use loads at once.
- Switching models is refused while dictating, recording a meeting or transcribing one, so nothing in progress is discarded.

## Around the system

- Shortcuts and Siri: Voice note, Dictate and copy, Get last dictation, Start and Stop meeting.
- Controls for the Action Button, Control Center and the Lock Screen: Voice note, Dictate and copy, and Toggle Zone, which turns the keyboard's instant dictation on (opening Zone) or off for the time set in Zone.
- Home Screen and StandBy widget; CarPlay widget stack.
- Apple Watch: dictate or type a note on the wrist. It is saved on the Watch first, then sent to the iPhone, and the Watch keeps its copy until the phone confirms.
- iMessage: insert a recent dictation into the message you are writing.
- Appearance and accent color, start and stop sounds, haptics, key clicks.

## The keyboard itself

- Hold space, slide left/right to move the cursor, then lift to resume typing. It works with swipe typing on or off and preserves emoji/accented characters; holding does not insert a space. [How to use it](../README.md#move-the-cursor-by-holding-space).
- Optional English swipe typing adds spaces between words, offers alternatives and whole-word Delete, and supports explicit local learning/reset. It remains beta; corpus scores are not real-phone typing-quality claims.
- Optional Emoji key with recents and remembered skin tones.
- A full keyboard with autocorrect (77,000 words, aware of where your taps landed), suggestions and contractions.
- Contact names from your phone are known to autocorrect.
- Off in password, email, URL and one-time-code fields, where autocorrect would only get in the way.
- Autocorrect per keystroke: 23 microseconds on average, so typing never waits on it.

## Numbers people ask about

| What | Number | Where it was measured |
| --- | --- | --- |
| Stop to text, Fluid Speech Mini (then Heavy), model warm | 0.17 to 0.59 s | iPhone 15 Pro |
| Stop to text, legacy Medium preset, p50 / p90 | 0.44 / 0.90 s | iPhone simulator, LibriSpeech and 30 s dictations |
| Autocorrect per keystroke, mean / p99 | 23 / 175 us | M4 Mac, release build |
| Core checks for build 2026110805 | 580 XCTest (2 skipped, zero failures) + 19 Swift Testing | Release validation, November 8, 2026 |

Latency figures above are historical measurements, not a rerun of the current model lineup or a long-meeting benchmark.

A side-by-side against Apple's keyboard dictation on the same phone and the same clips has not been published yet. Until it is, Zone does not claim a number against Apple.

## Requirements

iPhone with iOS 17 or later. The widget, Controls and Live Activity need iOS 18. Medium (Fluid Speech Mini) needs iOS 18. Meeting transcription needs a speech model; the separate speaker model is needed only for labels. 45 to 253 MB of storage for the speech model.
