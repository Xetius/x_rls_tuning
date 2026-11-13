-- Tuning Telemetry: in-game graph window (Ctrl+Alt+Shift+G).
-- Pick any of the values the vehicle streamer records and watch them as live line graphs,
-- up to four stacked plots sharing one time axis. Marks show as vertical lines.
-- The streamer (vehicle side) sends only the picked values, and only while this asks for them.

local M = {}

local im = ui_imgui
local ffi = require("ffi")

local SETTINGS = "/settings/tuningTelemetry/graph.json"
local MAX_FIELDS = 12
local MAX_PLOTS = 4
local MAX_SECONDS = 120
local ASK_PERIOD = 1 -- seconds between requests to the vehicle (it stops after 3 s without one)

local showWindow = im.BoolPtr(false)
local recordHidden = im.BoolPtr(true)
local paused = false
local filterBuf = im.ArrayChar(64)
local windowSecs = im.FloatPtr(30)

local selected = {} -- {key=, plot=, color=}
local selVer = 1 -- bumped whenever the selection changes; data for an older one is dropped
local sentKeys = {} -- selVer -> list of keys in the order the vehicle sends them

local catalog = {} -- keys the vehicle has, sorted
local catalogInfo = {} -- {vid=, mode=, rate=}
local samples = {} -- {t=, v={key -> value}} oldest first
local first = 1 -- index of the oldest kept sample
local marks = {} -- {t=, n=}
local dataVid, lastT
local askTimer = ASK_PERIOD
local dirty = false
local saveAt = 0 -- settings are written a second after the last change, not on every slider step
local clockNow = 0 -- real seconds since load
local dataVer = 0 -- bumped on new samples, marks or a clear; the plots rebuild from it
local layoutVer = 0 -- bumped when the selection or plot assignment changes
local catalogVer = 0

-- ---------------------------------------------------------------- field descriptions

local RAD = 180 / math.pi
local MPH = 2.23694
local G = 1 / 9.81

-- key -> {label, unit, scale, group}
local info = {
  spd = {"Speed", "mph", MPH, "Speed & engine"},
  wspd = {"Wheel speed", "mph", MPH, "Speed & engine"},
  rpm = {"Engine rpm", "rpm", 1, "Speed & engine"},
  gin = {"Gearbox input rpm", "rpm", 1, "Speed & engine"},
  gear = {"Gear", "", 1, "Speed & engine"},
  gi = {"Gear index", "", 1, "Speed & engine"},
  revLim = {"Rev limiter cutting", "on/off", 1, "Speed & engine"},
  load = {"Engine load", "%", 100, "Speed & engine"},
  boost = {"Boost", "psi", 1, "Speed & engine"},
  cel = {"Check engine light", "on/off", 1, "Speed & engine"},
  thr = {"Throttle (after aids)", "%", 100, "Driver inputs"},
  thrIn = {"Throttle pedal", "%", 100, "Driver inputs"},
  brk = {"Brake (after aids)", "%", 100, "Driver inputs"},
  brkIn = {"Brake pedal", "%", 100, "Driver inputs"},
  clu = {"Clutch", "%", 100, "Driver inputs"},
  pbrk = {"Handbrake", "%", 100, "Driver inputs"},
  steerIn = {"Steering input (+ = right)", "%", 100, "Driver inputs"},
  steer = {"Steering wheel angle", "deg", 1, "Driver inputs"},
  ffb = {"Steering force to wheel", "% of max", 100, "Force feedback"},
  ffbOut = {"Steering force after damping/softlock", "% of max", 100, "Force feedback"},
  ffbLim = {"Steering force limit", "% of max", 100, "Force feedback"},
  gx = {"Lateral g (+ = turning left)", "g", G, "Chassis"},
  gy = {"Longitudinal g (- = accelerating)", "g", G, "Chassis"},
  gz = {"Vertical g", "g", G, "Chassis"},
  yawRate = {"Yaw rate", "deg/s", RAD, "Chassis"},
  hdg = {"Heading", "deg", 1, "Chassis"},
  slipAng = {"Slip angle (+ = travelling left of the nose)", "deg", 1, "Chassis"},
  roll = {"Roll", "deg", RAD, "Chassis"},
  pitch = {"Pitch", "deg", RAD, "Chassis"},
  rollRate = {"Roll rate", "deg/s", RAD, "Chassis"},
  pitchRate = {"Pitch rate", "deg/s", RAD, "Chassis"},
  ["pos.x"] = {"Position x", "m", 1, "Chassis"},
  ["pos.y"] = {"Position y", "m", 1, "Chassis"},
  ["pos.z"] = {"Elevation", "m", 1, "Chassis"},
  abs = {"ABS active", "on/off", 1, "Driver aids"},
  tcs = {"Traction control active", "on/off", 1, "Driver aids"},
  esc = {"ESC active", "on/off", 1, "Driver aids"},
  wtemp = {"Coolant temperature", "C", 1, "Temperatures & fuel"},
  otemp = {"Oil temperature", "C", 1, "Temperatures & fuel"},
  fuel = {"Fuel level", "%", 100, "Temperatures & fuel"},
  chute = {"Parachute deployed", "on/off", 1, "Temperatures & fuel"},
  ["ex.tq"] = {"Engine torque", "Nm", 1, "Engine limits"},
  ["ex.lim"] = {"Engine torque rating", "Nm", 1, "Engine limits"},
  ["ex.otd"] = {"Over-torque damage", "", 1, "Engine limits"},
  ["ex.otdMax"] = {"Over-torque damage limit", "", 1, "Engine limits"},
  ["ex.ord"] = {"Over-rev damage", "%", 100, "Engine limits"},
  ["fuelx.afr"] = {"Air-fuel ratio", "", 1, "RLS fuel model"},
  ["fuelx.tafr"] = {"Target air-fuel ratio", "", 1, "RLS fuel model"},
  ["fuelx.tim"] = {"Timing trim", "deg", 1, "RLS fuel model"},
  ["fuelx.etim"] = {"Timing after knock retard", "deg", 1, "RLS fuel model"},
  ["fuelx.kr"] = {"Knock retard", "deg", 1, "RLS fuel model"},
  ["fuelx.knock"] = {"Knock", "", 1, "RLS fuel model"},
  ["fuelx.lean"] = {"Lean severity", "", 1, "RLS fuel model"},
  ["fuelx.rich"] = {"Rich severity", "", 1, "RLS fuel model"},
  ["fuelx.duty"] = {"Fuel delivery duty", "%", 100, "RLS fuel model"},
  ["fuelx.tq"] = {"Fuel torque multiplier", "x", 1, "RLS fuel model"},
  ["fuelx.cool"] = {"Charge cooling", "C", 1, "RLS fuel model"},
  ["fuelx.xk"] = {"Knock damage exposure", "", 1, "RLS fuel model"},
  ["fuelx.xl"] = {"Lean damage exposure", "", 1, "RLS fuel model"},
}

local wheelInfo = {
  ws = {"wheel speed", "mph", MPH},
  av = {"angular velocity", "rad/s", 1},
  slip = {"longitudinal slip", "m/s", 1},
  sslip = {"side slip", "m/s", 1},
  load = {"load", "N", 1},
  tq = {"drive torque (sign mirrored left/right)", "Nm", 1},
  btq = {"brake torque", "Nm", 1},
  se = {"slip energy", "", 1},
  bt = {"brake temperature", "C", 1},
  tt = {"tyre temperature", "C", 1},
  psi = {"tyre pressure", "psi", 1},
  broken = {"broken", "on/off", 1},
  deflated = {"deflated", "on/off", 1},
}

local groupOrder = {"Driver inputs", "Speed & engine", "Chassis", "Force feedback", "Driver aids",
  "Wheels", "Dampers", "Temperatures & fuel", "Engine limits", "RLS fuel model", "Other"}

local function describeUncached(key)
  local i = info[key]
  if i then return i[1], i[2], i[3], i[4] end
  local wheel, field = key:match("^w%.([^.]+)%.(.+)$")
  if wheel then
    local wi = wheelInfo[field]
    if wi then return wheel .. " " .. wi[1], wi[2], wi[3], "Wheels" end
    return wheel .. " " .. field, "", 1, "Wheels"
  end
  local damper = key:match("^d%.(.+)$")
  if damper then return damper .. " damper compression", "mm", 1, "Dampers" end
  return key, "", 1, "Other"
end

-- label, unit, scale, group; worked out once per key
local descCache = {}
local function describe(key)
  local d = descCache[key]
  if not d then
    local name, unit, scale, group = describeUncached(key)
    d = {name, unit, scale, group, name .. (unit ~= "" and (" (" .. unit .. ")") or "")}
    descCache[key] = d
  end
  return d[1], d[2], d[3], d[4], d[5]
end

local palette = {
  {0.30, 0.69, 0.98}, {0.98, 0.55, 0.20}, {0.40, 0.85, 0.40}, {0.95, 0.35, 0.40},
  {0.75, 0.55, 0.95}, {0.95, 0.85, 0.30}, {0.35, 0.90, 0.85}, {0.95, 0.55, 0.80},
  {0.65, 0.65, 0.65}, {0.60, 0.80, 0.30}, {0.85, 0.65, 0.45}, {0.55, 0.65, 1.00},
}

local function colU32(c, a) return im.GetColorU322(im.ImVec4(c[1], c[2], c[3], a or 1)) end

-- ---------------------------------------------------------------- presets

-- each entry: a Lua pattern over field names and the plot it goes on
local presets = {
  {name = "Steering feel", items = {{"^steerIn$", 1}, {"^ffb$", 1}, {"^gx$", 2}, {"^slipAng$", 2}, {"^w%.F[^.]*%.sslip$", 3}, {"^thrIn$", 4}}},
  {name = "Traction", items = {{"^thrIn$", 1}, {"^tcs$", 1}, {"^w%.[^.]+%.slip$", 2}, {"^gy$", 3}, {"^spd$", 4}}},
  {name = "Braking", items = {{"^brkIn$", 1}, {"^abs$", 1}, {"^w%.[^.]+%.slip$", 2}, {"^gy$", 3}, {"^w%.[^.]+%.bt$", 4}}},
  {name = "Engine", items = {{"^rpm$", 1}, {"^thr$", 2}, {"^boost$", 2}, {"^ex%.tq$", 3}, {"^ex%.lim$", 3}, {"^wtemp$", 4}, {"^otemp$", 4}}},
  {name = "Suspension", items = {{"^d%.", 1}, {"^roll$", 2}, {"^pitch$", 2}, {"^gz$", 3}, {"^w%.[^.]+%.load$", 4}}},
}

-- ---------------------------------------------------------------- selection

local function isSelected(key)
  for i, s in ipairs(selected) do
    if s.key == key then return i end
  end
end

local function freeColor()
  local used = {}
  for _, s in ipairs(selected) do used[s.color] = true end
  for i = 1, #palette do
    if not used[i] then return i end
  end
  return 1
end

local function saveSettings()
  local list = {}
  for _, s in ipairs(selected) do list[#list + 1] = {key = s.key, plot = s.plot, color = s.color} end
  jsonWriteFile(SETTINGS, {fields = list, window = windowSecs[0], recordHidden = recordHidden[0]}, true)
end

local function markDirty()
  dirty = true
  saveAt = clockNow + 1
end

local function selectionChanged()
  selVer = selVer + 1
  layoutVer = layoutVer + 1
  askTimer = ASK_PERIOD -- tell the vehicle on this frame
  markDirty()
end

local function addField(key, plot)
  if isSelected(key) or #selected >= MAX_FIELDS then return end
  table.insert(selected, {key = key, plot = plot or 1, color = freeColor()})
  selectionChanged()
end

local function removeField(key)
  local i = isSelected(key)
  if not i then return end
  table.remove(selected, i)
  selectionChanged()
end

local function applyPreset(p)
  selected = {}
  for _, item in ipairs(p.items) do
    for _, key in ipairs(catalog) do
      if key:find(item[1]) then addField(key, item[2]) end
    end
  end
  selectionChanged()
end

local function clearData()
  samples, first, marks, lastT = {}, 1, {}, nil
  dataVer = dataVer + 1
end

-- ---------------------------------------------------------------- data from the vehicle

local function drivenVehicle()
  local veh = getPlayerVehicle(0)
  if veh and veh:getJBeamFilename() ~= "unicycle" then return veh end
end

local function wantData()
  return showWindow[0] or (recordHidden[0] and #selected > 0)
end

local function ask(veh, on)
  local keys = "nil"
  if on then
    local list = {}
    for i, s in ipairs(selected) do list[i] = s.key end
    sentKeys = {[selVer] = list}
    keys = serialize(list)
  end
  veh:queueLuaCommand(string.format(
    "if extensions.tuningTelemetry_stream then extensions.tuningTelemetry_stream.setGraph(%d, %s) end", selVer, keys))
end

function M.onCatalog(vid, mode, rate, keys)
  keys = keys or {}
  local same = #keys == #catalog
  if same then
    for i = 1, #keys do
      if keys[i] ~= catalog[i] then same = false break end
    end
  end
  if not same then
    catalog = keys
    catalogVer = catalogVer + 1
  end
  catalogInfo.vid, catalogInfo.mode, catalogInfo.rate = vid, mode, rate
end

function M.onData(vid, ver, t, vals)
  if paused or not t then return end
  local keys = sentKeys[ver]
  if not keys then return end
  if vid ~= dataVid or (lastT and t < lastT) then
    clearData() -- another car, or the car was respawned (its clock restarts)
    dataVid = vid
  end
  lastT = t
  local v = {}
  for i, key in ipairs(keys) do v[key] = vals[i] end
  samples[#samples + 1] = {t = t, v = v}
  -- drop samples older than the longest window; compact now and then
  while first < #samples and t - samples[first].t > MAX_SECONDS do first = first + 1 end
  if first > 2000 then
    local kept = {}
    for i = first, #samples do kept[#kept + 1] = samples[i] end
    samples, first = kept, 1
  end
  dataVer = dataVer + 1
end

function M.onMark(vid, t, n)
  if vid == dataVid and t then
    marks[#marks + 1] = {t = t, n = n, label = "M" .. tostring(n)}
    dataVer = dataVer + 1
  end
end

-- ---------------------------------------------------------------- drawing
-- The plot lines are worked out at most REBUILD_PERIOD apart (or when the layout changes) and kept
-- as plain numbers; every frame only replays them. Two scratch vectors are reused for every draw
-- call, so drawing makes no garbage.

local REBUILD_PERIOD = 0.05 -- seconds: plots follow the data at up to 20 updates a second
local COLUMN = 2 -- pixels per column of the line simplification

local v1, v2 -- scratch ImVec2s, made on first draw
local colors -- U32 colours, made on first draw (they need an imgui context)
local paletteU32 = {}

local function setupDraw()
  if v1 then return end
  v1, v2 = im.ImVec2(0, 0), im.ImVec2(0, 0)
  colors = {
    bg = im.GetColorU322(im.ImVec4(0.08, 0.08, 0.10, 0.9)),
    border = im.GetColorU322(im.ImVec4(0.35, 0.35, 0.40, 1)),
    grid = im.GetColorU322(im.ImVec4(1, 1, 1, 0.08)),
    zero = im.GetColorU322(im.ImVec4(1, 1, 1, 0.25)),
    label = im.GetColorU322(im.ImVec4(0.7, 0.7, 0.7, 1)),
    dim = im.GetColorU322(im.ImVec4(0.6, 0.6, 0.6, 1)),
    mark = im.GetColorU322(im.ImVec4(1, 0.85, 0.2, 0.7)),
    markText = im.GetColorU322(im.ImVec4(1, 0.85, 0.2, 1)),
    cursor = im.GetColorU322(im.ImVec4(1, 1, 1, 0.5)),
    white = im.GetColorU322(im.ImVec4(1, 1, 1, 1)),
  }
  for i, c in ipairs(palette) do paletteU32[i] = im.GetColorU322(im.ImVec4(c[1], c[2], c[3], 1)) end
end

local function line(dl, x1, y1, x2, y2, col, thick)
  v1.x, v1.y, v2.x, v2.y = x1, y1, x2, y2
  im.ImDrawList_AddLine(dl, v1, v2, col, thick or 1)
end
local function rectFilled(dl, x1, y1, x2, y2, col)
  v1.x, v1.y, v2.x, v2.y = x1, y1, x2, y2
  im.ImDrawList_AddRectFilled(dl, v1, v2, col)
end
local function rect(dl, x1, y1, x2, y2, col)
  v1.x, v1.y, v2.x, v2.y = x1, y1, x2, y2
  im.ImDrawList_AddRect(dl, v1, v2, col)
end
local function text(dl, x, y, col, str)
  v1.x, v1.y = x, y
  im.ImDrawList_AddText1(dl, v1, col, str)
end

local function fmt(x)
  if x == nil then return "-" end
  local a = math.abs(x)
  if a >= 1000 then return string.format("%.0f", x) end
  if a >= 100 then return string.format("%.1f", x) end
  if a >= 10 then return string.format("%.2f", x) end
  return string.format("%.3f", x)
end

-- index of the last sample at or before time t (binary search over the kept samples)
local function sampleAt(t)
  local lo, hi = first, #samples
  if hi < lo or samples[lo].t > t then return nil end
  while lo < hi do
    local mid = math.floor((lo + hi + 1) / 2)
    if samples[mid].t <= t then lo = mid else hi = mid - 1 end
  end
  return lo
end

local function legendText(s, idx)
  local name, unit, scale = describe(s.key)
  local val = idx and samples[idx] and samples[idx].v[s.key]
  return string.format("%s: %s %s", name, val and fmt(val * scale) or "-", unit)
end

-- cached plot geometry, relative to each plot's top-left corner
local geo = {plots = {}, builtAt = -1, dataVer = -1, layoutVer = -1, w = 0, h = 0, span = 0, nPlots = 0, tEnd = 0, axis = {}, nAxis = 0}

local function buildPlot(pc, plotIdx, w, h, tEnd, span)
  local series = pc.series
  local n = 0
  for _, s in ipairs(selected) do
    if s.plot == plotIdx then
      n = n + 1
      series[n] = s
    end
  end
  for i = n + 1, #series do series[i] = nil end
  if n == 0 then return end

  local tStart = tEnd - span
  local i0 = sampleAt(tStart) or first

  local lo, hi = math.huge, -math.huge
  for _, s in ipairs(series) do
    local _, _, scale = describe(s.key)
    local key = s.key
    for i = i0, #samples do
      local val = samples[i].v[key]
      if val then
        val = val * scale
        if val < lo then lo = val end
        if val > hi then hi = val end
      end
    end
  end
  if lo > hi then lo, hi = 0, 1 end
  if hi - lo < 1e-6 then lo, hi = lo - 1, hi + 1 end
  local pad = (hi - lo) * 0.06
  lo, hi = lo - pad, hi + pad
  local yk = h / (hi - lo)
  local xk = w / span

  for k = 0, 4 do
    local val = lo + (hi - lo) * k / 4
    pc.gridY[k] = h - (val - lo) * yk
    pc.gridText[k] = fmt(val)
  end
  pc.zeroY = (lo < 0 and hi > 0) and (h + lo * yk) or nil

  local nm = 0
  for _, m in ipairs(marks) do
    if m.t >= tStart and m.t <= tEnd then
      nm = nm + 1
      pc.markX[nm], pc.markText[nm] = (m.t - tStart) * xk, m.label
    end
  end
  pc.nMarks = nm

  for j, s in ipairs(series) do
    local _, _, scale = describe(s.key)
    local key = s.key
    local segs = pc.segs[j] or {}
    pc.segs[j] = segs
    local ns = 0
    local colX, cMin, cMax, cFirst, cLast, prevX, prevY
    local function flush()
      if not colX then return end
      local yF = h - (cFirst - lo) * yk
      if prevX then
        segs[ns + 1], segs[ns + 2], segs[ns + 3], segs[ns + 4] = prevX, prevY, colX, yF
        ns = ns + 4
      end
      local yMin, yMax = h - (cMin - lo) * yk, h - (cMax - lo) * yk
      if yMin - yMax >= 1.5 then
        segs[ns + 1], segs[ns + 2], segs[ns + 3], segs[ns + 4] = colX, yMax, colX, yMin
        ns = ns + 4
      end
      prevX, prevY = colX, h - (cLast - lo) * yk
    end
    for i = i0, #samples do
      local smp = samples[i]
      local val = smp.v[key]
      if val == nil then
        flush()
        colX, prevX = nil, nil -- gap in the data
      else
        val = val * scale
        local x = math.floor((smp.t - tStart) * xk / COLUMN) * COLUMN + 0.5
        if x ~= colX then
          flush()
          colX, cMin, cMax, cFirst, cLast = x, val, val, val, val
        else
          if val < cMin then cMin = val end
          if val > cMax then cMax = val end
          cLast = val
        end
      end
    end
    flush()
    pc.nSegs[j] = ns
    pc.legend[j] = legendText(s, #samples)
  end
end

local function drawPlot(dl, x0, y0, w, h, pc, hoverIdx)
  rectFilled(dl, x0, y0, x0 + w, y0 + h, colors.bg)
  rect(dl, x0, y0, x0 + w, y0 + h, colors.border)
  local series = pc.series
  if #series == 0 then
    text(dl, x0 + 6, y0 + 4, colors.dim, pc.emptyText)
    return
  end
  for k = 0, 4 do
    local y = y0 + pc.gridY[k]
    line(dl, x0, y, x0 + w, y, colors.grid)
    if k > 0 and k < 4 then text(dl, x0 + w - 60, y - 14, colors.label, pc.gridText[k]) end
  end
  if pc.zeroY then line(dl, x0, y0 + pc.zeroY, x0 + w, y0 + pc.zeroY, colors.zero) end
  for i = 1, pc.nMarks do
    local x = x0 + pc.markX[i]
    line(dl, x, y0, x, y0 + h, colors.mark, 1.5)
    text(dl, x + 3, y0 + h - 16, colors.markText, pc.markText[i])
  end
  for j, s in ipairs(series) do
    local col = paletteU32[s.color] or colors.white
    local segs = pc.segs[j]
    for k = 1, pc.nSegs[j], 4 do
      line(dl, x0 + segs[k], y0 + segs[k + 1], x0 + segs[k + 2], y0 + segs[k + 3], col, 1.5)
    end
  end
  local ly = y0 + 4
  for j, s in ipairs(series) do
    local col = paletteU32[s.color] or colors.white
    rectFilled(dl, x0 + 6, ly + 4, x0 + 16, ly + 12, col)
    text(dl, x0 + 20, ly, col, hoverIdx and legendText(s, hoverIdx) or pc.legend[j])
    ly = ly + 16
  end
end

local function drawPlots()
  setupDraw()
  local avail = im.GetContentRegionAvail()
  local w, h = math.max(avail.x, 100), math.max(avail.y - 22, 100)
  local origin = im.GetCursorScreenPos()
  local ox, oy = origin.x, origin.y
  local nPlots = 1
  for _, s in ipairs(selected) do nPlots = math.max(nPlots, s.plot) end
  local gap = 6
  local ph = (h - gap * (nPlots - 1)) / nPlots

  v1.x, v1.y = w, h
  im.InvisibleButton("##ttGraphArea", v1)
  local hovered = im.IsItemHovered()
  local dl = im.GetWindowDrawList()

  local span = windowSecs[0]
  local tEnd = (#samples >= first and samples[#samples]) and samples[#samples].t or span

  -- rebuild the geometry when the layout changed, or new data arrived and enough time passed
  local layoutChanged = geo.layoutVer ~= layoutVer or geo.w ~= w or geo.h ~= h or geo.span ~= span or geo.nPlots ~= nPlots
  if layoutChanged or (geo.dataVer ~= dataVer and clockNow - geo.builtAt >= REBUILD_PERIOD) then
    for p = 1, nPlots do
      local pc = geo.plots[p]
      if not pc then
        pc = {series = {}, segs = {}, nSegs = {}, legend = {}, gridY = {}, gridText = {}, markX = {}, markText = {}, nMarks = 0,
          emptyText = "Plot " .. p .. ": nothing assigned"}
        geo.plots[p] = pc
      end
      buildPlot(pc, p, w, ph, tEnd, span)
    end
    geo.builtAt, geo.dataVer, geo.layoutVer, geo.w, geo.h, geo.span, geo.nPlots, geo.tEnd = clockNow, dataVer, layoutVer, w, h, span, nPlots, tEnd
    -- time axis labels: seconds before the newest sample
    local step = span <= 10 and 1 or (span <= 30 and 5 or (span <= 60 and 10 or 20))
    local na = 0
    for s = 0, span, step do
      na = na + 1
      local a = geo.axis[na] or {}
      geo.axis[na] = a
      a.x = math.min(w - s / span * w, w - 30)
      a.text = s == 0 and "now" or ("-" .. s .. " s")
    end
    geo.nAxis = na
  end

  local hoverT, hoverIdx
  if hovered and #samples >= first then
    hoverT = geo.tEnd - span + (im.GetMousePos().x - ox) / w * span
    hoverIdx = sampleAt(hoverT)
  end
  for p = 1, nPlots do
    drawPlot(dl, ox, oy + (p - 1) * (ph + gap), w, ph, geo.plots[p], hoverIdx)
  end
  if hoverT then
    local x = ox + (hoverT - (geo.tEnd - span)) / span * w
    line(dl, x, oy, x, oy + h, colors.cursor)
  end
  for i = 1, geo.nAxis do
    text(dl, ox + geo.axis[i].x, oy + h + 3, colors.label, geo.axis[i].text)
  end
  if hoverT then
    text(dl, ox + 4, oy + h + 3, colors.white, string.format("cursor %.2f s before now", geo.tEnd - hoverT))
  end
  v1.x, v1.y = w, 20
  im.Dummy(v1)
end

-- the grouped, filtered list of values; rebuilt only when the catalog or the filter changes
local picker = {catalogVer = -1, filter = nil, groups = {}}
local checkPtr = im.BoolPtr(false)
local plotNames = {}
for p = 1, MAX_PLOTS do plotNames[p] = {short = "P" .. p, long = "Plot " .. p} end

local function buildPicker(filter)
  local byGroup = {}
  for _, key in ipairs(catalog) do
    local name, _, _, group, label = describe(key)
    if filter == "" or name:lower():find(filter, 1, true) or key:lower():find(filter, 1, true) then
      byGroup[group] = byGroup[group] or {}
      table.insert(byGroup[group], {key = key, name = name, label = label .. "##" .. key})
    end
  end
  local groups = {}
  for _, group in ipairs(groupOrder) do
    local list = byGroup[group]
    if list then
      table.sort(list, function(a, b) return a.name < b.name end)
      groups[#groups + 1] = {header = string.format("%s (%d)##grp%s", group, #list, group), items = list}
    end
  end
  picker.groups, picker.catalogVer, picker.filter = groups, catalogVer, filter
end

local function drawPicker()
  setupDraw()
  im.TextUnformatted(string.format("Selected (%d/%d):", #selected, MAX_FIELDS))
  local removeKey, changed
  for _, s in ipairs(selected) do
    im.PushID1(s.key)
    local c = palette[s.color]
    im.ColorButton("##c", im.ImVec4(c[1], c[2], c[3], 1), 0, im.ImVec2(12, 12))
    im.SameLine()
    im.SetNextItemWidth(46)
    if im.BeginCombo("##plot", plotNames[s.plot].short) then
      for p = 1, MAX_PLOTS do
        if im.Selectable1(plotNames[p].long, s.plot == p) then
          s.plot = p
          changed = true
        end
      end
      im.EndCombo()
    end
    im.SameLine()
    if im.SmallButton("x") then removeKey = s.key end
    im.SameLine()
    local _, _, _, _, label = describe(s.key)
    im.TextUnformatted(label)
    im.PopID()
  end
  if removeKey then removeField(removeKey) end
  if changed then
    layoutVer = layoutVer + 1
    markDirty()
  end
  if #selected == 0 then im.TextDisabled("Tick values below, or pick a preset.") end

  im.Separator()
  im.SetNextItemWidth(-1)
  if im.BeginCombo("##preset", "Preset...") then
    for _, p in ipairs(presets) do
      if im.Selectable1(p.name) then applyPreset(p) end
    end
    im.EndCombo()
  end
  im.SetNextItemWidth(-1)
  im.InputText("##filter", filterBuf, 64)
  local filter = ffi.string(filterBuf):lower()
  if filter == "" then im.TextDisabled("Type to filter the list") end

  if #catalog == 0 then
    im.TextWrapped("No values yet. Get in a car; the list fills in within a couple of seconds.")
    return
  end
  if picker.catalogVer ~= catalogVer or picker.filter ~= filter then buildPicker(filter) end
  local openFlag = filter ~= "" and im.TreeNodeFlags_DefaultOpen or 0
  for _, g in ipairs(picker.groups) do
    if im.CollapsingHeader1(g.header, openFlag) then
      for _, f in ipairs(g.items) do
        checkPtr[0] = isSelected(f.key) ~= nil
        if im.Checkbox(f.label, checkPtr) then
          if checkPtr[0] then addField(f.key, 1) else removeField(f.key) end
        end
        if im.IsItemHovered() then im.SetTooltip(f.key) end
      end
    end
  end
end

local function drawWindow()
  im.SetNextWindowSize(im.ImVec2(1100, 640), im.Cond_FirstUseEver)
  if im.Begin("Telemetry Graph##tuningTelemetryGraph", showWindow) then
    if im.Button(paused and "Resume" or "Pause") then paused = not paused end
    im.SameLine()
    if im.Button("Clear") then clearData() end
    im.SameLine()
    im.SetNextItemWidth(180)
    if im.SliderFloat("Seconds shown", windowSecs, 5, MAX_SECONDS, "%.0f s") then markDirty() end
    im.SameLine()
    if im.Checkbox("Keep recording while closed", recordHidden) then markDirty() end
    im.SameLine()
    if catalogInfo.mode then
      im.TextDisabled(string.format("Driving mode: %s, %d per second", catalogInfo.mode, catalogInfo.rate or 0))
      if im.IsItemHovered() then im.SetTooltip("The recorder's driving mode decides which values exist and how often they update.\nUse the 'all' mode in the recorder window to see everything.") end
    end
    if paused then
      im.SameLine()
      im.TextColored(im.ImVec4(1, 0.8, 0.2, 1), "PAUSED")
    end

    im.BeginChild1("##ttPicker", im.ImVec2(330, 0), true)
    drawPicker()
    im.EndChild()
    im.SameLine()
    im.BeginChild1("##ttPlots", im.ImVec2(0, 0), false)
    if #selected == 0 then
      im.TextUnformatted("Pick values on the left to plot them. Assign each to plot 1-4 to stack graphs with different units.")
    elseif #samples < first then
      im.TextUnformatted(drivenVehicle() and "Waiting for data..." or "Get in a car to see data.")
    else
      drawPlots()
    end
    im.EndChild()
  end
  im.End()
end

-- ---------------------------------------------------------------- lifecycle

function M.toggleWindow()
  showWindow[0] = not showWindow[0]
  askTimer = ASK_PERIOD
end

function M.onUpdate(dtReal)
  dtReal = dtReal or 0
  clockNow = clockNow + dtReal
  askTimer = askTimer + dtReal
  if askTimer >= ASK_PERIOD then
    askTimer = 0
    local veh = drivenVehicle()
    if veh then ask(veh, wantData()) end
  end
  if showWindow[0] then drawWindow() end
  if dirty and clockNow >= saveAt then
    dirty = false
    saveSettings()
  end
end

function M.onVehicleSwitched()
  askTimer = ASK_PERIOD
end

function M.onExtensionLoaded()
  local s = jsonReadFile(SETTINGS)
  if type(s) == "table" then
    if type(s.fields) == "table" then
      for _, f in ipairs(s.fields) do
        if type(f.key) == "string" and #selected < MAX_FIELDS then
          table.insert(selected, {key = f.key, plot = math.max(1, math.min(MAX_PLOTS, tonumber(f.plot) or 1)), color = tonumber(f.color) or freeColor()})
        end
      end
    end
    if tonumber(s.window) then windowSecs[0] = math.max(5, math.min(MAX_SECONDS, s.window)) end
    if s.recordHidden ~= nil then recordHidden[0] = s.recordHidden and true or false end
  end
end

function M.onExtensionUnloaded()
  local veh = drivenVehicle()
  if veh then ask(veh, false) end
end

return M
