#!/usr/bin/env python3
"""TCP proxy: login 127.0.0.1:<port> → compute Jupyter <host>:<port>.

Used by start_jupyter_slurm.bash so Remote-SSH can use
http://localhost:<port>/lab?token=... (compute DNS is not visible on laptops).
"""
from __future__ import annotations

import argparse
import json
import os
import select
import socket
import threading
from pathlib import Path


def pipe(a: socket.socket, b: socket.socket) -> None:
    try:
        while True:
            readable, _, _ = select.select([a, b], [], [])
            for s in readable:
                data = s.recv(65536)
                if not data:
                    return
                (b if s is a else a).sendall(data)
    except Exception:
        pass
    finally:
        for s in (a, b):
            try:
                s.close()
            except Exception:
                pass


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--conn", required=True, help="Path to jupyter_*.json connection file")
    ap.add_argument("--pid-file", required=True)
    args = ap.parse_args()

    info = json.loads(Path(args.conn).read_text())
    host = info["host"]
    port = int(info["port"])
    listen = ("127.0.0.1", port)
    remote = (host, port)

    pid_path = Path(args.pid_file)
    if pid_path.is_file():
        try:
            os.kill(int(pid_path.read_text().strip()), 9)
        except Exception:
            pass

    srv = socket.socket()
    srv.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    srv.bind(listen)
    srv.listen(50)
    pid_path.write_text(f"{os.getpid()}\n")
    print(f"proxy {listen[0]}:{listen[1]} -> {remote[0]}:{remote[1]}", flush=True)

    while True:
        client, _ = srv.accept()
        upstream = socket.create_connection(remote)
        threading.Thread(target=pipe, args=(client, upstream), daemon=True).start()


if __name__ == "__main__":
    raise SystemExit(main())
