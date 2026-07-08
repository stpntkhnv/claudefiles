#!/usr/bin/env python3
"""Generate ready.wav - the "your turn" notification chime played by the Stop/Notification hooks.
Warm two-note rising chime (~0.42s, ~1.5-2 kHz + soft octave) tuned to be audible on quiet
laptop speakers without being shrill. Run from anywhere: writes ready.wav next to this script."""
import wave, struct, math, os

SR = 44100
OUT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "ready.wav")


def note(freq, dur, vol=0.85, fade=0.010):
    n = int(SR * dur)
    fn = int(SR * fade)
    s = []
    for i in range(n):
        env = 1.0
        if i < fn:
            env = i / fn
        if i > n - fn:
            env = (n - i) / fn
        v = math.sin(2 * math.pi * freq * i / SR) + 0.25 * math.sin(2 * math.pi * 2 * freq * i / SR)
        s.append(vol * env * v / 1.25)
    return s


def sil(d):
    return [0.0] * int(SR * d)


samples = note(1500, 0.15) + sil(0.05) + note(2000, 0.22)
w = wave.open(OUT, "w")
w.setnchannels(1)
w.setsampwidth(2)
w.setframerate(SR)
w.writeframes(b"".join(struct.pack("<h", int(max(-1, min(1, x)) * 32767)) for x in samples))
w.close()
print(f"wrote {OUT} ({len(samples)/SR:.2f}s)")
