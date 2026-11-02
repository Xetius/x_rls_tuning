-- Tuning Telemetry: game engine side.
-- Keeps the vehicle streamer loaded in the player's vehicle (part changes respawn the
-- vehicle and drop its extensions) and in anything coupled to it, sends vehicle
-- parts/tuning configs to the recorder, handles the "mark" input action, and takes
-- commands from the recorder window (driving mode, mark) on a second UDP port.

local M = {}

local socket = require("socket.socket")

local address = "127.0.0.1"
local port = 4445 -- recorder listens here
local controlPort = 4446 -- we listen here for the recorder's commands
local checkPeriod = 1 -- seconds between "is the streamer loaded?" checks
local configPeriod = 5 -- seconds between config repeats, so a recorder started mid-drive catches up
local maxDatagram = 60000
local modes = {all = true, road = true, race = true, drift = true, drag = true, offroad = true, truck = true, pull = true}

local udp, control
local checkTimer = 0
local configTimer = 0
local mode = "all"
local couplings = {} -- "id1:id2" -> {id1, id2}
local trailers = {} -- vid -> true for vehicles currently streaming as trailers

local function send(str)
  if not udp then return end
  if #str <= maxDatagram then
    udp:sendto(str, address, port)
    return
  end
  -- too big for one UDP packet: split it, the recorder reassembles by id
  local id = tostring(os.clock()) .. "_" .. #str
  local count = math.ceil(#str / maxDatagram)
  for i = 1, count do
    local part = str:sub((i - 1) * maxDatagram + 1, i * maxDatagram)
    udp:sendto(jsonEncode({type = "chunk", id = id, i = i, of = count, data = part}), address, port)
  end
end

-- the player's vehicle, or nil while on foot (walking mode drives the "unicycle" character)
local function getDrivenVehicle()
  local veh = getPlayerVehicle(0)
  if veh and veh:getJBeamFilename() ~= "unicycle" then return veh end
end

local function ensureStreamer(veh, role)
  veh:queueLuaCommand(string.format(
    'if not extensions.tuningTelemetry_stream then extensions.load("tuningTelemetry_stream") end; extensions.tuningTelemetry_stream.configure(%q, %q)',
    role, mode))
end

-- every vehicle reachable from the driven one through couplers (trailer, dolly, sled...)
local function coupledTo(vid)
  local found, queue = {[vid] = true}, {vid}
  while #queue > 0 do
    local cur = table.remove(queue)
    for _, pair in pairs(couplings) do
      local other = pair[1] == cur and pair[2] or (pair[2] == cur and pair[1])
      if other and not found[other] then
        found[other] = true
        table.insert(queue, other)
      end
    end
  end
  found[vid] = nil
  return found
end

local function sendConfig(veh, role)
  local vid = veh:getID()
  local vehData = core_vehicle_manager.getVehicleData(vid)
  local config = vehData and vehData.config
  if not config then return end

  local parts = config.parts
  if not parts and config.partsTree then
    parts = core_vehicle_partmgmt.partsTreeToPartsMap(config.partsTree)
  end

  -- RLS Career Overhaul replaces the vanilla career modules with overhaul_career_*
  local career, inventoryId, saveSlot, savePath
  if overhaul_career_career and overhaul_career_career.isActive and overhaul_career_career.isActive() then
    career = "rls"
    if overhaul_career_garage_inventory and overhaul_career_garage_inventory.getInventoryIdFromVehicleId then
      inventoryId = overhaul_career_garage_inventory.getInventoryIdFromVehicleId(vid)
    end
    if overhaul_career_saveSystem and overhaul_career_saveSystem.getCurrentProfile then
      saveSlot, savePath = overhaul_career_saveSystem.getCurrentProfile()
    end
  elseif career_career and career_career.isActive and career_career.isActive() then
    career = "vanilla"
    if career_modules_inventory and career_modules_inventory.getInventoryIdFromVehicleId then
      inventoryId = career_modules_inventory.getInventoryIdFromVehicleId(vid)
    end
    if career_saveSystem and career_saveSystem.getCurrentProfile then
      saveSlot, savePath = career_saveSystem.getCurrentProfile()
    end
  end

  send(jsonEncode({
    type = "config",
    vid = vid,
    role = role,
    model = veh:getJBeamFilename(),
    partConfigFilename = config.partConfigFilename,
    career = career or false,
    inventoryId = inventoryId,
    saveSlot = saveSlot,
    savePath = savePath,
    parts = parts,
    vars = config.vars,
  }))
end

-- start streaming from newly coupled vehicles, stop the ones no longer coupled
local function updateTrailers(veh, withConfig)
  local now = veh and coupledTo(veh:getID()) or {}
  for vid in pairs(now) do
    local t = be:getObjectByID(vid)
    if t then
      ensureStreamer(t, "trailer")
      if withConfig or not trailers[vid] then sendConfig(t, "trailer") end
    end
  end
  for vid in pairs(trailers) do
    if not now[vid] then
      local t = be:getObjectByID(vid)
      if t then t:queueLuaCommand('if extensions.tuningTelemetry_stream then extensions.tuningTelemetry_stream.configure("off") end') end
    end
  end
  trailers = now
end

local function mark()
  local veh = getDrivenVehicle()
  if not veh then return end
  veh:queueLuaCommand("if extensions.tuningTelemetry_stream then extensions.tuningTelemetry_stream.mark() end")
end

local function setMode(newMode)
  if not modes[newMode] or newMode == mode then return end
  mode = newMode
  checkTimer = checkPeriod -- push it to the vehicles on this frame
  send(jsonEncode({type = "modeAck", mode = mode}))
end

-- commands from the recorder window: {"type":"setMode","mode":"drift"} or {"type":"mark"}
local function readControl()
  if not control then return end
  for _ = 1, 10 do
    local data = control:receive()
    if not data then return end
    local ok, msg = pcall(jsonDecode, data)
    if ok and type(msg) == "table" then
      if msg.type == "setMode" then setMode(msg.mode)
      elseif msg.type == "mark" then mark()
      end
    end
  end
end

local function onUpdate(dtReal, dtSim, dtRaw)
  readControl()
  checkTimer = checkTimer + dtReal
  configTimer = configTimer + dtReal
  if checkTimer < checkPeriod then return end
  checkTimer = 0

  local veh = getDrivenVehicle()
  local withConfig = configTimer >= configPeriod
  if withConfig then configTimer = 0 end
  if veh then
    ensureStreamer(veh, "driver")
    if withConfig then sendConfig(veh, "driver") end
  end
  updateTrailers(veh, withConfig)
end

local function onVehicleSwitched(oldId, newId)
  local veh = getDrivenVehicle()
  if not veh then return end
  ensureStreamer(veh, "driver")
  sendConfig(veh, "driver")
end

local function onVehicleSpawned(vid)
  local veh = getDrivenVehicle()
  if veh and veh:getID() == vid then
    ensureStreamer(veh, "driver")
    configTimer = configPeriod -- send the new config on the next check, once the vehicle has settled
  end
end

local function onCouplerAttached(objId1, objId2)
  if objId1 == objId2 then return end
  couplings[math.min(objId1, objId2) .. ":" .. math.max(objId1, objId2)] = {objId1, objId2}
end

local function onCouplerDetached(objId1, objId2)
  couplings[math.min(objId1, objId2) .. ":" .. math.max(objId1, objId2)] = nil
end

local function onVehicleDestroyed(vid)
  for key, pair in pairs(couplings) do
    if pair[1] == vid or pair[2] == vid then couplings[key] = nil end
  end
  trailers[vid] = nil
end

local function onExtensionLoaded()
  udp = socket.udp()
  control = socket.udp()
  local ok, err = control:setsockname(address, controlPort)
  if ok then
    control:settimeout(0)
  else
    log("W", "tuningTelemetry", "Can't listen for recorder commands on port " .. controlPort .. ": " .. tostring(err))
    control:close()
    control = nil
  end
  log("I", "tuningTelemetry", string.format("Loaded, sending to %s:%d, commands on %d", address, port, controlPort))
end

local function onExtensionUnloaded()
  if udp then
    udp:close()
    udp = nil
  end
  if control then
    control:close()
    control = nil
  end
end

M.onExtensionLoaded = onExtensionLoaded
M.onExtensionUnloaded = onExtensionUnloaded
M.onUpdate = onUpdate
M.onVehicleSwitched = onVehicleSwitched
M.onVehicleSpawned = onVehicleSpawned
M.onVehicleDestroyed = onVehicleDestroyed
M.onCouplerAttached = onCouplerAttached
M.onCouplerDetached = onCouplerDetached
M.mark = mark
M.setMode = setMode

return M
