"""Builds the release zips into dist/:

    tuning_telemetry_<version>.zip            the BeamNG mod: put it in the game's mods folder
    tuning_telemetry_recorder_<version>.zip   the recorder: unzip anywhere, needs Python 3.9+

Run:  py build.py                  (version from `git describe`, else "dev")
      py build.py --version 1.2.0
"""

import argparse
import re
import subprocess
import zipfile
from pathlib import Path

ROOT = Path(__file__).resolve().parent
MOD = ROOT / "mod"
VERSION_FILE = "lua/ge/extensions/tuningTelemetry/main.lua"
VERSION_LINE = re.compile(r'^local version = "[^"]*"', re.M)
RECORDER_FILES = ["recorder/core.py", "recorder/recorder.py", "recorder/recorder_gui.py",
                  "record.cmd", "record_gui.cmd", "README.md"]
ZIP_TIME = (2020, 1, 1, 0, 0, 0)  # fixed, so the same source gives the same zip


def git_version():
    try:
        out = subprocess.run(["git", "describe", "--tags", "--always", "--dirty"], cwd=ROOT,
                             capture_output=True, text=True, check=True).stdout.strip()
    except (OSError, subprocess.CalledProcessError):
        return "dev"
    return out[1:] if out.startswith("v") else out


def add(zf: zipfile.ZipFile, name: str, data: bytes):
    info = zipfile.ZipInfo(name, ZIP_TIME)
    info.compress_type = zipfile.ZIP_DEFLATED
    info.external_attr = 0o644 << 16
    zf.writestr(info, data)


def build_mod(version: str, out: Path) -> Path:
    path = out / f"tuning_telemetry_{version}.zip"
    with zipfile.ZipFile(path, "w") as zf:
        for f in sorted(p for p in MOD.rglob("*") if p.is_file()):
            name = f.relative_to(MOD).as_posix()
            data = f.read_bytes()
            if name == VERSION_FILE:
                text, count = VERSION_LINE.subn(f'local version = "{version}"', data.decode("utf-8"), count=1)
                if count != 1:
                    raise SystemExit(f"version line not found in {name}")
                data = text.encode("utf-8")
            add(zf, name, data)
    return path


def build_recorder(version: str, out: Path) -> Path:
    path = out / f"tuning_telemetry_recorder_{version}.zip"
    top = "tuning_telemetry_recorder"
    with zipfile.ZipFile(path, "w") as zf:
        for name in RECORDER_FILES:
            add(zf, f"{top}/{name}", (ROOT / name).read_bytes())
        add(zf, f"{top}/VERSION", f"{version}\n".encode())
    return path


def main():
    ap = argparse.ArgumentParser(description="Build the Tuning Telemetry release zips.")
    ap.add_argument("--version", help="release version, e.g. 1.2.0 (default: from git)")
    ap.add_argument("--out", type=Path, default=ROOT / "dist")
    args = ap.parse_args()

    version = (args.version or git_version()).removeprefix("v")
    if not re.fullmatch(r"[0-9A-Za-z.+_-]+", version):
        raise SystemExit(f"bad version {version!r}")
    args.out.mkdir(parents=True, exist_ok=True)
    for path in (build_mod(version, args.out), build_recorder(version, args.out)):
        print(f"{path}  ({path.stat().st_size // 1024} KB)")


if __name__ == "__main__":
    main()
