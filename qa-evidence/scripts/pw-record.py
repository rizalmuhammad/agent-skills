#!/usr/bin/env python3
# pw-record.py - portable capture lane for browser-evidence-captions.
# Drives one chromium tab through Playwright, records its video, writes the two
# files make_recording.pl eats (run.webm + events.json) and then builds the
# evidence into OUT/evidence unless --no-build is given.
#
# usage: python3 pw-record.py FLOW.py [--out DIR] [--size 1280x720] [--channel chrome] [--no-build]
#
# FLOW.py defines one function run(api) that receives the api below and returns
# (or fills via api.mark) the event array described in references/recording.md.
#
#   def run(api):
#       api.navigate('https://example.test/start')
#       api.evaluate("() => document.title")
#       api.hover({'x': 100, 'y': 200}); api.click({'x': 100, 'y': 200})
#       api.type('#q', 'x')              # append, real key events
#       api.mark({'kind': 'step', 'status': 'PASS', 'text': '...'})

import argparse
import importlib.util
import json
import os
import shutil
import subprocess
import sys
import tempfile
import time


def now_ms():
    return int(time.time() * 1000)


class Api:
    def __init__(self, page):
        self.page = page
        self.log = []

    def mark(self, obj):
        self.log.append({'ms': now_ms(), **obj})

    def navigate(self, url):
        return self.page.goto(url, wait_until='load')

    def evaluate(self, js, arg=None):
        # js is a JavaScript string, same snippet the .mjs lane would run
        return self.page.evaluate(js, arg) if arg is not None else self.page.evaluate(js)

    def hover(self, t):
        return self.page.mouse.move(t['x'], t['y'])

    def click(self, t):
        return self.page.mouse.click(t['x'], t['y'])

    def type(self, sel, text, mode=None):
        if mode == 'replace':
            return self.page.fill(sel, text)            # fill replaces; nothing is logged for you
        return self.page.locator(sel).press_sequentially(text)  # appends, real key events

    def sleep(self, ms):
        time.sleep(ms / 1000)


def main():
    p = argparse.ArgumentParser(description='record one playwright tab and build captioned evidence')
    p.add_argument('flow', help='FLOW.py defining run(api)')
    p.add_argument('--out', default='.', help='where run.webm/events.json go; evidence lands in OUT/evidence')
    p.add_argument('--size', default='1280x720', help='viewport, kept as-is in the output (use even numbers)')
    p.add_argument('--channel', default=None, help='system browser channel, e.g. chrome or chromium')
    p.add_argument('--no-build', action='store_true', help='only capture; skip running make_recording.pl')
    p.add_argument('--gap', default=None, help='dead-air jump-cut length forwarded to the builder')
    p.add_argument('--voiceover', nargs='?', const='auto', default=None,
                   help='speak the steps over the mp4 (tiny-voca); optional script file, one line per step')
    p.add_argument('--voice', default=None, choices=['F2', 'M2'], help='narration voice')
    p.add_argument('--voice-speed', default=None, help='narration rate')
    p.add_argument('--vocoder-dir', default=None,
                   help='tiny-voca weights checkout (model.onnx + phonemizer/)')
    a = p.parse_args()
    if not a.flow.endswith('.py'):
        p.error('FLOW must be a .py file')
    width, height = (int(x) for x in a.size.split('x'))
    out_dir = os.path.abspath(a.out)
    os.makedirs(out_dir, exist_ok=True)

    try:
        from playwright.sync_api import sync_playwright
    except ImportError:
        sys.stderr.write(
            'need the playwright package: pip install playwright && python -m playwright install chromium\n'
            'low-memory machines: pip install playwright, skip playwright install, use a system chromium via --channel chrome|chromium\n')
        return 2

    spec = importlib.util.spec_from_file_location('flow', os.path.abspath(a.flow))
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    flow = getattr(mod, 'run', None)
    if not callable(flow):
        sys.stderr.write('flow file must define run(api)\n')
        return 2

    video_dir = tempfile.mkdtemp(prefix='pw-video-')
    browser = None
    try:
        with sync_playwright() as pw:
            kw = {'headless': True}
            if a.channel:
                kw['channel'] = a.channel
            browser = pw.chromium.launch(**kw)
            context = browser.new_context(
                viewport={'width': width, 'height': height},
                record_video_dir=video_dir,
                record_video_size={'width': width, 'height': height})
            page = context.new_page()
            api = Api(page)
            try:
                returned = flow(api)
                events = returned if isinstance(returned, list) else api.log
                with open(os.path.join(out_dir, 'events.json'), 'w') as f:
                    json.dump(events, f, indent=1)
                video_path = page.video.path()
                context.close()  # the webm is finalized only when the context closes
                shutil.move(video_path, os.path.join(out_dir, 'run.webm'))
                print('wrote %s and events.json (%d events)'
                      % (os.path.join(out_dir, 'run.webm'), len(events)))
                if a.no_build:
                    return 0
                builder = os.path.join(os.path.dirname(os.path.abspath(__file__)),
                                       'make_recording.pl')
                evdir = os.path.join(out_dir, 'evidence')
                cmd = ['perl', builder,
                       '--clip', os.path.join(out_dir, 'run.webm') + ',' + os.path.join(out_dir, 'events.json'),
                       '--out', evdir, '--selfcheck']
                if a.gap is not None:
                    cmd += ['--gap', a.gap]
                rc = subprocess.call(cmd)
                if rc != 0:
                    sys.stderr.write('evidence build failed (exit %d)\n' % rc)
                    return rc
                print('evidence: %s' % evdir)
                return 0
            except Exception as e:
                context.close()
                sys.stderr.write('flow failed: %s\n' % e)
                return 1
            finally:
                browser.close()
    except Exception as e:
        sys.stderr.write('record failed: %s\n' % e)
        return 1
    finally:
        shutil.rmtree(video_dir, ignore_errors=True)


if __name__ == '__main__':
    sys.exit(main())
