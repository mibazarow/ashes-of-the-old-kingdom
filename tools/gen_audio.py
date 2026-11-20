#!/usr/bin/env python3
"""Procedural placeholder SFX for «Пепел старого королевства».

Pure Python 3 standard library (`wave`, `struct`, `math`, `random`) — no
downloads, no third-party samples, no external encoders. Every file is written
as PCM 16-bit mono at 22050 Hz into `assets/audio/`.

The output is deterministic: each sound gets its own seeded RNG, so re-running
the script overwrites the files byte for byte. Nothing is appended, skipped or
renamed, which makes the generated WAVs reproducible from the committed script.

Amplitude: every sound is normalised to its own target peak (default -6 dBFS,
0.5 of full scale) and the quantised samples are hard-clamped below ±32767, so
no file can clip.

Run from the project root:

    python3 tools/gen_audio.py
"""

from __future__ import annotations

import math
import random
import struct
import wave
from pathlib import Path

SAMPLE_RATE = 22050
CHANNELS = 1
SAMPLE_WIDTH = 2
OUT_DIR = Path(__file__).resolve().parent.parent / "assets" / "audio"

## Default peak: -6 dBFS. `ui_click` is deliberately quieter (see SOUNDS).
DEFAULT_PEAK = 0.5
INT16_MAX = 32767
## Hard ceiling after quantising: leaves one LSB of headroom so no sample can
## reach ±32767 even when the float peak rounds upward.
QUANTISE_CEILING = 32760


def _ms(duration_ms: float) -> int:
    """Milliseconds -> sample count."""
    return max(1, int(round(SAMPLE_RATE * duration_ms / 1000.0)))


def _attack_release(count: int, attack: float, release: float) -> list[float]:
    """Linear fade-in / fade-out envelope (click-free edges)."""
    ramp_a = max(1, int(count * attack))
    ramp_r = max(1, int(count * release))
    env = [1.0] * count
    for i in range(min(ramp_a, count)):
        env[i] = i / float(ramp_a)
    for i in range(min(ramp_r, count)):
        idx = count - 1 - i
        env[idx] = min(env[idx], i / float(ramp_r))
    return env


def _sweep(count: int, start_hz: float, end_hz: float) -> list[float]:
    """Phase-continuous linear sweep start_hz -> end_hz."""
    out = []
    phase = 0.0
    for i in range(count):
        t = i / float(max(1, count - 1))
        freq = start_hz + (end_hz - start_hz) * t
        phase += 2.0 * math.pi * freq / SAMPLE_RATE
        out.append(math.sin(phase))
    return out


def _noise(rng: random.Random, count: int) -> list[float]:
    return [rng.uniform(-1.0, 1.0) for _ in range(count)]


def _mix(*layers: list[float]) -> list[float]:
    """Sum layers of equal length."""
    total = list(layers[0])
    for layer in layers[1:]:
        for i, value in enumerate(layer):
            total[i] += value
    return total


def _mul(values: list[float], factor: float) -> list[float]:
    return [v * factor for v in values]


def _apply_env(values: list[float], env: list[float]) -> list[float]:
    return [v * e for v, e in zip(values, env)]


# --- sounds ------------------------------------------------------------------


def sound_hit(rng: random.Random) -> list[float]:
    """90 ms noise burst with a fast decay — the player landing a hit."""
    n = _ms(90)
    noise = _noise(rng, n)
    body = _mix(_mul(noise, 0.85), _mul(_sweep(n, 900.0, 240.0), 0.35))
    env = [math.exp(-9.0 * i / float(n)) for i in range(n)]
    return _apply_env(body, _mul(env, 1.0))


def sound_hurt(rng: random.Random) -> list[float]:
    """140 ms low sine drop 320 -> 120 Hz — the player taking damage."""
    n = _ms(140)
    body = _mix(_sweep(n, 320.0, 120.0), _mul(_noise(rng, n), 0.06))
    env = _attack_release(n, 0.03, 0.45)
    return _apply_env(body, env)


def sound_enemy_die(rng: random.Random) -> list[float]:
    """260 ms descending noise + sine 220 -> 70 Hz — an enemy dying."""
    n = _ms(260)
    noise = _noise(rng, n)
    # Noise that slides down in level while it plays: the "collapsing" tail.
    descending_noise = [v * (1.0 - 0.75 * i / float(n)) for i, v in enumerate(noise)]
    body = _mix(_mul(descending_noise, 0.55), _mul(_sweep(n, 220.0, 70.0), 0.8))
    env = _attack_release(n, 0.02, 0.6)
    return _apply_env(body, env)


def sound_pickup(rng: random.Random) -> list[float]:
    """120 ms two-tone blip 880 -> 1320 Hz — loot collected."""
    n = _ms(120)
    half = n // 2
    first = _sweep(half, 880.0, 880.0)
    second = _sweep(n - half, 1320.0, 1320.0)
    body = first + second
    env = _attack_release(n, 0.04, 0.35)
    return _apply_env(body, env)


def sound_cast(rng: random.Random) -> list[float]:
    """180 ms rising sweep 400 -> 900 Hz with light noise — a skill cast."""
    n = _ms(180)
    body = _mix(_mul(_sweep(n, 400.0, 900.0), 0.9), _mul(_noise(rng, n), 0.12))
    env = _attack_release(n, 0.12, 0.4)
    return _apply_env(body, env)


def sound_ui_click(rng: random.Random) -> list[float]:
    """40 ms 1000 Hz square-ish click at low amplitude — menus and panels."""
    n = _ms(40)
    wave_samples = [1.0 if math.sin(2.0 * math.pi * 1000.0 * i / SAMPLE_RATE) >= 0.0 else -1.0 for i in range(n)]
    body = _mix(_mul(wave_samples, 0.9), _mul(_noise(rng, n), 0.1))
    env = [math.exp(-6.0 * i / float(n)) for i in range(n)]
    return _apply_env(body, env)


def sound_step(rng: random.Random) -> list[float]:
    """50 ms soft noise thump — a footstep."""
    n = _ms(50)
    noise = _noise(rng, n)
    # Two one-pole low-pass passes leave a soft thump instead of a hiss.
    soft = []
    prev = 0.0
    for value in noise:
        prev = prev + 0.18 * (value - prev)
        soft.append(prev)
    soft2 = []
    prev = 0.0
    for value in soft:
        prev = prev + 0.18 * (value - prev)
        soft2.append(prev)
    body = _mix(_mul(soft2, 3.2), _mul(_sweep(n, 130.0, 70.0), 0.5))
    env = [math.exp(-7.0 * i / float(n)) for i in range(n)]
    return _apply_env(body, env)


def sound_boss_roar(rng: random.Random) -> list[float]:
    """500 ms low 90 Hz sawtooth with vibrato — a boss entering phase two."""
    n = _ms(500)
    samples = []
    phase = 0.0
    for i in range(n):
        t = i / float(SAMPLE_RATE)
        freq = 90.0 * (1.0 + 0.06 * math.sin(2.0 * math.pi * 6.5 * t))
        phase += 2.0 * math.pi * freq / SAMPLE_RATE
        saw = 2.0 * ((phase / (2.0 * math.pi)) % 1.0) - 1.0
        samples.append(saw * 0.85 + 0.15 * math.sin(phase * 2.0))
    env = _attack_release(n, 0.15, 0.55)
    return _apply_env(samples, env)


## name -> (generator, peak). `ui_click` sits well below the others: a menu
## click that lands at -6 dBFS next to a hit is painfully loud in practice.
SOUNDS = {
    "hit": (sound_hit, DEFAULT_PEAK),
    "hurt": (sound_hurt, DEFAULT_PEAK),
    "enemy_die": (sound_enemy_die, DEFAULT_PEAK),
    "pickup": (sound_pickup, DEFAULT_PEAK),
    "cast": (sound_cast, DEFAULT_PEAK),
    "ui_click": (sound_ui_click, 0.22),
    "step": (sound_step, DEFAULT_PEAK),
    "boss_roar": (sound_boss_roar, DEFAULT_PEAK),
}


def _quantise(samples: list[float], peak: float) -> list[int]:
    """Normalise to `peak` of full scale and clamp inside the int16 range."""
    float_peak = max((abs(s) for s in samples), default=0.0)
    if float_peak <= 0.0:
        return [0] * len(samples)
    scale = peak * INT16_MAX / float_peak
    out = []
    for value in samples:
        code = int(round(value * scale))
        if code > QUANTISE_CEILING:
            code = QUANTISE_CEILING
        elif code < -QUANTISE_CEILING:
            code = -QUANTISE_CEILING
        out.append(code)
    return out


def _write_wav(path: Path, codes: list[int]) -> None:
    frames = b"".join(struct.pack("<h", c) for c in codes)
    with wave.open(str(path), "wb") as out:
        out.setnchannels(CHANNELS)
        out.setsampwidth(SAMPLE_WIDTH)
        out.setframerate(SAMPLE_RATE)
        out.writeframes(frames)


def main() -> int:
    OUT_DIR.mkdir(parents=True, exist_ok=True)
    print(
        "generating %d sounds -> %s (%d Hz, %d ch, %d-bit)"
        % (len(SOUNDS), OUT_DIR.relative_to(OUT_DIR.parents[1]), SAMPLE_RATE, CHANNELS, SAMPLE_WIDTH * 8)
    )
    for index, (name, (generator, peak)) in enumerate(sorted(SOUNDS.items())):
        # A per-sound seed keeps the whole set reproducible: re-running this
        # script rewrites every file with identical bytes.
        rng = random.Random(0x5EED + index * 7919)
        codes = _quantise(generator(rng), peak)
        path = OUT_DIR / ("%s.wav" % name)
        _write_wav(path, codes)
        measured = max(abs(c) for c in codes) if codes else 0
        dbfs = 20.0 * math.log10(measured / float(INT16_MAX)) if measured else -999.0
        print(
            "  %-11s %6.1f ms  %6d samples  peak %6.1f dBFS  %6d B"
            % (
                name,
                1000.0 * len(codes) / SAMPLE_RATE,
                len(codes),
                dbfs,
                path.stat().st_size,
            )
        )
    print("done")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
