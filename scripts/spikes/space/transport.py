#!/usr/bin/python3
"""Standard-library-only T3 terminal probe. Never print auth responses or WebSocket URLs."""
import argparse
import base64
import hashlib
import json
import math
import os
from pathlib import Path
import queue
import shlex
import socket
import ssl
import struct
import subprocess
import threading
import time
import urllib.parse
import urllib.request
import uuid

SANDBOX = Path.home() / 'CandyWrapper-research/sandbox'


def http(base, path, token=None, body=None, content_type='application/json'):
    headers = {'x-t3-orchestration-protocol': '2'}
    if token:
        headers['Authorization'] = 'Bearer ' + token
    if body is not None:
        headers['Content-Type'] = content_type
    req = urllib.request.Request(base + '/' + path, data=body, headers=headers)
    with urllib.request.urlopen(req, timeout=20) as response:
        return json.load(response)


class WebSocket:
    """RFC 6455 text client; no negotiated compression. Mask in C via bytearray slices."""
    def __init__(self, url):
        u = urllib.parse.urlsplit(url)
        self.sock = socket.create_connection((u.hostname, u.port or (443 if u.scheme == 'wss' else 80)), timeout=30)
        self.sock.setsockopt(socket.IPPROTO_TCP, socket.TCP_NODELAY, 1)
        if u.scheme == 'wss':
            self.sock = ssl.create_default_context().wrap_socket(self.sock, server_hostname=u.hostname)
        key = base64.b64encode(os.urandom(16)).decode()
        request = ('GET %s HTTP/1.1\r\nHost: %s\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n'
                   'Sec-WebSocket-Key: %s\r\nSec-WebSocket-Version: 13\r\n\r\n') % (u.path + '?' + u.query, u.netloc, key)
        self.sock.sendall(request.encode())
        self.buffer = bytearray()
        while b'\r\n\r\n' not in self.buffer:
            self.buffer.extend(self.sock.recv(4096))
        headers, _, tail = self.buffer.partition(b'\r\n\r\n')
        assert headers.startswith(b'HTTP/1.1 101'), 'WebSocket upgrade failed'
        expected = base64.b64encode(hashlib.sha1((key + '258EAFA5-E914-47DA-95CA-C5AB0DC85B11').encode()).digest())
        assert expected.lower() in headers.lower()
        self.buffer = bytearray(tail)
        self.sock.settimeout(300)
        self.lock = threading.Lock()

    def exact(self, count):
        while len(self.buffer) < count:
            data = self.sock.recv(max(65536, count - len(self.buffer)))
            if not data:
                raise EOFError('WebSocket closed')
            self.buffer.extend(data)
        data = self.buffer[:count]
        del self.buffer[:count]
        return bytes(data)

    def send(self, value=None, opcode=1, raw=None):
        data = bytearray(raw if raw is not None else json.dumps(value, separators=(',', ':')).encode())
        n = len(data)
        header = bytes([0x80 | opcode])
        if n < 126:
            header += bytes([0x80 | n])
        elif n < 65536:
            header += bytes([0x80 | 126]) + struct.pack('>H', n)
        else:
            header += bytes([0x80 | 127]) + struct.pack('>Q', n)
        mask = os.urandom(4)
        for i in range(4):
            data[i::4] = data[i::4].translate(bytes(x ^ mask[i] for x in range(256)))
        with self.lock:
            self.sock.sendall(header + mask + data)

    def receive(self):
        result = bytearray()
        while True:
            first, second = self.exact(2)
            length = second & 127
            if length == 126:
                length = struct.unpack('>H', self.exact(2))[0]
            elif length == 127:
                length = struct.unpack('>Q', self.exact(8))[0]
            assert not second & 128
            data = self.exact(length)
            opcode = first & 15
            if opcode == 8:
                raise EOFError('server closed WebSocket')
            if opcode == 9:
                self.send(opcode=10, raw=data)
                continue
            if opcode == 10:
                continue
            result.extend(data)
            if first & 128:
                return json.loads(result)


class RPC:
    def __init__(self, ws):
        self.ws = ws
        self.counter = 0
        self.pending = {}
        self.events = queue.Queue()
        self.error = None
        self.stream_exits = {}
        threading.Thread(target=self.receive, daemon=True).start()

    def receive(self):
        try:
            while True:
                messages = self.ws.receive()
                for message in messages if isinstance(messages, list) else [messages]:
                    if message['_tag'] == 'Chunk':
                        for value in message['values']:
                            self.events.put(value)
                        self.ws.send({'_tag': 'Ack', 'requestId': message['requestId']})
                    elif message['_tag'] == 'Exit':
                        q = self.pending.get(message['requestId'])
                        if q:
                            q.put(message['exit'])
                        else:
                            self.stream_exits[message['requestId']] = message['exit']
        except Exception as error:
            self.error = type(error).__name__

    def request(self, tag, payload=None, stream=False):
        self.counter += 1
        rid = str(self.counter)
        q = queue.Queue()
        self.pending[rid] = q
        self.ws.send({'_tag': 'Request', 'id': rid, 'tag': tag, 'payload': payload or {}, 'headers': []})
        if stream:
            self.pending.pop(rid, None)
            return rid
        try:
            result = q.get(timeout=45)
        except queue.Empty:
            raise RuntimeError('RPC timeout: ' + tag + '; receiver: ' + str(self.error)) from None
        finally:
            self.pending.pop(rid, None)
        if result['_tag'] != 'Success':
            # Auth payloads are never included in exception output.
            raise RuntimeError('RPC failure: ' + tag + ': ' + json.dumps(result)[:350])
        return result.get('value')


class Peer:
    def __init__(self, rpc, terminal):
        self.rpc, self.terminal = rpc, terminal
        self.buffer = ''
        self.messages = queue.Queue()
        self.startup = queue.Queue()
        self.output_chars = 0
        self.stream_id = None
        self.running = True
        threading.Thread(target=self.receive, daemon=True).start()

    def receive(self):
        while self.running:
            try:
                event = self.rpc.events.get(timeout=1)
            except queue.Empty:
                continue
            if event.get('terminalId') != self.terminal['terminalId']:
                continue
            if event.get('type') == 'output':
                data = event['data']
                self.output_chars += len(data)
                self.buffer += data
                while '\n' in self.buffer:
                    line, self.buffer = self.buffer.split('\n', 1)
                    if line == 'CWS-READY 0-spike':
                        self.startup.put(True)
                    else:
                        try:
                            self.messages.put(json.loads(base64.b64decode(line, validate=True)))
                        except (ValueError, json.JSONDecodeError):
                            pass  # Only shell startup/prompt before exec may be plain text.

    def send(self, message):
        frame = base64.b64encode(json.dumps(message, separators=(',', ':')).encode()).decode() + '\n'
        for offset in range(0, len(frame), 65536):
            self.rpc.request('terminal.write', dict(self.terminal, data=frame[offset:offset + 65536]))
        return math.ceil(len(frame) / 65536), len(frame)

    def wait(self, op, count=1):
        result = []
        deadline = time.monotonic() + 60
        while len(result) < count:
            if self.stream_id in self.rpc.stream_exits and self.messages.empty():
                raise RuntimeError('terminal output stream ended after %d of %d frames' % (len(result), count))
            try:
                value = self.messages.get(timeout=0.5)
            except queue.Empty:
                if time.monotonic() >= deadline:
                    raise TimeoutError('terminal response timeout after %d of %d frames' % (len(result), count))
                continue
            assert value['op'] == op, 'unexpected frame ordering'
            result.append(value)
        return result


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--base', default='http://127.0.0.1:47393')
    parser.add_argument('--ws-base', default=None)
    parser.add_argument('--server-home', type=Path, required=True)
    parser.add_argument('--binary', type=Path, required=True)
    parser.add_argument('--work', type=Path, required=True)
    parser.add_argument('--label', required=True)
    parser.add_argument('--sizes', type=int, nargs='+', choices=[1, 5, 20], default=[1, 5, 20])
    parser.add_argument('--text-count', type=int, default=100)
    args = parser.parse_args()
    for folder in [args.work.resolve(), args.server_home.resolve()]:
        assert folder.is_relative_to(SANDBOX.resolve()), 'sandbox paths only'
    assert urllib.parse.urlsplit(args.base).hostname in ['127.0.0.1', 'localhost']
    args.work.mkdir(parents=True, exist_ok=True)
    # env -i semantics: no inherited live T3 service variables.
    clean = {'HOME': str(Path.home()), 'PATH': '/usr/bin:/bin', 'T3CODE_TELEMETRY_ENABLED': 'false'}
    output = subprocess.check_output([str(args.binary), 'auth', 'pairing', 'create', '--base-dir',
        str(args.server_home), '--label', 'Space spike', '--json'], env=clean, stderr=subprocess.DEVNULL).decode()
    code = json.loads(output[output.index('{'):output.rindex('}') + 1])['credential']
    body = urllib.parse.urlencode({'grant_type': 'urn:ietf:params:oauth:grant-type:token-exchange',
        'subject_token': code, 'subject_token_type': 'urn:t3:params:oauth:token-type:environment-bootstrap',
        'requested_token_type': 'urn:ietf:params:oauth:token-type:access_token', 'client_label': 'Space spike',
        'client_device_type': 'desktop', 'client_os': 'macOS'}).encode()
    token = http(args.base, 'oauth/token', body=body, content_type='application/x-www-form-urlencoded')['access_token']
    descriptor = http(args.base, '.well-known/t3/environment')
    link = http(args.base, 'api/connect/link-state', token)
    ticket = http(args.base, 'api/auth/websocket-ticket', token, body=b'')['ticket']
    wsbase = args.ws_base or args.base
    url = wsbase.replace('http', 'ws', 1) + '/ws?' + urllib.parse.urlencode({
        'orchestrationProtocol': '2', 'wsTicket': ticket, 'clientSurface': 'desktop',
        'clientAppVersion': '0.0.0-space-spike', 'connectionMethod': 'direct'})
    rpc = RPC(WebSocket(url))
    terminal = {'threadId': 'candywrapper-space', 'terminalId': 'space-spike-' + uuid.uuid4().hex[:8]}
    peer = Peer(rpc, terminal)
    results = {'label': args.label, 'serverVersion': descriptor['serverVersion'],
               'connectLinked': link['linked'], 'images': [], 'terminal': terminal}
    opened = False
    try:
        # Follow CandyWrapper's global terminal subscription, then open the hidden terminal.
        peer.stream_id = rpc.request('subscribeTerminalEvents', stream=True)
        snapshot = rpc.request('terminal.open', dict(terminal, cwd=str(args.work), cols=80, rows=24))
        opened = True
        (args.work / 'results.json').write_text(json.dumps(results, indent=2) + '\n')
        results['shellPID'] = snapshot['pid']
        host = Path(__file__).resolve().with_name('host.py')
        command = ' exec /usr/bin/python3 ' + shlex.quote(str(host)) + ' space-serve\n'
        rpc.request('terminal.write', dict(terminal, data=command))
        peer.startup.get(timeout=15)
        peer.send({'type': 'hello', 'op': 'hello'})
        hello = peer.wait('hello')[0]
        results['rawTTY'] = hello
        assert not hello['echo'] and not hello['canonical']
        samples = []
        for i in range(args.text_count + 1):
            start = time.perf_counter()
            peer.send({'type': 'push', 'op': str(i), 'ct': base64.b64encode(os.urandom(300)).decode()})
            peer.wait(str(i))
            if i:
                samples.append((time.perf_counter() - start) * 1000)
        if samples:
            results['text'] = {'n': len(samples), 'p50MS': sorted(samples)[math.ceil(len(samples) * .5) - 1],
                               'p95MS': sorted(samples)[math.ceil(len(samples) * .95) - 1],
                               'maxMS': max(samples), 'samplesMS': samples}
        else:
            results['text'] = {}
        print(json.dumps({'label': args.label, 'text': {k:v for k,v in results['text'].items() if k != 'samplesMS'}}), flush=True)
        fixture = args.work.parent / 'fixtures'
        for size in args.sizes:
            chunks = [p.read_bytes() for p in sorted(fixture.glob('image-%d-*.ct' % size), key=lambda p:int(p.stem.split('-')[-1]))]
            assert len(chunks) == size
            blob = uuid.uuid4().hex
            writes = wire_bytes = 0
            start = time.perf_counter()
            for n, data in enumerate(chunks):
                op = '%s-%d' % (blob, n)
                w, b = peer.send({'type': 'blob.put', 'op': op, 'id': blob, 'n': n,
                                 'last': n == size - 1, 'ct': base64.b64encode(data).decode()})
                writes += w
                wire_bytes += b
                ack = peer.wait(op)[0]
                assert ack['sha256'] == hashlib.sha256(data).hexdigest()
            upload = time.perf_counter() - start
            result = {'MiB': size, 'encryptedBytes': sum(map(len, chunks)), 'terminalWrites': writes,
                      'uploadFrameChars': wire_bytes, 'uploadSeconds': upload, 'uploadMiBps': size / upload}
            results['images'].append(result)
            print(json.dumps(dict(result, label=args.label, phase='upload')), flush=True)
            start = time.perf_counter()
            peer.send({'type': 'blob.get', 'op': blob, 'id': blob, 'chunks': len(chunks)})
            output_before = peer.output_chars
            try:
                frames = peer.wait(blob, len(chunks))
            except (RuntimeError, TimeoutError) as error:
                result.update({'downloadFailed': str(error), 'downloadElapsedSeconds': time.perf_counter() - start,
                               'downloadReceivedChars': peer.output_chars - output_before,
                               'streamExit': rpc.stream_exits.get(peer.stream_id)})
                print(json.dumps(dict(result, label=args.label)), flush=True)
                break
            for n, frame in enumerate(frames):
                assert frame['n'] == n and base64.b64decode(frame['ct']) == chunks[n]
            download = time.perf_counter() - start
            result.update({'downloadSeconds': download, 'downloadMiBps': size / download, 'sha256Matched': True})
            print(json.dumps(dict(result, label=args.label)), flush=True)
        time.sleep(1)  # Allow the server's 250 ms history flush to settle before measuring it.
        logs = list(args.server_home.rglob('*'))
        marker = base64.urlsafe_b64encode(terminal['terminalId'].encode()).decode().rstrip('=')
        history = [p for p in logs if p.is_file() and marker in p.name]
        assert len(history) == 1, 'expected exactly one probe history file'
        results['history'] = [{'bytes': p.stat().st_size, 'filename': p.name} for p in history]
        results['receivedOutputChars'] = peer.output_chars
        before = peer.output_chars
        time.sleep(2)
        results['idleOutputCharsIn2Seconds'] = peer.output_chars - before
    except Exception as error:
        results['error'] = type(error).__name__ + ': ' + str(error)
        raise
    finally:
        if opened:
            start = time.perf_counter()
            rpc.request('terminal.close', dict(terminal, deleteHistory=True))
            results['closeMS'] = (time.perf_counter() - start) * 1000
            time.sleep(0.5)
            results['historyRemoved'] = all(not p.exists() for p in locals().get('history', []))
            try:
                os.kill(results.get('rawTTY', {}).get('pid', snapshot['pid']), 0)
                results['peerExited'] = False
            except ProcessLookupError:
                results['peerExited'] = True
        peer.running = False
        rpc.ws.sock.close()
        (args.work / 'results.json').write_text(json.dumps(results, indent=2) + '\n')
    print(json.dumps({k: v for k, v in results.items() if k not in ['images', 'text', 'terminal']}), flush=True)


if __name__ == '__main__':
    main()
