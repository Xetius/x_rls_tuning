-- Tuning Telemetry: vehicle side.
-- Streams per-frame driving data as JSON over UDP to the recorder (recorder/recorder.py).
-- Loaded into the player's vehicle, and into anything coupled to it (trailers), by the
-- GE extension tuningTelemetry_main, which also sets the driving mode.

local M = {}

local socket = require("socket.socket")
local floor, atan2, deg, sqrt = math.floor, math.atan2, math.deg, math.sqrt

local address = "127.0.0.1"
local port = 4445
local metaPeriod = 5 -- seconds between metadata repeats, so a recorder started mid-drive catches up

-- What each driving mode records. Every frame has the core fields (time, speed, rpm, gear,
-- pedals, steering, g-forces, yaw rate, heading, slip angle, position); groups add the rest.
-- Rates are in sim time (pausing stops the stream).
local modes = {
  all = {rate = 50, groups = {"drive", "chassis", "wheels", "wheelHeat", "dampers", "temps", "aids", "fuel", "chute", "awd"}},
  road = {rate = 20, groups = {"drive", "chassis", "wheels", "wheelHeat", "temps", "aids", "fuel", "awd"}},
  race = {rate = 50, groups = {"drive", "chassis", "wheels", "wheelHeat", "dampers", "temps", "aids", "fuel"}},
  drift = {rate = 50, groups = {"drive", "chassis", "wheels", "wheelHeat", "dampers", "temps", "aids"}},
  drag = {rate = 50, groups = {"drive", "chassis", "wheels", "dampers", "temps", "fuel", "chute"}},
  offroad = {rate = 25, groups = {"drive", "chassis", "wheels", "dampers", "temps", "aids", "awd"}},
  truck = {rate = 10, groups = {"drive", "chassis", "wheels", "wheelHeat", "dampers", "temps", "aids", "fuel", "awd"}},
  pull = {rate = 50, groups = {"drive", "chassis", "wheels", "dampers", "temps", "fuel", "awd"}},
}
-- coupled vehicles (trailers, sleds) carry no engine: just how they ride and brake
local trailerMode = {rate = 10, groups = {"chassis", "wheels", "wheelHeat", "dampers"}}

local udp
local role = "driver" -- "driver": streams while the player sits in it; "trailer": coupled to the player's vehicle; "off"
local modeName = "all"
local current = modes.all
local has = {}
local sendPeriod = 1 / current.rate
local sendTimer = 0
local metaTimer = 0
local simTime = 0
local seq = 0
local markCount = 0
local dampers = {}
local modeDevices = {}
local meta
local engine, gearbox
local avToRPM = 30 / math.pi
local minShockDamp = 500 -- real shocks are thousands; link and wheelie-bar dampers are tens to hundreds

local function r(x, decimals)
  if type(x) ~= "number" or x ~= x then return nil end
  local m = 10 ^ (decimals or 3)
  return floor(x * m + 0.5) / m
end

local function send(tbl)
  if not udp then return end
  udp:sendto(jsonEncode(tbl), address, port)
end

-- name of the wheel whose hub node is closest to the given node
local function nearestWheel(nodeCid)
  local node = v.data.nodes[nodeCid]
  if not node or not v.data.wheels then return nil, math.huge end
  local best, bestDist = nil, math.huge
  for _, wd in pairs(v.data.wheels) do
    local hub = v.data.nodes[wd.node1]
    if hub then
      local dist = (vec3(node.pos) - vec3(hub.pos)):length()
      if dist < bestDist then best, bestDist = wd.name, dist end
    end
  end
  return best, bestDist
end

local function sameNodes(a, b)
  return (a.id1 == b.id1 and a.id2 == b.id2) or (a.id1 == b.id2 and a.id2 == b.id1)
end

-- Shock absorbers. Vanilla cars tag them with vkTag "damper_XX". Modded parts often
-- don't (Meo's drag rear coilover), so any wheel still without a damper falls back to
-- beams with split bump/rebound damping and (almost) no spring, normal or bounded.
local function findDampers()
  dampers = {}
  local beams = v.data.beams or {}
  local found = {}
  local covered = {}
  for _, b in pairs(beams) do
    if type(b.vkTag) == "string" and b.vkTag:find("^damper") then
      local corner = b.vkTag:match("^damper_(.+)$") or nearestWheel(b.id1)
      table.insert(found, {beam = b, corner = corner, source = "vkTag"})
      covered[corner] = true
    end
  end
  -- one damper per uncovered wheel: the candidate with a node closest to the hub
  -- (wheelie bar or link dampers can also sit within reach of a rear wheel)
  local best = {}
  for _, b in pairs(beams) do
    local beamType = b.beamType or 0
    if type(b.beamDampRebound) == "number" and b.beamDampRebound >= minShockDamp and (b.beamSpring or 0) <= 1000
        and (beamType == 0 or beamType == 2) and not (type(b.vkTag) == "string" and b.vkTag:find("^damper")) then
      local corner1, dist1 = nearestWheel(b.id1)
      local corner2, dist2 = nearestWheel(b.id2)
      local corner, dist = corner1, dist1
      if dist2 < dist1 then corner, dist = corner2, dist2 end
      if corner and dist < 1.0 and not covered[corner] and (not best[corner] or dist < best[corner].dist) then
        best[corner] = {beam = b, corner = corner, source = "heuristic", dist = dist}
      end
    end
  end
  for _, f in pairs(best) do
    table.insert(found, f)
  end

  for _, f in ipairs(found) do
    local b = f.beam
    local d = {
      corner = f.corner,
      cid = b.cid,
      source = f.source,
      restLength = obj:getBeamRestLength(b.cid),
      bump = b.beamDamp,
      bumpFast = b.beamDampFast,
      rebound = b.beamDampRebound,
      reboundFast = b.beamDampReboundFast,
      velocitySplit = b.beamDampVelocitySplit,
    }
    -- bump stop on the same node pair: the bounded beam there with the largest compression range
    -- (Meo's coilover puts spring, damper and bump stop all on one node pair)
    for _, s in pairs(beams) do
      if s ~= b and s.beamType == 2 and sameNodes(s, b) and type(s.shortBoundRange) == "number"
          and s.shortBoundRange > (d.shortBoundRange or 0) then
        d.shortBoundRange = s.shortBoundRange
        d.longBoundRange = s.longBoundRange
        d.boundZone = s.boundZone
      end
    end
    table.insert(dampers, d)
  end
end

-- driver-switchable powertrain devices: diff locks, 4WD (split shafts), low range
local function findModeDevices()
  modeDevices = {}
  for _, dev in pairs(powertrain.getDevices() or {}) do
    if type(dev.mode) == "string" and ((type(dev.availableModes) == "table" and #dev.availableModes > 1) or dev.type == "rangeBox") then
      table.insert(modeDevices, dev)
    end
  end
end

local function buildMeta()
  local wheelList = {}
  for _, wd in pairs(wheels.wheels) do
    table.insert(wheelList, {name = wd.name, radius = r(wd.radius, 4), wheelDir = wd.wheelDir})
  end
  local damperList = {}
  for i, d in ipairs(dampers) do
    damperList[i] = {
      corner = d.corner, source = d.source, restLength = r(d.restLength, 4),
      bump = d.bump, bumpFast = d.bumpFast, rebound = d.rebound, reboundFast = d.reboundFast, velocitySplit = d.velocitySplit,
      shortBoundRange = d.shortBoundRange, longBoundRange = d.longBoundRange, boundZone = d.boundZone,
    }
  end
  local modeList = {}
  for i, dev in ipairs(modeDevices) do
    modeList[i] = {name = dev.name, type = dev.type, modes = dev.availableModes}
  end
  meta = {
    type = "meta",
    vid = objectId,
    vehicle = vehiclePath,
    role = role,
    mode = modeName,
    sendRate = current.rate,
    wheels = wheelList,
    dampers = damperList,
    modeDevices = modeList,
  }
end

-- RLS Career Overhaul (2.8+) fuel & ignition model: rlsFuelRuntime hangs its
-- per-engine context on the engine device and refreshes context.response each frame
local function rlsFuel()
  local c = engine and engine.rlsFuelContext
  local fr = type(c) == "table" and c.response
  if type(fr) ~= "table" or not fr.afr then return nil end
  local exposure = c.state and c.state.exposure
  return {
    native = fr.mode == "native" or nil, -- stock calibration: RLS only estimates these values
    afr = r(fr.afr, 2),
    tafr = r(fr.targetAFR, 2),
    tim = r(fr.timing, 2), -- map timing trim, degrees relative to stock
    etim = r(fr.effectiveTiming, 2), -- after knock retard
    kr = r(fr.knockRetard, 2),
    knock = r(fr.knock, 3),
    lean = r(fr.leanSeverity, 3),
    rich = r(fr.richSeverity, 3),
    duty = r(fr.deliveryDuty, 3), -- fuel demand / injector-or-pump capacity
    dlim = fr.deliveryLimit,
    tq = r(fr.torque, 3), -- torque multiplier from mixture/timing/knock
    cool = r(fr.chargeCoolingC, 1),
    cut = fr.boostFuelCut or nil,
    xk = exposure and r(exposure.knock, 4), -- accumulated damage exposure (rings fail at 0.25 total)
    xl = exposure and r(exposure.lean, 4),
  }
end

local function buildWheels()
  local w = {}
  for _, wd in pairs(wheels.wheels) do
    local tw = {
      n = wd.name,
      av = r(wd.angularVelocity, 2),
      ws = r(wd.wheelSpeed, 2),
      slip = r(wd.lastSlip, 3),
      sslip = r(wd.lastSideSlip, 3),
      load = r(wd.downForce, 0),
      tq = r(wd.propulsionTorque, 0),
      btq = r(wd.brakingTorque, 0),
      mat = wd.contactMaterialID1,
      broken = wd.isBroken or nil,
      deflated = wd.isTireDeflated or nil,
    }
    if has.wheelHeat then
      tw.se = r(wd.slipEnergy, 1)
      tw.bt = r(wd.brakeSurfaceTemperature, 0)
      if wd.wheelID then
        tw.tt = r(obj:getWheelAvgTemperature(wd.wheelID), 1)
      end
      if wd.pressureGroup and v.data.pressureGroups and v.data.pressureGroups[wd.pressureGroup] then
        tw.psi = r(obj:getGroupPressure(v.data.pressureGroups[wd.pressureGroup]) * 0.000145038, 2)
      end
    end
    table.insert(w, tw)
  end
  return w
end

local function buildFrame()
  local e = electrics.values
  local px, py, pz = obj:getPositionXYZ()
  local _, _, yawRate = obj:getRollPitchYawAngularVelocity()

  -- heading (compass degrees, 0 = +y) and slip angle: how far the direction of travel is
  -- from where the car points (positive = travelling to the left of the nose)
  local dir = obj:getDirectionVector()
  local vel = obj:getVelocity()
  local hdg = deg(atan2(dir.x, dir.y)) % 360
  local slipAng
  if sqrt(vel.x * vel.x + vel.y * vel.y) > 2 then
    slipAng = deg(atan2(dir.x * vel.y - dir.y * vel.x, dir.x * vel.x + dir.y * vel.y))
  end

  local f = {
    type = "frame",
    vid = objectId,
    role = role ~= "driver" and role or nil,
    seq = seq,
    t = r(simTime, 3),
    spd = r(e.airspeed, 2),
    rpm = r(e.rpm, 0),
    gear = e.gear,
    gi = e.gearIndex,
    thr = r(e.throttle, 3),
    thrIn = r(e.throttle_input, 3),
    brk = r(e.brake, 3),
    brkIn = r(e.brake_input, 3),
    steerIn = r(e.steering_input, 3),
    gx = r(sensors.gx2, 2),
    gy = r(sensors.gy2, 2),
    yawRate = r(yawRate, 4),
    hdg = r(hdg, 2),
    slipAng = r(slipAng, 2),
    pos = {r(px, 2), r(py, 2), r(pz, 2)},
  }
  if has.drive then
    f.wspd = r(e.wheelspeed, 2)
    f.gin = gearbox and r(gearbox.inputAV * avToRPM, 0) -- gearbox input rpm: what an automatic's shift points compare against
    f.revLim = engine and engine.revLimiterActive or nil
    f.clu = r(e.clutch, 3)
    f.steer = r(e.steering, 1)
    f.pbrk = r(e.parkingbrake, 2)
    f.load = r(e.engineLoad, 3)
    f.boost = r(e.turboBoost, 2)
  end
  if has.chassis then
    local roll, pitch = obj:getRollPitchYaw()
    local rollRate, pitchRate = obj:getRollPitchYawAngularVelocity()
    f.gz = r(sensors.gz2, 2)
    f.roll = r(roll, 4)
    f.pitch = r(pitch, 4)
    f.rollRate = r(rollRate, 4)
    f.pitchRate = r(pitchRate, 4)
  end
  if has.temps then
    f.wtemp = r(e.watertemp, 1)
    f.otemp = r(e.oiltemp, 1)
    f.fuel = r(e.fuel, 4)
  end
  if has.aids then
    f.abs = e.absActive
    f.tcs = e.tcsActive
    f.esc = e.escActive
  end
  if has.chute then
    f.chute = e.meosParachute -- Meo's drag parachute: 1 while deployed, nil without one
  end
  if has.fuel then
    f.fuelx = rlsFuel()
  end
  if has.awd and #modeDevices > 0 then
    local pm = {}
    for _, dev in ipairs(modeDevices) do pm[dev.name] = dev.mode end
    f.pm = pm
  end
  if has.wheels then
    f.w = buildWheels()
  end
  if has.dampers then
    local d = {}
    for i, dm in ipairs(dampers) do
      -- compression in mm relative to spawn length (positive = compressed)
      d[i] = {n = dm.corner, c = r((dm.restLength - obj:getBeamLength(dm.cid)) * 1000, 1)}
    end
    f.d = d
  end
  return f
end

local function applyMode()
  current = role == "trailer" and trailerMode or modes[modeName]
  has = {}
  for _, g in ipairs(current.groups) do has[g] = true end
  sendPeriod = 1 / current.rate
  if meta then buildMeta() end
end

-- called by the GE extension every second; cheap when nothing changed
local function configure(newRole, newMode)
  newRole = newRole or role
  newMode = modes[newMode] and newMode or modeName
  if newRole == role and newMode == modeName then return end
  role, modeName = newRole, newMode
  applyMode()
  send({type = "mode", vid = objectId, role = role, mode = modeName, rate = current.rate, t = r(simTime, 3)})
  if meta then send(meta) end
end

local function updateGFX(dt)
  if role == "off" then return end
  if role == "driver" and not playerInfo.firstPlayerSeated then return end
  if not electrics.values.wheelspeed and not electrics.values.airspeed then return end -- not fully initialised yet

  simTime = simTime + dt
  metaTimer = metaTimer + dt
  if metaTimer >= metaPeriod then
    metaTimer = 0
    send(meta)
  end

  sendTimer = sendTimer + dt
  if sendTimer < sendPeriod then return end
  sendTimer = sendTimer % sendPeriod
  seq = seq + 1
  send(buildFrame())
end

local function mark()
  markCount = markCount + 1
  send({type = "mark", vid = objectId, n = markCount, t = r(simTime, 3), seq = seq})
  obj:queueGameEngineLua(string.format("ui_message(%q, 3, 'tuningTelemetry')", "Telemetry mark " .. markCount))
end

local function onReset()
  -- vehicle reset (not respawn): note it so analysis doesn't read the teleport as a crash
  send({type = "reset", vid = objectId, t = r(simTime, 3), seq = seq})
end

local function onExtensionLoaded()
  udp = socket.udp()
  engine = powertrain.getDevice("mainEngine")
  gearbox = powertrain.getDevice("gearbox")
  findDampers()
  findModeDevices()
  applyMode()
  buildMeta()
  send(meta)
  log("I", "tuningTelemetry", string.format("Streaming to %s:%d, %d wheels, %d dampers", address, port, #meta.wheels, #dampers))
end

local function onExtensionUnloaded()
  if udp then
    udp:close()
    udp = nil
  end
end

M.onExtensionLoaded = onExtensionLoaded
M.onExtensionUnloaded = onExtensionUnloaded
M.onReset = onReset
M.updateGFX = updateGFX
M.mark = mark
M.configure = configure

return M
