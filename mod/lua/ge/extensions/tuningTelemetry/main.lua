-- Tuning Telemetry: game engine side.
-- Keeps the vehicle streamer loaded in the player's vehicle (part changes respawn the
-- vehicle and drop its extensions), sends the vehicle's parts/tuning config to the
-- recorder, and handles the "mark" input action.

local M = {}

local socket = require("socket.socket")

local address = "127.0.0.1"
local port = 4445
local checkPeriod = 1 -- seconds between "is the streamer loaded?" checks
local configPeriod = 5 -- seconds between config repeats, so a recorder started mid-drive catches up
local maxDatagram = 60000

local udp
local checkTimer = 0
local configTimer = 0

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

local function ensureStreamer(veh)
  veh:queueLuaCommand('if not extensions.tuningTelemetry_stream then extensions.load("tuningTelemetry_stream") end')
end

local function sendConfig(veh)
  local vid = veh:getID()
  local vehData = core_vehicle_manager.getVehicleData(vid)
  local config = vehData and vehData.config
  if not config then return end

  local parts = config.parts
  if not parts and config.partsTree then
    parts = core_vehicle_partmgmt.partsTreeToPartsMap(config.partsTree)
  end

  local inventoryId
  if career_modules_inventory and career_modules_inventory.getInventoryIdFromVehicleId then
    inventoryId = career_modules_inventory.getInventoryIdFromVehicleId(vid)
  end

  send(jsonEncode({
    type = "config",
    vid = vid,
    model = veh:getJBeamFilename(),
    partConfigFilename = config.partConfigFilename,
    inventoryId = inventoryId,
    career = career_career and career_career.isActive and career_career.isActive() or false,
    parts = parts,
    vars = config.vars,
  }))
end

local function onUpdate(dtReal, dtSim, dtRaw)
  checkTimer = checkTimer + dtReal
  configTimer = configTimer + dtReal
  if checkTimer < checkPeriod then return end
  checkTimer = 0

  local veh = getPlayerVehicle(0)
  if not veh then return end
  ensureStreamer(veh)
  if configTimer >= configPeriod then
    configTimer = 0
    sendConfig(veh)
  end
end

local function onVehicleSwitched(oldId, newId)
  local veh = getPlayerVehicle(0)
  if not veh then return end
  ensureStreamer(veh)
  sendConfig(veh)
end

local function onVehicleSpawned(vid)
  local veh = getPlayerVehicle(0)
  if veh and veh:getID() == vid then
    ensureStreamer(veh)
    configTimer = configPeriod -- send the new config on the next check, once the vehicle has settled
  end
end

local function mark()
  local veh = getPlayerVehicle(0)
  if not veh then return end
  veh:queueLuaCommand("if extensions.tuningTelemetry_stream then extensions.tuningTelemetry_stream.mark() end")
end

local function onExtensionLoaded()
  udp = socket.udp()
  log("I", "tuningTelemetry", string.format("Loaded, sending to %s:%d", address, port))
end

local function onExtensionUnloaded()
  if udp then
    udp:close()
    udp = nil
  end
end

M.onExtensionLoaded = onExtensionLoaded
M.onExtensionUnloaded = onExtensionUnloaded
M.onUpdate = onUpdate
M.onVehicleSwitched = onVehicleSwitched
M.onVehicleSpawned = onVehicleSpawned
M.mark = mark

return M
