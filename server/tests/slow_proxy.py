"""A bad line, for testing: a TCP proxy that makes everything through it late,
narrow and now and then silent. HTTP and the WebSocket both go through it.

  server/.venv/bin/python server/tests/slow_proxy.py LISTEN_PORT UPSTREAM_PORT \\
      [--delay MS] [--jitter MS] [--kbps N] [--handshake RTTS] [--stall EVERY_S,FOR_S]

--delay is one way (a 300 ms delay is a 600 ms round trip). --handshake holds
each new connection's first bytes for that many more round trips: the TCP and
TLS setup a real line pays (3 for HTTPS) and a local proxy does not.
--stall freezes everything FOR_S seconds every EVERY_S.
game/tools/flow_shots.py runs its clients through one with FLOW_SLOW="--delay 300 ...".
"""
import argparse
import asyncio
import random
import time


async def pump(reader, writer, a, first_hold):
    """Passes bytes on in order, each chunk `delay` (+ jitter) late, no faster
    than --kbps, and not at all during a stall."""
    due = 0.0
    hold = first_hold
    try:
        while data := await reader.read(16384):
            now = time.monotonic()
            due = max(due, now + a.delay / 1000 + random.uniform(0, a.jitter / 1000) + hold)
            hold = 0.0
            if a.kbps:
                due += len(data) * 8 / (a.kbps * 1000)
            if a.stall:
                every, length = a.stall
                into = due % every
                if into < length:
                    due += length - into
            await asyncio.sleep(max(0.0, due - time.monotonic()))
            writer.write(data)
            await writer.drain()
    except (ConnectionError, asyncio.CancelledError):
        pass
    finally:
        writer.close()


async def main():
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument("listen", type=int)
    p.add_argument("upstream", type=int)
    p.add_argument("--delay", type=float, default=0)
    p.add_argument("--jitter", type=float, default=0)
    p.add_argument("--kbps", type=float, default=0)
    p.add_argument("--handshake", type=float, default=0)
    p.add_argument("--stall", type=lambda v: tuple(float(x) for x in v.split(",")), default=None)
    a = p.parse_args()

    async def serve(reader, writer):
        try:
            up_reader, up_writer = await asyncio.open_connection("127.0.0.1", a.upstream)
        except OSError:
            writer.close()
            return
        await asyncio.gather(pump(reader, up_writer, a, a.handshake * 2 * a.delay / 1000), pump(up_reader, writer, a, 0.0))

    server = await asyncio.start_server(serve, "127.0.0.1", a.listen)
    async with server:
        await server.serve_forever()


if __name__ == "__main__":
    asyncio.run(main())
