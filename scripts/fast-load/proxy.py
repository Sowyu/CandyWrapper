#!/usr/bin/env python3
"""Loopback reverse proxy: 400 kbit/s aggregate per direction, 400 ms RTT.

Counts actual TCP payload, including compressed HTTP/WS bodies and framing. No
TLS, TCP/IP overhead or retransmissions. Header logs deliberately omit secrets.
"""
import argparse
import asyncio
import json
import time
from urllib.parse import urlsplit


class HeaderObserver:
    def __init__(self, emit, direction):
        self.emit, self.direction = emit, direction
        self.buffer = bytearray()
        self.remaining = 0
        self.chunked = False
        self.chunk_remaining = None
        self.upgraded = False

    def feed(self, data):
        if self.upgraded:
            return
        self.buffer.extend(data)
        while self.buffer:
            if self.remaining:
                count = min(self.remaining, len(self.buffer))
                del self.buffer[:count]
                self.remaining -= count
                continue
            if self.chunked:
                if self.chunk_remaining is None:
                    end = self.buffer.find(b"\r\n")
                    if end < 0:
                        return
                    self.chunk_remaining = int(self.buffer[:end].split(b";")[0], 16)
                    del self.buffer[:end + 2]
                    if self.chunk_remaining == 0:
                        self.chunked = False
                        self.remaining = 2
                        self.chunk_remaining = None
                        continue
                if len(self.buffer) < self.chunk_remaining + 2:
                    return
                del self.buffer[:self.chunk_remaining + 2]
                self.chunk_remaining = None
                continue
            end = self.buffer.find(b"\r\n\r\n")
            if end < 0:
                return
            lines = bytes(self.buffer[:end]).decode("latin1").split("\r\n")
            del self.buffer[:end + 4]
            headers = dict(line.split(":", 1) for line in lines[1:] if ":" in line)
            headers = {k.lower(): v.strip() for k, v in headers.items()}
            first = lines[0].split(" ")
            # Strip WS tickets, signed paths, authorization and cookies.
            summary = {k: v for k, v in headers.items() if k in {
                "accept-encoding", "content-encoding", "content-length",
                "transfer-encoding", "sec-websocket-extensions", "upgrade"}}
            summary["status" if first[0].startswith("HTTP") else "method"] = first[1] if first[0].startswith("HTTP") else first[0]
            if not first[0].startswith("HTTP"):
                summary["path"] = urlsplit(first[1]).path
            self.emit({"event": "headers", "direction": self.direction, **summary})
            if headers.get("upgrade", "").lower() == "websocket":
                self.upgraded = True
                self.buffer.clear()
                return
            self.remaining = int(headers.get("content-length", "0"))
            self.chunked = "chunked" in headers.get("transfer-encoding", "")


class Proxy:
    def __init__(self, port, target, log, kbps=400, rtt_ms=400):
        self.port, self.target, self.log = port, target, log
        self.rate, self.latency = kbps * 1000 / 8, rtt_ms / 2000
        self.next_slot = {"up": 0, "down": 0}
        self.total = {"up": 0, "down": 0}
        self.channels = {"http_up": 0, "http_down": 0, "socket_up": 0, "socket_down": 0}
        self.serial = 0
        self.server = None

    def emit(self, value):
        self.log.write(json.dumps({"time": time.monotonic(), **value}) + "\n")
        self.log.flush()

    async def start(self):
        self.server = await asyncio.start_server(self.handle, "127.0.0.1", self.port)
        self.control = await asyncio.start_server(self.mark, "127.0.0.1", self.port + 1000)
        self.emit({"event": "start", "port": self.port, "target": self.target,
                   "bytes_per_second_per_direction": self.rate, "one_way_seconds": self.latency})

    async def mark(self, reader, writer):
        # An unthrottled control endpoint snapshots delivered bytes even while
        # URLSession keeps an HTTP connection alive across benchmark phases.
        try:
            request = await reader.readuntil(b"\r\n\r\n")
            label = urlsplit(request.split(b" ")[1].decode()).path
            value = {"event": "mark", "label": label, **self.total, **self.channels}
            self.emit(value)
            body = json.dumps(value).encode()
            writer.write(b"HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nConnection: close\r\nContent-Length: " + str(len(body)).encode() + b"\r\n\r\n" + body)
            await writer.drain()
        finally:
            writer.close()

    async def handle(self, reader, writer):
        self.serial += 1
        serial = self.serial
        counts = {"up": 0, "down": 0}
        try:
            remote_reader, remote_writer = await asyncio.open_connection("127.0.0.1", self.target)
        except OSError:
            writer.close()
            return

        async def pump(source, destination, direction):
            queue = asyncio.Queue(maxsize=1024)
            observer = HeaderObserver(lambda value: self.emit({"connection": serial, **value}), direction)

            async def receive():
                try:
                    while True:
                        data = await source.read(1024)
                        if not data:
                            break
                        observer.feed(data)
                        await queue.put((time.monotonic() + self.latency, data, observer.upgraded))
                finally:
                    await queue.put((0, None, False))

            producer = asyncio.create_task(receive())
            try:
                while True:
                    due, data, socket = await queue.get()
                    if data is None:
                        break
                    finish = max(due, self.next_slot[direction]) + len(data) / self.rate
                    self.next_slot[direction] = finish
                    await asyncio.sleep(max(0, finish - time.monotonic()))
                    destination.write(data)
                    await destination.drain()
                    counts[direction] += len(data)
                    self.total[direction] += len(data)
                    self.channels[("socket_" if socket else "http_") + direction] += len(data)
            finally:
                producer.cancel()
                await asyncio.gather(producer, return_exceptions=True)

        pumps = [asyncio.create_task(pump(reader, remote_writer, "up")),
                 asyncio.create_task(pump(remote_reader, writer, "down"))]
        try:
            await asyncio.wait(pumps, return_when=asyncio.FIRST_COMPLETED)
        finally:
            for task in pumps:
                task.cancel()
            await asyncio.gather(*pumps, return_exceptions=True)
            writer.close()
            remote_writer.close()
            self.emit({"event": "closed", "connection": serial, **counts})


async def main(args):
    with open(args.log, "a", buffering=1) as log:
        proxy = Proxy(args.port, args.target, log, args.kbps, args.rtt_ms)
        await proxy.start()
        async with proxy.server:
            await proxy.server.serve_forever()


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--port", type=int, required=True)
    parser.add_argument("--target", type=int, required=True)
    parser.add_argument("--log", required=True)
    parser.add_argument("--kbps", type=float, default=400)
    parser.add_argument("--rtt-ms", type=float, default=400)
    asyncio.run(main(parser.parse_args()))
