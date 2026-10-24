#!/usr/bin/python3
"""Throwaway space-serve wire peer. It stores only synthetic ciphertext in its cwd."""
import base64
import hashlib
import json
import os
import signal
import sys
import termios
import tty
from pathlib import Path

assert sys.argv[1:] == ['space-serve']
assert str(Path.cwd()).startswith(str(Path.home() / 'CandyWrapper-research/sandbox/'))
old = termios.tcgetattr(0)
tty.setraw(0)
# Python normally ignores SIGHUP; let terminal.close stop this exact peer.
signal.signal(signal.SIGHUP, signal.SIG_DFL)


def send(value):
    data = base64.b64encode(json.dumps(value, separators=(',', ':')).encode()) + b'\n'
    while data:
        n = os.write(1, data)
        data = data[n:]


try:
    os.write(1, b'CWS-READY 0-spike\n')
    buf = bytearray()
    while True:
        part = os.read(0, 65536)
        if not part:
            break
        buf.extend(part)
        while b'\n' in buf:
            line, _, tail = buf.partition(b'\n')
            buf = bytearray(tail)
            message = json.loads(base64.b64decode(line, validate=True))
            op = message['op']
            if message['type'] == 'hello':
                flags = termios.tcgetattr(0)
                send({'op': op, 'type': 'hello', 'pid': os.getpid(),
                      'echo': bool(flags[3] & termios.ECHO),
                      'canonical': bool(flags[3] & termios.ICANON)})
            elif message['type'] == 'push':
                with open('log.jsonl', 'ab') as f:
                    f.write(line + b'\n')
                    f.flush()
                    os.fsync(f.fileno())
                send({'op': op, 'type': 'ack'})
            elif message['type'] == 'blob.put':
                # The host never holds the encryption key or parses the image.
                data = base64.b64decode(message['ct'], validate=True)
                name = 'blob-%s-%d' % (message['id'], message['n'])
                assert all(c in '0123456789abcdef-' for c in message['id'])
                with open(name, 'wb') as f:
                    f.write(data)
                    f.flush()
                    os.fsync(f.fileno())
                send({'op': op, 'type': 'ack', 'sha256': hashlib.sha256(data).hexdigest()})
            elif message['type'] == 'blob.get':
                for n in range(message['chunks']):
                    data = Path('blob-%s-%d' % (message['id'], n)).read_bytes()
                    send({'op': op, 'type': 'blob', 'n': n, 'last': n == message['chunks'] - 1,
                          'ct': base64.b64encode(data).decode()})
            else:
                raise ValueError('unknown message')
finally:
    termios.tcsetattr(0, termios.TCSANOW, old)
