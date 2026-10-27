# Demo video

`WiseCrowd_demo.mp4` is a narrated walkthrough: an architecture and design introduction, the local deployment, then a
hands-on demo of every feature on a freshly started local chain. Captions are burned in. The same captions are in
`WiseCrowd_demo.srt`, and `chapters.txt` lists the start time of each section. These three files are not committed
to git (the MP4 is about 40 MB and changes with every take); the steps under [Regenerating](#regenerating) build them.

Everything shown in the app is real: `record.py` starts `./run.sh`, then drives the actual UI and sends real
transactions. The two terminal scenes replay real output, sped up and marked as replays on screen: the `./run.sh`
output from the same recording run, and the `forge test` summary lines from `build/forge_test.log`.

## Files

| File | What it does |
|---|---|
| `narration.py` | Every caption in order, plus spelling fixes for the voice (USDT, ERC-1155, SC4053 …) |
| `tts.py` | Makes one voice clip per caption with Kokoro, offline (`build/tts/`) |
| `studio.html` | The recording page: slides, terminal replay, caption band, cursor and highlights, with the app in a frame |
| `record.py` | Restarts `./run.sh`, drives the app in headless Edge in step with the narration, captures frames |
| `assemble.py` | Places the clips on the timeline, writes the `.srt` and chapters, encodes the 1080p MP4 |

## Regenerating

Requirements:

- **WSL (Ubuntu):** Foundry in `~/.foundry/bin`, `pip install kokoro-onnx soundfile`, and
  `kokoro-v1.0.onnx` + `voices-v1.0.bin` in `~/kokoro`.
- **Windows Python:** `pip install playwright imageio-ffmpeg numpy`. Microsoft Edge must be installed.

```bash
wsl -d Ubuntu-22.04 -e python3 video/tts.py   # 1. voice clips (only changed lines are regenerated)
python video/record.py --fast                 # 2. optional rehearsal of the whole flow (~4 min, no frames)
python video/record.py                        # 3. the real take (~9 min)
python video/assemble.py                      # 4. WiseCrowd_demo.mp4 + .srt + chapters.txt
```

`record.py` stops anything `./run.sh` started on ports 8554/5554 and launches a fresh copy, because the demo
changes chain state (reports, votes, a new market). It stops the chain again when it finishes.
`tts.py --voice am_michael` (or another Kokoro voice) changes the narrator.
