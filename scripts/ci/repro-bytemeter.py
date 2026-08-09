#!/usr/bin/env python3
# SPDX-License-Identifier: AGPL-3.0-or-later
#
# Byte-counting TCP proxy + HTTP state endpoint for the zmx scrollback-reload
# repro (BUG A: keyboard toggle with preserve-size re-attaches and replays the
# entire scrollback; a full reload implies a NEW SSH TCP connection).
#
# Topology (all on the macOS runner, shared with the iOS simulator loopback):
#   app (simulator)  ->  127.0.0.1:22229  (this proxy)
#                     ->  127.0.0.1:22232  (repro sshd)
#
# The app's TerminalReconnectUITestHarness hardcodes the fixture SSH port
# 22229, so the proxy owns that port and forwards to the real sshd. It counts
# bytes in both directions per connection and records every connect/close as
# an event with a wall-clock timestamp, so phases can be attributed either
# live (HTTP) or post-hoc (log file).
#
# HTTP state on 127.0.0.1:22233:
#   GET  /state             -> JSON: {connections, upBytes, downBytes, marks,
#                                     connectionEvents:[...]}
#   GET  /mark?phase=NAME   -> records a snapshot {phase, ts, connections,
#                              upBytes, downBytes, openConnections} and returns
#                              it as JSON (idempotent; repeats replace).
#
# Env knobs (defaults match the repro rig):
#   VVTERM_BYTEMETER_PORT         listen port of the SSH proxy (22229)
#   VVTERM_BYTEMETER_TARGET_PORT  upstream sshd port (22232)
#   VVTERM_BYTEMETER_STATE_PORT   HTTP state port (22233)
import itertools
import json
import logging
import os
import socket
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

LISTEN_HOST = "127.0.0.1"
LISTEN_PORT = int(os.environ.get("VVTERM_BYTEMETER_PORT", "22229"))
TARGET_HOST = os.environ.get("VVTERM_BYTEMETER_TARGET_HOST", "127.0.0.1")
TARGET_PORT = int(os.environ.get("VVTERM_BYTEMETER_TARGET_PORT", "22232"))
STATE_PORT = int(os.environ.get("VVTERM_BYTEMETER_STATE_PORT", "22233"))
MAX_EVENTS = 100

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s %(levelname)s %(message)s",
    datefmt="%Y-%m-%dT%H:%M:%S",
)

state = {
    "connections": 0,      # connections opened since start
    "upBytes": 0,          # client -> server bytes since start
    "downBytes": 0,        # server -> client bytes since start
    "marks": [],           # [{phase, ts, connections, upBytes, downBytes}]
    "connectionEvents": [],  # [{n, openTs, closeTs, upBytes, downBytes}]
}
lock = threading.Lock()
conn_ids = itertools.count(1)
mark_index = {}


def snapshot(phase):
    with lock:
        return {
            "phase": phase,
            "ts": time.time(),
            "connections": state["connections"],
            "upBytes": state["upBytes"],
            "downBytes": state["downBytes"],
            "openConnections": sum(
                1 for ev in state["connectionEvents"] if ev.get("closeTs") is None
            ),
        }


def record_mark(phase):
    mark = snapshot(phase)
    with lock:
        if phase in mark_index:
            state["marks"][mark_index[phase]] = mark
        else:
            mark_index[phase] = len(state["marks"])
            state["marks"].append(mark)
        event = dict(mark)
        event["event"] = "mark"
    logging.info("MARK phase=%s connections=%d upBytes=%d downBytes=%d", phase,
                 event["connections"], event["upBytes"], event["downBytes"])
    return mark


class StateHandler(BaseHTTPRequestHandler):
    def log_message(self, fmt, *args):  # silence default per-request logging
        pass

    def _json(self, payload, code=200):
        body = json.dumps(payload).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self):
        if self.path.startswith("/mark"):
            import urllib.parse
            query = urllib.parse.urlparse(self.path).query
            phase = urllib.parse.parse_qs(query).get("phase", [""])[0]
            if not phase:
                self._json({"error": "missing phase"}, 400)
                return
            self._json(record_mark(phase))
            return
        if self.path.startswith("/state"):
            with lock:
                payload = {
                    "connections": state["connections"],
                    "upBytes": state["upBytes"],
                    "downBytes": state["downBytes"],
                    "marks": list(state["marks"]),
                    "connectionEvents": list(state["connectionEvents"]),
                }
            self._json(payload)
            return
        self._json({"error": "not found"}, 404)

    def do_POST(self):
        # /mark works with POST too (the UI test uses GET for simplicity).
        self.do_GET()


def pump(src, dst, direction, conn_id, counters):
    """Copy src -> dst, counting bytes into counters[direction]."""
    try:
        while True:
            data = src.recv(65536)
            if not data:
                break
            dst.sendall(data)
            with lock:
                state[direction] += len(data)
                for ev in state["connectionEvents"]:
                    if ev["n"] == conn_id:
                        ev[direction] = ev.get(direction, 0) + len(data)
                        break
            counters["log_count"] += 1
            if counters["log_count"] % 32 == 1:
                logging.info("DATA conn=%d dir=%s bytes=%d totalUp=%d totalDown=%d",
                             conn_id, direction, len(data),
                             state["upBytes"], state["downBytes"])
    except OSError:
        pass
    finally:
        try:
            dst.shutdown(socket.SHUT_WR)
        except OSError:
            pass


def handle_connection(client):
    conn_id = next(conn_ids)
    open_ts = time.time()
    with lock:
        state["connections"] += 1
        state["connectionEvents"].append({
            "n": conn_id, "openTs": open_ts, "closeTs": None,
            "upBytes": 0, "downBytes": 0,
        })
        if len(state["connectionEvents"]) > MAX_EVENTS:
            del state["connectionEvents"][0]
    logging.info("CONNECT conn=%d total=%d", conn_id, state["connections"])
    upstream = None
    try:
        upstream = socket.create_connection((TARGET_HOST, TARGET_PORT), timeout=10)
    except OSError as exc:
        logging.error("CONNECT conn=%d upstream %s:%d failed: %s",
                      conn_id, TARGET_HOST, TARGET_PORT, exc)
        client.close()
        with lock:
            for ev in state["connectionEvents"]:
                if ev["n"] == conn_id:
                    ev["closeTs"] = time.time()
                    break
        return

    counters = {"log_count": 0}
    up = threading.Thread(target=pump, args=(client, upstream, "upBytes", conn_id, counters), daemon=True)
    down = threading.Thread(target=pump, args=(upstream, client, "downBytes", conn_id, counters), daemon=True)
    up.start()
    down.start()
    up.join()
    down.join()
    close_ts = time.time()
    with lock:
        for ev in state["connectionEvents"]:
            if ev["n"] == conn_id:
                ev["closeTs"] = close_ts
                break
    logging.info("CLOSE conn=%d upBytes=%d downBytes=%d",
                 conn_id,
                 state["connectionEvents"][-1]["upBytes"],
                 state["connectionEvents"][-1]["downBytes"])
    client.close()
    upstream.close()


def serve_http():
    httpd = ThreadingHTTPServer((LISTEN_HOST, STATE_PORT), StateHandler)
    logging.info("HTTP state on %s:%d", LISTEN_HOST, STATE_PORT)
    httpd.serve_forever()


def main():
    logging.info("bytemeter starting: listen=%s:%d -> %s:%d state=%s:%d",
                 LISTEN_HOST, LISTEN_PORT, TARGET_HOST, TARGET_PORT,
                 LISTEN_HOST, STATE_PORT)
    threading.Thread(target=serve_http, daemon=True).start()
    with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as listener:
        listener.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        listener.bind((LISTEN_HOST, LISTEN_PORT))
        listener.listen(32)
        logging.info("SSH proxy listening on %s:%d", LISTEN_HOST, LISTEN_PORT)
        while True:
            client, _ = listener.accept()
            threading.Thread(target=handle_connection, args=(client,), daemon=True).start()


if __name__ == "__main__":
    main()
