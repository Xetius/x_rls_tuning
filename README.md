# BeamNG Tuning Telemetry

A BeamNG.drive mod that streams driving data to a recorder on the same PC, so a run can be
analysed afterwards together with a description of what the car was doing, and the
vehicle's parts and tuning can be adjusted from that.

## Parts

| Path | What it does |
|---|---|
| `mod/lua/vehicle/extensions/tuningTelemetry/stream.lua` | Runs inside the player's vehicle. Sends a JSON frame over UDP (`127.0.0.1:4445`) 50 times per second of sim time, plus metadata (wheels, detected shock absorbers) every 5 s. |
| `mod/lua/ge/extensions/tuningTelemetry/main.lua` | Game-engine side. Keeps the streamer loaded in whatever car you drive (part changes respawn the car), sends the car's parts and tuning vars every 5 s, and handles the mark action. |
| `mod/lua/ge/extensions/core/input/actions/tuningTelemetry.json` | The **Mark moment** control (Options → Controls → Tuning Telemetry). |
| `mod/settings/inputmaps/keyboard_tuningTelemetry.json` | Default key for Mark: **Alt+M** (unused by the game and the installed mods when this was written). Bind a wheel button to it in Controls. |
| `recorder/recorder.py` | Listens on UDP 4445 and writes a session folder under `sessions/`. Standard-library Python only. |

## Use

1. Run `install.ps1` once (and again after changing anything in `mod/`).
2. Start the recorder: double-click `record.cmd`, or `py recorder\recorder.py`.
3. Drive. When the car does something wrong, press **Mark** (Alt+M or your bound button).
   A "Telemetry mark N" message shows in game, and the recorder prints the mark.
4. Optionally type a description into the recorder window and press Enter; it is saved
   as a note on the latest mark.
5. Ctrl+C in the recorder window to stop.

## Data recorded

Each frame (`type: "frame"`):

- **Driver inputs and drivetrain:** speed (`spd`, m/s), wheel speed, rpm, gear, throttle,
  brake, clutch, steering (and the raw inputs), handbrake, engine load, boost, temperatures, fuel.
- **Driver aids:** whether ABS, traction control and ESC are active.
- **Chassis:** g-forces `gx/gy/gz`; roll and pitch angles; roll, pitch and yaw rates; position.
- **`w`, per wheel:** angular velocity, wheel speed, longitudinal and side slip, slip energy,
  load, drive torque, brake torque, brake temperature, tyre temperature, tyre pressure (psi),
  surface material.
- **`d`, per shock absorber:** compression in mm relative to its length when the car spawned.
- **`gin`, `revLim`:** gearbox input rpm and whether the rev limiter is cutting.
- **`chute`:** 1 while Meo's drag parachute is deployed (absent on cars without one).
- **`fuelx`, RLS Career Overhaul 2.8+ fuel & ignition model** (absent without it): actual and
  target AFR (`afr`, `tafr`), map timing trim and timing after knock retard (`tim`, `etim`),
  knock retard (`kr`), knock / lean / rich severity, fuel delivery duty (`duty`; over 1 means
  the `dlim` injector or pump can't keep up), torque multiplier (`tq`), charge cooling,
  boost fuel cut, and accumulated knock / lean damage exposure (`xk`, `xl`). `native: true`
  means the stock calibration is running and RLS only estimates these values.

Events: `mark`, `note`, `reset` (vehicle reset, so a teleport isn't read as a crash),
`configSnapshot` and `metaSnapshot` (stored in full under `configs/` and `meta/`, written
once per distinct content). Each line also has `rt`, the wall-clock receive time.

## Status

- Used in game with RLS Career Overhaul since 2026-11-02. The `fuelx` readings are not yet
  tested in game.
- Shock absorbers are found by their `vkTag: damper_XX` tag (vanilla cars). Cars without
  the tag fall back to a heuristic (split bump/rebound damping, no spring); check the
  recorder's `[meta]` line to see what was found.
