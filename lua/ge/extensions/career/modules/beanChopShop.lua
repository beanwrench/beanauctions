-- BeanAuctions chop shop: one button in the part customization menu that queues removal of
-- every removable part. It only fills the stock shopping cart; the player still confirms
-- (or cancels) with the stock buttons, and removed parts go to the part inventory as usual.

local M = {}
M.dependencies = {'career_career'}

local function chop()
  local shop = career_modules_partShopping
  if not shop.isShoppingSessionActive() then return end
  local cart, last = shop.getShoppingCart(), nil
  for _, part in ipairs(shop.getPartsInShop()) do
    -- the shop offers an "empty" placeholder for every non-core slot that has a part
    if part.emptyPlaceholder then
      if last then cart.partsIn[last.containingSlot] = last end
      last = part
    end
  end
  if not last then return ui_message("Nothing left to remove", 3, "beanChopShop") end
  shop.installPart(last) -- applies the whole cart in a single vehicle respawn
end

local buttonJs = [[
(function(){var b=document.getElementById('beanChopShop');if(b)b.remove();if(!%s)return;
b=document.createElement('div');b.id='beanChopShop';b.textContent='CHOP SHOP: REMOVE ALL PARTS';
b.title='Queue removal of every removable part. Nothing changes until you apply the cart.';
b.style.cssText='position:fixed;top:12px;left:50%%;transform:translateX(-50%%);z-index:9999;padding:8px 16px;background:#c62828;color:#fff;font:bold 14px sans-serif;border-radius:4px;cursor:pointer;box-shadow:0 2px 8px rgba(0,0,0,.5)';
b.onclick=function(){bngApi.engineLua('career_modules_beanChopShop.chop()')};document.body.appendChild(b);})();]]

local function showButton(show) be:executeJS(string.format(buttonJs, show and "true" or "false")) end

M.chop = chop
M.onPartShoppingStarted = function() showButton(true) end
M.onPartShoppingCancelled = function() showButton(false) end
M.onPartShoppingTransactionComplete = function() showButton(false) end
M.onExtensionUnloaded = function() showButton(false) end

return M
