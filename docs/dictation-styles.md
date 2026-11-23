# What each dictation style does

The style pill on the keyboard picks one of four styles. This is the reference for what each
one changes. `ZoneCore/Tests/ZoneCoreTests/DictationStylesTests.swift` holds the code to this
table: change one and change the other.

No style rewrites your wording. "Gonna" stays "gonna" in formal.

## Same in every style

| What | Result |
| --- | --- |
| Hesitations ("um", "uh") | removed |
| Accidental repeats ("I I think", "the the") | one copy |
| Numbers | digits for larger numbers, years, percentages, decimals, times with a time word, and small numbers before a unit or in a range. Small counts in prose stay words ("two things"). |
| A word spelled out loud ("D-A-A-N", "D A A N", "D. A.N.", "D double A N") | the word, written as a name ("Daan"); a known acronym or brand keeps its casing ("API", "SaaS"); caps lock writes "DAAN" |
| Current names the recognizer splits or mishears ("test flight", "chat GPT", "clawed code") | spelled correctly |
| Your own words (My Words, contacts, handles) | always win, in their own spelling |
| Links, emails, code, handles | never touched |
| Spoken punctuation and commands ("new line", "question mark") | applied |
| A contact's surname that is also a word ("brown") | capital only after a first name or title ("Sarah Brown", "Dr. Brown") |
| Quotation marks | "quote hello unquote", "quote hello end quote" and "quote hello quote" write "hello". After "said", "was like" and similar, a "quote" nobody closes runs to the end of the sentence. "The quote unquote expert" writes the "expert". "A quote", "the quote" and "quote me" stay words. |

## Where the styles differ

| | casual | very casual | formal. | excited! |
| --- | --- | --- | --- | --- |
| First letter | capital | lowercase | capital | capital |
| Later sentence starts | as recognized | lowercase | capital | capital |
| "I" | capital | lowercase | capital | capital |
| Commas the recognizer adds | dropped, kept in lists | dropped | kept | kept |
| Periods inside the text | kept | dropped | kept | "!" at each sentence end |
| Final period | dropped | dropped | added | replaced by "!" |
| Question marks | kept, repeats collapsed to one | kept, repeats collapsed to one | kept | kept |
| Company and product names | spelled right, lowercase ("openai", "claude code") | lowercase | the company's way ("OpenAI", "Claude Code") | the company's way |
| Acronyms ("API", "LLMs") and "iPhone" | kept | lowercase | kept | kept |
| A spelled word | a name ("Daan") | lowercase ("daan") | a name | a name |
| People from contacts and My Words | capital | capital | capital | capital |
| Texting words ("lol", "idk", "imma") | lowercase | lowercase | as recognized | as recognized |
| Shorthand said as letters ("TS", "FR", "AI", "DM", "ASAP", "GOAT") | lowercase ("ts", "fr", "ai") | lowercase | capitals | capitals |
| A said face ("smiley face", "winky face", "sad face") | the face: `:)` `;)` `:(` | the face | the words | the words |

## Examples

Said: "So, um, I asked open AI and clawed code about it, and it said eleven percent."

- casual: `So I asked openai and claude code about it, and it said 11%`
- very casual: `so i asked openai and claude code about it and it said 11%`
- formal: `So I asked OpenAI and Claude Code about it, and it said 11%.`
- excited: `So I asked OpenAI and Claude Code about it, and it said 11%!`

Said: "Hello there. this is great, right"

- casual: `Hello there. this is great right`
- very casual: `hello there this is great right`
- formal: `Hello there. This is great, right.`
- excited: `Hello there! This is great, right!`

Said: "TS is crazy FR, she was like quote no way quote smiley face"

- casual: `ts is crazy fr she was like "no way" :)`
- very casual: `ts is crazy fr she was like "no way" :)`
- formal: `TS is crazy FR, she was like "no way" smiley face.`
- excited: `TS is crazy FR, she was like "no way" smiley face!`

Faces can be turned off in Settings, Experimental, Faces. The full list: smiley `:)`, winky
`;)`, sad or frowny `:(`, crying `:'(`, kissy `:*`, tongue `:P`. "A smiley face" and "her sad
face" stay words.

## Typing and swipe

Styles apply to dictation only. Typed and swiped words follow the Shift key and the keyboard's
own settings. Swipe writes a listed name in its standard casing, and tap typing gives a
lowercase typed name its capital unless lowercase typing is being preserved. A name made of
ordinary words ("micro center", "taco bell") is written the name's way once its last word is
typed or swiped, with the same exception; Delete right after puts the words back as typed.
