#!/usr/bin/env python3
"""Builds `en-pairs.bin`, the swipe decoder's word-pair prior (ZoneCore `WordPairs.swift`).

Counts pairs of consecutive dictionary words in plain-text corpora, estimates P(word | previous)
with interpolated absolute discounting (D = 0.75), and writes the most frequent pairs (count at
least `--min-count`, at most `--max-pairs`) as `-log P` costs quantized to sixteenths of a nat,
with a per-previous-word backoff cost. Word identity is the line index in `en-words.txt`, and the
file carries a 64-bit FNV-1a digest of that list's words, so a table built from another list is
refused at load (`WordPairsResourceTests` fails when the list changes without a rebuild).

Tokenization matches `SwipeSpacing.previousWord(before:)` on the keyboard: whitespace-separated
tokens, surrounding quotes, brackets and commas stripped, curly apostrophes folded. A token that
ends in . ! ? ; : ends the context, and so does any token that is not a dictionary word (a
number, an emoji, a URL), so "at 5 pm" never teaches "at pm".

The shipped table (2026-11-08): the first 40,000,000 lines of the English OpenSubtitles text
cached as `~/.cache/zone-swipe-data/subtitles-en.txt.gz`, `--min-count 3 --max-pairs 1200000`.
See docs/research/swipe-context-2026-11-08 for the evaluation and source notes.

    python3 -I scripts/swipe-eval/build-wordpairs.py \\
        --words ZoneCore/Sources/ZoneCore/Resources/en-words.txt \\
        --corpus ~/.cache/zone-swipe-data/subtitles-en.txt.gz --max-lines 40000000 \\
        --min-count 3 --max-pairs 1200000 --out ZoneKeyboard/Resources/en-pairs.bin

`--weight` (one per corpus, default 1) scales a corpus's counts.
"""
import argparse
import gzip
import math
import multiprocessing as mp
import os
import pickle
import tempfile
import re
import struct
import sys
from collections import Counter, defaultdict

D = 0.75
SCALE = 16.0
WORD = re.compile(r"^[A-Za-z]+(?:'[A-Za-z]+)*$")
LEADING = '"\'([{\u201c\u2018'
TRAILING = '"\')]},\u201d\u2019'
ENDS = '.!?;:'

KEY = 1 << 17  # pair key = previous * KEY + next; the list has fewer than 131,072 words


def count_lines(lines, index, counts):
    """Adds this text's pairs to `counts` (pair key to count) and returns in-list tokens."""
    tokens = 0
    for line in lines:
        previous = None
        for raw in line.replace('\u2019', "'").split():
            token = raw.lstrip(LEADING)
            ends = False
            while token and (token[-1] in TRAILING or token[-1] in ENDS):
                ends = ends or token[-1] in ENDS
                token = token[:-1]
            i = index.get(token.lower()) if WORD.match(token) else None
            if i is None:
                previous = None
                continue
            tokens += 1
            if previous is not None:
                key = previous * KEY + i
                counts[key] = counts.get(key, 0) + 1
            previous = None if ends else i
    return tokens


def _worker(queue, results, index, out_path):
    counts, tokens = {}, 0
    while True:
        chunk = queue.get()
        if chunk is None:
            break
        tokens += count_lines(chunk.decode('utf-8', errors='replace').split('\n'), index, counts)
    with open(out_path, 'wb') as out:
        pickle.dump((counts, tokens), out, protocol=pickle.HIGHEST_PROTOCOL)
    results.put(out_path)


def count_corpus(path, index, max_lines, workers):
    """Pair counts for one corpus, in parallel when `workers` > 1. Lines are read in order
    and split into newline-aligned chunks, so the counts equal a serial pass."""
    opener = gzip.open if path.endswith('.gz') else open
    if workers <= 1:
        counts, lines = {}, 0
        with opener(path, 'rt', encoding='utf-8', errors='replace') as handle:
            def limited():
                nonlocal lines
                for line in handle:
                    lines += 1
                    if max_lines and lines > max_lines:
                        return
                    yield line
            tokens = count_lines(limited(), index, counts)
        return counts, tokens, min(lines, max_lines) if max_lines else lines
    queue, results = mp.Queue(maxsize=workers * 2), mp.Queue()
    scratch = tempfile.mkdtemp(prefix='wordpairs-')
    procs = [mp.Process(target=_worker, args=(queue, results, index, os.path.join(scratch, f'{k}.pickle')))
             for k in range(workers)]
    for proc in procs:
        proc.start()
    lines, batch = 0, []
    with opener(path, 'rb') as handle:
        for line in handle:
            lines += 1
            if max_lines and lines > max_lines:
                lines -= 1
                break
            batch.append(line)
            if len(batch) == 200_000:
                queue.put(b''.join(batch))
                batch = []
    if batch:
        queue.put(b''.join(batch))
    for _ in procs:
        queue.put(None)
    total, tokens = {}, 0
    for _ in procs:
        part = results.get()
        with open(part, 'rb') as handle:
            counts, seen = pickle.load(handle)
        os.remove(part)
        tokens += seen
        if not total:
            total = counts
        else:
            for key, c in counts.items():
                total[key] = total.get(key, 0) + c
    for proc in procs:
        proc.join()
    os.rmdir(scratch)
    return total, tokens, lines


def fnv1a(words):
    h = 0xcbf29ce484222325
    for w in words:
        for b in w.encode('utf-8'):
            h ^= b
            h = (h * 0x100000001b3) & 0xFFFFFFFFFFFFFFFF
    return h


def load_words(path):
    words, ranks = [], []
    for line in open(path, 'r', encoding='utf-8'):
        line = line.rstrip('\n')
        if not line:
            continue
        parts = line.split('\t')
        words.append(parts[0])
        ranks.append(int(parts[1]))
    return words, ranks


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--words', required=True)
    parser.add_argument('--corpus', action='append', required=True)
    parser.add_argument('--weight', action='append', type=float)
    parser.add_argument('--max-lines', type=int, default=0, help='per corpus, 0 for all')
    parser.add_argument('--min-count', type=float, default=2)
    parser.add_argument('--max-pairs', type=int, default=600_000)
    parser.add_argument('--workers', type=int, default=1, help='parallel counting processes')
    parser.add_argument('--out', required=True)
    args = parser.parse_args()

    words, ranks = load_words(args.words)
    index = {}
    for i, w in enumerate(words):
        index.setdefault(w.lower(), i)
    weights = args.weight or [1.0] * len(args.corpus)
    assert len(weights) == len(args.corpus)

    pair_counts = defaultdict(float)
    prev_counts = defaultdict(float)
    tokens_seen = 0
    for path, weight in zip(args.corpus, weights):
        counts, tokens, lines = count_corpus(path, index, args.max_lines, args.workers)
        tokens_seen += tokens
        for key, c in counts.items():
            p, n = divmod(key, KEY)
            pair_counts[(p, n)] += c * weight
            prev_counts[p] += c * weight
        print(f'{path}: {lines} lines', file=sys.stderr)
    print(f'{tokens_seen} in-list tokens, {len(pair_counts)} distinct pairs', file=sys.stderr)

    # Followers per previous word, for the discount mass.
    followers = Counter()
    for (p, _), c in pair_counts.items():
        if c >= 1:
            followers[p] += 1

    kept = [(p, n, c) for (p, n), c in pair_counts.items() if c >= args.min_count]
    kept.sort(key=lambda t: -t[2])
    kept = kept[:args.max_pairs]
    kept.sort()
    print(f'{len(kept)} pairs kept', file=sys.stderr)

    # Zipf fit for the unigram fallback: -log P(w) ~ log(rank + 2) + constant, with the constant
    # chosen so that the fallback distribution over the list sums to one.
    harmonic = sum(1.0 / (r + 2) for r in ranks)
    constant = math.log(harmonic)

    count = len(words)
    backoff = bytearray(count)
    offsets = [0] * (count + 1)
    nexts = []
    costs = bytearray()
    by_prev = defaultdict(list)
    for p, n, c in kept:
        by_prev[p].append((n, c))
    for p in range(count):
        offsets[p] = len(nexts)
        total = prev_counts.get(p, 0.0)
        if total <= 0:
            backoff[p] = 255
            continue
        lam = D * followers[p] / total
        backoff[p] = min(255, int(round(-math.log(max(lam, 1e-9)) * SCALE)))
        for n, c in by_prev.get(p, []):
            p_uni = 1.0 / ((ranks[n] + 2) * harmonic)
            prob = max(c - D, 0.0) / total + lam * p_uni
            cost = -math.log(max(prob, 1e-12))
            nexts.append(n)
            costs.append(min(255, int(round(cost * SCALE))))
    offsets[count] = len(nexts)

    with open(args.out, 'wb') as out:
        out.write(b'ZPR1')
        out.write(struct.pack('<I', count))
        out.write(struct.pack('<Q', fnv1a(words)))
        out.write(struct.pack('<I', len(nexts)))
        out.write(struct.pack('<f', constant))
        out.write(bytes(backoff))
        out.write(struct.pack(f'<{count + 1}I', *offsets))
        out.write(struct.pack(f'<{len(nexts)}I', *nexts))
        out.write(bytes(costs))
    size = 24 + count + (count + 1) * 4 + len(nexts) * 5
    print(f'wrote {args.out}: {size / 1e6:.2f} MB', file=sys.stderr)


if __name__ == '__main__':
    main()
