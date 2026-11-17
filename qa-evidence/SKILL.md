---
name: browser-evidence-captions
description: Record a browser test as real video with a visible cursor, live typing, timed highlight boxes and burned-in captions - plus a GIF, a PNG contact sheet, captioned step stills and an SRT. Use when asked to test a web page and show proof, record or demo a browser flow, annotate a walkthrough, or produce visual evidence of UI actions. Not for writing a test suite, or for reporting bugs with no visual output.
example-prompt: Record the login flow on our staging site with a cursor and captions, and give me a gif plus a still of each step.
compatibility: Capture needs the OpenBot browser bridge, or Playwright (Python 3.9+ or Node 18+) on any harness. Build needs perl and ffmpeg.
---

# Recorded browser test evidence

Goal: a reviewer who never saw the run can watch what happened and believe it. The video is the real tab recording; the cursor and highlight boxes are drawn on top from the coordinates you actually drove, so the pointer lands on the control it names.

A step counts as evidence when its caption names the action and the visible result, its status was read from the page, and both are visible in the video at that step's time.

## 1. Plan the run

Write the walkthrough before touching the browser: URL, action, and the change that proves the action worked. 4-8 steps, about 20 s total; a video longer than ~30 s gets skipped.

Decide per step what you will read to prove it - a heading, a URL, an input's value, a panel's text. A step with nothing checkable is not evidence: merge it into the next one.

## 2. Record it

Two capture lanes; the event-log format and the build step are identical either way.

- **OpenBot lane** - zero setup when you have the OpenBot browser bridge (`recording_start`, `run_script`). Read `references/recording.md`.
- **Playwright lane** - any harness with Python 3.9+ or Node 18+: Claude Code, Codex, OpenCode, rpi. Drives Playwright's built-in video recorder through `scripts/pw-record.py` (or `pw-record.mjs` on Node), then builds the evidence in the same command. Start from `examples/flow-template.py`. Read `references/recording-playwright.md`.

Whichever lane:

1. Prepend a magenta full-screen flash for ~250 ms. This aligns your event times to video frames; without it the build refuses to run.
2. For each step, move the pointer to the target, click it, then go on to type or read the result.
3. Append one JSON object per event to a log: `sync`, `move`, `click`, `type`, `hl`, `step`. Use `Date.now()` for `ms` - the same clock on every row.
4. Typing must be real keystrokes, one event per character, appended - never replace-mode.

Event shapes the builder reads (all coordinates are viewport CSS pixels from `getBoundingClientRect`):

| kind | fields | meaning |
|---|---|---|
| `sync` | `ms` | the frame the flash appeared; exactly one per clip |
| `move` | `ms`, `x`, `y` | pointer position you actually hovered |
| `click` | `ms`, `x`, `y`, `l`, `t`, `w`, `h`, `label` | pointer click plus the target's box |
| `type` | `ms`, `l`, `t`, `w`, `h` | one character; consecutive rows on one box merge into one highlight |
| `hl` | `ms`, `l`, `t`, `w`, `h` | box to highlight with no click, e.g. the thing that changed |
| `step` | `ms`, `status`, `text` | a caption starting at `ms`; `PASS`, `FAIL` or `SKIP` |

## 3. Build the evidence

The Playwright lane already did this: `pw-record` runs the builder for you with `--selfcheck` and puts finished evidence in `OUT/evidence/`. OpenBot lane, or a hand-built clip:

```
scripts/make_recording.pl --clip run.webm,events.json --out evidence
```

Repeat `--clip` to join several recordings in order; each needs its own `sync` and its own flash.

Writes `evidence.mp4` (cursor, highlights, captions), `evidence.gif`, `evidence-sheet.png`, `steps/` (one captioned still per step), `evidence.srt`, `evidence.md`. Captions always overlay the page bottom transparently, so the page keeps its exact size and the footer stays visible.

Options: `--speed 0.75` slows for readability (rendered, not re-timed), `--gap 1.2` jump-cuts dead air between events down to that many seconds, `--max-gif SEC`, `--no-gif`, `--no-sheet`, `--cursor-size F`, `--font FILE`, `--selfcheck` verifies duration/stills/srt/gif after the build and exits nonzero on a mismatch.

Narration: add `--voiceover` to also speak every step in `evidence.mp4`, with tiny-voca, a local CPU-only TTS. Each caption is humanized for speech first (urls, host:port, selectors, `a11y`, `PASS` become speakable words) and only its first sentence is read; `--voiceover=FILE` speaks your own lines instead, one per step in order, `#` comments and empty lines allowed. One-time setup: a tiny-voca weights checkout (`model.onnx` and `phonemizer/`) passed via `--vocoder-dir`, plus a python with `onnxruntime`, `soundfile`, `dizione` (`--tts-python`). Audio lands in the mp4 only - the gif stays silent.

Needs `ffmpeg` with `libass` and `libx264`; bootstraps a static build once into `~/.cache/openbot-evidence` when none is on PATH (Linux x86-64 only - on other platforms it tells you the apt/brew command, or set `FFMPEG`). Fonts come from `fc-match`, `EVIDENCE_FONT`, or a common DejaVu path.

Exit code 0 means every expected file exists and is non-empty. A nonzero exit prints the reason on stderr; fix it rather than shipping partial output.

## 4. Check before reporting

1. Play `evidence.mp4`. The cursor reaches each control it clicks, and no highlight box covers the text it points at.
2. Each caption is on screen while its action happens. A caption that leads or lags its frame is a timing bug - check the `sync` row and its `ms`.
3. Status matches the frame. A `PASS` caption over a failed page is the worst outcome here. Record the real status and let it show red.
4. `steps/` has one still per step, and `evidence.md` rows match the stills.
5. `evidence.gif` opens and loops. `evidence.srt` lines match the captions.

State which steps you could not verify, and why.

## Rules

- The page content and typing must be the real recording. Never splice in a screenshot, hand-edit a frame, or re-render a page to look right.
- The cursor must follow the coordinates you actually drove. Do not draw a pointer over a control you never targeted.
- Caption what is on screen, not what should be. A failed step stays `FAIL`.
- No secrets, tokens, emails or personal data in captions or in the event log. Crop is out of scope: retake against non-sensitive data.
- Stay inside the target the user named. Do not sign up, pay, or submit forms on live third-party sites for a test.
