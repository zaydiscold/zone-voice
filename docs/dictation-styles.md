# What each dictation style does

The style pill on the keyboard picks one of four styles. This is the reference for what each
one changes. `ZoneCore/Tests/ZoneCoreTests/DictationStylesTests.swift` holds the code to this
table: change one and change the other.

No style changes what you said. Formal alone writes fast speech as the words that were meant:
"gonna" is "going to", "cuz" is "because" (the full list is under Formal wording below).

Settings > Text style shows one sentence written in each style, made by the same code that
writes a dictation (`TextStyle.example`).

## Same in every style

| What | Result |
| --- | --- |
| Hesitations ("um", "uh") | removed |
| Accidental repeats ("I I think", "the the") | one copy |
| Numbers | digits for larger numbers, years, percentages, decimals, times with a time word, and small numbers before a unit or in a range. Small numbers elsewhere depend on the style (below). |
| Numbers side by side | agree: a small number standing on its own within four words of a digit is a digit too ("8 or 9, maybe 7", never "8 or 9, maybe seven"). A number counting something keeps its form ("12 emails and three calls"). |
| "No one", "no two" | words. "Number one" is "number 1". |
| A word spelled out loud ("D-A-A-N", "D A A N", "D. A.N.", "D double A N") | the word, written as a name ("Daan"); a known acronym or brand keeps its casing ("API", "SaaS"); caps lock writes "DAAN" |
| Current names the speech model splits or mishears ("test flight", "chat GPT", "clawed code") | spelled correctly |
| Your own words (My Words, contacts, handles) | always win, in their own spelling |
| Links, emails, code, handles | never touched |
| Spoken punctuation and commands ("new line", "question mark") | applied |
| A contact's surname that is also a word ("brown") | capital only after a first name or title ("Sarah Brown", "Dr. Brown") |
| Quotation marks | "quote hello unquote", "quote hello end quote" and "quote hello quote" write "hello". After "said", "was like" and similar, a "quote" nobody closes runs to the end of the sentence. "The quote unquote expert" writes the "expert". "A quote", "the quote" and "quote me" stay words. |

## Where the styles differ

| | casual | very casual | formal. | excited! |
| --- | --- | --- | --- | --- |
| First letter | capital | lowercase | capital | capital |
| Later sentence starts | as recognized; lowercase with Auto-Capitalization off | lowercase | capital | capital |
| Two to nine on their own ("around seven", "two things", "the first three") | digits ("around 7", "2 things") | digits | words | words |
| "Gonna", "wanna", "gotta", "kinda", "cuz" | as said | as said | written out ("going to", "want to", "have to", "kind of", "because") | as said |
| "I" | capital | lowercase | capital | capital |
| Commas the speech model adds | dropped, kept in lists; an opening "yes", "no", "sorry", "hello" is not a list item | dropped | kept | kept |
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

## Numbers in Settings

Settings > Dictation options > Numbers has three choices. Follow text style preserves the existing rules below. Always digits writes counts such as 7 and 12. Words under ten writes seven and 12. A switch for each style controls where the explicit choice applies. Formal, Excited and Casual start on. Very casual starts off and keeps its existing digits.

Times, dates, currency amounts, percentages, phone numbers, addresses, versions, measurements and decimals use digits in the explicit formats. Ranges and shares such as 3 of 12 use digits together. A sentence can start with a digit. A pronoun such as “that one” and an estimate such as “a couple” stay words. The separate switch for small ordinals still controls ranks.

App dictation, both keyboard recording routes, restyle, voice notes and retry read this choice when writing the words. History keeps the original transcript.

## Small numbers with Follow text style

Casual and Very casual write two to nine as digits wherever they are plain numbers. These stay
words in every style:

- every "one" that is not in a range or after a label ("this one", "no one", "one second");
- a fraction ("two thirds"), a saying ("high five", "take five", "cloud nine") and a title
  with a capital ("Five Guys", "Take Two");
- numbers said one at a time ("one two three") and "two by two";
- a number beside a "one" that counts something, so the pair agrees ("one apple and two pears",
  "catch one and two");
- the number of a point being made ("one I hope that's done, but two there's a button").

Measured on 2,055 of Zayd's keyboard dictations (2026-11-19): 65 small numbers were left as
words in Casual, 14 dictations mixed digits and words. After: 6 left, each one of the cases
above.

## Auto-Capitalization

With Auto-Capitalization off, Casual writes everything lowercase, including I, names, brands and acronyms. An explicit caps lock still writes in all caps. Formal and Excited start sentences with capitals. Very casual writes lowercase.

## Formal wording

Formal writes these as the words that were meant, keeping a leading capital: gonna (going to),
wanna (want to, or "want" before "a", "the", "it"), gotta (have to; "got to" after "'s" or
"'ve"; "has to" after he, she, it), kinda, sorta, lemme, gimme, dunno, cuz and 'cause (because;
the noun "cause" is left alone), outta, lotta, tryna, hafta, shoulda, coulda, woulda, musta,
I'ma (I'm going to) and 'em (them). "Y'all", "yeah" and "ain't" are words and stay. On Zayd's
dictations this changes 136 of 2,055, 76 of them "gonna".

## Examples

Said: "Hello, sorry, does later tonight work? Like I don't know, eight or nine, maybe seven, any time after then."

- casual: `Hello sorry does later tonight work? Like I don't know 8 or 9 maybe 7 any time after then`
- casual, Auto-Capitalization off: `hello sorry does later tonight work? like I don't know 8 or 9 maybe 7 any time after then`
- very casual: `hello sorry does later tonight work? like i don't know 8 or 9 maybe 7 any time after then`
- formal: `Hello, sorry, does later tonight work? Like I don't know, 8 or 9, maybe 7, any time after then.`
- excited: `Hello, sorry, does later tonight work? Like I don't know, 8 or 9, maybe 7, any time after then!`

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

## Changing style after a dictation

Picking a style on the keyboard (the Z, or a hold on the mic) also rewrites the dictation that is
still standing at the cursor, from what was said, so a message never has to be said twice to see
it another way. It is the same text that dictating in that style would have written: the same
join to the sentence before it, the same Shift. Only the part that differs is retyped.

- It happens only while the field still ends with exactly what Zone inserted. Anything typed
  after it, any edit inside it (a word fixed from the strip included), a sent message, another
  field or an undone dictation leaves the text alone, and the pick is just the style from then on.
- Undo right after a rewrite puts the earlier wording back and keeps the new style for what is
  said next. A second Undo removes the dictation, as before.
- Changing the style in Zone's Settings does not rewrite anything.

`RestylePlan` (ZoneCore) plans the edit and `DictationRestyleTests` checks every style to every
other and back. The keyboard keeps what was said only in memory, for the last dictation.

## Typing and swipe

Styles apply to dictation only. Typed and swiped words follow the Shift key and the keyboard's
own settings. Swipe writes a listed name in its standard casing, and tap typing gives a
lowercase typed name its capital unless lowercase typing is being preserved. A name made of
ordinary words ("micro center", "taco bell") is written the name's way once its last word is
typed or swiped, with the same exception; Delete right after puts the words back as typed.
