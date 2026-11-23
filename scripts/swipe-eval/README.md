# Swipe evaluation

Human swipes come from the swipe.futo.org corpus (MIT), cached in `~/.cache/zone-swipe-data`.
Build a fixture, then score the decoder in release mode:

```sh
python3 -I scripts/swipe-eval/build-fixtures.py --data ~/.cache/zone-swipe-data --split dev \
    --count 12000 --seed 1108 --out ~/.cache/zone-swipe-data/eval-dev-12000.json
ZONE_SWIPE_NEURAL=1 ZONE_SWIPE_PAIRS=$PWD/ZoneKeyboard/Resources/en-pairs.bin \
    zsh scripts/swipe-eval/sweep.sh '{"visitRadius":0,"shortlist":160}'
```

`{"visitRadius":0,"shortlist":160}` is the keyboard's configuration (`SwipeEngine`). Tune on dev
fixtures only; run the test split once per decision.

Environment:

- `ZONE_SWIPE_FIXTURES`: fixture files, comma separated.
- `ZONE_SWIPE_TUNING`: JSON object of `SwipeTuning` overrides.
- `ZONE_SWIPE_PAIRS`: word-pair table (the shipped one is `ZoneKeyboard/Resources/en-pairs.bin`).
- `ZONE_SWIPE_NEURAL=1`: rerank with the FUTO encoder, as the keyboard does.
- `ZONE_SWIPE_WEIGHTS`: `word<TAB>count` files, comma separated. The corpus prompts are Wikipedia
  sentences; each file adds a column where every row is weighted by that word's frequency over its
  share of the fixture, an estimate of accuracy on that word mix from the same gestures.
- `ZONE_SWIPE_ALL_WORDS=1`: also score targets autocorrect never suggests (profanity).

`build-wordpairs.py` rebuilds the pair table. It is keyed to `en-words.txt`, and
`WordPairsResourceTests` fails when the list changes without a rebuild.
