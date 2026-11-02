"""Tuning Telemetry recorder.

Listens for UDP packets from the Tuning Telemetry BeamNG mod and writes them to a
session folder:

    sessions/<start time>/
        telemetry.jsonl   every frame, mark, reset, note (one JSON object per line)
        events.jsonl      everything except frames, for quick reading
        configs/          each distinct vehicle config (parts + tuning vars) seen
        meta/             each distinct vehicle metadata (wheels, dampers) seen

Every line gets "rt" (wall-clock receive time, seconds since the epoch).
While it runs, anything you type in this window and press Enter is saved as a
note attached to the latest mark.

Run:  py recorder.py            (defaults: 127.0.0.1:4445, ../sessions)
      py recorder.py --help
"""

import argparse
import hashlib
import json
import socket
import sys
import threading
import time
from datetime import datetime
from pathlib import Path

DEFAULT_PORT = 4445


class Session:
    def __init__(self, root: Path):
        self.dir = root / datetime.now().strftime("%Y-%m-%d_%H%M%S")
        (self.dir / "configs").mkdir(parents=True)
        (self.dir / "meta").mkdir()
        self.telemetry = open(self.dir / "telemetry.jsonl", "a", encoding="utf-8")
        self.events = open(self.dir / "events.jsonl", "a", encoding="utf-8")
        self.lock = threading.Lock()
        self.seen = {}  # kind -> set of hashes already written
        self.frames = 0
        self.marks = 0
        self.last_mark = None
        self.last_frame = None
        self.model = None

    def write(self, msg: dict):
        line = json.dumps(msg, separators=(",", ":"))
        with self.lock:
            self.telemetry.write(line + "\n")
            if msg.get("type") != "frame":
                self.events.write(line + "\n")
                self.events.flush()

    def snapshot(self, kind: str, msg: dict) -> bool:
        """Store a config/meta snapshot once per distinct content. Returns True if new."""
        body = {k: v for k, v in msg.items() if k != "rt"}
        digest = hashlib.sha1(json.dumps(body, sort_keys=True).encode()).hexdigest()[:10]
        seen = self.seen.setdefault(kind, set())
        if digest in seen:
            return False
        seen.add(digest)
        name = f"{datetime.now().strftime('%H%M%S')}_{digest}.json"
        (self.dir / kind / name).write_text(json.dumps(body, indent=2), encoding="utf-8")
        self.write({"type": f"{msg['type']}Snapshot", "rt": msg.get("rt"), "vid": msg.get("vid"), "file": f"{kind}/{name}"})
        return True

    def flush(self):
        with self.lock:
            self.telemetry.flush()

    def close(self):
        with self.lock:
            self.telemetry.close()
            self.events.close()


class Chunks:
    """Reassembles messages the mod split across several UDP packets."""

    def __init__(self):
        self.pending = {}

    def add(self, msg: dict):
        parts = self.pending.setdefault(msg["id"], {})
        parts[msg["i"]] = msg["data"]
        if len(parts) == msg["of"]:
            del self.pending[msg["id"]]
            return json.loads("".join(parts[i] for i in range(1, msg["of"] + 1)))
        return None


def handle(session: Session, chunks: Chunks, msg: dict):
    rt = round(time.time(), 3)
    if msg.get("type") == "chunk":
        msg = chunks.add(msg)
        if msg is None:
            return
    msg["rt"] = rt
    kind = msg.get("type")

    if kind == "frame":
        session.frames += 1
        session.last_frame = msg
        session.write(msg)
    elif kind == "config":
        if session.snapshot("configs", msg):
            session.model = msg.get("model")
            vars_count = len(msg.get("vars") or {})
            where = f"{msg['career']} career, save {msg.get('saveSlot')}, inventory {msg.get('inventoryId')}" if msg.get("career") else "not in career"
            print(f"[config] {msg.get('model')} (vehicle {msg.get('vid')}, {where}), "
                  f"{len(msg.get('parts') or {})} parts, {vars_count} tuning vars")
    elif kind == "meta":
        if session.snapshot("meta", msg):
            dampers = msg.get("dampers") or []
            corners = ", ".join(sorted({d.get("corner") or "?" for d in dampers})) or "none found"
            print(f"[meta] {msg.get('vehicle')}: {len(msg.get('wheels') or [])} wheels, "
                  f"{len(dampers)} dampers ({corners})")
    elif kind == "mark":
        session.marks += 1
        session.last_mark = msg
        session.write(msg)
        f = session.last_frame or {}
        print(f"[MARK {msg.get('n')}] t={msg.get('t')}s  speed={f.get('spd', '?')} m/s  gear={f.get('gear', '?')}  "
              f"rpm={f.get('rpm', '?')}  -- type a description and press Enter (optional)")
    else:
        session.write(msg)


def read_notes(session: Session):
    for line in sys.stdin:
        text = line.strip()
        if not text:
            continue
        mark = session.last_mark or {}
        session.write({"type": "note", "rt": round(time.time(), 3), "mark": mark.get("n"), "t": mark.get("t"), "text": text})
        print(f"[note saved{' for mark ' + str(mark['n']) if mark else ''}]")


def main():
    sys.stdout.reconfigure(line_buffering=True)
    here = Path(__file__).resolve().parent
    ap = argparse.ArgumentParser(description="Record Tuning Telemetry from BeamNG.")
    ap.add_argument("--host", default="127.0.0.1")
    ap.add_argument("--port", type=int, default=DEFAULT_PORT)
    ap.add_argument("--out", type=Path, default=here.parent / "sessions")
    args = ap.parse_args()

    sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    sock.setsockopt(socket.SOL_SOCKET, socket.SO_RCVBUF, 4 * 1024 * 1024)
    sock.bind((args.host, args.port))
    sock.settimeout(1.0)

    session = Session(args.out)
    chunks = Chunks()
    print(f"Recording to {session.dir}")
    print(f"Listening on {args.host}:{args.port}. Ctrl+C to stop.")
    threading.Thread(target=read_notes, args=(session,), daemon=True).start()

    last_status = last_flush = time.time()
    last_frames = 0
    try:
        while True:
            try:
                data, _ = sock.recvfrom(65535)
                handle(session, chunks, json.loads(data))
            except socket.timeout:
                pass
            except (json.JSONDecodeError, KeyError, TypeError) as e:
                print(f"[warn] bad packet: {e}")

            now = time.time()
            if now - last_flush >= 1:
                session.flush()  # closing the window kills the process; lose at most a second
                last_flush = now
            if now - last_status >= 10:
                rate = (session.frames - last_frames) / (now - last_status)
                state = f"{rate:.0f} frames/s" if rate else "waiting for BeamNG (drive the car)"
                print(f"[status] {state}, {session.frames} frames, {session.marks} marks")
                last_status, last_frames = now, session.frames
    except KeyboardInterrupt:
        pass
    finally:
        session.close()
        print(f"Stopped. {session.frames} frames, {session.marks} marks saved in {session.dir}")


if __name__ == "__main__":
    main()
