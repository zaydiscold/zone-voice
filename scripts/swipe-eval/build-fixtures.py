#!/usr/bin/env python3
"""Builds swipe evaluation fixtures from the swipe.futo.org corpus (MIT).

Reads the jsonl splits (one swipe per line: `word`, `data` points with normalized x, y and a
millisecond `t`, `canvas_width`, `canvas_height`, `sentence`, `word_idx`) and writes a compact
JSON fixture the ZoneCore `SwipeEvalTests` harness reads through `ZONE_SWIPE_FIXTURES`.

Coordinates stay normalized (0...1 across the canvas); the Swift side maps them into key-pitch
units with the layout's key centers, so the fixture never bakes in a unit convention.

    python3 -I scripts/swipe-eval/build-fixtures.py --data ~/.cache/zone-swipe-data \
        --split test --rows eval-test-3000-row-indices.json --out eval-test-3000.json

Row-index files are the ones recorded on 2026-11-06 (docs/research/keyboard-2026-11-06), so
every run scores the same traces as that report. Without `--rows`, `--count` random rows are
drawn with `--seed`.
"""
import argparse
import json
import random
import sys

PUNCT = '.,;:!?"()[]{}“”‘’\'-–—'


def clean(token):
    return token.strip(PUNCT)


def previous_word(row):
    tokens = row['sentence'].split()
    index = row['word_idx']
    if not (0 <= index < len(tokens)) or clean(tokens[index]) != clean(row['word']):
        return None
    if index == 0:
        return None
    token = tokens[index - 1]
    # A sentence boundary inside the prompt resets context.
    if token[-1:] in '.!?':
        return None
    return clean(token)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--data', required=True)
    parser.add_argument('--split', required=True, choices=['train', 'dev', 'test'])
    parser.add_argument('--rows')
    parser.add_argument('--count', type=int, default=2000)
    parser.add_argument('--seed', type=int, default=7)
    parser.add_argument('--out', required=True)
    args = parser.parse_args()

    path = f'{args.data}/{args.split}.jsonl'
    wanted = None
    if args.rows:
        wanted = set(json.load(open(args.rows)))
    else:
        total = sum(1 for _ in open(path, 'rb'))
        wanted = set(random.Random(args.seed).sample(range(total), args.count))

    rows = []
    with open(path, 'r', encoding='utf-8') as handle:
        for index, line in enumerate(handle):
            if index not in wanted:
                continue
            row = json.loads(line)
            points = row['data']
            if not isinstance(points, list):
                continue
            t0 = points[0]['t'] if points else 0
            rows.append({
                'i': index,
                'word': row['word'],
                'prev': previous_word(row),
                'w': row['canvas_width'],
                'h': row['canvas_height'],
                'points': [[round(p['x'], 5), round(p['y'], 5), p['t'] - t0] for p in points],
            })
    rows.sort(key=lambda r: r['i'])
    layout = json.load(open(f'{args.data}/qwerty.json'))
    keys = {k['letter']: [k['cx'], k['cy']] for k in layout['keys']}
    json.dump({'layout': keys, 'rows': rows}, open(args.out, 'w'))
    print(f'{args.split}: {len(rows)} rows -> {args.out}', file=sys.stderr)


if __name__ == '__main__':
    main()
