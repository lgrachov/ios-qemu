#!/usr/bin/env python3
"""Send touch and button input to a running qemu-sweet.py --ufs guest.

  qemu-touch.py RUN_DIR tap X Y
  qemu-touch.py RUN_DIR swipe X1 Y1 X2 Y2 [MS]
  qemu-touch.py RUN_DIR key power|home|volup|voldown [MS]   (Ctrl+Option+key)
  qemu-touch.py RUN_DIR type TEXT              (hardware keyboard, US layout)
  qemu-touch.py RUN_DIR unlock                 (swipe up from the bottom edge)
  qemu-touch.py RUN_DIR screenshot OUT.png

RUN_DIR is the qemu-sweet.py output directory (its QMP socket mon.sock).
X/Y are screen pixels as in the screenshots: 1125x2436 (harness.sh --ios uses
qemu-sweet.py --fullfb; set QEMU_TOUCH_PANEL=1080x2400 for the phone layout). Events go through QMP
input-send-event to the virtio-tablet/-keyboard that bsd/dev/sweet_vinput.c
(patch 0084, boot-arg sweetvinput=1) turns into SweetHID touch and buttons,
the same path as clicking in the QEMU window.
"""
import json, os, socket, sys, time

PANEL_W, PANEL_H = map(int, os.environ.get('QEMU_TOUCH_PANEL', '1125x2436').split('x'))
ABS_MAX = 0x7fff
KEYS = {'power': 'p', 'home': 'h', 'volup': 'up', 'voldown': 'down'}


class QMP:
    def __init__(self, path):
        self.s = socket.socket(socket.AF_UNIX)
        self.s.connect(path)
        self.f = self.s.makefile('rw')
        self.f.readline()
        self.call('qmp_capabilities')

    def call(self, execute, **args):
        self.f.write(json.dumps({'execute': execute, 'arguments': args}) + '\n')
        self.f.flush()
        while True:
            r = json.loads(self.f.readline())
            if 'error' in r:
                raise RuntimeError(f'{execute}: {r["error"]}')
            if 'return' in r:
                return r['return']

    def close(self):
        self.f.close()	# the makefile() handle keeps the socket open otherwise
        self.s.close()

    def events(self, *ev):
        self.call('input-send-event', events=list(ev))


def pos(x, y):
    ax = round(min(max(x, 0), PANEL_W - 1) * ABS_MAX / (PANEL_W - 1))
    ay = round(min(max(y, 0), PANEL_H - 1) * ABS_MAX / (PANEL_H - 1))
    return ({'type': 'abs', 'data': {'axis': 'x', 'value': ax}},
            {'type': 'abs', 'data': {'axis': 'y', 'value': ay}})


def btn(down):
    return {'type': 'btn', 'data': {'down': down, 'button': 'left'}}


def swipe(q, x1, y1, x2, y2, ms=300, steps=20):
    q.events(*pos(x1, y1), btn(True))
    for i in range(1, steps + 1):
        time.sleep(ms / 1000 / steps)
        q.events(*pos(x1 + (x2 - x1) * i / steps, y1 + (y2 - y1) * i / steps))
    q.events(btn(False))


def main():
    if len(sys.argv) < 3:
        sys.exit(__doc__)
    run, cmd, args = sys.argv[1], sys.argv[2], sys.argv[3:]
    q = QMP(os.path.join(run, 'mon.sock'))
    if cmd == 'tap':
        x, y = map(float, args[:2])
        q.events(*pos(x, y), btn(True))
        time.sleep(0.08)
        q.events(btn(False))
    elif cmd == 'swipe':
        x1, y1, x2, y2 = map(float, args[:4])
        swipe(q, x1, y1, x2, y2, float(args[4]) if len(args) > 4 else 300)
    elif cmd == 'unlock':
        swipe(q, PANEL_W / 2, PANEL_H - 10, PANEL_W / 2, PANEL_H * 0.35, 350)
    elif cmd == 'key':
        # buttons are Ctrl+Option(Alt)+key (patch 0089); bare keys are typing
        keys = [{'type': 'qcode', 'data': c} for c in ('ctrl', 'alt', KEYS[args[0]])]
        for k in keys:
            q.events({'type': 'key', 'data': {'down': True, 'key': k}})
        time.sleep((float(args[1]) if len(args) > 1 else 100) / 1000)
        for k in reversed(keys):
            q.events({'type': 'key', 'data': {'down': False, 'key': k}})
    elif cmd == 'type':
        # US layout: letters, digits, space and common punctuation
        shifted = dict(zip('~!@#$%^&*()_+{}|:"<>?', '`1234567890-=[]\\;\',./'))
        names = {' ': 'spc', '-': 'minus', '=': 'equal', '[': 'bracket_left', ']': 'bracket_right',
                 '\\': 'backslash', ';': 'semicolon', "'": 'apostrophe', '`': 'grave_accent',
                 ',': 'comma', '.': 'dot', '/': 'slash', '\n': 'ret'}
        for ch in ' '.join(args):
            base = shifted.get(ch, ch.lower())
            shift = ch in shifted or ch.isupper()
            code = {'type': 'qcode', 'data': names.get(base, base)}
            seq = ([{'type': 'qcode', 'data': 'shift'}] if shift else []) + [code]
            for k in seq:
                q.events({'type': 'key', 'data': {'down': True, 'key': k}})
            for k in reversed(seq):
                q.events({'type': 'key', 'data': {'down': False, 'key': k}})
            time.sleep(0.03)
    elif cmd == 'screenshot':
        # PNG: QEMU's PPM screendump shears odd widths (rows padded to 4 bytes)
        q.call('screendump', filename=os.path.abspath(args[0]), format='png')
    else:
        sys.exit(__doc__)
    q.close()


if __name__ == '__main__':
    main()
