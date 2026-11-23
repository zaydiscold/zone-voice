# California Mode: Aggressive catches the fillers people actually say (2026-11-16)

Branch `feature/california-recall-2026-11-16`. Code: `ZoneCore/Sources/ZoneCore/CaliforniaMode.swift`
(the extension at the end, "Every other like"). Tests: `CaliforniaModeTests`, plus California on
Aggressive inside `ExperimentalTogetherTests`.

## What was wrong

Zayd turned California Mode to Aggressive, dictated on purpose with "like" everywhere, and almost
none came out. Measured on his own library, he was right: the rules removed a "like" only when its
neighbours proved it was a filler, and real speech rarely gives that proof. Light removed 4% of his
fillers and Aggressive 18%.

The rules had been tuned on synthetic sentences, novels, DailyDialog and the Santa Barbara Corpus,
all scored for precision (no meaningful "like" lost), and recall on natural conversation was already
known to be low (about 20% on the Santa Barbara Corpus, `docs/evidence/2026-11-12-california-mode.md`
in the preserved root checkout). Nobody had measured it on the person using the feature.

## The labeled set

Every dictation in Zayd's Zone library that contains "like", exported with `zone export --kind
dictation`: 272 dictations, 668 "like"s. Each was labeled by reading it in context:

| Label | Meaning | Count |
|---|---|---|
| F | filler, remove at both levels | 413 |
| H | hedge before an amount ("like five minutes"), remove at Aggressive | 37 |
| K | meaning: the verb, a comparison, an example, a quote, the word talked about, sarcasm | 184 |
| X | unclear or broken speech, not scored | 34 |

Dictations are split into two halves by a hash of their id. Rules were tuned only on the dev half's
mistakes; the test half is reported separately. The set and its labels are private and stay out of
Git: `~/Library/Caches/zone-eval/like-zayd/` (`occurrences.json`, `labels.txt`), scored by
`harness/zayd.py`. `harness/all.sh` rebuilds the evaluator against this worktree and runs every
measurement below.

## Results

| Set | Level | Before: fillers / hedges / meaning removed | After |
|---|---|---|---|
| Zayd dev (141 dictations) | Light | 9/185 (5%), 0/20, 0/86 | 51/185 (28%), 0/20, 0/86 |
| | Aggressive | 25/185 (14%), 13/20, 0/86 | 124/185 (67%), 17/20, 1/86 |
| Zayd test (131 dictations) | Light | 9/228 (4%), 0/17, 0/98 | 54/228 (24%), 0/17, 0/98 |
| | Aggressive | 50/228 (22%), 9/17, 1/98 | 158/228 (69%), 11/17, 1/98 |

The two meaningful "like"s Aggressive removes on Zayd's set: an example opening a sentence with a
noun that is also a verb (paraphrased: "Like copy or the menus"), and an example after a comma before a number,
which the rules before already removed.

Precision on everything else (no sentence below was written by Zayd):

| Set | Before | After |
|---|---|---|
| Synthetic dev, held-out and blind sets, typed and recognized by Fluid Speech Mini: meaningful "like"s removed | 0 of 538 | 0 of 538 |
| Santa Barbara Corpus, blind labels: meaningful removed (Aggressive) | 4 of 108 | 4 of 108 (the same four: corpus markup digits read as amounts, and a pre-existing case) |
| Santa Barbara Corpus, blind labels: fillers removed (Aggressive) | 106 of 162 | 116 of 162 |
| Five novels, 1,094 "like"s, removed (Aggressive) | 1 | 5 |
| DailyDialog, 6,087 "like"s, removed (Aggressive) | 8 | 23 |
| Any word other than "like" changed | 0 | 0 |

Every new removal in the novels and DailyDialog was read. In DailyDialog most are real hedges
("I haven't seen him in like 5 years", "it's like $130 each"); about eight are examples or verbs
whose subject is far away. The novels' five are dialect or 19th century phrasing ("slighted like",
"for like elves they had worked"). A sample of 50 of the Santa Barbara Corpus's 138 new removals was
read: about 45 are fillers or hedges.

Each mistake the first draft made in that real text became a guard and a test in
`testAggressiveKeepsWhatTheLooseRulesMustNotTouch`: the verb with its subject further back ("Girls
usually like looking after pets", "I do not particularly like"), "like to", "what the weather will be
like tomorrow", "like before", "like mad", "in a like manner", similes after a noun or a particle
("flew about like gauzy butterflies", "slept like dead people"), and a fronted comparison ("Like that
immortal hero, she rested").

Speed is unchanged: the whole `TextStyle` pass on a 20 word dictation takes the same 3 ms on this Mac
at every level, and a 6,600 word passage with 1,800 "like"s is no slower than Off.

## How Aggressive decides now

The earlier rules still run first and still remove what they removed. Whatever they leave, Aggressive
now removes unless something protects it:

- **The verb.** A subject or auxiliary behind it, past any adverbs ("I really like", "you'd like",
  "doesn't like to", "girls usually like"), "like to", "would like". Not when a bare verb follows,
  which the verb "like" never takes: "can like prime the mic", "Can I like drop off the prints".
- **A comparison.** After "look", "feel", "seem", "sound", "act", "become", "something", "nothing",
  "kind of", "more", "just", "not"; before "me", "him", "this", "that", "mine"; "like a" after a
  word Zone cannot place ("fold like a chair"); a fronted comparison with its comma.
- **An example.** After a plural or "stuff" ("tools like Claude"), after a comma before a noun, before
  a name.
- **A quote.** "I was like, no way", "he's like keep trying", "she was like really?", before "okay",
  "yeah", "hey".
- **The word talked about.** "I keep saying like but", "or like is a big one", "if I say something
  like like too much".
- **"As" or "as if" before a clause.** "higher like it was before", "like you said". The exception is
  the speaker thinking out loud: "like I mean", "like I don't know".
- **Sarcasm.** "Like I care", "Like who cares?".

Light keeps its old rules and adds the loose fillers that never touch an amount: between two small
words ("so like for instance", "but like right now"), after "the" or "this", before "I mean", and an
adjective after "is" ("I'm like paranoid about it").

Also fixed: a "like" removed at the start of a sentence handed its capital to the "um" after it, which
is removed later, so "Like, um you know" came out as "you know" in lowercase. It is "You know" now.

## What it still misses

About a third of Zayd's fillers stay, mostly where "like" could mean "similar to" and nothing nearby
says otherwise (paraphrased): "it's like a lot of the work", "this is like a long answer", "it should
be like harmony" (a noun after "is like"), "the gap like the letters" (a noun phrase after a noun), "it
just like is sore", and "like" before a clause after a noun ("this page like it's too long"), where "as
if" is just as likely. Removing those too would remove "it's like a dream" and "she's like her sister",
which the tests pin.

## Not verified yet

The keyboard insert path on a simulator (the `say` fixture in Messages, California on Aggressive) was
not completed. The Debug build for the simulator succeeded at this commit's parent, but on November 16
the Mac ran about 20 builds at once (load average near 640) and `simctl launch` hung for over 30 minutes
twice. The keyboard calls the same `TextStyle.insertion` the tests drive, with the setting read from
`KeyboardPreferences`; run the check before calling this done on a phone.

## Reproduce

```
~/Library/Caches/zone-eval/like-zayd/harness/all.sh          # every number above
python3 ~/Library/Caches/zone-eval/like-zayd/harness/zayd.py dev --show   # each mistake on Zayd's set
LIKEEVAL=~/Library/Caches/zone-eval/like-zayd/harness/likeeval-baseline python3 .../zayd.py all   # the rules before
swift test --package-path ZoneCore --filter CaliforniaModeTests
```
