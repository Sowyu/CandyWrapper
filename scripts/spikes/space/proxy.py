#!/usr/bin/python3
"""Sandbox-only TCP link model: pipelined latency plus a per-direction rate ceiling.

It is a substitute measurement, not T3 Connect or an Internet measurement.
"""
import argparse
import asyncio
import time


async def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--port', type=int, default=47394)
    parser.add_argument('--target', type=int, default=47393)
    parser.add_argument('--rtt-ms', type=float, default=100)
    parser.add_argument('--mbps', type=float, default=10)
    args = parser.parse_args()

    async def connect(reader, writer):
        upstream_reader, upstream_writer = await asyncio.open_connection('127.0.0.1', args.target)
        for w in [writer, upstream_writer]:
            import socket
            w.get_extra_info('socket').setsockopt(socket.IPPROTO_TCP, socket.TCP_NODELAY, 1)

        async def pipe(source, destination):
            scheduled = time.monotonic()
            pending = asyncio.Queue()

            async def read():
                nonlocal scheduled
                while True:
                    data = await source.read(65536)
                    if not data:
                        await pending.put(None)
                        return
                    # Serialization time and propagation time overlap between successive chunks.
                    scheduled = max(scheduled, time.monotonic() + args.rtt_ms / 2000) + len(data) / (args.mbps * 1e6 / 8)
                    await pending.put((scheduled, data))

            async def write():
                while True:
                    item = await pending.get()
                    if item is None:
                        destination.close()
                        return
                    at, data = item
                    await asyncio.sleep(max(0, at - time.monotonic()))
                    destination.write(data)
                    await destination.drain()

            await asyncio.gather(read(), write())
        try:
            await asyncio.gather(pipe(reader, upstream_writer), pipe(upstream_reader, writer))
        finally:
            writer.close()
            upstream_writer.close()

    server = await asyncio.start_server(connect, '127.0.0.1', args.port)
    print('Loopback proxy: %.0f ms modeled RTT, %.1f Mbps each direction' % (args.rtt_ms, args.mbps), flush=True)
    async with server:
        await server.serve_forever()


asyncio.run(main())
