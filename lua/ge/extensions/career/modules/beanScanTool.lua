-- BeanAuctions scan tool: reads an owned vehicle's part conditions, turns them into
-- OBD-style trouble codes and repairs them for parts + labor.
-- UI lives in the BeanAuctions web page (Scan Tool tab); beanAuctions.lua routes actions here.

local M = {}
M.dependencies = {'career_career', 'career_modules_beanValue'}

local laborRate = 125   -- $/hour
local scanRange = 15    -- metres: you have to be at the car to plug in
local minPartValue = 150

-- repair recipes: share of the part's value spent on parts (at least minParts), and book labor hours
local repairs = {
  ignition = {parts = 0.06, minParts = 280, hours = 1.5, severity = "Moderate", fix = "Replace ignition coils, plugs, reflash ECU"},
  engine = {parts = 0.45, minParts = 1600, hours = 12, severity = "Critical", fix = "Engine rebuild (rings, bearings, gaskets)"},
  transmission = {parts = 0.4, minParts = 1200, hours = 8, severity = "Critical", fix = "Transmission rebuild (clutches, synchros)"},
  cooling = {parts = 0.8, minParts = 260, hours = 2, severity = "Moderate", fix = "Replace radiator, flush coolant"},
  turbo = {parts = 0.6, minParts = 900, hours = 4, severity = "Moderate", fix = "Replace turbocharger"},
  powertrain = {parts = 0.5, minParts = 300, hours = 3, severity = "Moderate", fix = "Replace component"},
  body = {parts = 1, minParts = 0, hours = 1.5, severity = "Minor", fix = "Replace damaged part"},
}

-- refurbishing: rebuild a whole mechanical system with refurbished parts. Parts come back to
-- career_modules_beanValue.refurbishMax (95%) at best, never new. A part belongs to the first
-- system whose name pattern it contains; anything else (shell, frame, panels, interior, paint,
-- glass, wheels) is body work, so refurbishing every system puts the whole car at 95%.
local systems = {
  {id = "engine", name = "Engine", hours = 10, match = {"engine", "internals", "intake", "turbo", "supercharger", "radiator", "ecu", "header"}},
  {id = "trans", name = "Transmission & clutch", hours = 6, match = {"transmission", "transaxle", "gearbox", "clutch", "flywheel", "converter", "transfer_case"}},
  {id = "driveline", name = "Driveline", hours = 4, match = {"differential", "finaldrive", "driveshaft", "halfshaft", "axle", "hub"}},
  {id = "chassis", name = "Suspension, steering & brakes", hours = 5, match = {"suspension", "coilover", "shock", "strut", "spring", "leaf", "swaybar", "brake", "steering", "ifs", "trailingarm", "knuckle"}},
  {id = "body", name = "Body, frame & interior", hours = 20, match = {}}, -- catch-all, see systemOf
}
local refurbPartsShare = 0.6 -- parts cost: this share of a part's value per 100% of condition restored

local scans = {} -- inventoryId -> {at = os.time(), faults = {...}}
local pending   -- inventoryId being refreshed

local function partInfo(inventoryId, partPath)
  local map = career_modules_partInventory.getPartPathToPartIdMap()[inventoryId]
  local part = map and career_modules_partInventory.getInventory()[map[partPath]]
  local name = part and part.description and part.description.description or partPath:match("[^/]+$")
  local value = part and part.partCondition and career_modules_valueCalculator.getPartValue(part) or (part and part.value) or minPartValue
  return name, math.max(value or 0, minPartValue)
end

local function anyTrue(t)
  for _, v in pairs(t or {}) do if v == true then return true end end
end

-- returns kind, codes or nil for one partConditions entry
local function classify(c)
  local iv = c.integrityValue or 1
  local pt = c.integrityState and c.integrityState.powertrain
  if pt then
    for devName, st in pairs(pt) do
      if type(st) == "table" then
        if st.fastIgnitionErrorChance ~= nil or st.thermals then
          local th = st.thermals or {}
          if st.isBroken or anyTrue(th) or iv < 0.35 then
            local codes = {{"P0300", "Random/Multiple Cylinder Misfire Detected"}, {"P0325", "Knock Sensor 1 Circuit (Bank 1)"}}
            if th.headGasketDamaged or th.engineBlockMelted then table.insert(codes, {"P0217", "Engine Coolant Over Temperature Condition"}) end
            if th.connectingRodBearingsDamaged then table.insert(codes, {"P0524", "Engine Oil Pressure Too Low"}) end
            if st.isBroken then table.insert(codes, {"P0335", "Crankshaft Position Sensor A Circuit (no start)"}) end
            return "engine", codes
          elseif iv < 0.97 or (st.fastIgnitionErrorChance or 0) > 0.02 then
            return "ignition", {{"P0300", "Random/Multiple Cylinder Misfire Detected"}, {"P0351", "Ignition Coil A Primary/Secondary Circuit"}, {"P0606", "Control Module Processor Fault"}}
          end
        elseif (st.radiatorDamage or 0) > 0 then
          return "cooling", {{"P0217", "Engine Coolant Over Temperature Condition"}, {"P2560", "Engine Coolant Level Low"}}
        elseif devName:lower():find("gearbox") and (iv < 0.97 or (st.damageFrictionCoef or 1) > 1.05 or st.isBroken) then
          return "transmission", {{"P0700", "Transmission Control System Malfunction"}, {"P0730", "Incorrect Gear Ratio"}}
        elseif devName:lower():find("turbo") and iv < 0.97 then
          return "turbo", {{"P0299", "Turbocharger/Supercharger A Underboost"}}
        elseif iv < 0.97 then
          return "powertrain", {{"P0700", "Powertrain Component Malfunction (" .. devName .. ")"}}
        end
      end
    end
  end
  if iv == 0 then return "body", {{"B1A00", "Body/Chassis Component Damaged"}} end
end

local function diagnose(inventoryId)
  local veh = career_modules_inventory.getVehicles()[inventoryId]
  local faults = {}
  for partPath, c in pairs(veh and veh.partConditions or {}) do
    local kind, codes = classify(c)
    if kind then
      local name, value = partInfo(inventoryId, partPath)
      local r = repairs[kind]
      local parts, labor = math.floor(math.max(value * r.parts, r.minParts)), math.floor(r.hours * laborRate)
      table.insert(faults, {path = partPath, kind = kind, part = name, codes = codes, severity = r.severity, fix = r.fix,
        hours = r.hours, parts = parts, labor = labor, total = parts + labor})
    end
  end
  local rank = {Critical = 1, Moderate = 2, Minor = 3}
  table.sort(faults, function(a, b) if a.severity ~= b.severity then return rank[a.severity] < rank[b.severity] end return a.total > b.total end)
  return faults
end

local function nearby(inventoryId)
  local vehId = career_modules_inventory.getVehicleIdFromInventoryId(inventoryId)
  local obj = vehId and getObjectByID(vehId)
  if not obj then return false, "Vehicle isn't spawned. Get it out of storage first." end
  local player = getPlayerVehicle(0)
  if not player or obj:getPosition():distance(player:getPosition()) > scanRange then return false, "Get closer to the vehicle to plug in the scanner." end
  return true, vehId
end

-- pulls live conditions from the car first, then calls done(faults) / done(nil, err)
local function scan(inventoryId, done)
  local ok, vehIdOrErr = nearby(inventoryId)
  if not ok then return done(nil, vehIdOrErr) end
  pending = inventoryId
  career_modules_inventory.updatePartConditions(vehIdOrErr, inventoryId, function()
    pending = nil
    scans[inventoryId] = {at = os.time(), faults = diagnose(inventoryId)}
    done(scans[inventoryId].faults)
  end)
end

-- paths: part paths to fix (nil = everything). Re-reads the live car first so the price
-- matches its current state and damage taken after the scan isn't repaired for free.
-- done(ok, message)
local function repair(inventoryId, paths, done)
  if not scans[inventoryId] then return done(false, "Scan the vehicle first") end
  local ok, vehIdOrErr = nearby(inventoryId)
  if not ok then return done(false, vehIdOrErr) end
  pending = inventoryId
  career_modules_inventory.updatePartConditions(vehIdOrErr, inventoryId, function()
    pending = nil
    local veh = career_modules_inventory.getVehicles()[inventoryId]
    local faults = diagnose(inventoryId)
    scans[inventoryId] = {at = os.time(), faults = faults}
    local want, total, todo = {}, 0, {}
    for _, p in ipairs(paths or {}) do want[p] = true end
    for _, f in ipairs(faults) do
      if not paths or want[f.path] then total = total + f.total table.insert(todo, f) end
    end
    if not veh or #todo == 0 then return done(false, "Nothing to repair") end
    if career_modules_playerAttributes.getAttributeValue("money") < total then return done(false, "Not enough money ($" .. total .. " needed)") end

    local body = {}
    for _, f in ipairs(todo) do
      local c = veh.partConditions[f.path]
      if f.kind == "body" then
        body[f.path] = c -- broken parts go through the stock repair so paint/repairCount stay consistent
      else
        c.integrityValue = 1
        c.integrityState = nil
      end
    end
    if next(body) then career_modules_insurance_insurance.repairPartConditions({partConditions = body, inventoryId = inventoryId}) end

    career_modules_playerAttributes.addAttributes({money = -total}, {tags = {"repair"}, label = string.format("Scan tool repair: %d fault(s)", #todo)})
    scans[inventoryId] = nil
    career_modules_insurance_insurance.startRepairInstant(veh) -- respawns the car with the fixed conditions and saves
    career_modules_beanValue.invalidate(inventoryId)
    done(true, string.format("Repaired %d fault(s) for $%d", #todo, total))
  end)
end

local function systemOf(partName)
  local n = partName:lower()
  for _, sys in ipairs(systems) do
    for _, pat in ipairs(sys.match) do if n:find(pat, 1, true) then return sys end end
  end
  return systems[#systems]
end

-- per system: value-weighted condition, the parts that need work, and the price to bring them to the cap
local function refurbPlan(inventoryId, fresh)
  local bv = career_modules_beanValue
  local plan = {}
  for _, sys in ipairs(systems) do plan[sys.id] = {id = sys.id, name = sys.name, hours = sys.hours, parts = {}, value = 0, scoreSum = 0, partsCost = 0} end
  for _, part in ipairs(bv.partsOf(inventoryId, fresh)) do
    local sys = part.partCondition and systemOf(part.name or "")
    if sys then
      local p, value, score = plan[sys.id], math.max(part.value or 0, 1), bv.partScore(part.partCondition)
      p.value, p.scoreSum = p.value + value, p.scoreSum + value * score
      if score < bv.refurbishMax - 0.005 then
        table.insert(p.parts, part)
        p.partsCost = p.partsCost + value * refurbPartsShare * (bv.refurbishMax - score)
      end
    end
  end
  local list = {}
  for _, sys in ipairs(systems) do
    local p = plan[sys.id]
    if p.value > 1 then
      p.score = p.scoreSum / p.value
      p.labor = #p.parts > 0 and math.floor(p.hours * laborRate) or 0
      p.cost = math.floor(p.partsCost) + p.labor
      table.insert(list, p)
    end
  end
  return list
end

-- systemId nil = every system that needs it. Re-reads the live car first, like repair. done(ok, message)
local function refurbish(inventoryId, systemId, done)
  local ok, vehIdOrErr = nearby(inventoryId)
  if not ok then return done(false, vehIdOrErr) end
  pending = inventoryId
  career_modules_inventory.updatePartConditions(vehIdOrErr, inventoryId, function()
    pending = nil
    local veh = career_modules_inventory.getVehicles()[inventoryId]
    local todo, total, count = {}, 0, 0
    for _, p in ipairs(refurbPlan(inventoryId, true)) do
      if (not systemId or p.id == systemId) and #p.parts > 0 then table.insert(todo, p) total = total + p.cost count = count + #p.parts end
    end
    if not veh or #todo == 0 then return done(false, "Nothing needs refurbishing") end
    if career_modules_playerAttributes.getAttributeValue("money") < total then return done(false, "Not enough money ($" .. total .. " needed)") end
    local odo, broken = career_modules_beanValue.refurbishOdometer, {}
    for _, p in ipairs(todo) do
      for _, part in ipairs(p.parts) do
        local live = veh.partConditions and veh.partConditions[part.partPath]
        if live and live.integrityValue == 0 then broken[part.partPath] = live end
      end
    end
    -- broken body parts go through the stock repair first so paint, visuals and repairCount stay consistent
    if next(broken) then career_modules_insurance_insurance.repairPartConditions({partConditions = broken, inventoryId = inventoryId}) end
    for _, p in ipairs(todo) do
      for _, part in ipairs(p.parts) do
        for _, c in ipairs({part.partCondition, veh.partConditions and veh.partConditions[part.partPath]}) do
          if c then
            c.odometer = math.min(c.odometer or 0, odo) -- wear rolled back to the cap, never to zero
            c.integrityValue, c.integrityState = 1, nil
          end
        end
      end
    end
    career_modules_playerAttributes.addAttributes({money = -total}, {tags = {"repair"}, label = string.format("Refurbished %d part(s)", count)})
    scans[inventoryId] = nil
    career_modules_insurance_insurance.startRepairInstant(veh) -- respawns the car with the new conditions and saves
    career_modules_beanValue.invalidate(inventoryId)
    done(true, string.format("Refurbished %d part(s) for $%d", count, total))
  end)
end

local function slimPlan(inventoryId)
  local out = {}
  for _, p in ipairs(refurbPlan(inventoryId)) do
    table.insert(out, {id = p.id, name = p.name, score = p.score, cost = p.cost, labor = p.labor, hours = p.hours, worn = #p.parts})
  end
  return out
end

local function uiData()
  local list = {}
  for id, veh in pairs(career_modules_inventory.getVehicles()) do
    if veh.owned ~= false then
      local inRange, err = nearby(id)
      local s = scans[id]
      table.insert(list, {id = id, name = career_modules_inventory.getVehicleNiceNameTranslated(id) or veh.model, year = veh.year, inRange = inRange, reason = not inRange and err or nil,
        scanning = pending == id, scannedAt = s and s.at, faults = s and s.faults or nil,
        refurb = slimPlan(id), condition = career_modules_beanValue and career_modules_beanValue.info(id) or nil,
        thumbnail = career_modules_inventory.getVehicleThumbnail and career_modules_inventory.getVehicleThumbnail(id) or nil})
    end
  end
  table.sort(list, function(a, b) if a.inRange ~= b.inRange then return a.inRange end return a.id < b.id end)
  return {vehicles = list, laborRate = laborRate, refurbishMax = career_modules_beanValue and career_modules_beanValue.refurbishMax or 0.95}
end

-- assert-based check of classification + pricing: career_modules_beanScanTool.selfTest()
local function selfTest()
  assert(classify({integrityValue = 1}) == nil)
  assert(classify({integrityValue = 0}) == "body")
  assert(classify({integrityValue = 0.5, integrityState = {powertrain = {mainEngine = {fastIgnitionErrorChance = 0.1}}}}) == "ignition")
  assert(classify({integrityValue = 0.1, integrityState = {powertrain = {mainEngine = {fastIgnitionErrorChance = 0.3}}}}) == "engine")
  assert(classify({integrityValue = 1, integrityState = {powertrain = {mainEngine = {thermals = {headGasketDamaged = true}}}}}) == "engine")
  assert(classify({integrityValue = 0.2, integrityState = {powertrain = {gearbox = {damageFrictionCoef = 40}}}}) == "transmission")
  assert(classify({integrityValue = 1, integrityState = {powertrain = {mainEngine = {radiatorDamage = 0.4}}}}) == "cooling")
  assert(systemOf("pickup_engine_v8_4.5").id == "engine" and systemOf("pickup_transmission_4A").id == "trans")
  assert(systemOf("pickup_differential_R").id == "driveline" and systemOf("pickup_IFS").id == "chassis" and systemOf("pickup_door_FL").id == "body")
  return "ok"
end

M.scan = scan
M.repair = repair
M.refurbish = refurbish
M.refurbPlan = refurbPlan
M.uiData = uiData
M.diagnose = diagnose
M.selfTest = selfTest

M.onVehicleRemoved = function(inventoryId) scans[inventoryId] = nil end -- ids get reused, so old results must not stick

return M
