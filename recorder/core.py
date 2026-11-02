"""Tuning Telemetry recorder engine, shared by the console (recorder.py) and the
window (recorder_gui.py).

Listens for UDP packets from the Tuning Telemetry BeamNG mod and writes them to a
session folder:

    sessions/<start time>/
        telemetry.jsonl   every frame, mark, reset, note (one JSON object per line)
        events.jsonl      everything except frames, for quick reading
        configs/          each distinct vehicle config (parts + tuning vars) seen
        meta/             each distinct vehicle metadata (wheels, dampers) seen

Every line gets "rt" (wall-clock receive time, seconds since the epoch).
Commands (driving mode, mark) go back to the game on the control port.
"""

import hashlib
import json
import socket
import threading
import time
from datetime import datetime
from pathlib import Path

DEFAULT_PORT = 4445
DEFAULT_CONTROL_PORT = 4446
MODE_REPEAT = 2  # seconds; the game forgets the mode when it restarts

# Must match the modes in mod/lua/vehicle/extensions/tuningTelemetry/stream.lua
MODES = [
    ("all", "Everything", "Every field at 50 Hz. Use when unsure."),
    ("road", "Normal driving", "20 Hz: drivetrain, chassis, tyres, temperatures, driver aids, fuel."),
    ("race", "Racing", "50 Hz: chassis, tyre and brake heat, suspension, aids, fuel."),
    ("drift", "Drifting", "50 Hz: slip angle, tyre slip and heat, suspension, chassis."),
    ("drag", "Drag racing", "50 Hz: launch, shifts, rear grip, suspension, parachute, fuel."),
    ("offroad", "Offroad", "25 Hz: suspension travel, traction, surfaces, diff locks and 4WD."),
    ("truck", "Trucking / towing", "10 Hz: temperatures, brakes, fuel, plus trailer frames."),
    ("pull", "Tractor pulling", "50 Hz: traction, wheel slip, suspension, diff locks, engine."),
]
MODE_NAMES = [m[0] for m in MODES]


class Session:
    def __init__(self, root: Path):
        self.dir = root / datetime.now().strftime("%Y-%m-%d_%H%M%S")
        (self.dir / "configs").mkdir(parents=True)
        (self.dir / "meta").mkdir()
        self.telemetry = open(self.dir / "telemetry.jsonl", "a", encoding="utf-8")
        self.events = open(self.dir / "events.jsonl", "a", encoding="utf-8")
        self.lock = threading.Lock()
        self.seen = {}  # kind -> set of hashes already written

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


class Recorder:
    """Receives telemetry on a background thread.

    Callbacks (called from that thread):
        on_log(text)      a line for the output window
        on_mark(mark)     a new mark: dict with n, t, spd, gear, rpm, vid, notes
        on_note(mark)     a note was added to a mark (same dict, notes updated)
        on_status(status) about once a second: dict with rate, frames, marks, mode, gameMode, vehicle
    """

    def __init__(self, out: Path, host="127.0.0.1", port=DEFAULT_PORT, control_port=DEFAULT_CONTROL_PORT,
                 mode="all", on_log=print, on_mark=None, on_note=None, on_status=None):
        self.out, self.host, self.port, self.control_port = out, host, port, control_port
        self.mode = mode if mode in MODE_NAMES else "all"
        self.on_log = on_log
        self.on_mark = on_mark or (lambda m: None)
        self.on_note = on_note or (lambda m: None)
        self.on_status = on_status or (lambda s: None)
        self.session = None
        self.chunks = Chunks()
        self.lock = threading.Lock()
        self.frames = 0
        self.marks = []
        self.last_frame = None
        self.game_mode = None
        self.vehicle = None
        self.running = False
        self.thread = None
        self.sock = None
        self.control = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)

    # --- lifecycle -------------------------------------------------------

    def start(self):
        self.sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        self.sock.setsockopt(socket.SOL_SOCKET, socket.SO_RCVBUF, 4 * 1024 * 1024)
        self.sock.bind((self.host, self.port))
        self.sock.settimeout(0.2)
        self.open_session()
        self.running = True
        self.thread = threading.Thread(target=self._loop, daemon=True)
        self.thread.start()

    def stop(self):
        self.running = False
        if self.thread:
            self.thread.join(timeout=2)
        if self.sock:
            self.sock.close()
        with self.lock:
            if self.session:
                self.session.close()
                self.on_log(f"Stopped. {self.frames} frames, {len(self.marks)} marks saved in {self.session.dir}")
                self.session = None

    def open_session(self):
        """Start a new session folder (closing the current one)."""
        with self.lock:
            if self.session:
                self.session.close()
                self.on_log(f"Closed session: {self.frames} frames, {len(self.marks)} marks in {self.session.dir}")
            self.session = Session(self.out)
            self.frames = 0
            self.marks = []
            self.last_frame = None
            self.session.write({"type": "modeSet", "rt": round(time.time(), 3), "mode": self.mode})
        self.on_log(f"Recording to {self.session.dir}")
        return self.session.dir

    # --- commands --------------------------------------------------------

    def _command(self, msg: dict):
        try:
            self.control.sendto(json.dumps(msg).encode(), (self.host, self.control_port))
        except OSError as e:
            self.on_log(f"[warn] can't reach the game: {e}")

    def set_mode(self, mode: str):
        if mode not in MODE_NAMES:
            raise ValueError(f"unknown mode {mode!r}")
        self.mode = mode
        with self.lock:
            if self.session:
                self.session.write({"type": "modeSet", "rt": round(time.time(), 3), "mode": mode})
        self._command({"type": "setMode", "mode": mode})
        self.on_log(f"[mode] asked the game for '{mode}'")

    def request_mark(self):
        """Ask the game to place a mark, as if the in-game Mark key was pressed."""
        self._command({"type": "mark"})

    def add_note(self, text: str, mark_n=None):
        """Save a note, attached to mark `mark_n` (or the latest mark). Returns that mark or None."""
        text = text.strip()
        if not text:
            return None
        with self.lock:
            mark = next((m for m in self.marks if m["n"] == mark_n), None) if mark_n is not None else None
            mark = mark or (self.marks[-1] if self.marks else None)
            frame = self.last_frame or {}
            if self.session:
                self.session.write({"type": "note", "rt": round(time.time(), 3), "mark": mark and mark["n"],
                                    "t": mark["t"] if mark else frame.get("t"), "vid": mark and mark.get("vid"), "text": text})
            if mark:
                mark["notes"].append(text)
        if mark:
            self.on_note(mark)
        self.on_log(f"[note saved{' for mark ' + str(mark['n']) if mark else ''}] {text}")
        return mark

    # --- receiving -------------------------------------------------------

    def _loop(self):
        last_status = last_flush = last_mode = time.time()
        last_frames = 0
        rate = 0.0
        self._command({"type": "setMode", "mode": self.mode})
        while self.running:
            try:
                data, _ = self.sock.recvfrom(65535)
                self._handle(json.loads(data))
            except socket.timeout:
                pass
            except OSError:
                if self.running:
                    raise
            except (json.JSONDecodeError, KeyError, TypeError) as e:
                self.on_log(f"[warn] bad packet: {e}")

            now = time.time()
            if now - last_flush >= 1:
                with self.lock:
                    if self.session:
                        self.session.flush()  # closing the window kills the process; lose at most a second
                last_flush = now
            if now - last_mode >= MODE_REPEAT:
                self._command({"type": "setMode", "mode": self.mode})
                last_mode = now
            if now - last_status >= 1:
                rate = (self.frames - last_frames) / (now - last_status) if self.frames >= last_frames else 0
                last_status, last_frames = now, self.frames
                self.on_status({"rate": rate, "frames": self.frames, "marks": len(self.marks), "mode": self.mode,
                                "gameMode": self.game_mode, "vehicle": self.vehicle,
                                "session": str(self.session.dir) if self.session else None})

    def _handle(self, msg: dict):
        rt = round(time.time(), 3)
        if msg.get("type") == "chunk":
            msg = self.chunks.add(msg)
            if msg is None:
                return
        msg["rt"] = rt
        kind = msg.get("type")
        with self.lock:
            session = self.session
            if not session:
                return
            if kind == "frame":
                self.frames += 1
                if not msg.get("role"):
                    self.last_frame = msg
                session.write(msg)
                return
            if kind == "config":
                new = session.snapshot("configs", msg)
            elif kind == "meta":
                new = session.snapshot("meta", msg)
            else:
                new = True
                session.write(msg)

        if kind == "config" and new:
            where = ", ".join([f"{msg['career']} career"]
                              + [f"{label} {msg[key]}" for key, label in (("saveSlot", "save"), ("inventoryId", "inventory")) if msg.get(key) is not None]
                              ) if msg.get("career") else "not in career"
            role = " (coupled)" if msg.get("role") == "trailer" else ""
            if msg.get("role") != "trailer":
                self.vehicle = {"model": msg.get("model"), "vid": msg.get("vid"), "where": where}
            self.on_log(f"[config] {msg.get('model')}{role} (vehicle {msg.get('vid')}, {where}), "
                        f"{len(msg.get('parts') or {})} parts, {len(msg.get('vars') or {})} tuning vars")
        elif kind == "meta" and new:
            dampers = msg.get("dampers") or []
            corners = ", ".join(sorted({d.get("corner") or "?" for d in dampers})) or "none found"
            devices = ", ".join(d.get("name") for d in msg.get("modeDevices") or []) or "none"
            self.on_log(f"[meta] {msg.get('vehicle')} ({msg.get('role', 'driver')}, {msg.get('mode', '?')} mode): "
                        f"{len(msg.get('wheels') or [])} wheels, {len(dampers)} dampers ({corners}), switchable: {devices}")
        elif kind == "mode":
            self.game_mode = msg.get("mode")
            self.on_log(f"[mode] vehicle {msg.get('vid')} ({msg.get('role')}) now records '{msg.get('mode')}' at {msg.get('rate')} Hz")
        elif kind == "modeAck":
            self.game_mode = msg.get("mode")
            self.on_log(f"[mode] game switched to '{msg.get('mode')}'")
        elif kind == "mark":
            f = self.last_frame or {}
            mark = {"n": msg.get("n"), "t": msg.get("t"), "vid": msg.get("vid"), "spd": f.get("spd"),
                    "gear": f.get("gear"), "rpm": f.get("rpm"), "rt": rt, "notes": []}
            with self.lock:
                self.marks.append(mark)
            spd = f"{mark['spd']:.1f}" if isinstance(mark["spd"], (int, float)) else "?"
            rpm = f"{mark['rpm']:.0f}" if isinstance(mark["rpm"], (int, float)) else "?"
            self.on_log(f"[MARK {mark['n']}] t={mark['t']}s  speed={spd} m/s  gear={mark['gear']}  rpm={rpm}")
            self.on_mark(mark)
        elif kind == "reset":
            self.on_log(f"[reset] vehicle {msg.get('vid')} reset at t={msg.get('t')}s")
