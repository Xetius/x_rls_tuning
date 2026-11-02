-- Tuning Telemetry: vehicle side.
-- Streams per-frame driving data as JSON over UDP to the recorder (recorder/recorder.py).
-- Loaded into the player's vehicle by the GE extension tuningTelemetry_main.

local M = {}

local socket = require("socket.socket")
local floor = math.floor

local address = "127.0.0.1"
local port = 4445
local sendRate = 50 -- Hz, in sim time (pausing stops the stream)
local metaPeriod = 5 -- seconds between metadata repeats, so a recorder started mid-drive catches up

local udp
local sendPeriod = 1 / sendRate
local sendTimer = 0
local metaTimer = 0
local simTime = 0
local seq = 0
local markCount = 0
local dampers = {}
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
  meta = {
    type = "meta",
    vid = objectId,
    vehicle = vehiclePath,
    sendRate = sendRate,
    wheels = wheelList,
    dampers = damperList,
  }
end

local function buildFrame()
  local e = electrics.values
  local roll, pitch = obj:getRollPitchYaw()
  local rollRate, pitchRate, yawRate = obj:getRollPitchYawAngularVelocity()
  local px, py, pz = obj:getPositionXYZ()

  local w = {}
  for _, wd in pairs(wheels.wheels) do
    local tw = {
      n = wd.name,
      av = r(wd.angularVelocity, 2),
      ws = r(wd.wheelSpeed, 2),
      slip = r(wd.lastSlip, 3),
      sslip = r(wd.lastSideSlip, 3),
      se = r(wd.slipEnergy, 1),
      load = r(wd.downForce, 0),
      tq = r(wd.propulsionTorque, 0),
      btq = r(wd.brakingTorque, 0),
      bt = r(wd.brakeSurfaceTemperature, 0),
      mat = wd.contactMaterialID1,
      broken = wd.isBroken or nil,
      deflated = wd.isTireDeflated or nil,
    }
    if wd.wheelID then
      tw.tt = r(obj:getWheelAvgTemperature(wd.wheelID), 1)
    end
    if wd.pressureGroup and v.data.pressureGroups and v.data.pressureGroups[wd.pressureGroup] then
      tw.psi = r(obj:getGroupPressure(v.data.pressureGroups[wd.pressureGroup]) * 0.000145038, 2)
    end
    table.insert(w, tw)
  end

  local d = {}
  for i, dm in ipairs(dampers) do
    -- compression in mm relative to spawn length (positive = compressed)
    d[i] = {n = dm.corner, c = r((dm.restLength - obj:getBeamLength(dm.cid)) * 1000, 1)}
  end

  return {
    type = "frame",
    seq = seq,
    t = r(simTime, 3),
    spd = r(e.airspeed, 2),
    wspd = r(e.wheelspeed, 2),
    rpm = r(e.rpm, 0),
    gin = gearbox and r(gearbox.inputAV * avToRPM, 0), -- gearbox input rpm: what the automatic's shift points compare against
    revLim = engine and engine.revLimiterActive or nil,
    gear = e.gear,
    gi = e.gearIndex,
    thr = r(e.throttle, 3),
    thrIn = r(e.throttle_input, 3),
    brk = r(e.brake, 3),
    brkIn = r(e.brake_input, 3),
    clu = r(e.clutch, 3),
    steer = r(e.steering, 1),
    steerIn = r(e.steering_input, 3),
    pbrk = r(e.parkingbrake, 2),
    load = r(e.engineLoad, 3),
    boost = r(e.turboBoost, 2),
    wtemp = r(e.watertemp, 1),
    otemp = r(e.oiltemp, 1),
    fuel = r(e.fuel, 4),
    abs = e.absActive,
    tcs = e.tcsActive,
    esc = e.escActive,
    gx = r(sensors.gx2, 2),
    gy = r(sensors.gy2, 2),
    gz = r(sensors.gz2, 2),
    roll = r(roll, 4),
    pitch = r(pitch, 4),
    rollRate = r(rollRate, 4),
    pitchRate = r(pitchRate, 4),
    yawRate = r(yawRate, 4),
    pos = {r(px, 2), r(py, 2), r(pz, 2)},
    w = w,
    d = d,
  }
end

local function updateGFX(dt)
  if not playerInfo.firstPlayerSeated then return end
  if not electrics.values.watertemp and not electrics.values.wheelspeed then return end -- not fully initialised yet

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
  buildMeta()
  send(meta)
  log("I", "tuningTelemetry", string.format("Streaming to %s:%d at %d Hz, %d wheels, %d dampers", address, port, sendRate, #meta.wheels, #dampers))
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

return M
