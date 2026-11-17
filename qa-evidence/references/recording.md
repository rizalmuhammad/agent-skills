# Recording a run (OpenBot lane)

The steps below drive one browser tab through the OpenBot bridge and produce the two files the builder needs: a `.webm` and a JSON event log. No OpenBot bridge? Use the Playwright lane in `recording-playwright.md` instead - the event format and the traps below apply there unchanged. Everything here was exercised against the tab recorder; the numbers to watch are in the last section.

## The shape of a run

1. `recording_start` on the tab.
2. One `run_script` call that does the whole flow and returns the event array.
3. `recording_stop`, which returns the saved `.webm` path.

Keep the whole flow in one script: the recorder keeps running between calls, so drifting gaps between calls land in the video as dead air.

## Harness

Adapt targets and captions; keep the sync flash, the logging and the per-character typing. Paste this helper verbatim at the top of the run script - it owns the event shapes, so the flow never hand-rolls one and gets a field wrong:

```javascript
const L = [];
const now = () => Date.now();

// paste-verbatim helper: owns the event shapes described in SKILL.md
const ev = {
  sync: () => L.push({ kind: 'sync', ms: now() }),
  move: (x, y) => L.push({ kind: 'move', ms: now(), x, y }),
  step: (status, text) => L.push({ kind: 'step', ms: now(), status, text }),
  box: async (sel) => evaluate(
    `(() => { const b = document.querySelector('${sel}').getBoundingClientRect();` +
    ` return { l: b.x, t: b.y, w: b.width, h: b.height }; })()`),
  click: async (sel, label) => {
    const r = await ev.box(sel);   // read right before marking, after any layout shift
    L.push({ kind: 'click', ms: now(),
             x: Math.round(r.l + r.w / 2), y: Math.round(r.t + r.h / 2),
             ...r, label: label || sel });
  },
  type: async (sel) => L.push({ kind: 'type', ms: now(), ...(await ev.box(sel)) }),
  hl:   async (sel) => L.push({ kind: 'hl', ms: now(), ...(await ev.box(sel)) }),
};
```

Then the flow reads as actions, not JSON:

```javascript
await navigate('https://example.test/start');
await sleep(800);

// 1. sync flash: the builder finds this frame and anchors every other timestamp to it
await evaluate(() => {
  const d = document.createElement('div');
  d.id = '__syncflash';
  d.style.cssText = 'position:fixed;inset:0;background:#ff00cc;z-index:2147483647;pointer-events:none';
  document.documentElement.appendChild(d);
  return true;
});
ev.sync();
await sleep(260);
await evaluate(() => { const d = document.getElementById('__syncflash'); if (d) d.remove(); return true; });
await sleep(150);

// 2. real pointer travel: several hover points, so the cursor moves instead of teleporting
const glide = async (from, to, steps, per) => {
  for (let i = 1; i <= steps; i++) {
    const t = i / steps;
    const e = t < 0.5 ? 2 * t * t : 1 - Math.pow(-2 * t + 2, 2) / 2;   // ease in/out
    const x = Math.round(from.x + (to.x - from.x) * e);
    const y = Math.round(from.y + (to.y - from.y) * e);
    await hover({ kind: 'point', x, y });
    ev.move(x, y);
    await sleep(per);
  }
};

ev.step('PASS', 'open the start page; the form is empty');
await sleep(800);

const f = await ev.box('#q');
const g = await ev.box('#go');
const ctr = (b) => ({ x: Math.round(b.l + b.w / 2), y: Math.round(b.t + b.h / 2) });
await glide({ x: 640, y: 660 }, ctr(f), 9, 60);
await click({ kind: 'point', ...ctr(f) });
await ev.click('#q', 'Search field');
await sleep(500);
ev.step('PASS', 'click the search field; it takes focus');
await sleep(700);

// 3. real typing: one character per call, appended, one event each
for (const ch of 'hello') {
  await type('#q', ch, { mode: 'append' });
  await ev.type('#q');
  await sleep(150);
}
const typed = await evaluate(() => document.getElementById('q').value);
ev.step(typed === 'hello' ? 'PASS' : 'FAIL', `type hello; the field reads ${typed}`);
await sleep(600);

await glide(ctr(f), ctr(g), 8, 60);
await click({ kind: 'point', ...ctr(g) });
await ev.click('#go', 'Search button');
await sleep(700);

// 4. prove the step from the page, then highlight what changed
const res = await evaluate(() => {
  const el = document.querySelector('#result');
  return { text: el.textContent, on: el.classList.contains('on') };
});
await ev.hl('#result h1');
ev.step(res.on && /hello/.test(res.text) ? 'PASS' : 'FAIL', `click Search; the panel shows ${res.text}`);
await sleep(1200);

return L;
```

Save the returned array as `events.json` next to the recording.

## Details that break the build

- **Hand-rolled event shapes.** A `click` row with `x,y` but no box, or a `type` row with no `l,t,w,h`, silently degrades the output. Use the `ev` helper above; it owns the shapes.
- **No `sync` row.** The builder cannot map wall-clock times onto frames and stops with an error. Add the flash.
- **`ms` from different clocks.** Use `Date.now()` for every row. A row built from a different source will drift captions by seconds.
- **Replace-mode typing.** `type(sel, ch)` replaces the field contents, so the video shows one character while the caption claims a word. Pass `{ mode: 'append' }` after an initial clear, or type the whole string in one call and log a single event.
- **`evaluate` takes no second argument.** It accepts one expression or function. To read several boxes, return them all from one `evaluate`, as in the harness above.
- **Coordinates outside the viewport.** `getBoundingClientRect` is viewport-relative, which is what the overlay uses. Do not add `scrollY`.
- **Boxes read before a layout change.** Read boxes right before you act on them. A panel that opens shifts everything below it.

## What the recorder really produces

Measured on a live run, and worth designing around:

- **VP9 in WebM, no duration header.** Anything that reads duration up front sees `N/A`; the builder counts sampled frames instead.
- **Variable frame rate, only changed frames.** A 22 s interaction produced a few dozen frames. The build re-times to a constant rate, so timing comes from your timestamps, not the packet count.
- **No OS cursor in the video.** The capture is the page surface, so the pointer you see is the one the builder draws from your `move` and `click` rows. This is why the logged coordinates have to be the ones you actually drove.
- **Type is visible.** Keystroke-by-keystroke text appears in the field, so real typing is what makes the video convincing.
- **5 minute / 100 MB cap**, then it stops on its own. Keep runs to a few steps.

## If timing looks off

Check the flash itself first: extract a frame at the computed start and look for magenta. A flash that was never fully painted, or one removed before a frame was emitted, gives the builder a wrong anchor. Hold it 250-300 ms and remove it in a separate call, as the harness does.
