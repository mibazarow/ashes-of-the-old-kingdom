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


# --- music & ambience --------------------------------------------------------
#
# The same stdlib-only, deterministic philosophy as the SFX above, but for the
# looping beds the game now ships (spec §17): a slow chord progression built
# from sine/triangle partials with a soft attack/release envelope, a low drone,
# and — for the forest — sparse seeded bird chirps. Python's standard library
# cannot encode OGG, so these are WAV, exactly like the SFX; the loop is done by
# the engine (`AudioStreamWAV.LOOP_FORWARD`), and the first/last quarter second
# is faded to silence so the loop seam cannot click.
#
# Every track is normalised to -6 dBFS and hard-clamped below ±32767 by the same
# `_quantise` the SFX use, so nothing clips. Each track gets its own seeded RNG,
# so re-running the script rewrites every file byte for byte.

_PI2 = 2.0 * math.pi


def _midi_hz(midi: float) -> float:
    """MIDI note number -> frequency (A4 = 69 = 440 Hz)."""
    return 440.0 * (2.0 ** ((midi - 69.0) / 12.0))


def _new_buf(seconds: float) -> list[float]:
    return [0.0] * max(1, int(round(SAMPLE_RATE * seconds)))


def _render_tone(
    buf: list[float],
    start: int,
    length: int,
    freq: float,
    gain: float,
    kind: str = "sine",
    attack: float = 0.02,
    release: float = 0.05,
    decay_tau: float = 0.0,
) -> None:
    """Mix one enveloped oscillator into `buf[start:start+length]`.

    `kind` is "sine" or a cheap "tri" (triangle from the phase fraction, no
    `asin`). Envelope is a linear attack, then either an exponential decay
    (`decay_tau` in seconds, for bells and plucks) or a flat sustain with a
    linear release over the last `release` seconds (for pads and drones). The
    phase keeps advancing for a note that starts before sample 0, so a chord
    whose tail overlaps the loop head is still in tune there.
    """
    if length <= 0 or gain == 0.0:
        return
    n = len(buf)
    if start >= n:
        return
    inc = _PI2 * freq / SAMPLE_RATE
    phase = 0.0
    na = max(1, int(attack * SAMPLE_RATE))
    nr = max(1, int(release * SAMPLE_RATE))
    use_decay = decay_tau > 0.0
    tau = decay_tau * SAMPLE_RATE if use_decay else 0.0
    sin = math.sin
    exp = math.exp
    pi = math.pi
    for i in range(length):
        idx = start + i
        if idx < 0:
            phase += inc
            continue
        if idx >= n:
            break
        if i < na:
            env = i / float(na)
        elif use_decay:
            env = exp(-(i - na) / tau)
            if env < 1e-4:
                break
        elif i >= length - nr:
            env = (length - i) / float(nr)
        else:
            env = 1.0
        if kind == "tri":
            frac = (phase / _PI2) % 1.0
            osc = 4.0 * abs(frac - 0.5) - 1.0
        else:
            osc = sin(phase)
        buf[idx] += gain * env * osc
        phase += inc


def _render_chord(
    buf: list[float],
    start: int,
    length: int,
    midis: list[int],
    gain: float,
    kind: str = "sine",
    attack: float = 0.3,
    release: float = 0.5,
    decay_tau: float = 0.0,
) -> None:
    for midi in midis:
        _render_tone(buf, start, length, _midi_hz(midi), gain, kind, attack, release, decay_tau)


def _render_noise(
    buf: list[float], start: int, length: int, rng: random.Random, gain: float, cutoff: float = 0.2
) -> None:
    """One-pole low-passed white noise mixed into the buffer (wind/wing beds)."""
    n = len(buf)
    prev = 0.0
    for i in range(length):
        idx = start + i
        if idx < 0:
            continue
        if idx >= n:
            break
        prev = prev + cutoff * (rng.uniform(-1.0, 1.0) - prev)
        buf[idx] += gain * prev


def _render_bird(buf: list[float], start: int, rng: random.Random) -> None:
    """A short seeded chirp: 2-4 rising sine blips, the forest's only "melody"."""
    n = len(buf)
    sin = math.sin
    pos = start
    for _ in range(2 + rng.randint(0, 2)):
        length = int((0.05 + rng.random() * 0.08) * SAMPLE_RATE)
        f0 = 1800.0 + rng.random() * 900.0
        f1 = f0 + 600.0 + rng.random() * 1200.0
        phase = 0.0
        for i in range(length):
            idx = pos + i
            if idx < 0:
                continue
            if idx >= n:
                return
            tt = i / float(max(1, length - 1))
            phase += _PI2 * (f0 + (f1 - f0) * tt) / SAMPLE_RATE
            buf[idx] += 0.12 * sin(math.pi * tt) * sin(phase)
        pos += length + int((0.03 + rng.random() * 0.06) * SAMPLE_RATE)


def _loop_edges_fade(buf: list[float], seconds: float = 0.25) -> None:
    """Fade the first and last `seconds` to silence so a loop seam cannot click."""
    fade = min(len(buf), int(round(SAMPLE_RATE * seconds)))
    for i in range(fade):
        g = i / float(fade)
        buf[i] *= g
        buf[len(buf) - 1 - i] *= g


def music_menu(rng: random.Random) -> list[float]:
    """Calm A-minor pad at a ~60 BPM feel: drone + slow chords + a soft melody."""
    total = _new_buf(32.0)
    prog = [[45, 48, 52], [41, 45, 48], [48, 52, 55], [43, 47, 50]]  # Am F C G
    chord_len = 4.0
    _render_tone(total, 0, len(total), _midi_hz(33), 0.30, "sine", 1.5, 2.0)  # A1 drone
    t = 0.0
    for _rep in range(2):
        for chord in prog:
            start = int(t * SAMPLE_RATE)
            length = int(chord_len * 1.4 * SAMPLE_RATE)
            _render_chord(total, start, length, chord, 0.28, "sine", 0.7, 1.3)
            _render_tone(total, start, length, _midi_hz(chord[0] + 12), 0.09, "tri", 0.7, 1.3)
            t += chord_len
    mel = [69, 72, 76, 74, 69, 72, 77, 74]  # A4 C5 E5 D5 A4 C5 F5 D5
    t = 0.0
    for note in mel:
        _render_tone(total, int(t * SAMPLE_RATE), int(2.4 * SAMPLE_RATE), _midi_hz(note), 0.15, "sine", 0.5, 1.4)
        t += 4.0
    _loop_edges_fade(total)
    return total


def music_forest(rng: random.Random) -> list[float]:
    """Pastoral C-major bed at a mid-tempo pulse, with sparse seeded birdsong."""
    dur = 33.0
    total = _new_buf(dur)
    prog = [[48, 52, 55], [43, 47, 50], [45, 48, 52], [41, 45, 48]]  # C G Am F
    chord_len = 2.75
    _render_tone(total, 0, len(total), _midi_hz(36), 0.24, "sine", 1.5, 2.0)  # C2 drone
    t = 0.0
    while t < dur:
        for chord in prog:
            if t >= dur:
                break
            start = int(t * SAMPLE_RATE)
            length = int(chord_len * 1.3 * SAMPLE_RATE)
            _render_chord(total, start, length, chord, 0.24, "tri", 0.3, 0.7)
            _render_chord(total, start, length, chord, 0.14, "sine", 0.3, 0.7)
            t += chord_len
    scale = [60, 62, 64, 67, 69, 72, 74, 76]  # C pentatonic, two octaves
    beat = 0.6875
    t = 0.0
    while t < dur - 0.5:
        if rng.random() < 0.62:
            note = rng.choice(scale)
            _render_tone(total, int(t * SAMPLE_RATE), int(beat * 1.6 * SAMPLE_RATE),
                         _midi_hz(note), 0.13, "sine", 0.02, 0.25, decay_tau=0.35)
        t += beat
    tb = 2.0 + rng.random() * 2.0
    while tb < dur - 1.0:
        _render_bird(total, int(tb * SAMPLE_RATE), rng)
        tb += 3.0 + rng.random() * 3.0
    _loop_edges_fade(total)
    return total


def music_ruins(rng: random.Random) -> list[float]:
    """Sparse and hollow: a slow A drone under long bell notes with echo tails."""
    dur = 36.0
    total = _new_buf(dur)
    _render_tone(total, 0, len(total), _midi_hz(33), 0.22, "sine", 2.5, 3.0)   # A1
    _render_tone(total, 0, len(total), _midi_hz(33.15), 0.15, "sine", 2.5, 3.0)  # detuned
    _render_tone(total, 0, len(total), _midi_hz(40), 0.09, "sine", 2.5, 3.0)   # E2 fifth
    bells = [57, 64, 60, 69, 55, 64, 57, 67]  # A3 E4 C4 A4 G3 E4 A3 G4
    t = 1.0
    for note in bells:
        start = int(t * SAMPLE_RATE)
        _render_tone(total, start, int(6.0 * SAMPLE_RATE), _midi_hz(note), 0.20, "sine", 0.01, 0.1, decay_tau=1.6)
        _render_tone(total, start, int(6.0 * SAMPLE_RATE), _midi_hz(note + 12), 0.06, "sine", 0.01, 0.1, decay_tau=1.2)
        for delay, echo_gain in ((0.28, 0.09), (0.56, 0.05)):  # hollow reverb-like tail
            _render_tone(total, int((t + delay) * SAMPLE_RATE), int(4.0 * SAMPLE_RATE),
                         _midi_hz(note), echo_gain, "sine", 0.01, 0.1, decay_tau=1.4)
        t += 4.2
    _loop_edges_fade(total)
    return total


def music_dungeon(rng: random.Random) -> list[float]:
    """Low and dissonant: a D drone beating against Eb, with a tritone above."""
    dur = 34.0
    total = _new_buf(dur)
    _render_tone(total, 0, len(total), _midi_hz(26), 0.30, "sine", 2.5, 3.0)  # D1
    _render_tone(total, 0, len(total), _midi_hz(38), 0.18, "sine", 2.5, 3.0)  # D2
    _render_tone(total, 0, len(total), _midi_hz(39), 0.15, "tri", 2.5, 3.0)   # Eb2 minor 2nd
    _render_tone(total, 0, len(total), _midi_hz(45), 0.09, "sine", 2.5, 3.0)  # A2 tritone
    t = 0.0
    while t < dur - 4.0:  # a slow G1 swell breathing under the cluster
        _render_tone(total, int(t * SAMPLE_RATE), int(4.0 * SAMPLE_RATE), _midi_hz(31), 0.11, "sine", 1.6, 1.6)
        t += 4.0
    _loop_edges_fade(total)
    return total


def music_fortress(rng: random.Random) -> list[float]:
    """Martial: a steady low pulse on every beat under a D-minor pad."""
    dur = 32.0
    total = _new_buf(dur)
    prog = [[38, 41, 45], [38, 41, 45], [36, 41, 44], [36, 40, 43]]  # Dm Dm Bb C
    chord_len = 4.0
    beat = 0.6
    t = 0.0
    for _rep in range(2):
        for chord in prog:
            if t >= dur:
                break
            start = int(t * SAMPLE_RATE)
            length = int(chord_len * 1.2 * SAMPLE_RATE)
            _render_chord(total, start, length, chord, 0.20, "tri", 0.4, 0.8)
            t += chord_len
    t = 0.0
    while t < dur - 0.2:  # the pulse: a short low root hit each beat
        root = 38 if t < dur / 2.0 else 36
        _render_tone(total, int(t * SAMPLE_RATE), int(beat * 0.8 * SAMPLE_RATE),
                     _midi_hz(root), 0.26, "sine", 0.005, 0.05, decay_tau=0.18)
        t += beat
    _loop_edges_fade(total)
    return total


def music_boss(rng: random.Random) -> list[float]:
    """Tense and fast: a driving low E ostinato with a shifting tritone stab."""
    dur = 32.0
    total = _new_buf(dur)
    _render_tone(total, 0, len(total), _midi_hz(28), 0.20, "sine", 1.0, 2.0)  # E1 drone
    eighth = 0.227  # ~132 BPM eighths
    ostinato = [28, 28, 40, 28, 28, 28, 41, 28]  # E1 E1 E2 E1 ... F2 (tritone tension)
    t = 0.0
    step = 0
    while t < dur - eighth:
        note = ostinato[step % len(ostinato)]
        _render_tone(total, int(t * SAMPLE_RATE), int(eighth * 0.9 * SAMPLE_RATE),
                     _midi_hz(note), 0.30, "sine", 0.004, 0.03, decay_tau=0.12)
        t += eighth
        step += 1
    bar = 1.816
    stab = [45, 46, 45, 44]  # A2 Bb2 A2 G#2 — dissonant stab per bar
    t = 0.0
    i = 0
    while t < dur - 0.5:
        _render_chord(total, int(t * SAMPLE_RATE), int(0.5 * SAMPLE_RATE),
                      [stab[i % len(stab)], stab[i % len(stab)] + 7], 0.16, "tri", 0.01, 0.2, decay_tau=0.3)
        t += bar
        i += 1
    _loop_edges_fade(total)
    return total


def ambience_forest(rng: random.Random) -> list[float]:
    """Wind and wing bed only, no melody: gusting low-passed noise plus flutters."""
    dur = 20.0
    total = _new_buf(dur)
    _render_noise(total, 0, len(total), rng, 0.30, cutoff=0.06)  # steady wind floor
    t = 0.0
    while t < dur:  # slow gusts: a louder, softer band of noise swelling in and out
        length = int((2.5 + rng.random() * 2.0) * SAMPLE_RATE)
        _render_noise(total, int(t * SAMPLE_RATE), length, rng, 0.22, cutoff=0.03)
        t += 2.0 + rng.random() * 2.5
    t = 1.0
    while t < dur - 1.0:  # wing flutter: a brief band-passed noise swell
        length = int((0.15 + rng.random() * 0.2) * SAMPLE_RATE)
        _render_noise(total, int(t * SAMPLE_RATE), length, rng, 0.18, cutoff=0.4)
        t += 2.5 + rng.random() * 3.0
    _loop_edges_fade(total)
    return total


def sting_victory(rng: random.Random) -> list[float]:
    """A short rising C-major arpeggio — the victory cue (not a loop)."""
    total = _new_buf(1.6)
    arp = [60, 64, 67, 72]  # C4 E4 G4 C5
    t = 0.0
    for note in arp:
        _render_tone(total, int(t * SAMPLE_RATE), int(1.4 * SAMPLE_RATE), _midi_hz(note), 0.30, "sine", 0.01, 0.1, decay_tau=0.5)
        _render_tone(total, int(t * SAMPLE_RATE), int(1.4 * SAMPLE_RATE), _midi_hz(note + 12), 0.10, "sine", 0.01, 0.1, decay_tau=0.4)
        t += 0.16
    _render_tone(total, int(t * SAMPLE_RATE), int(1.2 * SAMPLE_RATE), _midi_hz(76), 0.22, "sine", 0.01, 0.2, decay_tau=0.6)  # E5 top
    return total


## name -> (generator, peak). The loop beds sit at the same -6 dBFS as the SFX;
## the ambience is a touch quieter because it plays under everything at once.
MUSIC = {
    "music_menu": (music_menu, DEFAULT_PEAK),
    "music_forest": (music_forest, DEFAULT_PEAK),
    "music_ruins": (music_ruins, DEFAULT_PEAK),
    "music_dungeon": (music_dungeon, DEFAULT_PEAK),
    "music_fortress": (music_fortress, DEFAULT_PEAK),
    "music_boss": (music_boss, DEFAULT_PEAK),
    "ambience_forest": (ambience_forest, 0.4),
    "sting_victory": (sting_victory, DEFAULT_PEAK),
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


def _emit(out_dir: Path, name: str, generator, peak: float, seed: int) -> None:
    """Generate one file, write it, and print its measured duration and peak."""
    rng = random.Random(seed)
    codes = _quantise(generator(rng), peak)
    path = out_dir / ("%s.wav" % name)
    _write_wav(path, codes)
    measured = max(abs(c) for c in codes) if codes else 0
    dbfs = 20.0 * math.log10(measured / float(INT16_MAX)) if measured else -999.0
    print(
        "  %-16s %7.2f s  %6d samples  peak %6.1f dBFS  %7d B"
        % (name, len(codes) / SAMPLE_RATE, len(codes), dbfs, path.stat().st_size)
    )


def main(argv: list[str]) -> int:
    # An optional argv[1] redirects the output (used by the idempotency test to
    # regenerate into a temp dir and compare md5 without touching the shipped
    # assets). With no argument the shipped directory is written, as before.
    out_dir = Path(argv[1]).resolve() if len(argv) > 1 else OUT_DIR
    out_dir.mkdir(parents=True, exist_ok=True)
    print(
        "generating %d sounds + %d music/ambience -> %s (%d Hz, %d ch, %d-bit)"
        % (
            len(SOUNDS),
            len(MUSIC),
            out_dir if out_dir != OUT_DIR else OUT_DIR.relative_to(OUT_DIR.parents[1]),
            SAMPLE_RATE,
            CHANNELS,
            SAMPLE_WIDTH * 8,
        )
    )
    for index, (name, (generator, peak)) in enumerate(sorted(SOUNDS.items())):
        # A per-sound seed keeps the whole set reproducible: re-running this
        # script rewrites every file with identical bytes.
        _emit(out_dir, name, generator, peak, 0x5EED + index * 7919)
    # A different seed base for the music so a track never reuses an SFX stream.
    for index, (name, (generator, peak)) in enumerate(sorted(MUSIC.items())):
        _emit(out_dir, name, generator, peak, 0x9E3779B1 + index * 7919)
    print("done")
    return 0


if __name__ == "__main__":
    import sys

    raise SystemExit(main(sys.argv))

