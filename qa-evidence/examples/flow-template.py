# flow-template.py - fill-in-the-blank flow for scripts/pw-record.py.
# Copy this file, replace the URL/selectors/captions, run:
#   python3 scripts/pw-record.py flow-template.py --out run
# The evidence lands in run/evidence/. Delete the steps you don't need;
# keep the sync flash and the per-character typing.

def run(api):
    # 1. sync flash - mandatory. The builder finds this frame and anchors
    #    every event timestamp to it.
    api.evaluate(
        "() => { const d = document.createElement('div'); d.id = '__syncflash';"
        " d.style.cssText = 'position:fixed;inset:0;background:#ff00cc;"
        "z-index:2147483647;pointer-events:none';"
        " document.documentElement.appendChild(d); return true; }")
    api.mark({'kind': 'sync'})
    api.sleep(300)
    api.evaluate("() => { const d = document.getElementById('__syncflash');"
                 " if (d) d.remove(); return true; }")
    api.sleep(150)

    # 2. open the page under test
    api.navigate('https://example.test/start')
    api.sleep(800)

    def box(sel):
        return api.evaluate(
            "(() => { const b = document.querySelector('%s').getBoundingClientRect();"
            " return { l: b.x, t: b.y, w: b.width, h: b.height }; })()" % sel)

    def center(b):
        return {'x': round(b['l'] + b['w'] / 2), 'y': round(b['t'] + b['h'] / 2)}

    def glide(target, steps=8, per_ms=60):
        # real pointer travel so the drawn cursor glides instead of teleporting
        for i in range(1, steps + 1):
            t = i / steps
            e = 2 * t * t if t < 0.5 else 1 - (-2 * t + 2) ** 2 / 2
            x = round(from_xy['x'] + (target['x'] - from_xy['x']) * e)
            y = round(from_xy['y'] + (target['y'] - from_xy['y']) * e)
            api.hover({'x': x, 'y': y})
            api.mark({'kind': 'move', 'x': x, 'y': y})
            api.sleep(per_ms)

    from_xy = {'x': 640, 'y': 660}

    # 3. step 1: click a field - read its box right before you act
    api.mark({'kind': 'step', 'status': 'PASS',
              'text': 'open the start page; the form is empty'})
    api.sleep(600)
    field = box('#q')
    glide(center(field))
    api.click(center(field))
    f = box('#q')   # re-read: layout may have shifted on focus
    api.mark({'kind': 'click', 'x': round(f['l'] + f['w'] / 2),
              'y': round(f['t'] + f['h'] / 2),
              'l': f['l'], 't': f['t'], 'w': f['w'], 'h': f['h'],
              'label': 'Search field'})
    api.sleep(400)
    api.mark({'kind': 'step', 'status': 'PASS',
              'text': 'click the search field; it takes focus'})
    api.sleep(500)

    # 4. step 2: type - one real keystroke per character, one event each
    for ch in 'hello':
        api.type('#q', ch)          # append is the default; real key events
        f = box('#q')
        api.mark({'kind': 'type', 'l': f['l'], 't': f['t'], 'w': f['w'], 'h': f['h']})
        api.sleep(140)
    typed = api.evaluate("() => document.getElementById('q').value")
    status = 'PASS' if typed == 'hello' else 'FAIL'
    api.mark({'kind': 'step', 'status': status,
              'text': 'type hello; the field reads %s' % typed})
    api.sleep(500)

    # 5. step 3: submit, prove the result from the page, highlight it
    go = box('#go')
    glide(center(go))
    api.click(center(go))
    g = box('#go')
    api.mark({'kind': 'click', 'x': round(g['l'] + g['w'] / 2),
              'y': round(g['t'] + g['h'] / 2),
              'l': g['l'], 't': g['t'], 'w': g['w'], 'h': g['h'],
              'label': 'Search button'})
    api.sleep(700)
    res = api.evaluate(
        "() => { const el = document.querySelector('#result');"
        " return { text: el.textContent, on: el.classList.contains('on') }; }")
    h = box('#result h1')
    api.mark({'kind': 'hl', 'l': h['l'], 't': h['t'], 'w': h['w'], 'h': h['h']})
    status = 'PASS' if res['on'] and 'hello' in res['text'] else 'FAIL'
    api.mark({'kind': 'step', 'status': status,
              'text': 'click Search; the panel shows %s' % res['text']})
    api.sleep(1000)

    # events come from api.mark() - no return needed
