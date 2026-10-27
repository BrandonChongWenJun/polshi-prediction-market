#!/usr/bin/env python3
"""Generate one narration clip per caption with Kokoro (offline) -> build/tts/<id>.wav + durations.json.

Run inside WSL/Linux:  python3 video/tts.py [--voice af_heart] [--speed 1.0]
Clips are cached by text + voice + speed, so editing one line only regenerates that clip.
"""

import argparse
import hashlib
import json
import os
import sys
import wave

import numpy as np
from kokoro_onnx import Kokoro

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
from narration import LINES, spoken  # noqa: E402

OUT = os.path.join(HERE, "build", "tts")
MODEL_DIR = os.path.expanduser(os.environ.get("KOKORO_DIR", "~/kokoro"))


def trim(audio: np.ndarray, sr: int, pad: float = 0.06, threshold: float = 0.004) -> np.ndarray:
    loud = np.flatnonzero(np.abs(audio) > threshold)
    if not len(loud):
        return audio
    a = max(0, loud[0] - int(pad * sr))
    b = min(len(audio), loud[-1] + int(pad * sr))
    return audio[a:b]


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("--voice", default="af_heart")
    ap.add_argument("--speed", type=float, default=1.0)
    args = ap.parse_args()
    os.makedirs(OUT, exist_ok=True)
    kokoro = Kokoro(os.path.join(MODEL_DIR, "kokoro-v1.0.onnx"), os.path.join(MODEL_DIR, "voices-v1.0.bin"))
    meta_path = os.path.join(OUT, "durations.json")
    meta = json.load(open(meta_path)) if os.path.exists(meta_path) else {}
    total = 0.0
    for uid, text in LINES.items():
        say = spoken(text)
        key = hashlib.sha1(f"{args.voice}|{args.speed}|{say}".encode()).hexdigest()[:12]
        wav = os.path.join(OUT, f"{uid}.wav")
        if meta.get(uid, {}).get("key") != key or not os.path.exists(wav):
            audio, sr = kokoro.create(say, voice=args.voice, speed=args.speed, lang="en-us")
            audio = trim(np.asarray(audio, dtype=np.float32), sr)
            pcm = (np.clip(audio, -1, 1) * 32767).astype("<i2")
            with wave.open(wav, "wb") as w:
                w.setnchannels(1)
                w.setsampwidth(2)
                w.setframerate(sr)
                w.writeframes(pcm.tobytes())
            meta[uid] = {"key": key, "dur": round(len(pcm) / sr, 3), "sr": sr}
            print(f"{uid} {meta[uid]['dur']:6.2f}s  {say[:70]}")
        total += meta[uid]["dur"]
    for stale in set(meta) - set(LINES):
        del meta[stale]
    json.dump(meta, open(meta_path, "w"), indent=1)
    print(f"{len(LINES)} clips, {total:.1f}s of narration")


if __name__ == "__main__":
    main()
