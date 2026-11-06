-- BeanAuctions vehicle value fix. Stock career values a car by its main part's odometer (which
-- can't be swapped) and only half-credits new parts, so a full restoration barely changes the price.
-- This wraps the stock getInventoryVehicleValue, which every sell / trade-in / marketplace /
-- insurance / auction path calls, and never returns less than the stock value.

local M = {}
M.dependencies = {'career_career', 'career_modules_valueCalculator', 'career_modules_partInventory'}

local freshKm = 150000   -- parts averaging this many km score 0 condition
local classicAge = 25
local classicMax = 2.0   -- a perfect restored classic is worth up to 2x its price new
local classicCurve = 4   -- premium = classicMax * score^4: 1.0 -> 2x, 0.9 -> 1.3x, 0.8 -> 0.8x, worn originals ~0
local refurbishMax = 0.95 -- refurbished parts come back to this condition at best, never new

-- 0..1 condition of one part: wear from its odometer, times its integrity
local function partScore(pc)
  return math.max(0, 1 - (pc.odometer or 0) / 1000 / freshKm) * (pc.integrityValue or 1)
end

-- The part inventory holds every part the player owns, so scanning it once per car per screen
-- refresh grows with cars x parts. Index it by car instead, rebuilt at most once a second
-- (fresh = rebuild now, for money paths that just changed parts).
local partsIndex, partsIndexAt
local function partsOf(id, fresh)
  if fresh or not partsIndex or os.clock() - partsIndexAt > 1 then
    partsIndex, partsIndexAt = {}, os.clock()
    for _, p in pairs(career_modules_partInventory.getInventory()) do
      if p.location then
        partsIndex[p.location] = partsIndex[p.location] or {}
        table.insert(partsIndex[p.location], p)
      end
    end
  end
  return partsIndex[id] or {}
end

-- km and 0..1 condition score from every part on the car, weighted by part price
local function condition(id, fresh)
  local sumV, sumOdo, sumScore = 0, 0, 0
  for _, p in ipairs(partsOf(id, fresh)) do
    if p.partCondition then
      local w = math.max(p.value or 0, 1)
      sumV = sumV + w
      sumOdo = sumOdo + w * (p.partCondition.odometer or 0)
      sumScore = sumScore + w * partScore(p.partCondition)
    end
  end
  if sumV == 0 then return end
  return sumOdo / sumV / 1000, sumScore / sumV
end

local function classicValue(newPrice, score) return newPrice * classicMax * score ^ classicCurve end

-- orig = the stock function. Returns the as-is value, the repaired value and details for the site,
-- from one pair of stock calls. fresh = rebuild the parts index first.
local function values(orig, id, fresh)
  local damaged, clean = orig(id), orig(id, true)
  local veh = career_modules_inventory.getVehicles()[id]
  if not damaged or not clean or not veh or not veh.configBaseValue then return damaged, clean end
  local km, score = condition(id, fresh)
  if not km then return damaged, clean end
  local VC = career_modules_valueCalculator
  local age = 2023 - (veh.year or 2023)
  -- 1. mileage from the parts actually on the car, not the original body's odometer
  local stockMileage = VC.getVehicleMileageById(id) or 0
  local gain = VC.getAdjustedVehicleBaseValue(veh.configBaseValue, {mileage = km * 1000, age = age})
    - VC.getAdjustedVehicleBaseValue(veh.configBaseValue, {mileage = stockMileage, age = age})
  local improved = clean + math.max(0, gain)
  -- 2. restored-classic premium
  local premium = age >= classicAge and classicValue(veh.configBaseValue, score) > improved
  if premium then improved = classicValue(veh.configBaseValue, score) end
  -- never below stock; damage still costs what the stock repair would
  return math.max(damaged, improved - (clean - damaged)), math.max(clean, improved), {km = math.floor(km), score = score, restoredClassic = premium or false}
end

local function value(orig, id, ignoreDamage, fresh)
  local damaged, clean, details = values(orig, id, fresh)
  return (ignoreDamage and clean or damaged), details
end

local function install()
  local VC = career_modules_valueCalculator
  if not VC or VC.beanOrigValue then return end
  local orig = VC.getInventoryVehicleValue
  VC.beanOrigValue = orig
  -- looks us up on every call, so reloading this file takes effect and unloading falls back to stock
  VC.getInventoryVehicleValue = function(id, ignoreDamage)
    local bv = career_modules_beanValue
    if not bv then return orig(id, ignoreDamage) end
    return (bv.value(orig, id, ignoreDamage, true)) -- real prices: always from a fresh parts index; one value only, like stock
  end
end

-- For the mod's own screens only, which refresh every ~1.2 s: values are remembered for a few
-- seconds. Selling, trade-ins and insurance go through the wrapper above and stay live.
local cacheTime = 3
local cache = {} -- [id] = {t = os.clock(), damaged =, clean =, details =}
local function cached(id, ignoreDamage)
  local c = cache[id]
  -- staggered by car so a big garage doesn't recompute every car on the same refresh (the stock
  -- value function still scans the whole part inventory per call)
  if not c or os.clock() - c.t > cacheTime + (id % 7) * 0.4 then c = {t = os.clock()} cache[id] = c end
  if not c.damaged then
    local VC = career_modules_valueCalculator
    c.damaged, c.clean, c.details = values(VC.beanOrigValue or VC.getInventoryVehicleValue, id)
  end
  return (ignoreDamage and c.clean or c.damaged), c.details
end
local function invalidate(id) if id then cache[id] = nil else cache = {} end partsIndex = nil end

-- details for the site: {km, score, restoredClassic}
local function info(id)
  local _, details = cached(id, true)
  return details
end

local function selfTest()
  assert(partScore({odometer = 0}) == 1 and partScore({odometer = freshKm * 1000}) == 0)
  assert(math.abs(partScore({odometer = (1 - refurbishMax) * freshKm * 1000}) - refurbishMax) < 1e-9, "refurbish odometer lands on the cap")
  assert(classicValue(10000, 1) == 20000)
  assert(math.abs(classicValue(10000, 0.9) - 13122) < 1)
  assert(classicValue(10000, 0.3) < 200, "worn originals get no real premium")
  return "ok"
end

M.onExtensionLoaded = install
M.value = value
M.partScore = partScore
M.partsOf = partsOf
M.cached = cached
M.invalidate = invalidate
M.onVehicleRemoved = invalidate
M.refurbishMax = refurbishMax
M.refurbishOdometer = (1 - refurbishMax) * freshKm * 1000 -- metres
M.info = info
M.selfTest = selfTest

return M
