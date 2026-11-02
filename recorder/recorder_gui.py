"""Tuning Telemetry recorder, window version.

A window with the recorder output, a driving-mode dropdown (tells the game what to
record), a Mark button, a note box and the list of marks in this session.

Run:  pyw recorder_gui.py           (or double-click record_gui.cmd)
"""

import argparse
import os
import queue
import tkinter as tk
from pathlib import Path
from tkinter import messagebox, ttk

from core import DEFAULT_CONTROL_PORT, DEFAULT_PORT, MODE_NAMES, MODES, Recorder

MAX_LOG_LINES = 2000


class App:
    def __init__(self, root: tk.Tk, args):
        self.root = root
        self.events = queue.Queue()  # (kind, data) from the recorder thread
        self.rec = Recorder(args.out, args.host, args.port, args.control_port, args.mode,
                            on_log=lambda s: self.events.put(("log", s)),
                            on_mark=lambda m: self.events.put(("mark", m)),
                            on_note=lambda m: self.events.put(("note", m)),
                            on_status=lambda s: self.events.put(("status", s)))

        root.title("Tuning Telemetry recorder")
        root.geometry("900x640")
        root.minsize(640, 420)
        root.protocol("WM_DELETE_WINDOW", self.close)

        # --- top: mode, mark, session buttons --------------------------------
        top = ttk.Frame(root, padding=(8, 8, 8, 4))
        top.pack(fill="x")
        ttk.Label(top, text="Mode:").pack(side="left")
        self.labels = {f"{label} ({name})": name for name, label, _ in MODES}
        self.mode_var = tk.StringVar(value=next(k for k, v in self.labels.items() if v == self.rec.mode))
        mode_box = ttk.Combobox(top, textvariable=self.mode_var, values=list(self.labels), state="readonly", width=28)
        mode_box.pack(side="left", padx=(4, 8))
        mode_box.bind("<<ComboboxSelected>>", self.mode_changed)
        ttk.Button(top, text="Mark", command=self.rec.request_mark).pack(side="left")
        ttk.Button(top, text="Open folder", command=self.open_folder).pack(side="right")
        ttk.Button(top, text="New session", command=self.new_session).pack(side="right", padx=(0, 4))

        self.mode_help = ttk.Label(root, padding=(8, 0, 8, 4), foreground="#555")
        self.mode_help.pack(fill="x")
        self.show_mode_help()

        # --- middle: marks list above, output below ---------------------------
        panes = ttk.PanedWindow(root, orient="vertical")
        panes.pack(fill="both", expand=True, padx=8)

        marks_frame = ttk.LabelFrame(panes, text="Marks (select one to add a note to it)", padding=4)
        cols = ("n", "t", "spd", "gear", "rpm", "notes")
        self.marks = ttk.Treeview(marks_frame, columns=cols, show="headings", height=6, selectmode="browse")
        for col, title, width, stretch in [("n", "#", 40, False), ("t", "Game time", 80, False),
                                           ("spd", "Speed", 90, False), ("gear", "Gear", 50, False),
                                           ("rpm", "RPM", 60, False), ("notes", "Notes", 300, True)]:
            self.marks.heading(col, text=title)
            self.marks.column(col, width=width, stretch=stretch, anchor="w" if col == "notes" else "center")
        marks_scroll = ttk.Scrollbar(marks_frame, orient="vertical", command=self.marks.yview)
        self.marks.configure(yscrollcommand=marks_scroll.set)
        self.marks.pack(side="left", fill="both", expand=True)
        marks_scroll.pack(side="right", fill="y")
        panes.add(marks_frame, weight=1)

        log_frame = ttk.LabelFrame(panes, text="Output", padding=4)
        self.log = tk.Text(log_frame, height=12, wrap="word", state="disabled", font=("Consolas", 9))
        log_scroll = ttk.Scrollbar(log_frame, orient="vertical", command=self.log.yview)
        self.log.configure(yscrollcommand=log_scroll.set)
        self.log.tag_configure("mark", foreground="#b00020", font=("Consolas", 9, "bold"))
        self.log.tag_configure("warn", foreground="#b06000")
        self.log.tag_configure("mode", foreground="#1f5fa8")
        self.log.pack(side="left", fill="both", expand=True)
        log_scroll.pack(side="right", fill="y")
        panes.add(log_frame, weight=2)

        # --- bottom: note entry and status -------------------------------------
        note = ttk.Frame(root, padding=(8, 6, 8, 2))
        note.pack(fill="x")
        ttk.Label(note, text="Note:").pack(side="left")
        self.note_var = tk.StringVar()
        self.note_entry = ttk.Entry(note, textvariable=self.note_var)
        self.note_entry.pack(side="left", fill="x", expand=True, padx=4)
        self.note_entry.bind("<Return>", self.add_note)
        ttk.Button(note, text="Add note", command=self.add_note).pack(side="left")
        self.note_target = ttk.Label(root, padding=(8, 0, 8, 2), foreground="#555")
        self.note_target.pack(fill="x")
        self.marks.bind("<<TreeviewSelect>>", lambda e: self.show_note_target())
        self.marks.bind("<Button-1>", self.toggle_mark)
        self.show_note_target()

        self.status = ttk.Label(root, padding=(8, 2, 8, 6), relief="sunken", anchor="w")
        self.status.pack(fill="x", side="bottom")
        self.status.configure(text="Starting...")

        try:
            self.rec.start()
        except OSError as e:
            messagebox.showerror("Tuning Telemetry recorder",
                                 f"Can't listen on port {args.port}: {e}\n\nIs another recorder already running?")
            root.destroy()
            return
        self.root.after(100, self.poll)

    # --- actions -----------------------------------------------------------

    def mode_changed(self, _event=None):
        self.rec.set_mode(self.labels[self.mode_var.get()])
        self.show_mode_help()

    def show_mode_help(self):
        name = self.labels[self.mode_var.get()]
        self.mode_help.configure(text=next(desc for n, _, desc in MODES if n == name))

    def selected_mark(self):
        sel = self.marks.selection()
        return int(sel[0]) if sel else None

    def toggle_mark(self, event):
        row = self.marks.identify_row(event.y)
        if row and row in self.marks.selection():
            self.marks.selection_remove(row)
            return "break"

    def show_note_target(self):
        n = self.selected_mark()
        if n is not None:
            text = f"Notes go to mark {n}. Click it again to deselect."
        elif self.marks.get_children():
            text = "Notes go to the latest mark (select a mark to note an earlier one)."
        else:
            text = "No marks yet: notes are saved at the current game time."
        self.note_target.configure(text=text)

    def add_note(self, _event=None):
        text = self.note_var.get().strip()
        if not text:
            return
        self.rec.add_note(text, self.selected_mark())
        self.note_var.set("")

    def new_session(self):
        self.rec.open_session()
        self.marks.delete(*self.marks.get_children())
        self.show_note_target()

    def open_folder(self):
        folder = self.rec.session.dir if self.rec.session else self.rec.out
        os.startfile(folder)

    def close(self):
        self.rec.stop()
        self.root.destroy()

    # --- recorder events (from its thread, through the queue) ---------------

    def poll(self):
        try:
            while True:
                kind, data = self.events.get_nowait()
                if kind == "log":
                    self.append_log(data)
                elif kind == "mark":
                    self.marks.insert("", "end", iid=str(data["n"]), values=self.mark_row(data))
                    self.marks.see(str(data["n"]))
                    self.show_note_target()
                    self.note_entry.focus_set()
                elif kind == "note":
                    if self.marks.exists(str(data["n"])):
                        self.marks.item(str(data["n"]), values=self.mark_row(data))
                elif kind == "status":
                    self.show_status(data)
        except queue.Empty:
            pass
        self.root.after(100, self.poll)

    @staticmethod
    def mark_row(m):
        spd = f"{m['spd']:.1f} m/s" if isinstance(m.get("spd"), (int, float)) else "?"
        rpm = f"{m['rpm']:.0f}" if isinstance(m.get("rpm"), (int, float)) else "?"
        t = f"{m['t']:.2f} s" if isinstance(m.get("t"), (int, float)) else "?"
        return (m["n"], t, spd, m.get("gear", "?"), rpm, " | ".join(m["notes"]))

    def append_log(self, line):
        tag = "mark" if line.startswith("[MARK") else "warn" if line.startswith("[warn") else "mode" if line.startswith("[mode") else None
        self.log.configure(state="normal")
        self.log.insert("end", line + "\n", tag)
        excess = int(self.log.index("end-1c").split(".")[0]) - MAX_LOG_LINES
        if excess > 0:
            self.log.delete("1.0", f"{excess + 1}.0")
        self.log.configure(state="disabled")
        self.log.see("end")

    def show_status(self, s):
        if s["rate"]:
            state = f"Receiving {s['rate']:.0f} frames/s"
        else:
            state = "Waiting for BeamNG (sit in a vehicle)"
        game = s["gameMode"]
        if game is None:
            mode = "game mode: not confirmed yet"
        elif game != s["mode"]:
            mode = f"game mode: {game} (switching...)"
        else:
            mode = f"game mode: {game}"
        vehicle = f"{s['vehicle']['model']} ({s['vehicle']['where']})" if s["vehicle"] else "no vehicle yet"
        self.status.configure(text=f"{state}  |  {mode}  |  {vehicle}  |  {s['frames']} frames, {s['marks']} marks")


def main():
    here = Path(__file__).resolve().parent
    ap = argparse.ArgumentParser(description="Record Tuning Telemetry from BeamNG (window).")
    ap.add_argument("--host", default="127.0.0.1")
    ap.add_argument("--port", type=int, default=DEFAULT_PORT)
    ap.add_argument("--control-port", type=int, default=DEFAULT_CONTROL_PORT)
    ap.add_argument("--out", type=Path, default=here.parent / "sessions")
    ap.add_argument("--mode", choices=MODE_NAMES, default="all")
    args = ap.parse_args()

    root = tk.Tk()
    App(root, args)
    root.mainloop()


if __name__ == "__main__":
    main()
