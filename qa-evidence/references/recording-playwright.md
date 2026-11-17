# Recording a run on any harness (Playwright lane)

Use this lane when there is no OpenBot browser bridge: Claude Code, Codex, OpenCode, rpi, or any harness that can run shell commands. The event-log format, the sync flash, and the build step are identical to the OpenBot lane - read `recording.md` for the event table and the traps. This page only covers what changes.

## Setup, once per machine

Python 3.9+ is the default - rpi and minimal images ship python, not node:

```
pip install playwright && python -m playwright install chromium
```

Node 18+ works just as well:

```
npm i playwright && npx playwright install chromium
```

Low-memory machines (rpi, small VPS) skip the ~170 MB browser download and use a system chromium. The pip package never downloads a browser unless you run `playwright install`, so on python there is nothing to avoid; on node use `playwright-core`:

```
pip install playwright             # or: npm i playwright-core
apt install chromium ffmpeg        # rpi: the builder's self-download is amd64-only, so ffmpeg comes from apt too
# then always pass --channel chromium   (or chrome)
```

The builder still needs perl + ffmpeg as usual.

## The shape of a run

1. Copy `examples/flow-template.py` (in this skill) and adapt targets and captions, or write a flow from scratch: python defines `run(api)`, node exports one async function. Both get the same api: `navigate, evaluate, hover, click, type, sleep, mark, log`.
2. Run it - capture and build in one command:

```
python3 scripts/pw-record.py flow.py --out run     # or: node scripts/pw-record.mjs flow.mjs --out run
```

3. That records `run/run.webm` + `run/events.json`, then runs the builder with `--selfcheck`. Finished evidence lands in `run/evidence/` - mp4, gif, contact sheet, step stills, srt, md. `--no-build` stops after capture if you want to build by hand:

```
scripts/make_recording.pl --clip run/run.webm,run/events.json --out evidence
```

## Flow file

Python flavor (node is the same calls inside `export default async ({ navigate, evaluate, hover, click, type, sleep, mark }) => { ... }`):

```python
def run(api):
    # 1. sync flash - unchanged, and still mandatory
    api.evaluate(
        "() => { const d = document.createElement('div'); d.id = '__syncflash';"
        " d.style.cssText = 'position:fixed;inset:0;background:#ff00cc;"
        "z-index:2147483647;pointer-events:none';"
        " document.documentElement.appendChild(d); return true; }")
    api.mark({'kind': 'sync'})
    api.sleep(260)
    api.evaluate("() => { const d = document.getElementById('__syncflash');"
                 " if (d) d.remove(); return true; }")
    api.sleep(150)

    # 2. the flow: navigate / evaluate / hover / click / type exactly as in recording.md
    api.navigate('https://example.test/start')
    # ... hover glides, clicks, per-character typing, mark(...) rows ...

    # return the events list, or nothing if you only used mark()
```

`evaluate` runs a JavaScript string in both drivers, so the snippets in `recording.md` carry over unchanged.

The mapping:

| OpenBot bridge call | Playwright api here | note |
|---|---|---|
| `recording_start` / `recording_stop` | automatic | video records from `new_page` to `context.close()` |
| `hover({kind:'point', x, y})` | `hover({'x':.., 'y':..})` | real `mouse.move`, so hovers trigger page handlers |
| `click({kind:'point', x, y})` | `click({'x':.., 'y':..})` | real `mouse.click` at those coordinates |
| `type(sel, ch, {mode:'append'})` | `type(sel, ch)` | append is the default; `mode='replace'` fills |
| `evaluate(fn)` | `evaluate("...js...")` | one function argument, return everything from one call |
| `run_script` wrapping | the flow file itself | keep the whole run in one module |

## Lane differences worth knowing

- Playwright video is also VP9 WebM with variable frame rate, and it carries no OS cursor - everything `recording.md` says about the sync flash and honest coordinates applies unchanged.
- Video starts when the page opens and stops when the context closes. Navigate inside the flow, after the flash, so no dead air leads the clip.
- `--size WxH` sets both viewport and video size; keep them equal or highlights land off their targets.
- Headless is the default and what you want: the video is the page surface, not a window.
