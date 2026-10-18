#!/usr/bin/env python3
"""TCP relay that severs a connection after a fixed number of bytes.

Killing a server after `sleep 0.2` is a race: on a fast machine the transfer is
already finished, on a slow one it has not started. Counting bytes is not a race,
so "the network dropped mid-transfer" becomes a deterministic scenario instead of
a flaky one.

Only the server-to-client direction is budgeted: that is the direction that
carries file contents. The client-to-server direction is relayed untouched, so
the protocol handshake always completes before the cut.

    tcp_proxy.py --listen-port 4000 --target-port 3690 --cut-after 65536

`--cut-after 0` relays without ever cutting, which lets one scenario reuse the
same endpoint before and after the fault.
"""

from __future__ import annotations

import argparse
import socket
import sys
import threading

CHUNK = 65536


def log(message: str) -> None:
    print(message, flush=True)


def handle(client: socket.socket, args: argparse.Namespace, budget: dict, lock: threading.Lock) -> None:
    try:
        upstream = socket.create_connection((args.target_host, args.target_port), timeout=10)
    except OSError as error:
        log(f"proxy: cannot reach target: {error}")
        client.close()
        return

    def relay(source: socket.socket, destination: socket.socket, metered: bool) -> None:
        try:
            while True:
                data = source.recv(CHUNK)
                if not data:
                    break

                if not metered or budget["left"] is None:
                    destination.sendall(data)
                    continue

                with lock:
                    allowed = budget["left"]
                    if allowed <= 0:
                        break
                    payload = data[:allowed]
                    budget["left"] = allowed - len(payload)
                    exhausted = budget["left"] <= 0

                destination.sendall(payload)
                if exhausted:
                    log("proxy: byte budget exhausted, cutting the connection")
                    break
        except OSError:
            pass
        finally:
            for sock in (source, destination):
                # Reset rather than a polite FIN: a clean EOF reads as "the
                # server finished", which is not the fault being simulated.
                try:
                    sock.setsockopt(socket.SOL_SOCKET, socket.SO_LINGER, b"\x01\x00\x00\x00\x00\x00\x00\x00")
                except OSError:
                    pass
                try:
                    sock.shutdown(socket.SHUT_RDWR)
                except OSError:
                    pass
                try:
                    sock.close()
                except OSError:
                    pass

    to_server = threading.Thread(target=relay, args=(client, upstream, False), daemon=True)
    to_client = threading.Thread(target=relay, args=(upstream, client, True), daemon=True)
    to_server.start()
    to_client.start()
    to_server.join()
    to_client.join()


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--listen-host", default="127.0.0.1")
    parser.add_argument("--listen-port", type=int, required=True)
    parser.add_argument("--target-host", default="127.0.0.1")
    parser.add_argument("--target-port", type=int, required=True)
    parser.add_argument(
        "--cut-after",
        type=int,
        default=0,
        help="bytes forwarded server->client before the connection is reset; 0 never cuts",
    )
    args = parser.parse_args()

    budget = {"left": args.cut_after if args.cut_after > 0 else None}
    lock = threading.Lock()

    listener = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    listener.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    listener.bind((args.listen_host, args.listen_port))
    listener.listen(16)
    log(f"proxy listening on {args.listen_host}:{args.listen_port} -> "
        f"{args.target_host}:{args.target_port} (cut-after={args.cut_after})")

    try:
        while True:
            client, _ = listener.accept()
            threading.Thread(target=handle, args=(client, args, budget, lock), daemon=True).start()
    except KeyboardInterrupt:
        return 0
    finally:
        listener.close()


if __name__ == "__main__":
    sys.exit(main())
