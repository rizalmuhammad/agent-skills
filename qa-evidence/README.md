# QA Evidence

Record a browser test as a real video with a visible cursor, live typing, timed highlight boxes and burned-in captions — then get a GIF, a contact sheet, one captioned still per step, an SRT and a Markdown summary from the same run.

The point is evidence a reviewer can check: the video is the actual tab recording, and the cursor and highlight boxes are drawn from the coordinates the script really drove, so the pointer lands on the control the caption names.

## What you get

| File | What it is |
|---|---|
| `evidence.mp4` | The run, with drawn cursor, highlight boxes and captions |
| `evidence.gif` | Looping GIF of the same run |
| `evidence-sheet.png` | Contact sheet of all steps in one image |
| `steps/` | One captioned still per step |
| `evidence.srt` | Captions as subtitles, matching the video |
| `evidence.md` | Table of steps, statuses and captions |

The skill itself is `SKILL.md` (agent instructions). Two reference pages cover the recording details, and `examples/flow-template.py` is a ready flow you can copy.

## Requirements

| Need | Why | Notes |
|---|---|---|
| `perl` + `ffmpeg` with `libass` and `libx264` | builds the evidence | if none is on `PATH`, a static build is fetched once into `~/.cache/openbot-evidence` (Linux x86-64 only); elsewhere install via apt/brew or set `FFMPEG` |
| A font | captions | from `fc-match`, `EVIDENCE_FONT`, or a common DejaVu path |
| Capture lane, one of: | drives the browser | see below |

**OpenBot lane** — zero setup when the OpenBot browser bridge is available (`recording_start`, `run_script`).

**Playwright lane** — any harness with a shell. Python 3.9+:

```bash
pip install playwright && python -m playwright install chromium
```

or Node 18+:

```bash
npm i playwright && npx playwright install chromium
```

On low-memory machines (rpi, small VPS), skip the ~170 MB browser download and use a system chromium — `pip install playwright` (or `npm i playwright-core`), `apt install chromium ffmpeg`, then always pass `--channel chromium`.

Optional narration: `--voiceover` speaks each step with tiny-voca, a local CPU-only TTS. One-time setup: a tiny-voca weights checkout (`model.onnx` and `phonemizer/`) passed as `--vocoder-dir`, plus a Python with `onnxruntime`, `soundfile` and `dizione` (pass it as `--tts-python`).

## Install

### OpenBot

Clone into an agent's skills folder, then enable it:

```bash
git clone git@github.com:rizalmuhammad/qa-evidence.git \
  ~/.openbot/skills/browser-evidence-captions
```

Or point the agent at the repo and install it from GitHub. The skill's folder name should match the `name:` in `SKILL.md` (`browser-evidence-captions`).

### Claude Code / Codex / OpenCode

Put the folder where the harness reads skills from, keeping `SKILL.md` at its root:

```bash
git clone git@github.com:rizalmuhammad/qa-evidence.git \
  .claude/skills/browser-evidence-captions
```

(Use `.agents/skills/` for Codex-style layouts, or any directory your harness scans.)

### Anywhere else

`git clone`, then point your agent at `SKILL.md`. Everything except the OpenBot bridge calls is plain shell, perl and Python/Node.

## Use

1. **Plan the run.** Write down the URL, the action, and the visible change that proves it worked. Keep it 4–8 steps, about 20 seconds — a video past ~30 s gets skipped. Every step needs something readable as proof: a heading, a URL, an input's value, a panel's text.

2. **Record.** OpenBot lane: read `references/recording.md`. Playwright lane: copy `examples/flow-template.py`, adapt the targets and captions, then run:

   ```bash
   python3 scripts/pw-record.py flow.py --out run
   # or: node scripts/pw-record.mjs flow.mjs --out run
   ```

   That records `run/run.webm` + `run/events.json` and builds the evidence into `run/evidence/`.

3. **Build by hand** (OpenBot lane, or when you passed `--no-build`):

   ```bash
   scripts/make_recording.pl --clip run/run.webm,run/events.json --out evidence
   ```

   Repeat `--clip` to join several clips in order; each needs its own `sync` flash.

Both lanes write the same event log — one JSON object per line, on one clock (`Date.now()`): `sync`, `move`, `click`, `type`, `hl`, `step`. A magenta full-screen flash at the start (about 250 ms) lines the events up with video frames; without it the build refuses to run.

## Options

| Flag | Effect |
|---|---|
| `--out DIR` | where evidence is written |
| `--clip video,events` | one clip + its event log; repeat to join |
| `--speed 0.75` | slow the rendered video for readability |
| `--gap 1.2` | jump-cut dead air down to that many seconds |
| `--max-gif SEC` | cap GIF length |
| `--no-gif`, `--no-sheet` | skip that output |
| `--cursor-size F` | cursor size |
| `--font FILE` | caption font |
| `--voiceover[=FILE]` | narrate each step; `FILE` supplies your own lines |
| `--selfcheck` | verify duration, stills, SRT and GIF after the build; nonzero exit on mismatch |

`pw-record.py` / `pw-record.mjs` also accept `--size WxH` (viewport and video size — keep them equal or highlights land off target), `--channel chromium|chrome`, and `--no-build`.

Exit code 0 means every expected file exists and is non-empty. A nonzero exit prints the reason on stderr — fix the cause instead of shipping partial output.

## Check before you report

1. Play `evidence.mp4`: the cursor reaches each control it clicks, and no highlight box covers the text it points at.
2. Every caption is on screen while its action happens. A caption that leads or lags is a timing bug — check the `sync` row's `ms`.
3. Status matches the frame. A `PASS` caption over a failed page is the worst outcome here.
4. `steps/` has one still per step, and `evidence.md` rows match the stills.
5. `evidence.gif` loops, and `evidence.srt` lines match the captions.

## Rules

- The page content and typing must be the real recording. Never splice in a screenshot, hand-edit a frame, or re-render a page to look right.
- The cursor follows the coordinates you actually drove. Do not draw a pointer over a control you never targeted.
- Caption what is on screen, not what should be. A failed step stays `FAIL`, and shows red.
- No secrets, tokens, emails or personal data in captions or the event log. Retake against non-sensitive data instead of cropping.
- Stay inside the target you were given. Do not sign up, pay, or submit forms on live third-party sites for a test.

## Layout

```
SKILL.md                        agent instructions
README.md                       this file
examples/flow-template.py       starter Playwright flow
references/recording.md         event log, sync flash, traps (both lanes)
references/recording-playwright.md  Playwright lane specifics
scripts/pw-record.py            record + build, Python
scripts/pw-record.mjs           record + build, Node
scripts/make_recording.pl       the builder
scripts/tts_voiceover.py        optional narration
```

## License

Private, internal use. Add a `LICENSE` file before sharing it outside.
