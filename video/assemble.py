#!/usr/bin/env python3
"""Build the final video from record.py's output.

  python video/assemble.py

Inputs : build/frames/*.jpg + build/timeline.json (record.py), build/tts/*.wav (tts.py)
Outputs: WiseCrowd_demo.mp4 (1080p, captions burned in), WiseCrowd_demo.srt (same captions as a subtitle file),
         chapters.txt (timestamps per section, e.g. for a video description)
"""

import json
import math
import os
import subprocess
import sys
import textwrap
import wave

import imageio_ffmpeg
import numpy as np

HERE = os.path.dirname(os.path.abspath(__file__))
BUILD = os.path.join(HERE, "build")
FRAMES = os.path.join(BUILD, "frames")
sys.path.insert(0, HERE)
from narration import LINES  # noqa: E402

NAME = "WiseCrowd_demo"
AUDIO_LEAD = 0.08  # the caption fades in ~90 ms after it is triggered; start the voice with it


def srt_time(t: float) -> str:
    ms = int(round(max(0.0, t) * 1000))
    h, ms = divmod(ms, 3_600_000)
    m, ms = divmod(ms, 60_000)
    s, ms = divmod(ms, 1000)
    return f"{h:02d}:{m:02d}:{s:02d},{ms:03d}"


def subtitle_chunks(text: str, width: int = 52) -> list[str]:
    """Split a caption into evenly sized subtitle cues of at most two lines."""
    n = math.ceil(len(textwrap.wrap(text, width)) / 2)
    chunks, cur = [], ""
    for word in text.split():
        if cur and len(chunks) < n - 1 and len(cur) + 1 + len(word) > len(text) / n * 1.08:
            chunks.append(cur)
            cur = word
        else:
            cur = f"{cur} {word}".strip()
    chunks.append(cur)
    return ["\n".join(textwrap.wrap(c, max(width - 10, math.ceil(len(c) / 2) + 8))) for c in chunks]


def main() -> None:
    tl = json.load(open(os.path.join(BUILD, "timeline.json")))
    dur = json.load(open(os.path.join(BUILD, "tts", "durations.json")))
    use_cdp = abs(tl["recv_lag"]) < 1.0  # screencast timestamps share the local clock (normal case)
    frames = [((f[0] if use_cdp else f[1] - tl["recv_lag"]), f[2]) for f in tl["frames"]]
    t0, end = tl["start"], tl["end"]
    total = end - t0

    # ---- video: variable-rate screencast frames -> concat list with per-frame durations
    first = max((i for i, (t, _) in enumerate(frames) if t <= t0), default=0)
    kept = [(max(t, t0), n) for t, n in frames[first:] if t <= end]
    with open(os.path.join(FRAMES, "list.txt"), "w") as f:
        for i, (t, n) in enumerate(kept):
            nxt = kept[i + 1][0] if i + 1 < len(kept) else end
            f.write(f"file '{n}'\nduration {max(nxt - t, 0.001):.4f}\n")
        f.write(f"file '{kept[-1][1]}'\n")

    # ---- audio: every narration clip at the moment its caption appeared
    sr = next(iter(dur.values()))["sr"]
    buf = np.zeros(int(math.ceil(total * sr)) + 1, np.float32)
    for m in tl["marks"]:
        with wave.open(os.path.join(BUILD, "tts", f"{m['id']}.wav")) as w:
            clip = np.frombuffer(w.readframes(w.getnframes()), "<i2").astype(np.float32) / 32768
        s = int(round((m["t"] - t0 + AUDIO_LEAD) * sr))
        n = min(len(clip), len(buf) - s)
        buf[s:s + n] += clip[:n]
    narration = os.path.join(BUILD, "narration.wav")
    with wave.open(narration, "wb") as w:
        w.setnchannels(1)
        w.setsampwidth(2)
        w.setframerate(sr)
        w.writeframes((np.clip(buf, -1, 1) * 32767).astype("<i2").tobytes())

    # ---- subtitles + chapters
    cues = []
    marks = tl["marks"]
    for i, m in enumerate(marks):
        a = m["t"] - t0 + AUDIO_LEAD
        b = a + dur[m["id"]]["dur"] + 0.2
        if i + 1 < len(marks):
            b = min(b, marks[i + 1]["t"] - t0)
        chunks = subtitle_chunks(LINES[m["id"]])
        weights = [len(c) for c in chunks]
        at = a
        for c, wgt in zip(chunks, weights):
            span = (b - a) * wgt / sum(weights)
            cues.append((at, at + span, c))
            at += span
    with open(os.path.join(HERE, f"{NAME}.srt"), "w", encoding="utf-8") as f:
        for i, (a, b, c) in enumerate(cues, 1):
            f.write(f"{i}\n{srt_time(a)} --> {srt_time(b)}\n{c}\n\n")
    with open(os.path.join(HERE, "chapters.txt"), "w", encoding="utf-8") as f:
        for i, c in enumerate(tl["chapters"]):
            s = 0 if i == 0 else int(c["t"] - t0)
            f.write(f"{s // 60}:{s % 60:02d} {c['title']}\n")

    # ---- encode
    out = os.path.join(HERE, f"{NAME}.mp4")
    cmd = [
        imageio_ffmpeg.get_ffmpeg_exe(), "-y", "-hide_banner", "-loglevel", "error", "-stats",
        "-f", "concat", "-safe", "0", "-i", os.path.join(FRAMES, "list.txt"),
        "-i", narration,
        "-vf", "fps=30,scale=1920:1080:flags=lanczos:in_range=pc:out_range=tv:in_color_matrix=bt601:out_color_matrix=bt709,format=yuv420p",
        "-colorspace", "bt709", "-color_primaries", "bt709", "-color_trc", "bt709", "-color_range", "tv",
        "-af", "loudnorm=I=-16:TP=-1.5:LRA=11,aresample=48000",
        "-c:v", "libx264", "-preset", "slow", "-crf", "18",
        "-c:a", "aac", "-b:a", "192k",
        "-t", f"{total:.3f}", "-movflags", "+faststart",
        "-metadata", "title=WiseCrowd - SC4053 Option 4 prediction market demo",
        out,
    ]
    subprocess.run(cmd, check=True)
    print(f"{out}\n  {total / 60:.0f}:{total % 60:04.1f} long, {len(kept)} source frames, {len(marks)} narration clips, {len(cues)} subtitle cues")


if __name__ == "__main__":
    main()
