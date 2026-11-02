# BeamNG Tuning Telemetry

A BeamNG.drive mod that streams driving data to a recorder on the same PC, so a run can be
analysed afterwards together with a description of what the car was doing, and the
vehicle's parts and tuning can be adjusted from that.

## Parts

| Path | What it does |
|---|---|
| `mod/lua/vehicle/extensions/tuningTelemetry/stream.lua` | Runs inside the player's vehicle (and anything coupled to it). Sends JSON frames over UDP (`127.0.0.1:4445`) at the rate of the current driving mode, plus metadata (wheels, detected shock absorbers, switchable diffs/4WD/range box) every 5 s. |
| `mod/lua/ge/extensions/tuningTelemetry/main.lua` | Game-engine side. Keeps the streamer loaded in whatever car you drive (part changes respawn the car) and in coupled trailers, sends their parts and tuning vars every 5 s, handles the mark action, and takes commands (driving mode, mark) from the recorder on UDP `4446`. |
| `mod/lua/ge/extensions/core/input/actions/tuningTelemetry.json` | The **Mark moment** control (Options → Controls → Tuning Telemetry). |
| `mod/settings/inputmaps/keyboard_tuningTelemetry.json` | Default key for Mark: **Alt+M** (unused by the game and the installed mods when this was written). Bind a wheel button to it in Controls. |
| `recorder/core.py` | The recording engine: listens on UDP 4445, writes a session folder under `sessions/`, sends commands to the game. Standard-library Python only. |
| `recorder/recorder_gui.py` | The recorder window (`record_gui.cmd`). |
| `recorder/recorder.py` | The console recorder (`record.cmd`), e.g. `py recorder\recorder.py --mode drift`. |
| `test/fake_sender.py` | Pretends to be the game, to test the recorder without BeamNG. |
| `build.py` | Builds the release zips into `dist/`. |
| `.github/workflows/release.yml` | Builds and publishes a GitHub release when a version tag (e.g. `1.0.0`) is pushed. |

## Install from a release

1. Download `x_rls_tuning_<version>.zip` and put it, still zipped, in
   `%LOCALAPPDATA%\BeamNG\BeamNG.drive\current\mods`. Enable it in the game's mod manager
   if it isn't already.
2. Download `x_rls_tuning_recorder_<version>.zip` and unzip it anywhere. It needs
   [Python 3.9 or newer](https://www.python.org/downloads/) (standard library only).
   Sessions are saved in a `sessions` folder next to it.
3. Carry on from step 2 of **Use** below.

Don't have the release zip and the `install.ps1` development copy
(`mods\unpacked\x_rls_tuning`) installed at the same time: both would load.

## Making a release

```
git tag 1.0.0
git push origin 1.0.0
```

The workflow checks that the Lua and Python compile, runs `build.py` with the tag's version
(written into the mod, so each recording's config says which version made it) and attaches
both zips to a new GitHub release. A tag with a hyphen (`1.1.0-beta1`) is marked as a
pre-release. To build locally: `py build.py` (or `--version 1.0.0`).

## Use

1. Run `install.ps1` once (and again after changing anything in `mod/`); or install a
   release as above.
2. Start the recorder: double-click `record_gui.cmd` (window) or `record.cmd` (console).
3. Pick the **driving mode** in the dropdown (see below). The game switches within a
   couple of seconds; the status bar shows the mode the game confirmed.
4. Drive. When the car does something wrong, press **Mark** (Alt+M, your bound button, or
   the Mark button in the window). A "Telemetry mark N" message shows in game and the mark
   appears in the marks list.
5. Type a description in the Note box and press Enter. It goes to the selected mark, or
   the latest one if none is selected. (Console: type and press Enter.)
6. **New session** starts a new folder (e.g. for a different car or discipline);
   closing the window stops recording.

### Driving modes

The mode decides which fields are sent and how often, so the files hold what matters for
that kind of driving. Every mode sends the core fields (below).

| Mode | Rate | Adds |
|---|---|---|
| `all` (default) | 50 Hz | everything |
| `road` | 20 Hz | drivetrain, chassis, wheels + tyre/brake heat, temperatures, aids, fuel, diff/4WD modes |
| `race` | 50 Hz | drivetrain, chassis, wheels + heat, suspension, temperatures, aids, fuel |
| `drift` | 50 Hz | drivetrain, chassis, wheels + heat, suspension, temperatures, aids |
| `drag` | 50 Hz | drivetrain, chassis, wheels, suspension, temperatures, fuel, parachute |
| `offroad` | 25 Hz | drivetrain, chassis, wheels, suspension, temperatures, aids, diff/4WD modes |
| `truck` | 10 Hz | drivetrain, chassis, wheels + heat, suspension, temperatures, aids, fuel, diff/4WD modes |
| `pull` | 50 Hz | drivetrain, chassis, wheels, suspension, temperatures, fuel, diff/4WD modes |

Anything coupled to the driven vehicle (trailer, dolly...) streams its own frames with
`role: "trailer"` at 10 Hz: chassis, wheels with heat, and suspension.

## Data recorded

Each frame (`type: "frame"`):

- **Core (every mode):** vehicle id `vid` (and `role` for trailers), `seq`, game time `t`,
  speed, rpm, gear, throttle, brake and steering (actual and raw input), `gx/gy`, yaw rate,
  compass heading `hdg` (degrees), slip angle `slipAng` (degrees, + = travelling left of
  where the nose points; only above 2 m/s), position.
- **Driver inputs and drivetrain:** speed (`spd`, m/s), wheel speed, rpm, gear, throttle,
  brake, clutch, steering (and the raw inputs), handbrake, engine load, boost, temperatures, fuel.
- **Driver aids:** whether ABS, traction control and ESC are active.
- **Chassis:** g-forces `gx/gy/gz`; roll and pitch angles; roll, pitch and yaw rates; position.
- **`w`, per wheel:** angular velocity, wheel speed, longitudinal and side slip, slip energy,
  load, drive torque, brake torque, brake temperature, tyre temperature, tyre pressure (psi),
  surface material.
- **`d`, per shock absorber:** compression in mm relative to its length when the car spawned.
- **`gin`, `revLim`:** gearbox input rpm and whether the rev limiter is cutting.
- **`pm`:** the mode of each switchable diff, transfer case and range box (e.g. `open`,
  `locked`, `lsd`; 4WD `connected` / `disconnected`; range `high` / `low`).
- **`chute`:** 1 while Meo's drag parachute is deployed (absent on cars without one).
- **`fuelx`, RLS Career Overhaul 2.8+ fuel & ignition model** (absent without it): actual and
  target AFR (`afr`, `tafr`), map timing trim and timing after knock retard (`tim`, `etim`),
  knock retard (`kr`), knock / lean / rich severity, fuel delivery duty (`duty`; over 1 means
  the `dlim` injector or pump can't keep up), torque multiplier (`tq`), charge cooling,
  boost fuel cut, and accumulated knock / lean damage exposure (`xk`, `xl`). `native: true`
  means the stock calibration is running and RLS only estimates these values.

Events: `mark`, `note`, `reset`, `modeSet` (mode picked in the recorder), `modeAck` and
`mode` (the game switched; `mode` per vehicle, with its rate) (vehicle reset, so a teleport isn't read as a crash),
`configSnapshot` and `metaSnapshot` (stored in full under `configs/` and `meta/`, written
once per distinct content). Each line also has `rt`, the wall-clock receive time.

## Status

- Used in game with RLS Career Overhaul since 2026-11-02. Not yet tested in game: the
  `fuelx` readings, driving modes, trailer frames, `hdg`/`slipAng`/`pm`, and the recorder
  window (tested against `test/fake_sender.py` only).
- Not recorded yet: the pulling force on a hitch or sled.
- Shock absorbers are found by their `vkTag: damper_XX` tag (vanilla cars). Cars without
  the tag fall back to a heuristic (split bump/rebound damping, no spring); check the
  recorder's `[meta]` line to see what was found.
