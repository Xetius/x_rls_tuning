"""Tuning Telemetry recorder, console version (recorder_gui.py is the window version).

Writes a session folder under sessions/ (see core.py for the layout).
While it runs, anything you type in this window and press Enter is saved as a
note attached to the latest mark.

Run:  py recorder.py                (defaults: 127.0.0.1:4445, ../sessions, mode "all")
      py recorder.py --mode drift
      py recorder.py --help
"""

import argparse
import sys
import threading
import time
from pathlib import Path

from core import DEFAULT_CONTROL_PORT, DEFAULT_PORT, MODE_NAMES, MODES, Recorder


def main():
    sys.stdout.reconfigure(line_buffering=True)
    here = Path(__file__).resolve().parent
    ap = argparse.ArgumentParser(description="Record Tuning Telemetry from BeamNG.",
                                 epilog="Modes: " + "; ".join(f"{n} = {label}" for n, label, _ in MODES))
    ap.add_argument("--host", default="127.0.0.1")
    ap.add_argument("--port", type=int, default=DEFAULT_PORT)
    ap.add_argument("--control-port", type=int, default=DEFAULT_CONTROL_PORT)
    ap.add_argument("--out", type=Path, default=here.parent / "sessions")
    ap.add_argument("--mode", choices=MODE_NAMES, default="all", help="what to record (default: all)")
    args = ap.parse_args()

    last = {"t": 0}

    def status(s):
        if time.time() - last["t"] < 10:
            return
        last["t"] = time.time()
        state = f"{s['rate']:.0f} frames/s" if s["rate"] else "waiting for BeamNG (drive the car)"
        print(f"[status] {state}, {s['frames']} frames, {s['marks']} marks, mode {s['gameMode'] or '?'}")

    def mark(m):
        print("  -- type a description and press Enter (optional)")

    rec = Recorder(args.out, args.host, args.port, args.control_port, args.mode, on_log=print, on_mark=mark, on_status=status)
    rec.start()
    print(f"Listening on {args.host}:{args.port}, mode '{args.mode}'. Ctrl+C to stop.")

    def read_notes():
        for line in sys.stdin:
            rec.add_note(line)

    threading.Thread(target=read_notes, daemon=True).start()
    try:
        while True:
            time.sleep(0.5)
    except KeyboardInterrupt:
        pass
    finally:
        rec.stop()


if __name__ == "__main__":
    main()
