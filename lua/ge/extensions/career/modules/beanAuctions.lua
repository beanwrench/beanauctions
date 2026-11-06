-- BeanAuctions: salvage auctions for career mode.
-- Lots are generated from the stock config pool, AI bidders hold hidden max bids,
-- each lot gets a live "going once / twice" round when its pre-bid timer runs out.

local M = {}
M.dependencies = {'career_career', 'util_configListGenerator', 'career_modules_beanScanTool'}


local saveFileName = "/career/beanAuctions.json"
local lotCount = 100
local lotSpacing = 40           -- seconds between lots going live (100 lots ~ 67 min of sales)
local yardSize = 30             -- parking spots in the yard; lots share them
local goingTime = 9            -- seconds without a bid before "sold"
local liveTickTime = 1.2       -- seconds between live bids
local towFee = 400
local instaTowFee = 1200
local towDelay = 300

local filter = {
  whiteList = {Value = {min = 1500}},
  blackList = {Type = {"Trailer"}},
}

-- vehicle-side faults: devices = powertrain device types the fault breaks
local faults = {
  engine = {label = "Engine knocking, low compression", devices = {combustionEngine = true, electricMotor = true}, integrity = {0.02, 0.2}, penalty = 0.35},
  ignition = {label = "Misfire / ECU fault", devices = {combustionEngine = true}, integrity = {0.45, 0.65}, penalty = 0.12},
  transmission = {label = "Transmission slipping / grinding", devices = {manualGearbox = true, automaticGearbox = true, dctGearbox = true, cvtGearbox = true, sequentialGearbox = true}, integrity = {0.05, 0.3}, penalty = 0.25},
  front = {label = "Front end collision damage", crash = 1, strength = {30000, 55000}, penalty = 0.3},
  rear = {label = "Rear end collision damage", crash = -1, strength = {30000, 55000}, penalty = 0.22},
  -- small stuff for low-mileage repo / insurance cars
  minor = {label = "Check engine light (minor misfire)", devices = {combustionEngine = true}, integrity = {0.86, 0.95}, penalty = 0.04, minor = true},
  scuffs = {label = "Minor dents / scratches", crash = 1, strength = {13000, 19000}, penalty = 0.06, minor = true},
}
local mechFaults = {"engine", "ignition", "transmission"}

-- seller, title, body hit pool, min/max mechanical faults (from mechPool), mileage range in metres
local highMileage = {60e6, 400e6}
local profiles = {
  {id = "salvage", seller = "Salvage Pool", title = "Salvage", body = {"front", "front", "rear"}, mech = {0, 1}, weight = 3},
  {id = "mechanical", seller = "Dealer Trade-In", title = "Clean", mech = {1, 2}, weight = 3},
  {id = "mixed", seller = "Salvage Pool", title = "Salvage", body = {"front", "front", "rear"}, mech = {1, 2}, weight = 2},
  {id = "runsAndDrives", seller = "Dealer Trade-In", title = "Clean", mech = {0, 0}, weight = 2},
  -- low mileage, late model: insurance write-offs (crash only) and repos (run & drive, tiny issues at most)
  {id = "insurance", seller = "Insurance", title = "Salvage", body = {"front", "front", "rear", "scuffs"}, mech = {0, 0}, weight = 3, mileage = {4e6, 60e6}, newer = true},
  {id = "repo", seller = "Repo", title = "Clean", body = {"scuffs"}, bodyChance = 0.35, mech = {0, 1}, mechPool = {"minor"}, weight = 3, mileage = {8e6, 80e6}, newer = true},
}

-- consigning the player's own cars. Fees are {flat, share of the hammer price}; range = bidder max vs. car value
local venues = {
  salvage = {seller = "Your consignment", sellerFee = {100, 0.08}, bidders = {3, 7}, range = {0.55, 1.1}, delay = 120, startShare = 0.15},
  collector = {seller = "Collector Auction", entryFee = {500, 0.01}, sellerFee = {0, 0.10}, bidders = {4, 9}, range = {0.85, 1.35}, delay = 300, startShare = 0.3,
    minValue = 25000, classicAge = 25, classicBonus = 1.15},
}
local collectorNames = {"Hollister Collection", "D. Marchetti", "Redline Classics", "K. Yamada", "Oldfield Motor Museum", "Bayshore Exotics", "A. Whitcombe", "Coastline Garage Fund", "M. Duarte", "Concours Holdings"}

local bidderNames = {"LKQ Parts", "Rebuildables LLC", "J. Ortiz", "Mike's Exports", "Belasco Salvage", "Quarryside Rebuilds", "T. Nguyen", "Gridline Motors", "S. Walker", "Pick-n-Pull"}

local lots = {}
local nextLotId = 1
local yardSpots -- array of parking spot names near the yard
local inspectVeh -- {lotId, vehId}
local pendingSpawns = {} -- vehId -> {lotId, mode}
local pendingAdds = {} -- inventoryId -> {year, tow}
local tickTimer = 0
local speed = 1 -- auction clock multiplier (2x toggle in the site), not saved

-- ===== pure helpers (see M.selfTest) =====

local function bidIncrement(price)
  if price < 1000 then return 50 elseif price < 5000 then return 100 elseif price < 20000 then return 250 end
  return 500
end

-- tiered buyer fee, like real salvage auctions
local function buyerFee(price)
  return math.floor(100 + price * (price < 5000 and 0.12 or price < 20000 and 0.09 or 0.07))
end

local function roundTo(v, step) return math.floor(v / step + 0.5) * step end

-- proxy resolution for lots that ended while nobody was watching (e.g. game closed).
-- bids = {{who=, max=}}; ties go to the earlier bid (array order). Returns winner, price.
local function resolveProxy(startBid, bids)
  local valid = {}
  for i, b in ipairs(bids) do if b.max >= startBid then valid[#valid + 1] = {who = b.who, max = b.max, i = i} end end
  if #valid == 0 then return nil end
  table.sort(valid, function(a, b) if a.max == b.max then return a.i < b.i end return a.max > b.max end)
  if not valid[2] then return valid[1].who, startBid end
  return valid[1].who, math.min(valid[1].max, valid[2].max + bidIncrement(valid[2].max))
end

local function asIsValue(lot, onlyKnown)
  local penalty = 0
  for _, f in ipairs(lot.faults) do
    if not onlyKnown or not f.hidden or lot.inspected then penalty = penalty + faults[f.id].penalty end
  end
  return lot.marketValue * (1 - math.min(penalty, 0.85))
end

-- ===== lot generation =====

local function pickYardSpots()
  local spots = gameplay_parking.getParkingSpots().byName
  local names = tableKeys(spots)
  if #names == 0 then return {} end
  -- yard = the random spot with the most other spots within 60 m
  local best, bestCount
  for _ = 1, 30 do
    local c = spots[names[math.random(#names)]]
    local n = 0
    for _, name in ipairs(names) do if spots[name].pos:distance(c.pos) < 60 then n = n + 1 end end
    if not bestCount or n > bestCount then best, bestCount = c, n end
  end
  table.sort(names, function(a, b) return spots[a].pos:distance(best.pos) < spots[b].pos:distance(best.pos) end)
  local result = {}
  for i = 1, math.min(yardSize, #names) do result[i] = names[i] end
  return result
end

local function freeYardSpot()
  -- least-used spot, so a lot's car rarely spawns on top of another one
  local used = {}
  for _, lot in ipairs(lots) do used[lot.spot] = (used[lot.spot] or 0) + 1 end
  local best
  for _, name in ipairs(yardSpots) do if not best or (used[name] or 0) < (used[best] or 0) then best = name end end
  return best
end

local function pickProfile()
  local total = 0
  for _, p in ipairs(profiles) do total = total + p.weight end
  local r = math.random() * total
  for _, p in ipairs(profiles) do r = r - p.weight if r <= 0 then return p end end
  return profiles[1]
end

-- configs that pass the filter, grouped by model; built once (getEligibleVehicles deep-copies every config)
local modelPool
local function getModelPool()
  if modelPool then return modelPool end
  modelPool = {}
  for _, info in ipairs(util_configListGenerator.getEligibleVehicles()) do
    -- buses are Type "Truck"; only the body style says bus (a blacklist entry would AND with Type)
    local bodyStyle = info.aggregates and info.aggregates["Body Style"] or {}
    if util_configListGenerator.doesVehiclePassFilter(info, filter) and not bodyStyle.Bus then
      modelPool[info.model_key] = modelPool[info.model_key] or {}
      table.insert(modelPool[info.model_key], info)
    end
  end
  return modelPool
end

-- variety: pick a random config of whichever model is least listed right now
local function pickVehicle()
  local listed = {}
  for _, lot in ipairs(lots) do
    if lot.state == "prebid" or lot.state == "live" then listed[lot.model] = (listed[lot.model] or 0) + 1 end
  end
  local best, ties = nil, {}
  for model in pairs(getModelPool()) do
    local n = listed[model] or 0
    if not best or n < best then best, ties = n, {model} elseif n == best then table.insert(ties, model) end
  end
  if #ties == 0 then return end
  local configs = modelPool[ties[math.random(#ties)]]
  return configs[math.random(#configs)]
end

local function generateLot(endsAt)
  local info = pickVehicle()
  if not info then return end
  local years = info.Years or info.aggregates.Years
  local profile = pickProfile()
  local yMin, yMax = (years and years.min) or 2000, (years and years.max) or 2020
  local year = math.random(profile.newer and math.max(yMin, yMax - 3) or yMin, yMax)
  local range = profile.mileage or highMileage
  local mileage = math.floor(randomGauss3() / 3 * (range[2] - range[1]) + range[1])

  local lotFaults = {}
  if profile.body and math.random() < (profile.bodyChance or 1) then
    table.insert(lotFaults, {id = profile.body[math.random(#profile.body)]})
  end
  local mechPool = arrayShuffle(deepcopy(profile.mechPool or mechFaults))
  local hasEngineFault
  for i = 1, math.random(profile.mech[1], profile.mech[2]) do
    local id = mechPool[i]
    if not id then break end
    if (id == "engine" or id == "ignition") and hasEngineFault then break end
    hasEngineFault = hasEngineFault or id == "engine" or id == "ignition"
    table.insert(lotFaults, {id = id, hidden = math.random() < 0.4})
  end
  for _, f in ipairs(lotFaults) do
    local range = faults[f.id].integrity
    if range then f.integrity = range[1] + math.random() * (range[2] - range[1]) end
  end

  local lot = {
    id = nextLotId,
    model = info.model_key, config = info.key,
    name = (info.Brand and info.Brand ~= "" and (info.Brand .. " ") or "") .. (info.Name or info.model_key),
    preview = info.preview,
    year = year, mileage = mileage,
    title = profile.title, profile = profile.id, seller = profile.seller,
    faults = lotFaults,
    marketValue = roundTo(career_modules_valueCalculator.getAdjustedVehicleBaseValue(info.Value, {mileage = mileage, age = 2023 - year}), 10),
    endsAt = endsAt,
    spot = freeYardSpot(),
    state = "prebid",
    bids = {}, -- {who, max}, player bid is who="player"
  }
  nextLotId = nextLotId + 1
  lot.startBid = math.max(100, roundTo(lot.marketValue * (0.08 + math.random() * 0.1), 25))
  lot.price = lot.startBid

  -- AI bidders only see the condition report (not hidden faults) and misjudge a bit
  local perceived = asIsValue(lot, true)
  for _, name in ipairs(arrayShuffle(deepcopy(bidderNames))) do
    if #lot.bids >= math.random(2, 6) then break end
    table.insert(lot.bids, {who = name, max = roundTo(perceived * (0.35 + math.random() * 0.55), 25)})
  end
  table.insert(lots, lot)
  return lot
end

local function getLot(lotId)
  for _, lot in ipairs(lots) do if lot.id == lotId then return lot end end
end

local function playerBid(lot)
  for _, b in ipairs(lot.bids) do if b.who == "player" then return b end end
end

local function money() return career_modules_playerAttributes.getAttributeValue("money") end

-- ===== consignment (selling the player's own cars) =====

local function sellerFee(venue, price) return math.floor(venue.sellerFee[1] + price * venue.sellerFee[2]) end
local function entryFee(venue, value) return venue.entryFee and math.floor(venue.entryFee[1] + value * venue.entryFee[2]) or 0 end

local function consignedLot(inventoryId)
  for _, lot in ipairs(lots) do
    if lot.consign and lot.consign.inventoryId == inventoryId and (lot.state == "prebid" or lot.state == "live") then return lot end
  end
end

-- what the site shows for each owned car: values, fees and why a venue is closed to it
local function consignInfo(id, veh)
  local bv, VC = career_modules_beanValue, career_modules_valueCalculator -- the cached path: this runs every screen refresh
  local value = math.floor((bv and bv.cached(id) or VC.getInventoryVehicleValue(id)) or 0)
  local clean = math.floor((bv and bv.cached(id, true) or VC.getInventoryVehicleValue(id, true)) or value)
  local age = 2023 - (veh.year or 2023)
  local reason
  if consignedLot(id) then reason = "Up for auction"
  elseif not veh.owned then reason = "Not owned (loaner)"
  elseif veh.timeToAccess then reason = "Not available right now"
  elseif career_modules_marketplace and career_modules_marketplace.findVehicleListing(id) then reason = "Listed on the marketplace"
  end
  local col = venues.collector
  local collectorReason = reason
    or (clean < col.minValue and age < col.classicAge and "Collector auctions take cars worth $25,000+ or 25+ years old")
    or (value < clean * 0.97 and "Repair it first: collector cars must be in top condition") or nil
  return {id = id, name = career_modules_inventory.getVehicleNiceNameTranslated(id) or veh.model, year = veh.year, value = value, clean = clean, classic = age >= col.classicAge,
    km = math.floor((career_modules_valueCalculator.getVehicleMileageById(id) or 0) / 1000),
    thumbnail = career_modules_inventory.getVehicleThumbnail and career_modules_inventory.getVehicleThumbnail(id) or nil,
    reason = reason, collectorReason = collectorReason, entryFee = entryFee(col, clean), lotId = (consignedLot(id) or {}).id,
    condition = career_modules_beanValue and career_modules_beanValue.info(id) or nil}
end

local function consign(inventoryId, venueId, reserve)
  local veh = career_modules_inventory.getVehicles()[inventoryId]
  local venue = venues[venueId]
  if not veh or not venue then return false, "Unknown vehicle" end
  local info = consignInfo(inventoryId, veh)
  local why = venueId == "collector" and info.collectorReason or info.reason
  if why then return false, why end
  local fee = venueId == "collector" and info.entryFee or 0
  if fee > money() then return false, "Not enough money for the entry fee" end
  if fee > 0 then career_modules_playerAttributes.addAttributes({money = -fee}, {tags = {"selling"}, label = "Collector auction entry: " .. info.name}) end

  -- the car goes to the auction: out of the world and locked in the inventory until the sale ends
  career_modules_inventory.removeVehicleObject(inventoryId)
  veh.timeToAccess, veh.delayReason = venue.delay + 120, "beanAuction"

  local lot = {
    id = nextLotId, model = veh.model, name = info.name, preview = info.thumbnail,
    year = veh.year or 2023, mileage = info.km * 1000, title = "Clean", seller = venue.seller, faults = {},
    marketValue = roundTo(info.clean, 10), endsAt = os.time() + venue.delay, spot = freeYardSpot(), state = "prebid", bids = {},
    damaged = info.value < info.clean * 0.97,
    consign = {inventoryId = inventoryId, venue = venueId, reserve = math.max(0, math.floor(tonumber(reserve) or 0))},
  }
  nextLotId = nextLotId + 1
  lot.startBid = math.max(100, roundTo(info.value * venue.startShare, 25))
  lot.price = lot.startBid
  local base = info.value * (venueId == "collector" and info.classic and venue.classicBonus or 1)
  local names = arrayShuffle(deepcopy(venueId == "collector" and collectorNames or bidderNames))
  for i = 1, math.random(venue.bidders[1], venue.bidders[2]) do
    if not names[i] then break end
    table.insert(lot.bids, {who = names[i], max = roundTo(base * (venue.range[1] + math.random() * (venue.range[2] - venue.range[1])), 25)})
  end
  table.insert(lots, lot)
  return true
end

local function closeConsigned(lot)
  local c, venue = lot.consign, venues[lot.consign.venue]
  local veh = career_modules_inventory.getVehicles()[c.inventoryId]
  if veh then veh.timeToAccess, veh.delayReason = nil, nil end
  if veh and lot.leader and lot.price >= c.reserve then
    local payout = lot.price - sellerFee(venue, lot.price)
    career_modules_inventory.sellVehicle(c.inventoryId, payout)
    lot.state, lot.payout = "sold", payout
    guihooks.trigger("toastrMsg", {type = "success", title = "BeanAuctions", msg = string.format("Your %s sold for $%d. You received $%d after fees.", lot.name, lot.price, payout)})
  else
    lot.state = "noSale"
    guihooks.trigger("toastrMsg", {type = "warning", title = "BeanAuctions", msg = string.format("Your %s didn't sell%s. It's back in your storage.", lot.name, lot.leader and " (reserve not met)" or "")})
  end
  lot.closedAt = os.time()
end

-- ===== spawning =====

-- runs in the vehicle VM: apply faults, optionally crash it, then report back
local vehicleScript = [==[
local faults, crash, strength, mileage, vehId = %s, %d, %d, %d, %d
local pc = {}
for partId, partName in pairs(v.data.activeParts) do
  local data = v.data.activePartsData[partName]
  if data and type(data.powertrain) == "table" then
    for i = 2, #data.powertrain do
      local row = data.powertrain[i]
      if type(row) == "table" and row[1] then
        for _, f in ipairs(faults) do
          if f.devices[row[1]] then pc[partId] = {odometer = mileage, integrityValue = f.integrity, visualValue = 1} end
        end
      end
    end
  end
end
partCondition.initConditions(pc, mileage, 1, 0.75)
if crash ~= 0 then
  local fwd = obj:getDirectionVector():normalized() * crash
  local maxF, d = -math.huge, {}
  for _, n in pairs(v.data.nodes) do d[n.cid] = obj:getNodePosition(n.cid):dot(fwd) if d[n.cid] > maxF then maxF = d[n.cid] end end
  for _, n in pairs(v.data.nodes) do
    if d[n.cid] > maxF - 0.7 then obj:applyForceVectorTime(n.cid, -fwd * (n.nodeWeight or 1) * strength, 0.0005) end
  end
end
obj:queueGameEngineLua(string.format("career_modules_beanAuctions.onLotVehicleReady(%%d)", vehId))
]==]

local function spawnLotVehicle(lot, mode)
  local spot = gameplay_parking.getParkingSpots().byName[lot.spot]
  local veh = core_vehicles.spawnNewVehicle(lot.model, {config = lot.config, autoEnterVehicle = false})
  if not veh then
    guihooks.trigger("toastrMsg", {type = "error", title = "BeanAuctions", msg = "Could not spawn " .. lot.name})
    return
  end
  if spot then spot:moveResetVehicleTo(veh:getID(), nil, nil, nil, nil, true) end
  core_vehicleBridge.executeAction(veh, 'setIgnitionLevel', 0)

  local vehFaults, crash, strength = {}, 0, 0
  for _, f in ipairs(lot.faults) do
    local def = faults[f.id]
    if def.devices then table.insert(vehFaults, {devices = def.devices, integrity = f.integrity}) end
    if def.crash then
      crash = def.crash
      strength = math.floor(def.strength[1] + (lot.id * 7919 % 1000) / 1000 * (def.strength[2] - def.strength[1])) -- stable per lot
    end
  end
  pendingSpawns[veh:getID()] = {lotId = lot.id, mode = mode}
  veh:queueLuaCommand(string.format(vehicleScript, serialize(vehFaults), crash, strength, lot.mileage, veh:getID()))
  return veh
end

local function addToInventory(lot, vehId, tow)
  local inventoryId = career_modules_inventory.addVehicle(vehId, nil, {finalPrice = lot.price})
  if not inventoryId then return end
  -- finished in onVehicleAddedToInventory, once the inventory has read parts + conditions
  pendingAdds[inventoryId] = {year = lot.year, tow = tow}
  lot.state = "collected"
end

local function onLotVehicleReady(vehId)
  local p = pendingSpawns[vehId]
  pendingSpawns[vehId] = nil
  local lot = p and getLot(p.lotId)
  if not lot then return end
  if p.mode == "inspect" then return end
  -- give the crash a moment to settle before the inventory reads part conditions
  lot.readyAt = os.clock() + 1.5
  lot.readyVehId = vehId
  lot.readyMode = p.mode
end

local function removeInspectVehicle()
  if not inspectVeh then return end
  local obj = getObjectByID(inspectVeh.vehId)
  if obj then obj:delete() end
  inspectVeh = nil
end

-- ===== player actions =====


local function setMaxBid(lotId, amount)
  local lot = getLot(lotId)
  if not lot or (lot.state ~= "prebid" and lot.state ~= "live") then return false, "Lot is closed" end
  if lot.consign then return false, "You can't bid on your own car" end
  amount = math.floor(tonumber(amount) or 0)
  local minBid = lot.leader and lot.price + bidIncrement(lot.price) or lot.startBid
  if amount < minBid then return false, "Bid must be at least $" .. minBid end
  if amount + buyerFee(amount) > money() then return false, "Not enough money to cover bid + fees" end
  local b = playerBid(lot)
  if b then
    if lot.leader == "player" and amount < b.max then return false, "You can't lower your max bid while winning" end
    b.max = amount
  else
    table.insert(lot.bids, {who = "player", max = amount})
  end
  return true
end

local function quickBid(lotId)
  local lot = getLot(lotId)
  if not lot then return end
  return setMaxBid(lotId, lot.leader and lot.price + bidIncrement(lot.price) or lot.startBid)
end

local function inspect(lotId)
  local lot = getLot(lotId)
  if not lot then return end
  local spot = gameplay_parking.getParkingSpots().byName[lot.spot]
  if not (inspectVeh and inspectVeh.lotId == lotId) then
    removeInspectVehicle()
    local veh = spawnLotVehicle(lot, "inspect")
    if veh then inspectVeh = {lotId = lotId, vehId = veh:getID()} end
  end
  if spot then core_groundMarkers.setPath(spot.pos) end
  guihooks.trigger("toastrMsg", {type = "info", title = "BeanAuctions", msg = "Route set to the yard. Walk up to the " .. lot.name .. " to inspect it."})
end

-- tow: nil = pick up yourself, "tow" = wait for delivery, "insta" = pay more, no wait
local function collect(lotId, tow)
  local lot = getLot(lotId)
  if not lot or lot.state ~= "won" then return end
  if tow and lot.towPaid ~= tow then
    local fee = tow == "insta" and instaTowFee or towFee
    if money() < fee then return end
    career_modules_playerAttributes.addAttributes({money = -fee}, {tags = {"buying"}, label = "Auction tow: " .. lot.name})
    lot.towPaid = tow -- survives a save/reload mid-spawn, so the fee is never charged twice
  end
  lot.state = "spawning"
  if inspectVeh and inspectVeh.lotId == lotId and getObjectByID(inspectVeh.vehId) then
    local vehId = inspectVeh.vehId
    inspectVeh = nil
    addToInventory(lot, vehId, tow)
  elseif not spawnLotVehicle(lot, tow or "pickup") then
    lot.state = "won"
    return
  end
  if not tow then
    local spot = gameplay_parking.getParkingSpots().byName[lot.spot]
    if spot then core_groundMarkers.setPath(spot.pos) end
  end
end

local function spotPos(lot)
  local spot = gameplay_parking.getParkingSpots().byName[lot.spot]
  return spot and (spot.pos + spot.rot * vec3(3, 0, 0))
end

local function travelPrice(lot)
  local pos = spotPos(lot)
  return pos and career_modules_quickTravel.getPriceForQuickTravel(pos) or 0
end

-- open lot: spawn it for inspection; won lot: spawn it for pickup. Then teleport next to it.
local function fastTravel(lotId)
  local lot = getLot(lotId)
  local pos = lot and spotPos(lot)
  if not pos then return false, "No yard spot for this lot" end
  if not career_modules_payment.canPay({money = {amount = travelPrice(lot)}}) then return false, "Not enough money to fast travel" end
  if lot.state == "won" then collect(lotId, nil) else inspect(lotId) end
  career_modules_quickTravel.quickTravelToPos(pos, true, "Auction yard fast travel")
  core_groundMarkers.setPath(nil)
  return true
end

-- ===== auction clock =====

local function closeLot(lot)
  if lot.consign then return closeConsigned(lot) end
  if lot.leader == "player" then
    lot.state = "won"
    local total = lot.price + buyerFee(lot.price)
    career_modules_playerAttributes.addAttributes({money = -total}, {tags = {"vehicleBought", "buying"}, label = "Auction win: " .. lot.name})
    guihooks.trigger("toastrMsg", {type = "success", title = "BeanAuctions", msg = string.format("You won the %s for $%d (+ fees). Pick it up at the yard or have it towed.", lot.name, lot.price)})
  else
    lot.state = lot.leader and "sold" or "noSale"
    if playerBid(lot) then
      guihooks.trigger("toastrMsg", {type = "warning", title = "BeanAuctions", msg = string.format("Outbid on the %s. Sold for $%d.", lot.name, lot.price)})
    end
    if inspectVeh and inspectVeh.lotId == lot.id then removeInspectVehicle() end
  end
  lot.closedAt = os.time()
end

local function liveTick(lot, now)
  local nextPrice = lot.leader and lot.price + bidIncrement(lot.price) or lot.startBid
  local candidates = {}
  for _, b in ipairs(lot.bids) do
    local canPay = b.who ~= "player" or money() >= nextPrice + buyerFee(nextPrice)
    if b.who ~= lot.leader and b.max >= nextPrice and canPay then table.insert(candidates, b) end
  end
  if #candidates > 0 then
    local b = candidates[math.random(#candidates)]
    -- AI sometimes jumps a few increments to keep rounds short
    if b.who ~= "player" then nextPrice = math.min(b.max, nextPrice + bidIncrement(nextPrice) * math.random(0, 3)) end
    lot.leader, lot.price, lot.lastBidAt = b.who, nextPrice, now
  elseif now - (lot.lastBidAt or now) >= goingTime then
    closeLot(lot)
  end
end

local function updateLots()
  local now = os.time()
  for _, lot in ipairs(lots) do
    if lot.state == "prebid" and now >= lot.endsAt then
      if now - lot.endsAt > 120 then
        -- ended while the game wasn't running: resolve instantly
        local winner, price = resolveProxy(lot.startBid, lot.bids)
        lot.leader, lot.price = winner, price or lot.startBid
        closeLot(lot)
      else
        lot.state, lot.lastBidAt = "live", now
      end
    elseif lot.state == "live" then
      liveTick(lot, now)
    end
    if lot.consign and (lot.state == "prebid" or lot.state == "live") then
      -- keep the car locked at the auction until the sale ends (the inventory counts this down)
      local veh = career_modules_inventory.getVehicles()[lot.consign.inventoryId]
      if veh then veh.timeToAccess, veh.delayReason = math.max(veh.timeToAccess or 0, 120), "beanAuction" end
    end
  end

  -- drop finished lots after a while, keep the lot count topped up
  for i = #lots, 1, -1 do
    local lot = lots[i]
    if (lot.state == "sold" or lot.state == "noSale" or lot.state == "collected") and now - (lot.closedAt or now) > 300 then
      table.remove(lots, i)
    end
  end
  local open = 0
  for _, lot in ipairs(lots) do if lot.state == "prebid" or lot.state == "live" then open = open + 1 end end
  if open < lotCount then
    -- queue new lots behind the last scheduled one so sales come up one at a time
    local last = now
    for _, lot in ipairs(lots) do if lot.state == "prebid" then last = math.max(last, lot.endsAt) end end
    for i = 1, lotCount - open do
      generateLot(last + lotSpacing * i + math.random(0, 15))
    end
  end
end

local function checkInspection()
  if not inspectVeh then return end
  local lot = getLot(inspectVeh.lotId)
  local obj = getObjectByID(inspectVeh.vehId)
  if not lot or not obj then inspectVeh = nil return end
  if lot.inspected then return end
  local player = getPlayerVehicle(0)
  if player and player:getPosition():distance(obj:getPosition()) < 8 then
    lot.inspected = true
    local found = {}
    for _, f in ipairs(lot.faults) do if f.hidden then table.insert(found, faults[f.id].label) end end
    guihooks.trigger("toastrMsg", {type = #found > 0 and "warning" or "success", title = "Inspection: " .. lot.name,
      msg = #found > 0 and ("Found: " .. table.concat(found, ", ")) or "Nothing beyond the condition report."})
  end
end

-- ===== web UI (iframe injected into the game UI, see ui/beanauctions/index.html) =====

local uiOpen = false
local travelPriceCache
local damageNames = {front = "FRONT END", rear = "REAR END", scuffs = "MINOR DENT/SCRATCHES"}

local function lotForUi(lot, now)
  local known, primary, secondary = {}, "NORMAL WEAR", nil
  local runsAndDrives = true
  for _, f in ipairs(lot.faults) do
    if not f.hidden or lot.inspected then
      table.insert(known, faults[f.id].label)
      if damageNames[f.id] then primary = damageNames[f.id]
      else
        secondary = secondary or (faults[f.id].minor and "MINOR MECHANICAL" or "MECHANICAL")
        if f.id ~= "ignition" and f.id ~= "minor" then runsAndDrives = false end
      end
    end
  end
  if lot.damaged then primary = "NEEDS REPAIR" end
  if primary == "NORMAL WEAR" and secondary then primary, secondary = secondary, nil end
  local pb = playerBid(lot)
  local nextBid = lot.leader and lot.price + bidIncrement(lot.price) or lot.startBid
  return {
    id = lot.id, name = lot.name, year = lot.year, preview = lot.preview,
    km = math.floor(lot.mileage / 1000), title = lot.title, seller = lot.seller or (lot.title == "Salvage" and "Salvage Pool" or "Dealer Trade-In"), primary = primary, secondary = secondary,
    known = known, inspected = lot.inspected or false, runsAndDrives = runsAndDrives,
    retail = lot.marketValue, price = lot.price, startBid = lot.startBid, nextBid = nextBid,
    fee = buyerFee(math.max(lot.price, pb and pb.max or 0)), state = lot.state,
    timeLeft = math.ceil(lot.endsAt - now), idle = math.floor(now - (lot.lastBidAt or now)),
    leader = lot.leader == "player" and "You" or lot.leader, winning = lot.leader == "player",
    myMax = pb and pb.max or nil, bidders = #lot.bids - (pb and 1 or 0),
    location = lot.consign and "Consigned by you" or ("Yard spot " .. tostring(lot.spot):gsub("Parking ", "")),
    consigned = lot.consign ~= nil, venue = lot.consign and lot.consign.venue, reserve = lot.consign and lot.consign.reserve,
    payout = lot.payout or (lot.consign and lot.price - sellerFee(venues[lot.consign.venue], lot.price)),
  }
end

local frameJs = "var f=document.getElementById('beanAuctionsFrame');if(f&&f.contentWindow&&f.contentWindow.baState)f.contentWindow.baState(%s);"

-- browser access: the same site served by the game's web server, see startWeb
local webPort = 8090
local web -- {server = , key = , peers = {peerId = true}} once started

local function pushUi(message, isError)
  if not uiOpen and not (web and next(web.peers)) then return end
  local now = os.time()
  local data = {scan = career_modules_beanScanTool.uiData(), money = math.floor(money()), towFee = towFee, instaTowFee = instaTowFee, towMinutes = towDelay / 60, speed = speed, units = settings.getValue("uiUnitLength"), lots = {}, message = message, isError = isError}
  if lots[1] then
    -- every lot is in the same yard, so one route price covers them all (cached, routing isn't free)
    if not travelPriceCache or os.clock() > travelPriceCache.t then travelPriceCache = {price = travelPrice(lots[1]), t = os.clock() + 10} end
    data.travelPrice = travelPriceCache.price
  end
  for _, lot in ipairs(lots) do table.insert(data.lots, lotForUi(lot, now)) end
  data.garage = {}
  for id, veh in pairs(career_modules_inventory.getVehicles()) do table.insert(data.garage, consignInfo(id, veh)) end
  table.sort(data.garage, function(a, b) return a.id < b.id end)
  data.venues = {salvageFee = venues.salvage.sellerFee, collectorFee = venues.collector.sellerFee}
  data.webUrl = web and string.format("http://localhost:%d/ui/beanauctions/index.html?key=%s", webPort, web.key)
  local json = jsonEncode(data)
  if uiOpen then be:executeJS(string.format(frameJs, json)) end
  if web then for peerId in pairs(web.peers) do web.server:sendData(peerId, json) end end
end

-- while the tablet is up, Esc closes it instead of opening the game's pause menu
local function blockMenu(block)
  core_input_actionFilter.setGroup('beanAuctionsTablet', {'toggleMenues'})
  core_input_actionFilter.addAction(0, 'beanAuctionsTablet', block)
end

local function openWindow(tab)
  uiOpen = true
  blockMenu(true)
  be:executeJS([[
    if(!document.getElementById('beanAuctionsFrame')){
      var f=document.createElement('iframe');f.id='beanAuctionsFrame';f.src='/ui/beanauctions/index.html?v=]] .. os.time() .. [[#]] .. (tab or "launcher") .. [[';
      f.style.cssText='position:fixed;inset:0;width:100vw;height:100vh;border:0;z-index:100000;pointer-events:auto;background:transparent';f.allowTransparency=true;
      document.body.appendChild(f);
    }]])
end

local function closeWindow()
  uiOpen = false
  blockMenu(false)
  setCEFTyping(false) -- removing a focused input fires no blur, so hand the keyboard back to the game here
  be:executeJS("var f=document.getElementById('beanAuctionsFrame');if(f)f.remove();")
end

-- single entry point for the page: action = refresh|bid|quickBid|inspect|pickup|tow|instaTow|travel|close|scan|repair
-- (for scan/repair, lotId is the inventory id and arg an optional part path)
local function uiAction(action, lotId, amount, arg)
  local ok, err = true, nil
  if action == "scan" then
    career_modules_beanScanTool.scan(lotId, function(found, scanErr)
      pushUi(scanErr or (#found == 0 and "No trouble codes found" or (#found .. " fault(s) found")), scanErr ~= nil)
    end)
    pushUi()
    return
  elseif action == "repair" then
    career_modules_beanScanTool.repair(lotId, arg and arg ~= "" and {arg} or nil, function(repaired, msg) pushUi(msg, not repaired) end)
    return
  elseif action == "refurbish" then
    career_modules_beanScanTool.refurbish(lotId, arg ~= "" and arg or nil, function(done, msg) pushUi(msg, not done) end)
    return
  elseif action == "bid" then ok, err = setMaxBid(lotId, amount)
  elseif action == "quickBid" then ok, err = quickBid(lotId)
  elseif action == "inspect" then closeWindow() inspect(lotId) return
  elseif action == "pickup" then closeWindow() collect(lotId, false) return
  elseif action == "tow" or action == "instaTow" then
    local mode = action == "tow" and "tow" or "insta"
    if money() < (mode == "insta" and instaTowFee or towFee) then ok, err = false, "Not enough money for towing" else collect(lotId, mode) end
  elseif action == "travel" then
    closeWindow()
    ok, err = fastTravel(lotId)
    if not ok then guihooks.trigger("toastrMsg", {type = "error", title = "BeanAuctions", msg = err}) end
    return
  elseif action == "close" then closeWindow() return
  elseif action == "openBrowser" then
    -- the game's openWebBrowser refuses localhost links, so hand the link over through the clipboard
    if not web then return pushUi("Browser access isn't running", true) end
    setClipboard(string.format("http://localhost:%d/ui/beanauctions/index.html?key=%s", webPort, web.key))
    return pushUi("Link copied. Paste it into your browser's address bar.")
  elseif action == "consign" then
    ok, err = consign(lotId, arg, amount)
    pushUi(ok and "Your car is up for auction" or err, not ok)
    return
  elseif action == "speed" then speed = speed == 1 and 2 or 1 pushUi("Auction speed " .. speed .. "x") return
  elseif action == "goLive" then
    local lot = getLot(lotId)
    if lot and lot.state == "prebid" then lot.endsAt = os.time() tickTimer = liveTickTime end -- next frame flips it live
    pushUi("Lot going live")
    return
  end
  local done = {bid = "Max bid set", quickBid = "Bid placed", tow = "Tow booked", instaTow = "Vehicle delivered to your garage"}
  pushUi(not ok and err or done[action], not ok)
end

-- ===== browser access =====
-- The game's built-in web server on localhost. We answer HTTP ourselves and serve only an
-- allowlist: the site page, vehicle photos and the thumbnails of cars the player owns. Never
-- settings or saves (the access key lives in settings, and DNS rebinding could let another
-- site read anything we serve). Commands come over a websocket and must carry the key.

local function webKey()
  local path = "/settings/beanauctions_web.json"
  local d = jsonReadFile(path) or {}
  if type(d.key) ~= "string" or #d.key < 16 then
    local chars, key = "abcdefghijkmnpqrstuvwxyz23456789", {}
    for i = 1, 20 do local n = math.random(#chars) key[i] = chars:sub(n, n) end
    d.key = table.concat(key)
    jsonWriteFile(path, d)
  end
  return d.key
end

local function startWeb()
  if web or not BNGWebWSServer then return end
  local server = BNGWebWSServer.getOrCreate("127.0.0.1", webPort, "", "beanauctions", "", false, false)
  if not server then return log("W", "beanauctions", "could not start the web server on port " .. webPort) end
  server:enableHttpHandler("/")
  web = {server = server, key = webKey(), peers = {}}
  log("I", "beanauctions", "browser access on http://localhost:" .. webPort .. " (copy the link from the tablet)") -- never log the key: players share logs
end

local function stopWeb()
  if not web then return end
  BNGWebWSServer.destroy(web.server)
  web = nil
end

local webTypes = {html = "text/html; charset=utf-8", jpg = "image/jpeg", jpeg = "image/jpeg", png = "image/png"}
local sitePage = "/ui/beanauctions/index.html"

-- true only for files the browser page needs (see the note above startWeb)
local function webAllowed(path)
  if path == sitePage then return true end
  local ext = (path:match("%.(%w+)$") or ""):lower()
  if path:find("..", 1, true) or not webTypes[ext] or ext == "html" then return false end
  if path:find("^/vehicles/") then return true end
  for id in pairs(career_modules_inventory.getVehicles()) do
    if career_modules_inventory.getVehicleThumbnail(id) == path then return true end
  end
  return false
end

local function serveHttp(req)
  local path = req.path == "/" and sitePage or req.path or ""
  local data = req.method == "GET" and webAllowed(path) and readFile(path)
  if not data then return web.server:respondHttp(req.id, 404, "text/plain", "Not found") end
  web.server:respondHttp(req.id, 200, webTypes[(path:match("%.(%w+)$") or ""):lower()], data)
end

local function pollWeb()
  if not web then return end
  for _, req in ipairs(web.server:getHttpRequests()) do serveHttp(req) end
  for _, evt in ipairs(web.server:getPeerEvents()) do
    if evt.type == "D" and evt.msg ~= "" then
      local data = jsonDecode(evt.msg)
      if type(data) == "table" and data.key == web.key and type(data.action) == "string" then
        web.peers[evt.peerId] = true
        if data.action ~= "close" then uiAction(data.action, tonumber(data.id) or 0, tonumber(data.amount) or 0, tostring(data.arg or "")) end
      else
        web.server:sendData(evt.peerId, jsonEncode({badKey = true}))
      end
    elseif evt.type ~= "D" then
      web.peers[evt.peerId] = nil -- connect/disconnect: a page re-registers with its next command
    end
  end
  web.server:update()
end

-- ===== hooks =====

local function onUpdate(dtReal)
  if not career_career.isActive() then return end
  pollWeb()
  tickTimer = tickTimer + dtReal
  if speed > 1 then
    -- run the clock faster by pulling deadlines closer instead of touching os.time()
    local extra = (speed - 1) * dtReal
    for _, lot in ipairs(lots) do
      if lot.state == "prebid" then lot.endsAt = lot.endsAt - extra
      elseif lot.state == "live" and lot.lastBidAt then lot.lastBidAt = lot.lastBidAt - extra end
    end
  end
  if tickTimer >= liveTickTime / speed then
    tickTimer = 0
    if not yardSpots or #yardSpots == 0 then yardSpots = pickYardSpots() end
    if #yardSpots > 0 then updateLots() end
    checkInspection()
    pushUi()
  end
  for _, lot in ipairs(lots) do
    if lot.readyAt and os.clock() >= lot.readyAt then
      local vehId, mode = lot.readyVehId, lot.readyMode
      lot.readyAt, lot.readyVehId, lot.readyMode = nil, nil, nil
      if getObjectByID(vehId) then addToInventory(lot, vehId, mode ~= "pickup" and mode or nil) end
    end
  end
end

local function onComputerAddFunctions(menuData, computerFunctions)
  computerFunctions.general["beanAuctions"] = {
    id = "beanAuctions",
    label = "Salvage Auctions",
    callback = function() career_career.closeAllMenus() openWindow("home") end,
    order = 11,
  }
  computerFunctions.general["beanScanTool"] = {
    id = "beanScanTool",
    label = "Scan Tool",
    callback = function() career_career.closeAllMenus() openWindow("scan") end,
    order = 12,
  }
end

local function onVehicleAddedToInventory(data)
  -- vehicleShopping's inventory hook stamps year 1990 when it isn't the buyer; fix ours up after it
  local p = data and pendingAdds[data.inventoryId]
  if not p then return end
  pendingAdds[data.inventoryId] = nil
  local veh = career_modules_inventory.getVehicles()[data.inventoryId]
  if veh then veh.year = p.year end
  if p.tow then
    if p.tow ~= "insta" then career_modules_inventory.delayVehicleAccess(data.inventoryId, towDelay, "bought") end
    career_modules_inventory.removeVehicleObject(data.inventoryId)
  end
end

local function onSaveCurrentProfile(currentSavePath)
  local saved = {}
  for _, lot in ipairs(lots) do
    local copy = shallowcopy(lot)
    if copy.state == "spawning" then copy.state = "won" end -- respawn on next load
    copy.readyAt, copy.readyVehId, copy.readyMode = nil, nil, nil
    table.insert(saved, copy)
  end
  career_saveSystem.jsonWriteFileSafe(currentSavePath .. saveFileName, {lots = saved, nextLotId = nextLotId, yardSpots = yardSpots}, true)
end

local function onExtensionLoaded()
  if not career_career.isActive() then return false end
  startWeb()
  local _, savePath = career_saveSystem.getCurrentProfile()
  local data = savePath and jsonReadFile(savePath .. saveFileName)
  if data then
    lots = data.lots or {}
    nextLotId = data.nextLotId or 1
    yardSpots = data.yardSpots and #data.yardSpots >= yardSize and data.yardSpots or nil -- older saves kept a smaller yard
    for _, lot in ipairs(lots) do if lot.state == "spawning" then lot.state = "won" end end
  end
end

local function onExtensionUnloaded()
  stopWeb()
  closeWindow()
  removeInspectVehicle()
end

-- assert-based check of the bid math: career_modules_beanAuctions.selfTest()
local function selfTest()
  assert(bidIncrement(999) == 50 and bidIncrement(1000) == 100 and bidIncrement(25000) == 500)
  local w, p = resolveProxy(500, {{who = "a", max = 400}})
  assert(w == nil and p == nil, "below start bid = no sale")
  w, p = resolveProxy(500, {{who = "a", max = 2000}})
  assert(w == "a" and p == 500, "single bidder pays start")
  w, p = resolveProxy(500, {{who = "a", max = 2000}, {who = "b", max = 1500}})
  assert(w == "a" and p == 1600, "second max + increment")
  w, p = resolveProxy(500, {{who = "a", max = 1550}, {who = "b", max = 1500}})
  assert(w == "a" and p == 1550, "capped at winner's max")
  w, p = resolveProxy(500, {{who = "a", max = 1500}, {who = "b", max = 1500}})
  assert(w == "a" and p == 1500, "tie goes to earlier bid")
  local lot = {marketValue = 10000, faults = {{id = "engine"}, {id = "transmission", hidden = true}}}
  assert(asIsValue(lot) == 4000 and asIsValue(lot, true) == 6500)
  return "ok"
end

M.onUpdate = onUpdate
M.onComputerAddFunctions = onComputerAddFunctions
M.onVehicleAddedToInventory = onVehicleAddedToInventory
M.onSaveCurrentProfile = onSaveCurrentProfile
M.onExtensionLoaded = onExtensionLoaded
M.onExtensionUnloaded = onExtensionUnloaded
M.onLotVehicleReady = onLotVehicleReady

M.openWindow = openWindow
-- closing goes through the page so the tablet can animate away first (it calls back with uiAction close)
M.toggleWindow = function()
  if uiOpen then
    be:executeJS([[var f=document.getElementById('beanAuctionsFrame');
      if(f&&f.contentWindow&&f.contentWindow.closeTablet)f.contentWindow.closeTablet();
      else bngApi.engineLua('career_modules_beanAuctions.uiAction("close",0,0,"")');]])
  elseif career_career.isActive() then openWindow() end
end
M.closeIfOpen = function() if uiOpen then M.toggleWindow() end end
M.openScanTool = function() openWindow("scan") end
M.uiAction = uiAction
M.getLots = function() return lots end
M.setMaxBid = setMaxBid
M.consign = consign
M.quickBid = quickBid
M.inspect = inspect
M.collect = collect
M.fastTravel = fastTravel
M.selfTest = selfTest
M.debugEndLot = function(lotId) local lot = getLot(lotId) if lot then lot.endsAt = os.time() end end

return M
