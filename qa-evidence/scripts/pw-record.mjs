#!/usr/bin/env node
// pw-record.mjs - portable capture lane for browser-evidence-captions.
// Drives one chromium tab through Playwright, records its video, writes the two
// files make_recording.pl eats (run.webm + events.json) and then builds the
// evidence into OUT/evidence unless --no-build is given.
//
// usage: node pw-record.mjs FLOW.mjs [--out DIR] [--size 1280x720] [--channel chrome] [--no-build]
//
// FLOW.mjs exports one async function that receives the api below and returns
// (or fills via mark) the event array described in references/recording.md.
//
//   export default async ({ navigate, evaluate, hover, click, type, sleep, mark }) => { ... }

import { createRequire } from 'node:module';
import { writeFileSync, renameSync, mkdtempSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join, resolve, dirname } from 'node:path';
import { pathToFileURL, fileURLToPath } from 'node:url';
import { spawnSync } from 'node:child_process';

const args = process.argv.slice(2);
const opt = (name, dflt) => {
  const i = args.indexOf('--' + name);
  return i >= 0 ? args[i + 1] : dflt;
};
const hasFlag = (name) => args.includes('--' + name);
const flowPath = args.find((a) => !a.startsWith('--') && a !== opt('out', '') && a !== opt('size', '') && a !== opt('channel', '') && a !== opt('gap', '') && a !== opt('voiceover', '') && a !== opt('voice', '') && a !== opt('voice-speed', '') && a !== opt('vocoder-dir', ''));
if (!flowPath || !flowPath.endsWith('.mjs')) {
  console.error('usage: node pw-record.mjs FLOW.mjs [--out DIR] [--size WxH] [--channel NAME] [--no-build] [--voiceover [FILE]] [--voice F2|M2] [--voice-speed F] [--vocoder-dir DIR]');
  process.exit(2);
}
const outDir = resolve(opt('out', '.'));
const [width, height] = opt('size', '1280x720').split('x').map(Number);
const channel = opt('channel', undefined);
const noBuild = hasFlag('no-build');
const gap = opt('gap', undefined);
const voRaw = opt('voiceover', undefined);
const voiceover = hasFlag('voiceover') ? (voRaw && !voRaw.startsWith('--') ? voRaw : 'auto') : undefined;
const voice = opt('voice', undefined);
const voiceSpeed = opt('voice-speed', undefined);
const vocoderDir = opt('vocoder-dir', undefined);

// playwright preferred; playwright-core works when a system browser is used via --channel
const require = createRequire(join(process.cwd(), 'x.js'));
let chromium;
for (const pkg of ['playwright', 'playwright-core']) {
  try { ({ chromium } = require(pkg)); break; } catch { /* next */ }
}
if (!chromium) {
  console.error('need the playwright package: npm i playwright && npx playwright install chromium');
  console.error('low-memory machines: npm i playwright-core, install a system chromium, pass --channel chrome|chromium');
  process.exit(2);
}

const flow = (await import(pathToFileURL(resolve(flowPath)).href)).default;
const browser = await chromium.launch({ headless: true, ...(channel ? { channel } : {}) });
const videoDir = mkdtempSync(join(tmpdir(), 'pw-video-'));
const context = await browser.newContext({
  viewport: { width, height },
  recordVideo: { dir: videoDir, size: { width, height } },
});
const page = await context.newPage();

const log = [];
const api = {
  mark: (o) => log.push(Object.assign({ ms: Date.now() }, o)),
  log,
  navigate: (url) => page.goto(url, { waitUntil: 'load' }),
  evaluate: (fn, arg) => page.evaluate(fn, arg),
  hover: (t) => page.mouse.move(t.x, t.y),
  click: (t) => page.mouse.click(t.x, t.y),
  type: (sel, text, { mode } = {}) =>
    mode === 'replace'
      ? page.fill(sel, text)                       // fill replaces; nothing is logged for you
      : page.locator(sel).pressSequentially(text), // appends, real key events
  sleep: (ms) => new Promise((r) => setTimeout(r, ms)),
};

try {
  const returned = await flow(api);
  const events = Array.isArray(returned) ? returned : log;
  writeFileSync(join(outDir, 'events.json'), JSON.stringify(events, null, 1));
  const video = page.video();
  const videoPath = await video.path();
  await context.close(); // the webm is finalized only when the context closes
  renameSync(videoPath, join(outDir, 'run.webm'));
  console.log('wrote ' + join(outDir, 'run.webm') + ' and events.json (' + events.length + ' events)');
  if (noBuild) return;
  const builder = join(dirname(fileURLToPath(import.meta.url)), 'make_recording.pl');
  const evdir = join(outDir, 'evidence');
  const cmd = ['perl', builder,
    '--clip', join(outDir, 'run.webm') + ',' + join(outDir, 'events.json'),
    '--out', evdir, '--selfcheck'];
  if (gap !== undefined) cmd.push('--gap', gap);
  if (voiceover !== undefined) cmd.push('--voiceover=' + voiceover);
  if (voice !== undefined) cmd.push('--voice', voice);
  if (voiceSpeed !== undefined) cmd.push('--voice-speed', voiceSpeed);
  if (vocoderDir !== undefined) cmd.push('--vocoder-dir', vocoderDir);
  const rc = spawnSync(cmd[0], cmd.slice(1), { stdio: 'inherit' }).status;
  if (rc) {
    console.error('evidence build failed (exit ' + rc + ')');
    process.exit(rc);
  }
  console.log('evidence: ' + evdir);
} catch (e) {
  await context.close().catch(() => {});
  console.error('flow failed: ' + (e && e.message ? e.message : e));
  process.exit(1);
} finally {
  await browser.close();
}
