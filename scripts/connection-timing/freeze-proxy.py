#!/usr/bin/python3
"""TCP proxy for the connection timing harness.

freeze-proxy.py <listen-port> <target-port> <control-file>

Forwards 127.0.0.1:<listen-port> to 127.0.0.1:<target-port>. Writing "freeze" to the control file stops
forwarding on every open connection without closing it, the way a dead Wi-Fi or a sleeping host leaves a
half-open socket. New connections still forward, so a client that reconnects gets through. Writing "open"
does nothing to frozen connections; they stay frozen until the client gives up on them.
"""
import asyncio, os, sys

listen_port, target_port, control = int(sys.argv[1]), int(sys.argv[2]), sys.argv[3]
connections = []  # [frozen flag holder]


async def pipe(reader, writer, state):
    try:
        while True:
            data = await reader.read(65536)
            if not data:
                break
            while state["frozen"]:
                await asyncio.sleep(3600)
            writer.write(data)
            await writer.drain()
    except Exception:
        pass
    finally:
        if not state["frozen"]:
            try:
                writer.close()
            except Exception:
                pass


async def handle(client_reader, client_writer):
    try:
        server_reader, server_writer = await asyncio.open_connection("127.0.0.1", target_port)
    except Exception:
        client_writer.close()
        return
    state = {"frozen": False}
    connections.append(state)
    await asyncio.gather(pipe(client_reader, server_writer, state), pipe(server_reader, client_writer, state))


async def watch_control():
    last = None
    while True:
        try:
            with open(control) as f:
                command = f.read().strip()
        except FileNotFoundError:
            command = ""
        if command != last:
            last = command
            if command == "freeze":
                for state in connections:
                    state["frozen"] = True
                print("froze", len(connections), "connections", flush=True)
        await asyncio.sleep(0.05)


async def main():
    server = await asyncio.start_server(handle, "127.0.0.1", listen_port)
    print("proxy", listen_port, "->", target_port, "pid", os.getpid(), flush=True)
    await asyncio.gather(server.serve_forever(), watch_control())


asyncio.run(main())
