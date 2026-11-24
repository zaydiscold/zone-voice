# Changelog

TestFlight builds of Zone, newest first. `scripts/testflight.sh` adds each entry from
`next-build/` when the build uploads. Earlier builds were recorded here afterward from their What
to Test notes in App Store Connect.

This file is per build, for testers. Each change is listed once, under the build it first went out
in. A later build of the same version lists only what is new, and a line that revises something an
earlier build announced starts with "Changed since" or "Fixed since" and that build's number. The
notes people read inside Zone (Settings > Version) are per version, in `Zone/ReleaseNotes/`; the
long form for 1.0.4 is `docs/release-notes/1.0.4.md`.

## 1.0.5 (2026112001), November 20, 2026

Source 9d3c176e4a6c26a02176d1f214aa9ab60c92c448. App Store Connect build `771d35e9-b6c9-4763-b532-15cce81007ef`. TestFlight distribution requested; App Store submission is separate.

What to Test in App Store Connect was written by hand for this build, and that text is kept there and in the build receipt. These are the per-change notes it stands for.

- When the Action Button cannot start the microphone, Zone says what works: press again, or with CarPlay, open Zone and then press. Before, it asked you to open Zone "once to start its microphone session".
- With CarPlay connected, Zone turns the microphone on only while you record, so music and audiobooks stay on the car speakers in stereo instead of moving to the iPhone. Turning Zone on from Home in the car keeps it ready, as before.
- What's New and Settings > Version are shorter: every change is one line, grouped by Dictation, Keyboard, Voice notes, Dynamic Island and more. The sheet after an update shows only the few big ones.
- If you tap the mic, Zone opens and no recording ever starts, the keyboard now says so after ten seconds and gives the mic back, instead of asking you to finish in Zone.
- Your data > Delete everything, and the delete-by-date choices, now remove text files left by earlier versions. Before, those stayed on the iPhone.
- Typing, swipe typing and dictation know more AI and developer terms people use every day, such as PRs, WebSocket, latencies, TPUs and FastAPI, and keep them as you write them.
- Settings > Experimental is now Dictation options, under Dictation: Scratch that, Check unsure words, caps lock, faces, ordinals and California Mode, with their on or off choices kept. Smart @ is in Settings > @ Handles.
- A second dictation after sentence punctuation starts with a capital when the field uses sentence capitals. Fixing an unsure word checks that the dictation is still at the cursor.
- Finish when quiet, off by default: stop talking and the dictation finishes and types by itself after 3, 5, 10 or 30 seconds (5 unless you choose). The keyboard counts down the last seconds. Turn it on in Settings > Microphone and timing.
- Fixing a word by hand no longer teaches Zone a typo: a slip made while retyping is corrected as usual, and names you capitalize are still learned. With Check unsure words on, a fix made by hand counts the same as one made from the strip.
- History opens and refreshes faster with a long library, and saving a dictation from the keyboard uses less memory.
- New, in Beta: hold the space bar to talk, and let go to type what you said. Turn it on in Settings > Keyboard > Hold space > Talk. A tap still types a space, and sliding sideways still moves the cursor. It works while Zone keeps the microphone ready; otherwise the keyboard asks you to tap the mic once.
- Hold Zone's icon on the Home Screen for Voice note, Dictate and copy, Record a meeting, and Share Zone with a friend.
- Under your word count on Home, see what it adds up to ("That's 1.2 Great Gatsbys."). Tap it for more comparisons. The one showing goes on your share card.
- History shows how much text you've kept and how little space it takes.
- Hold the gear on Home to jump to My words, Speech model, Keyboard, Appearance or Backup. Hold Share Zone with a friend in Settings for a QR code or just the links.
- New for 1.0.5: the dot in Zone's icon is ice blue. It changes color with each version.
- Stopping a meeting during a call clears the keyboard’s live mic indicator. A held dictation gets time to resume when the interruption ends.
- Zone keeps its small dot in the Dynamic Island after a call, Siri or other audio briefly takes the microphone. Before, the wide orange microphone pill could come back until you opened Zone.
- Five living Dynamic Island looks in Settings > Dynamic Island > Alive: Void (the island is a black cat whose eyes widen when you speak, and blink slowly while Zone waits), Mote (a pixel pet that hatches and grows with the words you dictate, and never shrinks), Sprout (grows as you speak, flowers when your words are kept), Nocturne (a bat, the camera is its body) and Loop (a comet circling an infinity).
- Three art looks in Settings > Dynamic Island > Art: Stream (your words pass through the island as you say them, the newest right of the camera), Pulse (a heart that beats by itself while Zone waits, with a trace that follows your voice) and Drift (petals carried by the wind of your voice, settling when you stop).
- Themes at the top of Settings > Dynamic Island set a look and a color in one tap, such as Night Watch (two white eyes on the black island), Heartline and Blossom. Two new colors: Bone and Rose.
- Start and stop from the Dynamic Island. Hold the island while Zone is ready and tap Dictate (your words are copied, ready to paste anywhere) or Note. While you record, Pause is on the left and Stop on the right; Stop is on the Lock Screen too. Turn the buttons off in Settings > Dynamic Island > Buttons.
- The island's edge lights in your accent color only while Zone is recording, and a check with your word count shows for a moment when a recording is kept.
- Clearing Zone from the Lock Screen now turns Zone off, microphone included, instead of leaving the orange microphone dot on. A notification says so; open Zone to turn it back on. Settings > Dynamic Island explains it.
- The Action Button and the Voice note control start more reliably when Zone is off or closed: if iOS refuses the microphone at first, Zone tries again within the same press.
- Tapping the keyboard's mic with Zone off should no longer bring Zone forward a second time after you return to your app.
- Settings > Dynamic Island starts with one switch, Zone in the Dynamic Island, on from the first launch. Turn it off and iPhone's own microphone pill shows while Zone waits, and the look, color and button choices are hidden because they no longer apply.
- Choose the island's color in Settings > Dynamic Island > Color: your accent, Blackout (dark grey on black with no white at all, so the island stays a black pill), Graphite, Red, Amber or Green. The Lock Screen card follows it.
- Zone's dot stays in the Dynamic Island past iOS's 8-hour limit: Zone starts a fresh one whenever you open it or press the Action Button. If iOS still ends it while the microphone is on, a notification says so, and a tap brings Zone back.
- New control, Bring back Zone's island: add it to Control Center (or run it from Shortcuts) to put Zone back in the Dynamic Island without opening Zone.
- Settings > Dynamic Island > Times: choose Live to see standby as "on for 29 minutes" and "Off in 15 minutes", counting by itself, instead of clock times.
- Zone's island now lasts 16 hours after you last open Zone, not 8: on iOS 26 and later, Zone has iOS start a fresh island just before the old one's 8 hours run out, while you are in other apps. You see Zone's island open for a moment when it does.
- Hold the island while Zone is ready to see this session: dictations, words and when you turned Zone on. The Lock Screen card shows the same and the time you saved, and says when Zone turns off as a time instead of a ticking countdown.
- While Zone waits, nothing on the island looks like recording: the Recorder look's dot is white until you record, and recognizing your words after Stop no longer shows a moving waveform.
- A misspelling Zone kept after an undone correction no longer takes over swipe typing for the everyday word beside it. When you type it, the row offers the everyday word, and choosing that makes Zone forget the misspelling.
- Two-letter texting shorthand that sits one key from a very common word is kept as you type it, and changes only when your tap landed at the edge of the key.
- A single slipped letter in more informal everyday words is now corrected, when no other word fits as well.
- The keyboard does less repeated work each time it opens, so the first swipe lands sooner.
- Phone number and card number fields on web forms get no swiped words or corrections, as code and password fields already did.
- The mic is available again if Zone stops answering or the keyboard cannot open the app.
- Zone starts getting the speech model ready as soon as the keyboard opens, so even a one-word dictation after the phone sat idle comes back without a wait.
- The keyboard's rows sit 3 points higher, level with Apple's keyboard instead of pressed against the globe row.
- Zone does less on launch and after each dictation, so opening it from the keyboard's mic is quicker. While it records, Zone no longer redraws its widget and controls every second.
- Fixed: after an iPhone restart, Zone could open with the default color and sounds and an empty notes list until it was closed. It now waits for the first unlock and opens with your own settings and notes.
- Home shows your longest dictation under your stats, with how long it ran, how many words it held and the day, once one runs a minute or more. Dictations already in History count.
- The share card shows your longest dictation under its wave.
- Send feedback (Settings > Send feedback): say or type what you think and Zone writes it into an email in your own mail app. Nothing is sent until you send it.
- Home marks word milestones (500 words, 1,000, 5,000 and up) with a short note from Zayd, the next time you open Zone. Settings > About has Rate Zone on the App Store.
- The first dictation after your phone has sat idle finishes about as fast as any other. Zone reads the speech model back into memory while you talk, so you no longer wait up to 3 seconds after you stop.
- On iOS 26, removing Fluid Speech Mini now frees all of its storage, about 1.2 GB more than before, and Settings shows its full size. A nearly full iPhone no longer refuses to load a speech model it already has.
- Dictation no longer swaps an everyday word like "repo" for one of My words that sounds like it.
- A single mistyped letter in a newer everyday word or app name is now corrected, and a two-letter slip is fixed when the tap landed on the edge nearest the intended key.
- The row above the keys now offers your next word. Finish a word and three likely next words appear; tap one to write it with a space, and keep tapping to carry the sentence on. While you type, the row puts the word that fits the sentence first, so "good m" offers morning. Suggestions are now on by default (Settings > Keyboard > Suggestions).
- A word typed in the middle of a sentence in Messages no longer gets a capital it should not have.
- Voice notes record in a card at the top of Zone instead of taking over the screen. Press the Action Button again and the next note starts at once.
- After a note saves, edit, copy, share or delete it right on the Note saved page. Added to Notes takes you to it on Home.
- While a note records, Home shows "Your note" and counts your words instead of repeating the card.
- After a voice note finishes by itself (Finish when quiet, or Stop in the Dynamic Island), the next Action Button press starts a new note. Before, that first press did nothing.
- With Finish when quiet on, a note that hears nothing for two seconds says Quiet on its card and in the Dynamic Island, with a countdown to when it saves. The note card has a Pause button.
- Several notes saved in a row from the Action Button now all show on the Note saved page when you open Zone: step between them, edit or delete each one, or use Copy all.
- A note from the Action Button no longer turns standby off. The island keeps showing Zone and the keyboard's mic starts in place instead of opening Zone. With "Turn on when Zone opens" on, a press from off also leaves the microphone ready for your "Keep microphone ready" time.
- The 123 key is as wide as Return when no emoji or globe key sits beside it, the size iOS gives it.
- A one-handed keyboard, off until you turn it on in Settings > Keyboard > One-handed. The keys move toward your left or right thumb at a width you choose (70 to 90 percent). Hold 123 and slide to switch sides or go back to full width, or tap the buttons beside the keys.
- Buttons across the app now share one shape with the keyboard keys, cards line up edge to edge, and the section switch spans the top of Home.
- Zone has one speech model now, Fluid Speech Mini, on every iPhone. Settings > Speech model explains it and shows each step from your voice to the text in your app. If you used Light, Zone removes it and downloads Fluid Speech Mini once (253 MB). Zone now needs iOS 18.
- The keyboard's Paste key pastes without iPhone asking you to allow it each time. Turn the key on in Settings > Keyboard > Paste key.
- Notes, History and Meetings are lighter: each item is a row on the page instead of its own card, with two lines of it and Copy right beside it. Tap a dictation to read all of it.
- Deleting a dictation or a note asks first, and a full swipe in History no longer deletes on its own. The swipe typing trail (Settings > Keyboard > Swipe typing) is shorter and a little more see-through.
- A long voice note or dictation keeps recording when iPhone removes Zone's Dynamic Island card at its eight-hour limit, instead of being stopped. Opening Zone brings the card back.
- Tapping the mic twice while it opens starts one recording. A new keyboard request lets an audio retry finish.
- Sending everything to a paired computer again now includes deletions made while the computer was offline.
- Changing the style on the keyboard rewrites the dictation you just made in that style, so you can see a message as Casual, Formal or any other without saying it again. Tap the Z, pick a style, and the text changes in place.
- Undo right after puts the earlier wording back and keeps the new style for what you say next.
- Fixed: after you undo a dictation, the next thing you dictate or type starts with a capital again.
- Long dictations use the same pauses to split speech even when audio arrives in a large batch.
- The space bar shows a slim line instead of the word "space". Choose Voice, Word or Blank in Settings > Keyboard > Space bar.
- Words per minute now counts only the time you spend talking, not the start of a recording, long pauses or the quiet before you tap stop, so short replies no longer drag your speed down. Time saved still counts the whole recording, against a typing speed of 36 words a minute.
- After each dictation the island's check shows how fast you spoke ("Kept 42 words · 128 wpm"), and the Lock Screen card shows this session's words, speed and time saved.
- With the microphone kept ready, Zone writes to storage about 95% less often in the background. If the keyboard ever says Zone is off while it is on, tell us.
- If Zone stops while it's ready for the keyboard (an update, the phone reclaiming memory, closing it), a quiet notification says so. Open Zone to turn it back on. Turning Zone off yourself never sends one.
- The styles the Z opens, and Insert and Dismiss, are raised keys with the keyboard's own shadow, and those shadows are a little deeper.
- Dictation now leaves out stutters on its own: a sound you cut off before the word ("f- fidgeting"), a small word said twice by accident ("I I", "it's it's", "a a") and a phrase you started over ("in the in the box"). Words doubled on purpose, like "really really" or "thank you thank you", stay.
- Tap the Z on the keyboard to choose the style for your next dictation. The styles open in the row beside it, and the Z stays put so a second tap closes them. Holding the microphone does the same, which is how to choose a style with the Z hidden (Settings > Keyboard > Hide the Z).
- The recent dictations button now sits on the right, beside the microphone. Holding the keyboard key still offers Open Zone.
- Casual and Very casual write small numbers as digits, the way people text: "around 7", "2 things". Formal and Excited still spell them out.
- Numbers said together are written the same way in every style: "8 or 9, maybe 7".
- Casual follows Settings > Keyboard > Auto-Capitalization. With it off, sentences in a casual dictation start lowercase; names and "I" keep their capitals.
- Formal writes "gonna", "wanna", "kinda" and "cuz" as "going to", "want to", "kind of" and "because".
- Settings > Text style shows the same sentence written in each style, so you can pick one by reading it.
- "No one" is no longer written "no 1".
- Dictation style names start with a capital: Casual, Very casual, Formal and Excited.
- The style you pick with the Z stays until you pick another, from the Z or Settings > Text style, whichever you changed last. It used to go back to the Settings style after 15 minutes without a dictation, which is why a message picked as Casual could come out Formal. Settings now shows the style the next dictation will use.
- Casual and very casual write times the way people text them: "7 am" and "12:45 pm", not "7 AM" or "7 a.m.". Formal keeps them as before.
- A spoken time after "later than", "earlier than" or "sooner than" is written as a time: "later than 12:45".
- A dictated question no longer ends with a stray period after its question mark ("work?." is now "work?").
- Recent dictations (the clock in the row above the keys) stays on screen while word suggestions show, so a dictation that did not land can always be put back.
- Typing and swipe typing know thousands more names and words: teams, players, places, brands, tech terms and British spellings are kept as you type them, and names take their capitals. Brands written with a hyphen or apostrophe, like T-Mobile and McDonald's, come out right when typed without one.
- Dictation writes a few brand names the speech model confuses with everyday words only when the sentence is about them, such as Vercel in a sentence about deploying a site, or Jupyter in "Jupyter notebook".
- When you backspace over the last word of a dictation and type it the way you meant, Zone remembers it and writes it that way in your next dictations (Settings > My words > Learn from corrections).
- Autocorrect leaves a word after @ or # as you typed it, corrects a word typed right after a dictation, and expands your iPhone text replacements even when the shortcut is also a word Zone knows.
- Fixing a typo in a selected everyday word no longer adds it to My words, and a capital an earlier build learned that way no longer follows the word into dictation and swipe.
- Tightened copy across setup, Home, Settings, Meetings, History, and the keyboard so explanations stay direct and plain.
- After Dictate and copy from the Action Button or a control, opening Zone later shows Home, not the finished screen of that earlier dictation.
- Verification code fields open on the next keyboard in your list, where iPhone offers the code from Messages. Switching back to Zone in that field sticks.
- Seven new voice graphics in Settings > Appearance > Voice graphic. Scope is the dot oscilloscope from Hex. Ink writes a line of script as you talk, Glyphs stamps a character per syllable, Branch grows and sheds leaves when you pause, Inkblot, Lanes and Stars each draw your voice their own way.
- A new voice graphic, Bars: thin upright bars that rise as you talk, on the keyboard and on Home. Choose it in Settings > Appearance > Voice graphic.
- The Z on the keyboard is drawn as a key, like the keys beside it, and stays pressed in while the styles are open.

## 1.0.4 (2026111604), November 16, 2026

Source 5e16dc26a5c87585d33e789a061502e49b8fbfa7. App Store Connect build `766b32e4-40e5-4094-bed0-af107c3b94c7`. TestFlight distribution requested; App Store submission is separate.

- Back, Save, Done and Cancel at the top of each screen are rounded keys, like the keyboard's. Swiping back from the left edge still works.
- Long dictations with Fluid Speech Mini keep the period where you paused between sentences, and no longer write a doubled period there.
- Changed since 2026111601: My words (Settings) shows each word as its own key. Add from one field, tap a word to fix its spelling, tap the x to remove it, and changes save as you make them. Words Zone learned from your corrections are listed apart, so a wrong one is easy to spot and remove.
- Updated speech engine, with fixes for long dictations, model downloads and memory use when a meeting sorts out who is speaking. Dictation and meeting transcripts should read the same as before; tell us if anything got worse.
- Shadows under cards and keys follow the real sky more closely: they lean right in the morning and left in the afternoon, the moon casts them after dark, and in the app they reach a little farther.

## 1.0.4 (2026111602), November 16, 2026

Source 47db2dcd25c2acde14785ca575d6ef337540e0b4. App Store Connect build `726f528a-5797-4c89-9ab5-54249a0be747`. TestFlight distribution requested; App Store submission is separate.

This is the build that went to the App Store as 1.0.4.

- Changed since 2026111601: California Mode on Aggressive takes out most filler "like"s, not just the textbook ones, and still keeps "I like it", "looks like", "something like that" and quotes. Light takes more of the clear ones.
- Fixed since 2026111601: Check unsure words (Beta) shows the words Zone may have misheard after a dictation. In 2026111601 the switch was there and no words ever appeared.
- Spoken corrections (Beta, Settings > Experimental): scratch that works without a pause.
- Changed since 2026111601: upside down smiley face writes (:, a list of faces or of ordinals ("second and third place") is written one way, and caps lock keeps winky and crying faces.
- Settings is in a clearer order: Computers (Beta) is under Setup, Your data (Dictation history, Backup and export, Delete data) sits near the bottom, and Privacy is under About.

## 1.0.4 (2026111601), November 16, 2026

Source cd83e92e28cc53c81ecd2a5d530da5bf5d781560. App Store Connect build `0fe936ab-44e3-43cf-8a9f-c329be4c4b7c`. TestFlight distribution requested; App Store submission is separate.

Zone 1.0.4: your words on your own computer, numbers written the way you type them, and a keyboard that knows today's words. What to Test in App Store Connect was a shorter summary of this list (it allows 4,000 characters), under the same four headings.

### Your words on your computer (Beta)

- Computers (Beta): send the text of your dictations, notes and meeting transcripts to your own computer, where your tools and AI agents can read them. It is off until you pair a computer in Settings > Computers, and it needs the free zone program running on that computer.
- New items arrive in seconds over any network. Only text is sent, encrypted from the iPhone to the computer, with no account and no Zone server. Audio stays on the iPhone.
- On the computer, zone gives you a searchable history, a command line and an MCP server, so AI agents like Claude Code, Codex and Cursor can search what you said.
- Settings > Computers says how to pair from the computer (open Zone and choose Pair a phone, or run zone pair) and has a "Get Zone for your computer" row that opens the download page or shares it to the computer.
- Each paired computer has a "Send to this computer" switch. Turn it off to pause sending to that computer; turn it back on and Zone sends only what changed meanwhile, deletions included.
- "Keep what I delete here", under that switch, is off by default. Turn it on and that computer keeps its copy of anything you delete on the iPhone. Turning it off later does not delete those copies, only what you delete after that. While a computer is paired, Privacy, History and the delete confirmations say where your text is and which computers keep their copies.
- Send text to your computer: in Settings > Computers, paste or type a link, a code or anything you copied, and it is on your paired computer a moment later (run zone clip there). If the computer cannot be reached, the text waits and goes with the next sync.
- The Send to Computer shortcut does the same without opening Zone. In Shortcuts, put Get Clipboard before it, then run it from the Action Button, Back Tap or Control Center.
- No connection between the two, on a plane or a network that blocks everything? "No connection? Send by Flash", on a paired computer's row, plays a short piece of moving art with a window of color codes in it for the computer's camera to read, after a short guide to setting up the computer. Each flash opens in one of three scenes (Dusk, Aurora, Ember) on the Zone wordmark, and every couple of seconds the art takes the window over for a moment. Older cameras can use black and white codes instead, which are plain. You do not need Flash while syncing works.
- Beside Start Flash, the guide warns that the codes change 20 times a second at full brightness, in color and in black and white. If flashing lights can affect you, do not use Flash: Zone syncs once the phone can reach the computer. With Reduce Motion on, the art holds still (the codes still change).
- Send by Flash tells the computer how many items it is sending and how to check each one, so the computer's Flash page can say "1,764 items, all checked" when it is done. The phone names each flash and shows how many items and pieces it has, and asks you to say it arrived only when the page says Done for that flash.
- If your library changes while the codes show, or while you are away from the Flash screen, the codes are made again, so the computer never gets an older version of something you just edited or deleted. A large library goes as several shorter flashes, and Everything goes on from where the last one stopped.

### Dictation

- Dictated numbers are written as digits where people expect them: larger numbers, years, percentages, decimals, times, amounts and measurements. Small counts in a sentence stay as words.
- Dictation writes ordinal numbers from 10th up as numbers: "I was in 10th and got bumped to 11th". To also write 1st through 9th as numbers where they rank something ("I came in 2nd"), turn on Settings > Experimental > 1st, 2nd, 3rd as numbers.
- A word you spell out loud in dictation ("D A A N", "D-A-A-N", "D. A. A. N.") is written as one word with a capital first letter, like a name: "Daan". With Shift locked it is written in capitals. Known acronyms keep theirs ("A P I" is API). Say "double" before a letter to write it twice: "D double A N".
- Abbreviations are written without periods (USA, RSVP, DC), and a contact's name no longer replaces a dictated acronym such as CLI.
- Tap Shift twice to lock it and the dictation is written IN CAPITALS, like typing with caps lock. Names and My words are capitals too; links, emails and @handles keep their spelling. It works whether or not Follow Shift is on.
- New Beta in Settings > Experimental: Caps lock drops punctuation. On, a caps-lock dictation also leaves out commas, periods and apostrophes; ? and ! stay.
- Quotation marks in dictation: "quote hello quote" and "quote hello unquote" both write "hello", and after "she said quote" the quotation runs to the end of the sentence. "A quote" and "quote me" stay words.
- In casual and very casual, say "smiley face", "winky face" or "sad face" to write :) ;) or :( . Turn it off in Settings > Experimental > Faces.
- Dictation styles treat names differently: casual and very casual spell company and product names correctly but in lowercase, formal and excited write them the company's way. Formal and excited now capitalize the start of every sentence.
- The excited text style now ends every sentence with an exclamation mark, not only the last one.
- Casual writes shorthand said as letters in lowercase, the way people text it, and knows more nicknames for everyday places and apps.
- California Mode (Beta) takes the filler "like" out of dictation: "it was, like, so good" becomes "it was so good". Light removes the clear ones; Aggressive also drops loose ones such as "it took like five minutes". A "like" that means something stays. Turn it on in Settings > Experimental.
- Check unsure words (Beta): after a dictation, the keyboard shows up to three words Zone may have misheard, underlined with dots beside Undo. Tap one to pick the right word, or the check mark to keep it. Your choices teach it which fix to offer first and how often to flag. Turn it on in Settings > Experimental.
- Dictation spells many more app, company and tech names correctly, including names the speech model splits into two words or spells by sound.
- A name in My words is caught in dictation more often when the speech model spells it the way it sounds.
- Contractions and names like "I'll" and "R&D" no longer come out with a stray "<unk>" or a gap in the middle.
- If the microphone goes silent partway through a recording, Zone stops waiting after about 8 seconds, keeps what it heard and pauses the recording instead of listening to nothing.
- Fixed a case where the keyboard said to open Zone and opening it did not bring the microphone back, and a false "previous recording was interrupted" message when starting a dictation from the keyboard.
- Keep microphone ready has two shorter choices, 30 seconds and 1 minute, for when you want the microphone released soon after you dictate (Settings > Microphone and timing). A dictation you pause is still held for at least 5 minutes before it saves.
- Labeling speakers in a meeting uses about half the memory, so long meetings are less likely to be interrupted.

### Keyboard

- About 800 current words and names are no longer autocorrected away and can be swiped. About 400 are AI tools, popular apps and well-known companies, which dictation also spells and capitalizes correctly. About 400 more are tech terms, market tickers, apps and teams, kept as you wrote them instead of being changed into other words. A word drawn out for emphasis, like "sooo", is left alone, and typos now resolve toward everyday words such as "congrats".
- Common texting shorthand is no longer autocorrected into a different word, and typing and swipe typing know more of it and more everyday chat slang.
- Everyday words that appear on a contact card ("Boss", "Dentist") no longer get a capital when you dictate or swipe them, and ordinary words no longer get one in the middle of a sentence because they appear in a contact's name. Real names from Contacts still keep theirs. If a contact's name is also a word ("Mark", "Bill"), undo the capital once and swipe keeps it lowercase from then on, the way tapping already did.
- A contact's last name that is also an ordinary word gets its capital right after a first name or title, in swipe and dictation.
- Typing and swiping write store and place names made of everyday words the right way once the whole name is in, like Micro Center, Taco Bell, Home Depot and Trader Joe's. Delete right after puts back what you typed.
- Autocorrect now reads the word before a typo to pick the fix, so the same slip can become a different word depending on the sentence. Typing only, nothing to turn on.
- Autocorrect now fixes a missed space bar even when the next word also has a small typo.
- Words misspelled with a doubled l at the end, such as "carefull" or "helpfull", are now corrected to one word instead of being split into two.
- A new sentence after a closing quote or bracket now starts with a capital when typing, the same as when dictating.
- Select a word to see its spelling fixes above the keys, then tap one to replace it. Needs Suggestions on in Settings > Keyboard.
- More spelling suggestions for words the keyboard had no answer for. They are offered above the keys and never applied on their own.
- One-letter text replacements from iPhone Settings now appear as suggestions.
- Suggestions now offer your own words: names in My Words, and unusual names from your contacts, complete as you type them. Turn on Settings > Keyboard > Suggestions.
- A typo in one of your My words is now corrected to that word, and a word you saved with a capital gets it when you type it in lowercase. Everyday words and other names are left as they were.
- My words takes words one per line or separated by commas, and a list pasted with bullets or numbers works too.
- Saving My words works on phones where the word list was set up by an earlier test build. Your existing words are kept.
- Suggestions share the row evenly, so each word stays in the same spot as you type, and three short suggestions fit beside the Z instead of the third being cut off.
- Typing with suggestions on is steadier: the row above the keys now changes at once when a word starts or ends, instead of fading the style and microphone buttons in and out on every word.
- Swipe typing (Settings > Keyboard > Swipe typing) now works in search bars and address bars (Messages, Passwords, Safari, Chrome), including over a selected address. Address bars get a period key beside space, and web address fields a slash.
- Name fields capitalize each word, the search key dims until you type, and dictating into a search bar no longer adds a period at the end.
- Words you pick in swipe suggestions keep their capitals the next time you swipe them, such as a company's name or "I'm".
- Smart punctuation: curly quotes, long dashes and the ellipsis as you type, with web addresses and measurements left alone. Backspace right after a dash or ellipsis puts back what you typed. Turn it on in Settings > Keyboard > Smart punctuation.
- Moving the cursor with the space bar is smoother. A slow slide moves one character at a time without stalling, and sliding up and down follows your finger line by line, both ways, without lifting. Slide diagonally to move lines and characters together.
- The space bar cursor stays in the right place in web pages and web-based editors that are slow to update.
- The keyboard keeps your accent color, your last layout and your own words the first time it opens after a restart, and no longer asks for Full Access when it is already on.
- The Zone keyboard uses less memory as you switch between apps and fields, so it is less likely to go blank or be replaced by the system keyboard after long use.
- The keyboard is steadier when it opens and closes, and the Recording log now notes any key the keyboard had to ignore.
- The voice wave, the level bars and the swipe trail now show your accent color clearly on light keyboards and in the app's light appearance. Ice, Ember, Mint, Rose and Violet each use a richer shade there; dark mode is unchanged.

### And more

- A new Dynamic Island. While Zone is ready it is a small dot with a ring that counts down, instead of the wide microphone pill. While you dictate it shows a live waveform in your accent color.
- Choose how it looks in Settings > Dynamic Island: Halo, Recorder, Caption (your words appear live when you hold the island) or Ghost (just a dot). "Try it in the Dynamic Island" plays a short preview.
- Turn Zone off from the Dynamic Island: hold the island while Zone is ready and tap the power button.
- History now keeps your dictations until you delete them. If you had it on 30 days, it moves to Until I delete, and nothing older is removed. You can still pick 7 days, 30 days or Off in History. Notes are never affected.
- New: tap Version in Settings to see every version of Zone, newest first, and what changed in each. After an update, Zone shows what is new once, the first time you open it yourself, as a short list with one line per feature. Read the full notes opens every change in detail, the same page as Settings > Version. It never appears when the keyboard, a Shortcut or the Action Button opens Zone to dictate or record.
- Zone no longer freezes for a moment after you copy text, and automatic folder backups (Settings > Backup and export) no longer pause the app.
- Folder backups write far less to your phone's storage: they save only when your library changed, at most every 5 minutes, and right away after a meeting ends or when you tap Back up now.
- Holding the Back button in History or Settings now shows Home instead of a blank menu.
- The Privacy screen is shorter and plainer.
- The words per minute, time saved and bytes shared figures on Home sit cleanly apart on every iPhone and text size; their labels no longer run together.
- After a few days of use, right after a dictation, note or meeting transcript finishes, Zone may show Apple's standard rating prompt. It asks at most once per version, never while recording or after an error, and iOS limits how often it appears. Apple never shows it in TestFlight builds, only in the App Store version.
- Not in the app: the App Store page now includes the Meetings screenshot, between the recorder and backup screens.

## 1.0.3 (2026111401), November 14, 2026

Source 7444566db0d41ce0871c63ba854d671a8b043e8a. App Store Connect build `967a5392-ea2c-4839-a4c8-8ee21ad00fa1`. TestFlight distribution requested; App Store submission is separate.

- Pressing the Action Button during a call or while Siri is listening now says the microphone is in use, instead of asking you to unlock.
- Voice notes and dictation start reliably in the car. Before, the microphone could fail to start with CarPlay or car audio connected until Zone was closed and reopened.
- The Action Button starts your next voice note on a locked iPhone without asking for the passcode. Before, the note after one you had just finished could ask you to unlock first.
- Opening Zone and starting a dictation no longer freeze the screen for up to a second while the microphone gets ready, and the first start and stop sounds no longer stutter.
- Fixed a rare crash when starting a dictation after hours of switching between AirPods, CarPlay and the phone's speaker. Zone now resets the microphone and tries again.
- Dictating the rest of a sentence no longer capitalizes its first word: "I went to" then "the store" stays "the store", including in long dictations split at a pause. Stopping mid-sentence ("I went to the") no longer adds a period, so the next dictation carries on.
- Words in My words no longer replace a common first name that sounds similar, and saying "at sign everyone" still writes @everyone without saving it to your handles.
- The X on a recording now asks before throwing it away, in the app and in the keyboard, so one stray tap can't lose a note.
- Pressing the Action Button while your last note is still being written out now waits a moment and starts the new recording, instead of doing nothing. If something else is already recording, Zone says so.
- With the home button hidden, the keyboard's top-left key no longer runs into the keyboard's rounded corner.
- Fixed: after a relaunch, the keyboard could ignore Swipe typing, Paste and Suggestions until you turned them off and on again. Your keyboard settings now apply the first time it opens.
- Labeling speakers for part of a meeting no longer listens to the audio just after that part.
- Dictating a quote no longer types a stray "<unk>" where the quotation marks belong.
- If recognition ever stops responding, Zone ends that recording after a minute, keeps its audio so you can transcribe it again, and stays ready for the next one. Before, Zone had to be closed.
- Titles in the middle of a sentence keep their capitals ("I love This Is Us so much"), and a restart before "I" ("I went home Then I slept") now comes out lowercase.
- New control: Toggle Zone. Add it to the Action Button, Control Center or the Lock Screen to turn Zone on before you need it, so the keyboard microphone starts at once. It stays on for the time you chose in Zone. Turning it on opens Zone; turning it off does not.

## 1.0.2 (2026110813), November 8, 2026

Source dcdd2f6713f2a7f92d6a33aaa396190f3cc05b7d. App Store Connect build `fb2f044d-541d-4eec-b5b4-912c098dd1fb`. TestFlight distribution requested; App Store submission is separate.

- Changed since 2026110812: the keyboard's Zone button is the plain Z again, without the dark square behind it, so it looks right in light and dark mode, and it sits closer to the other buttons.
- Hide the listening screen while you dictate: recording keeps going, and a strip at the top of every page shows the time, finishes with the checkmark, or opens the recording again.
- A new share card in Zone's own look, with a waveform drawn fresh each time you share. Home and the card now show words per minute, time saved (like "2h 5m") and "0 bytes shared. Ever."
- Sharing the card now includes a short note with the App Store and TestFlight links, and Settings has Share Zone with a friend to send the links on their own.
- Space-bar cursor: slide up or down to move between lines, and the cursor keeps its column as you go, like Apple's keyboard. Line breaks are exact; for long wrapped paragraphs Zone estimates where each line wraps.
- Fast drags no longer jump across blank lines: the cursor pauses at each line break with a tap you can feel, and a little more push carries it on. A single jerky movement no longer flings the cursor.
- "I I think" comes out as "I think", and times read "4:30" instead of "4.30".
- New Beta, off by default: say "meet Tuesday, scratch that, Wednesday" to type "meet Wednesday", or "at 3, no wait, 4" to type "at 4". Turn it on in Settings > Experimental > Spoken corrections.

## 1.0.2 (2026110812), November 8, 2026

Source d0de9f59bab5208bb39c43bb9f11b53638851609. App Store Connect build `985ead39-66c3-44ea-92c2-4793a0f0efe4`. TestFlight distribution requested; App Store submission is separate.

The first build of 1.0.2, and the first offered to public testers after 1.0, so its What to Test also summed up the 1.0.1 builds below: swipe typing, the space bar cursor, the Emoji key, smarter autocorrect, Dictation follows Shift, meetings, speech models and their fixes. New since 2026110811:

- New setting: Microphone and timing > Keyboard hidden. Keep dictating while the keyboard is out of sight, like when you open an image full screen: 30 seconds to 15 minutes, or until you stop it from the Dynamic Island (default 5 minutes; it used to stop after 30 seconds).
- When you restart a sentence mid-dictation ("so this was, this was one of those times"), the restart no longer comes out capitalized ("so this was This was"). Names, "I", titles such as "The Office" and months such as May keep their capitals.
- Changed since 2026110801: Settings > @ Handles: saying "at sign" and a name always writes a handle, and is no longer experimental. Smart @, which also tags a plain "at" and a name, stays experimental and can be turned off there.
- "At sign" now works even when speech recognition mishears it before a spelled handle, and saved handles are recognized after "at sign" with Smart @ off. With Smart @ on, a saved handle spelled at the start of a message is found even if the "at" was lost.
- "At sign" followed by a single letter or number stays words, so "I'm at sign B" or "meet me at sign 4" at an event is no longer turned into a handle.
- Handles are more careful: "@everyone" is never written unless you say "at sign", spoken commands like "new line" no longer block the next handle, and talking about the @ symbol ("type at sign followed by their name") no longer creates or saves a handle.
- "Concert tonight at Madison" and a sentence finished in a second dictation ("I'm looking", then "at Kevin") stay words.
- Swipe typing recognizes much more everyday slang and texting abbreviations, and picks the right word from the previous one a little more often.
- Changed since 2026110811: the keyboard's home button matches the app icon: your accent color on the icon's dark tile, the same color as the swipe trail in light and dark keyboards.
- Settings notes are easier to scan: one line on what a setting does, then short points that start with a bold label.
- Acknowledgments moved to the bottom of Settings.

## 1.0.1 (2026110811), November 8, 2026

Source b2723d2ec9a31218c8630a8ea5a54b6e7da69486. App Store Connect build `bad172fb-574b-4830-93e6-e1e52a863d8b`. TestFlight distribution requested; App Store submission is separate.

- Typing "thata" now becomes "that's", and "hows", "whens" and "everyones" get their apostrophes. The keyboard had been missing every 's contraction (it's, that's, what's, let's, there's). If you retyped a selected typo as "thats", that spelling no longer blocks the fix.
- Long dictations no longer capitalize a word in the middle of a sentence ("so this was This was") where the recording was split at a pause. Names and "I" keep their capitals.
- Emoji panel: on iPhones with a Home button, the globe now stays beside ABC, so you can still switch keyboards while emoji are open. The panel also says where stickers, Memoji and Genmoji are: hold the globe and pick Emoji.
- @/Handle Recognition leaves everyday sentences alone more often, such as "grab it at" or "I left my jacket at" a place, and accented names now tag the way the handles list saves them.
- One narrow exception for handles you saved yourself: spelling a saved handle that has a doubled letter now finds it even if speech recognition drops one of the repeats. Zone still never adds a letter to a name you say or to a handle you have not saved.
- The Z home button on the keyboard is a little larger, so its top and bottom bars read clearly instead of looking like a slash.
- When Zone saves a meeting at the six-hour limit or because storage is low, the Lock Screen now says why instead of the recording simply disappearing. In the last ten minutes the recorder and Lock Screen show when it will stop, and a call now shows as "Meeting interrupted" rather than "paused".
- Meetings shows how long you can record when free storage is shorter than six hours. Past two hours, the recorder notes that the transcript won't have speaker labels.
- The meeting waveform uses less battery during long recordings. Settings → Microphone and timing → "Keep microphone ready" explains that it never stops a recording or meeting.
- Speech models show their actual size, such as 259 MB for Medium. A nearly full iPhone is told before downloading instead of failing while the model gets ready.
- Model downloads can be cancelled, and a download waiting for a connection no longer blocks switching or removing models. A re-downloaded model is ready right away, a failed load no longer starts the mic later on its own, and switching models waits for an active dictation or meeting transcription instead of discarding it.
- Space-bar cursor control no longer freezes partway through a drag in apps such as T3 and other web-based editors; it keeps following your thumb until you lift.
- Changed since 2026110805: slide sideways along space to move the cursor straight away, without waiting for the hold, and drag faster to travel further. A slide on space never types a space mid-word, and holding space right after typing a space now works.
- Swipe typing now uses the word before it to pick the right word, so everyday phrases come out right more often.
- Words you keep while tapping (by choosing your own spelling or undoing a correction) can now be swiped too.

## 1.0.1 (2026110809), November 8, 2026

Source 82a4d30e39817ba1250d909ae0bfc45c82bca44a. App Store Connect build `f78998ba-150d-4931-8161-16ca5539f022`. TestFlight distribution requested; App Store submission is separate.

- Fixed a freeze when automatic backup and transcript-history updates happened together, including when reopening Zone or switching apps.
- The keyboard's home button shows the Z from the app icon again. In the last build it showed the empty space around the letter instead.
- Fixed a crash after stopping or saving an Action Button recording, including empty notes and repeated recording controls. Finished shortcuts now release the microphone cleanly.

## 1.0.1 (2026110807), November 8, 2026

Source bfdd402a0f99c6068b9fd2ea50757f7216567981. App Store Connect build `89e0de7b-1769-434b-aa07-90245484fce7`. TestFlight distribution requested; App Store submission is separate.

- Dictation follows the displayed Shift key even when the host briefly hides cursor context. Try Auto-Capitalization off, manual Shift, quoted openings and “a quick test”; names, acronyms and links keep their spelling.
- Casual “imma” and “yall” stay lowercase after spoken punctuation too. Follow Shift is in Settings → Keyboard; turning it off uses the text style and surrounding sentence.
- Experimental handle recognition preserves lowercase and hyphenated letter spelling, keeps following words out of handles, and refuses uncertain partial or overlong spellings. Saved short handles no longer steal the beginning of a longer spelling.
- Speech recognition can still omit repeated letters before formatting; this update does not guess that Dan means Daan. Check the handle before sending.
- Autocorrect now handles missing apostrophes together with missing spaces, such as “dontxknow” → “don't know”, and keeps useful completions such as “keyboard” visible while typing. Ambiguous words and protected spellings stay intact; invalid touch samples no longer partly train key positions.
- Meeting recording now supports landscape, with a simpler recorder and shorter information sheet. Recording appearance follows your accent color.
- Speech model download and selection buttons stay readable with pastel accent colors.
- Model downloads keep the screen responsive, and Fluid Speech Mini shows the storage needed after preparation.
- A simpler speech model screen shows storage details and makes clear that removing a model keeps your notes, recordings and transcripts.
- New Mint and Rose accents, with clearer buttons and color choices that follow your selection in light and dark mode.
- Experimental @/Handle Recognition now supports a local editable handles list and spelled handles such as “at T X M”. The toggle explains its limits and what turning it off does.
- Stronger ordinary-speech filtering; “throwing at zade” and “leave at will” stay words. Broad @everyone / @here mentions require explicit “at sign”.
- Turning dictation off now cancels a pending startup, even while microphone permission or model loading is still in progress. Microphone state and background polling also handle stop transitions more safely.
- Changed since 2026110801: record meetings for up to six hours, with automatic saving and low-storage protection.
- Holding Space stops sending further cursor movements when it detects an editor text or selection change. A movement already sent to iOS can still finish. Existing selected text stays selected; ordinary typing resumes when you lift your finger.
- Swipe understands more casual words and acronyms, and learns when you choose an alternative or delete a swipe and type a replacement. The swipe trail follows your accent color with a smooth fading tail.
- Apple’s supplementary vocabulary now reaches voice dictation as well as keyboard typing/swiping. Open the Zone keyboard with Full Access to sync its local snapshot; imported terms stay separate from My Words.
- Voice output uses imported name spellings, while ordinary words, literal handles and typed-only shortcut expansions stay protected. Case-only Apple entries such as iphone → iPhone now also reach swipe vocabulary.
- Regular typing repairs phrases such as “hesxhavingxfun” and “socmuchcfunx” when you press Space, including an extra final space-slip letter. Casual dictation reduces repeated question marks and writes “autocorrect” without an unwanted hyphen.
- Space taps now commit normally when swipe typing is disabled, instead of waiting for the next key or accidentally entering cursor mode.

## 1.0.1 (2026110806), November 8, 2026

Source 9f8549db547644f9ae88214114499e3309c964b9. App Store Connect build `1be4274b-141b-4c56-9716-9eb96c2ac832`. TestFlight distribution requested; App Store submission is separate.

- The keyboard's home button is now the small Z from the app icon. Hide it in Settings → Keyboard → Appearance; it stays visible by default.
- With the Z hidden, hold the keyboard key and choose Open Zone. Its normal tap still shows or hides the letters.

## 1.0.1 (2026110805), November 8, 2026

Source 34491c485d894e1b14f3867caca088ca5bd54ccc. App Store Connect build `1d49acdb-4b07-408c-ba37-945d8760b38c`. TestFlight distribution requested; App Store submission is separate.

- Improved name recognition in dictation while respecting spellings saved in My Words.
- Settings → Meeting appearance now has a live preview, an animation toggle, Gentle/Brisk timer pacing, and waveform styles. The timer eases into hours without jumping wider. The recorder stays uncluttered; appearance remains reachable from the Meetings home screen.
- Choose Light or Medium for dictation. Medium uses Fluid Speech Mini; older redundant speech models are retired and their downloads are cleaned up automatically.
- Free space with Delete all models or Remove retired models. Deletion now explains blockers beside the controls, can turn idle dictation off in one step, and clears model files and identifiable compiled caches while keeping your recordings.
- Hold the space bar, then slide left or right to move the cursor. Lift your finger to resume typing; holding space does not insert a space.
- Cursor control preserves emoji and accented characters and works with swipe typing on or off.

## 1.0.1 (2026110804), November 8, 2026

Source daa413619803947c575a8e9dbfcfc39d0d6c3af9. App Store Connect build `ec8316b6-a7ad-4650-aad4-32ebe22aafd8`. TestFlight distribution requested; App Store submission is separate.

Dedicated swipe typing beta.

Enable Settings → Keyboard → Swipe typing (Beta), then switch back to Zone's keyboard. Glide across English letters and lift. Swipe the next word or tap letters to continue; separating spaces are added automatically. Punctuation attaches to the last swipe. Tap an alternative to replace it, or tap Delete to remove the whole last swiped word.

Try short words, repeated letters, longer words, fast swipe→tap transitions, Shift, Auto-Capitalization off, punctuation and held Delete. Try Messages and another app, an empty field, moving the cursor and changing fields mid-gesture. Ordinary tap typing should remain predictable.

Learning is optional and stays on this iPhone. Only explicit alternative choices train word/context preferences. Switch learning off or reset it in Keyboard settings; reset takes effect the next time the keyboard opens and keeps My Words.

Please report the intended word, what appeared, the host app and this build number. No complete private messages needed. This is an English beta; corpus scores do not establish real-phone typing quality. Powered by FUTO Swipe.

## 1.0.1 (2026110801), November 8, 2026

Source 69aad5e67817443516783f35b78b01470c301c35. App Store Connect build `3a27c12c-c1b8-49c4-b065-ad429d5005e2`. TestFlight distribution requested; App Store submission is separate.

- Autocorrect now checks Apple's dictionary before changing a word, so real words like meds, donut, gameplay, cancelled and backend stay as typed. The correction is still offered in the strip if you meant it.
- The keyboard now remembers up to 5,000 words you kept, up from 1,000.
- Zone knows the name Zayd on every phone, not only the developer's. Zaid, Zayed, Zade, Zayde, Zeid, Zyed and the other spellings the speech models write become Zayd, and possessives too: "Zaid's car" becomes "Zayd's car". Real names that only sound close, such as Zahid, Zaida, Zada and Zod, are left alone. If your friend really is Zaid, add Zaid to My words and Zone keeps it.
- Names in My words now also fix their possessive form, so a corrected name followed by 's keeps the ending.
- Casual and very casual write imma and yall, lowercase and without the apostrophe. The keyboard no longer autocorrects them.
- Dictation follows Shift: when Shift is lowercase, the dictation starts lowercase, even at the top of a field. Names, "I" and acronyms keep their capitals. Turn it off in Settings > Keyboard > Follow Shift.
- The "Discard?" key no longer wraps onto two lines or cuts off on standard-width iPhones while a recording is paused.
- New Emoji key: turn it on in Settings > Keyboard > Emoji key. It sits left of space and opens emoji in place of the keys, recents first. Hold an emoji to pick a skin tone; Zone remembers it.
- New in Settings > Experimental: @/Handle Recognition. Say "at" and a name and Zone writes a handle: "at Kevin" writes @kevin, and spelled names work too ("at D A A N" writes @daan). It knows common first names and your words. For any other handle, say "at sign" first. "Look at Kevin", "works at Google" and "at Kevin's" stay words.
- Share on the Home card opens the share sheet again. On iOS 26 it opened an empty sheet.
- Turn off Auto-Capitalization in Settings > Keyboard to keep typed corrections lowercase, including missed spaces and names. Shift and your text replacements keep the capitals you choose.
- Meeting mode’s sound wave flows more smoothly around the screen, with rounded joins at the top and bottom. Pause and Reduce Motion keep a steady border.
- Meetings now show time remaining and save automatically at two hours or when storage runs low; recording problems stay visible with the saved meeting.
- Repeated Transcribe, Pause, Start and Stop actions are safer. Longer saved meetings can still be transcribed, with speaker labels limited to two hours.
- If meeting voices were grouped together, choose the number of speakers under Transcribe again. The choice applies only to that recording.
- Meeting transcription now keeps audible passages that speaker detection missed, leaving the speaker unlabeled instead of dropping the passage.
- Choose Flow, Breathe, or Still glow from the Meetings screen or while recording. Your choice is remembered. The timer now rolls more softly, with no bounce; Reduce Motion keeps its changes still.
- Pressing the letter above the space bar instead of space (x, c, v, b or n, and z when the emoji key is off) no longer leaves words like "youxarexproud" or "lotvinstead" behind: the space bar takes taps low on those keys right after a finished word, and autocorrect splits them into "you are proud" and "lot instead" on space.
- Autocorrect checks where you tapped: "youcare" tapped low on c (a missed space) becomes "you are", and tapped in the middle of c stays "you care".
- The keyboard no longer learns from those slips, which had slowly been moving those keys onto the space bar. Their learned positions reset once.
- Touch learning discards unfinished samples when you switch fields, move the cursor, paste, dictate, or leave the keyboard.

## 1.0 (2026110507), November 5, 2026

- Action Button and Controls fixes; smaller recording and saving activities; standby activity hidden.
- Meeting recovery, playback, editing and export.
- Full library backup and import, and optional Files or iCloud Drive folder backups.
- Organized settings, Apple Watch notes and iMessage draft insertion.
- Existing notes and recordings are preserved.

## 1.0 (2026110408), November 4, 2026 (Team only)

- The bundled test clip says "Testing Zone". Otherwise the same as 2026110407.

## 1.0 (2026110407), November 4, 2026 (Team only, expired)

- A visible Delete download button in Settings > Model library (swipe still works).

## 1.0 (2026110406), November 4, 2026

- First TestFlight build: onboarding, model download, the keyboard with Full Access, dictation,
  meeting transcription (Alpha) and Action Button voice notes.
