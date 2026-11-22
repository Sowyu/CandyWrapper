#!/usr/bin/python3
"""TCP proxy that adds a round trip and a bandwidth cap, for timing the app over a remote-like link on loopback.

latency-proxy.py <listen-port> <target-port> <rtt-ms> <mbit/s> [log-file]

Each direction delays every chunk by half the round trip and queues it behind earlier chunks at the given rate, so
a request costs one round trip plus its transfer time and TCP connections cost a handshake round trip on top
(the delay applies to the first bytes after accept). With a log file it writes one line per connection when it
closes: its index, open time, bytes each way and lifetime, so a run counts its connections and bytes.
"""
import asyncio, sys, time

listen_port, target_port = int(sys.argv[1]), int(sys.argv[2])
one_way = float(sys.argv[3]) / 2000
rate = float(sys.argv[4]) * 1_000_000 / 8
log_path = sys.argv[5] if len(sys.argv) > 5 else None
start = time.monotonic()
count = 0


async def pipe(reader, writer, stats, key):
    queue = asyncio.Queue()
    busy = [0.0]

    async def deliver():
        while True:
            at, data = await queue.get()
            if data is None:
                break
            wait = at - time.monotonic()
            if wait > 0:
                await asyncio.sleep(wait)
            writer.write(data)
            await writer.drain()
        try:
            writer.close()
        except Exception:
            pass

    task = asyncio.ensure_future(deliver())
    try:
        while True:
            data = await reader.read(65536)
            if not data:
                break
            stats[key] += len(data)
            now = time.monotonic()
            busy[0] = max(busy[0], now) + len(data) / rate
            queue.put_nowait((max(now + one_way, busy[0] + one_way), data))
    except Exception:
        pass
    queue.put_nowait((0, None))
    try:
        await task
    except Exception:
        pass


async def handle(client_reader, client_writer):
    global count
    count += 1
    index, opened = count, time.monotonic()
    # The handshake's round trip.
    await asyncio.sleep(one_way * 2)
    try:
        server_reader, server_writer = await asyncio.open_connection("127.0.0.1", target_port)
    except Exception:
        client_writer.close()
        return
    stats = {"up": 0, "down": 0}
    await asyncio.gather(pipe(client_reader, server_writer, stats, "up"), pipe(server_reader, client_writer, stats, "down"))
    if log_path:
        with open(log_path, "a") as f:
            f.write(f"conn {index} opened {1000 * (opened - start):.0f}ms up {stats['up']} down {stats['down']} "
                    f"lived {1000 * (time.monotonic() - opened):.0f}ms\n")


async def main():
    server = await asyncio.start_server(handle, "127.0.0.1", listen_port)
    async with server:
        await server.serve_forever()


asyncio.run(main())
