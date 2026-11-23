#!/usr/bin/env python3
"""Synthesize Zone's dictation sound sets. No third-party assets: pure sine partials.
Five sets, chosen in Settings > Sound: chime (default), drop, kalimba, glass, wood. Each writes
dictation-start-<set>.caf and dictation-stop-<set>.caf.

  droplet start: a real water drop rings as a tiny bubble whose resonance sweeps
                   upward as it collapses, so the cue is a fast rising chirp (380 to 1080 Hz)
                   with a soft octave shimmer and two faint ripples after it: "I'm listening".
  droplet stop:    the undrop. The same gesture falling (980 to 340 Hz), rounder and a touch
                   longer, landing like a drop absorbed back into water: "got it".

Each cue is about 0.2 s, peaks near -9 dBFS and fades to true silence, so it reads as
present but never sharp. Usage: python3 scripts/make-sounds.py [out_dir]
(writes WAV, converts to CAF with afconvert, removes the WAV).
"""
import math
import subprocess
import sys
import wave
from pathlib import Path

RATE = 44_100
PEAK = 0.36


def chirp(f0: float, f1: float, seconds: float, sweep: float, decay: float,
          attack: float = 0.004, shimmer: float = 0.18) -> list[float]:
    """An exponential pitch glide from f0 toward f1 with time constant `sweep`, under an
    attack/exponential-decay envelope. Phase is integrated so the glide stays click free."""
    n = int(RATE * seconds)
    out, phase = [], 0.0
    for i in range(n):
        t = i / RATE
        freq = f1 + (f0 - f1) * math.exp(-t / sweep)
        phase += 2 * math.pi * freq / RATE
        env = min(1.0, t / attack) * math.exp(-t / decay)
        env *= min(1.0, (seconds - t) / 0.012)  # fade the last 12 ms to exact silence
        out.append(env * (math.sin(phase) + shimmer * math.sin(2 * phase + 0.6)))
    return out


def mix(base: list[float], layer: list[float], at: float, gain: float) -> list[float]:
    start = int(RATE * at)
    end = start + len(layer)
    if end > len(base):
        base = base + [0.0] * (end - len(base))
    for i, value in enumerate(layer):
        base[start + i] += gain * value
    return base


def lowpass(samples: list[float], cutoff: float) -> list[float]:
    """One-pole low-pass: rounds off the attack so nothing reads as sharp."""
    a = math.exp(-2 * math.pi * cutoff / RATE)
    out, y = [], 0.0
    for x in samples:
        y = (1 - a) * x + a * y
        out.append(y)
    return out


def room(samples: list[float], taps: list[tuple[float, float]]) -> list[float]:
    """A few soft early reflections, like a drop in a small tiled room."""
    out = list(samples) + [0.0] * int(RATE * max(t for t, _ in taps))
    for delay, gain in taps:
        offset = int(RATE * delay)
        for i, x in enumerate(samples):
            out[i + offset] += gain * x
    return out


def water_drop(rising: bool) -> list[float]:
    """A real drip: a small bubble whose pitch rises as it closes (Minnaert resonance), low and
    round, with a softer second bubble and a quiet room. Falling for stop."""
    if rising:
        body = chirp(300, 640, 0.16, sweep=0.03, decay=0.05, attack=0.006, shimmer=0.06)
        body = mix(body, chirp(420, 760, 0.1, sweep=0.025, decay=0.035, attack=0.006, shimmer=0.0), 0.09, 0.28)
    else:
        body = chirp(640, 300, 0.18, sweep=0.04, decay=0.055, attack=0.006, shimmer=0.06)
        body = mix(body, chirp(520, 280, 0.1, sweep=0.03, decay=0.035, attack=0.006, shimmer=0.0), 0.08, 0.24)
    return normalized(room(lowpass(body, 2200), [(0.023, 0.18), (0.041, 0.1), (0.067, 0.05)]))


def normalized(samples: list[float]) -> list[float]:
    top = max(abs(s) for s in samples) or 1.0
    return [PEAK * s / top for s in samples]


def droplet() -> list[float]:
    body = chirp(380, 1080, 0.17, sweep=0.04, decay=0.05)
    body = mix(body, chirp(860, 1240, 0.07, sweep=0.02, decay=0.022, shimmer=0.0), 0.08, 0.2)
    body = mix(body, chirp(980, 1380, 0.06, sweep=0.02, decay=0.018, shimmer=0.0), 0.13, 0.09)
    return normalized(body)


def undrop() -> list[float]:
    body = chirp(980, 340, 0.21, sweep=0.055, decay=0.065, shimmer=0.12)
    body = mix(body, chirp(520, 300, 0.09, sweep=0.03, decay=0.03, shimmer=0.0), 0.09, 0.16)
    return normalized(body)


def tone(freq: float, seconds: float, decay: float, partials: list[tuple[float, float]],
         attack: float = 0.005) -> list[float]:
    """A struck tone: partials as (frequency ratio, gain), exponential decay, silent tail."""
    n = int(RATE * seconds)
    out = []
    for i in range(n):
        t = i / RATE
        env = min(1.0, t / attack) * math.exp(-t / decay) * min(1.0, (seconds - t) / 0.012)
        out.append(env * sum(g * math.sin(2 * math.pi * freq * r * t) for r, g in partials))
    return out


def pair(first: list[float], second: list[float], gap: float) -> list[float]:
    return normalized(mix(first, second, gap, 1.0))


# The original two-note cue (E5 then A5).
CHIME = [(1, 1.0), (2, 0.30), (3, 0.10)]
# A soft bell: inharmonic upper partial (2.76) like a small glass, long gentle decay.
GLASS = [(1, 1.0), (2.76, 0.22), (5.4, 0.05)]
# A kalimba tine: strong fundamental, a bright inharmonic overtone that fades first.
KALIMBA = [(1, 1.0), (3.0, 0.18), (5.4, 0.06)]
# A low hollow knock: strong fundamental, fast decay, a woody 1.5 partial.
WOOD = [(1, 1.0), (1.5, 0.35), (2.3, 0.12)]

SETS = {
    "chime": (lambda: pair(tone(659.25, 0.09, 0.09, CHIME), tone(880, 0.17, 0.11, CHIME), 0.087),
              lambda: pair(tone(880, 0.09, 0.09, CHIME), tone(659.25, 0.17, 0.11, CHIME), 0.087)),
    "drop": (lambda: water_drop(True), lambda: water_drop(False)),
    "kalimba": (lambda: normalized(lowpass(pair(tone(523.25, 0.12, 0.12, KALIMBA), tone(783.99, 0.3, 0.2, KALIMBA), 0.09), 5000)),
                lambda: normalized(lowpass(pair(tone(783.99, 0.12, 0.12, KALIMBA), tone(523.25, 0.3, 0.2, KALIMBA), 0.09), 5000))),
    "glass": (lambda: pair(tone(784, 0.1, 0.12, GLASS), tone(1046.5, 0.26, 0.16, GLASS), 0.07),
              lambda: pair(tone(1046.5, 0.1, 0.12, GLASS), tone(784, 0.26, 0.16, GLASS), 0.07)),
    "wood": (lambda: pair(tone(330, 0.07, 0.035, WOOD), tone(440, 0.1, 0.045, WOOD), 0.075),
             lambda: pair(tone(440, 0.07, 0.035, WOOD), tone(330, 0.1, 0.045, WOOD), 0.075)),
}


def write_wav(path: Path, samples: list[float]) -> None:
    with wave.open(str(path), "wb") as w:
        w.setnchannels(1)
        w.setsampwidth(2)
        w.setframerate(RATE)
        w.writeframes(b"".join(int(max(-1, min(1, s)) * 32767).to_bytes(2, "little", signed=True) for s in samples))


def main() -> int:
    out_dir = Path(sys.argv[1]) if len(sys.argv) > 1 else Path("Zone/Resources/Sounds")
    out_dir.mkdir(parents=True, exist_ok=True)
    for set_name, (start, stop) in SETS.items():
        for kind, make in (("start", start), ("stop", stop)):
            samples = make()
            wav = out_dir / f"dictation-{kind}-{set_name}.wav"
            caf = out_dir / f"dictation-{kind}-{set_name}.caf"
            write_wav(wav, samples)
            subprocess.run(["afconvert", "-f", "caff", "-d", "LEI16", str(wav), str(caf)], check=True)
            wav.unlink()
            print(f"{caf}: {len(samples) / RATE:.3f} s")
    return 0


if __name__ == "__main__":
    sys.exit(main())
