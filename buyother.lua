--[[
    buyother.lua
    Navigates to "Adrienne" and buys "Grimoire of Otherworldly Experience",
    which costs 15 x "Token of Legendary Might" each.

    Usage:  /lua run buyother        -- buy as many as you can afford
            /lua run buyother max    -- same, explicit
            /lua run buyother 3      -- buy at most 3 (needs 45 tokens)

    Requires: MQ2Nav loaded, with a navmesh for the current zone.

    Adrienne's window type is auto-detected:
      * NewPointMerchantWnd  -> point merchant (list + Purchase button)
      * MerchantWnd          -> regular merchant (/selectitem + /buyitem)
    If neither opens, run  /lua run wndscan  to identify the window.

    Currency is resolved in this order, and the script reports which it used:
      1. The point-merchant window's own "points available" label
      2. Count of the currency item in your inventory (FindItemCount)
      3. Me.AltCurrency[name]

    References (verified):
      window datatype  https://docs.macroquest.org/reference/data-types/datatype-window/
      /notify          https://docs.macroquest.org/reference/commands/notify/
      /buyitem         https://docs.macroquest.org/reference/commands/buyitem/
      /selectitem      https://docs.macroquest.org/reference/commands/selectitem/
      merchant type    https://docs.macroquest.org/reference/data-types/datatype-merchant/
      mq.delay / args  https://docs.macroquest.org/lua/
      Navigation TLO   https://www.redguides.com/docs/projects/mq2nav/
]]

local mq = require('mq')
local args = {...}

-- Config -------------------------------------------------------------------
local NPC_NAME      = 'Adrienne'
local ITEM_NAME     = 'Grimoire of Otherworldly Experience'
local CURRENCY_NAME = 'Token of Legendary Might'
local COST_EACH     = 15          -- currency units per item

local STOP_DIST     = 15
local NAV_TIMEOUT   = 60000
local UI_TIMEOUT    = 5000

-- Point-merchant window controls (confirmed on this server via wndscan)
local PWND     = 'NewPointMerchantWnd'
local C_LIST   = 'NewPointMerchant_ItemList'
local C_CURNAM = 'NewPointMerchant_PointsNameLabel'
local C_CURVAL = 'NewPointMerchant_PointsAvailableValue'
local C_BUY    = 'NewPointMerchant_PurchaseButton'
local C_DONE   = 'NewPointMerchant_DoneButton'
local COL_ITEM, COL_PRICE = 1, 2

-- Regular merchant window
local MWND = 'MerchantWnd'

-- Confirmation dialog (/yes is only an ini alias, so we drive it ourselves)
local DIALOG_WNDS = { 'ConfirmationDialogBox', 'LargeDialogWindow' }
local DIALOG_YES  = { 'CD_Yes_Button', 'CD_OK_Button', 'LDW_YesButton', 'LDW_OKButton' }
local DIALOG_WAIT = 3000

local NPC_QUERIES = {
    'npc ' .. NPC_NAME:gsub(' ', '_'),
    'npc ' .. NPC_NAME:match('^(%S+)'),
}

local function log(msg)  printf('\ag[buyoth]\ax %s', msg) end
local function warn(msg) printf('\ay[buyoth]\ax %s', msg) end
local function fail(msg) printf('\ar[buyoth]\ax %s', msg) end

-- Argument parsing ----------------------------------------------------------
local QUANTITY = nil   -- nil = resolve max from currency during preflight
local BUY_MAX  = true  -- false once an explicit quantity is given
local MAX_ROUNDS = 20  -- safety cap on the keep-going loop

if args[1] then
    local a = tostring(args[1]):lower()
    if a ~= 'max' and a ~= 'all' then
        local n = tonumber(args[1])
        if not n or n < 1 or n ~= math.floor(n) then
            fail(('Invalid quantity "%s". Pass a whole number >= 1, or "max".')
                :format(tostring(args[1])))
            return
        end
        QUANTITY = math.floor(n)
        BUY_MAX  = false
    end
end

-- Helpers -------------------------------------------------------------------
local MODE = nil   -- 'point' or 'merchant'

local function val(fn)
    local ok, v = pcall(fn)
    if ok then return v end
    return nil
end

local function waitFor(cb, timeout, label)
    mq.delay(timeout, cb)
    if not cb() then
        fail(('Timed out waiting for %s'):format(label))
        return false
    end
    return true
end

local function pchild(name) return mq.TLO.Window(PWND).Child(name) end

local function wndIsOpen(name)
    local w = mq.TLO.Window(name)
    if not val(function() return w() end) then return false end
    return val(function() return w.Open() end) == true
end

local function itemCount()
    return mq.TLO.FindItemCount('=' .. ITEM_NAME)() or 0
end

-- Cursor --------------------------------------------------------------------
local function cursorEmpty()
    return (val(function() return mq.TLO.Cursor.ID() end) or 0) == 0
end

local function clearCursor()
    if cursorEmpty() then return true end
    for attempt = 1, 5 do
        local held = val(function() return mq.TLO.Cursor.Name() end) or 'item'
        log(('Cursor holding "%s", auto-inventorying (attempt %d).'):format(held, attempt))
        mq.cmd('/autoinventory')
        mq.delay(1500, cursorEmpty)
        if cursorEmpty() then return true end
        mq.delay(300)
    end
    local held = val(function() return mq.TLO.Cursor.Name() end) or 'something'
    fail(('Could not clear cursor (still holding "%s"). Bags likely full.'):format(held))
    return false
end



-- Currency name matching ----------------------------------------------------
-- Vendors may label a currency in the plural ("Tokens of Might") while the
-- lookup name is singular ("Token of Might"). Normalise both before compare.
local function normName(s)
    if type(s) ~= 'string' then return '' end
    s = s:lower():gsub('[^%a%s]', ''):gsub('%s+', ' '):gsub('^%s+', ''):gsub('%s+$', '')
    -- strip a trailing 's' from each word so singular/plural collapse together
    s = s:gsub('(%a+)', function(w) return (#w > 3 and w:sub(-1) == 's') and w:sub(1, -2) or w end)
    return s
end

local function namesMatch(a, b)
    a, b = normName(a), normName(b)
    if a == '' or b == '' then return false end
    return a == b or a:find(b, 1, true) ~= nil or b:find(a, 1, true) ~= nil
end

-- Read the spendable currency.
-- ORDER MATTERS. An inventory ITEM can share a currency's name without being
-- the thing the vendor deducts, so inventory is the LAST resort, never the
-- first. Alt-currency is authoritative and updates live after each purchase.
local function readCurrency(allowWindow)
    -- 1. Alt currency, trying singular/plural variants of the configured name
    local variants = { CURRENCY_NAME }
    if CURRENCY_NAME:sub(-1) == 's' then
        variants[#variants + 1] = CURRENCY_NAME:sub(1, -2)
    else
        variants[#variants + 1] = CURRENCY_NAME .. 's'
    end
    -- also try pluralising the first word ("Token of Might" -> "Tokens of Might")
    variants[#variants + 1] = CURRENCY_NAME:gsub('^(%a+)', '%1s', 1)

    for _, name in ipairs(variants) do
        local amount = val(function() return mq.TLO.Me.AltCurrency(name)() end)
        if type(amount) == 'number' and amount > 0 then
            return amount, ('alt-currency "%s"'):format(name)
        end
    end

    -- 2. The vendor window label, if it names the same currency.
    --    Only at preflight: this label does NOT refresh while the window is open.
    if allowWindow and MODE == 'point' and wndIsOpen(PWND) then
        local label = val(function() return pchild(C_CURNAM).Text() end)
        if namesMatch(label, CURRENCY_NAME) then
            local text = val(function() return pchild(C_CURVAL).Text() end)
            local n = type(text) == 'string' and tonumber((text:gsub('[,%s]', ''))) or nil
            if n then return n, ('vendor label "%s"'):format(tostring(label)) end
        end
    end

    -- 3. Inventory item. Least trustworthy: a same-named item may not be the
    --    currency the vendor actually deducts.
    local bag = mq.TLO.FindItemCount('=' .. CURRENCY_NAME)() or 0
    if bag > 0 then return bag, 'inventory item (unverified)' end

    return nil, 'not found'
end

local function currencyOnHand() return readCurrency(true) end
local function currencyLive()   return readCurrency(false) end

-- Confirmation dialog -------------------------------------------------------
local function findYesButton(w, depth)
    if depth > 4 then return nil end
    local c = w.FirstChild
    local guard = 0
    while c and val(function() return c.Name() end) and guard < 300 do
        guard = guard + 1
        local ctype = val(function() return c.Type() end)
        local text  = val(function() return c.Text() end)
        if ctype == 'Button' and type(text) == 'string' then
            local t = text:lower()
            if t == 'yes' or t == 'ok' or t == 'accept' then
                return val(function() return c.Name() end)
            end
        end
        local found = findYesButton(c, depth + 1)
        if found then return found end
        c = c.Next
    end
    return nil
end

local function confirmPurchase()
    local openDialog = nil
    mq.delay(DIALOG_WAIT, function()
        for _, name in ipairs(DIALOG_WNDS) do
            if wndIsOpen(name) then openDialog = name return true end
        end
        return false
    end)

    if not openDialog then return true end   -- no confirmation needed

    local btn = findYesButton(mq.TLO.Window(openDialog), 1)
    if not btn then
        for _, name in ipairs(DIALOG_YES) do
            if val(function() return mq.TLO.Window(openDialog).Child(name)() end) then
                btn = name break
            end
        end
    end

    if not btn then
        fail(('Dialog "%s" opened but no Yes button found.'):format(openDialog))
        fail(('Run:  /lua run wndscan %s   and send me the dump.'):format(openDialog))
        return false
    end

    log(('Confirming: %s / %s'):format(openDialog, btn))
    mq.cmdf('/notify %s %s leftmouseup', openDialog, btn)

    mq.delay(3000, function() return not wndIsOpen(openDialog) end)
    if wndIsOpen(openDialog) then
        fail('Confirmation dialog did not close.')
        return false
    end
    return true
end

-- Close whichever vendor window is open, and confirm it closed --------------
local function findButtonByText(w, wanted, depth)
    if depth > 4 then return nil end
    local c = w.FirstChild
    local guard = 0
    while c and val(function() return c.Name() end) and guard < 300 do
        guard = guard + 1
        local ctype = val(function() return c.Type() end)
        local text  = val(function() return c.Text() end)
        if ctype == 'Button' and type(text) == 'string' and text:lower() == wanted then
            return val(function() return c.Name() end)
        end
        local found = findButtonByText(c, wanted, depth + 1)
        if found then return found end
        c = c.Next
    end
    return nil
end

local function closeWindow()
    if MODE == 'point' and wndIsOpen(PWND) then
        log('Closing vendor window.')
        mq.cmdf('/notify %s %s leftmouseup', PWND, C_DONE)
        mq.delay(2000, function() return not wndIsOpen(PWND) end)
        if wndIsOpen(PWND) then
            warn('Vendor window did not close; close it by hand.')
            return false
        end
        return true
    end

    if wndIsOpen(MWND) then
        log('Closing merchant window.')
        -- Documented method on the Merchant TLO; if the Lua bridge won't
        -- invoke it, fall back to clicking the button labelled "Done".
        pcall(function() mq.TLO.Merchant.CloseWindow()() end)
        mq.delay(1500, function() return not wndIsOpen(MWND) end)

        if wndIsOpen(MWND) then
            local btn = findButtonByText(mq.TLO.Window(MWND), 'done', 1)
            if btn then
                mq.cmdf('/notify %s %s leftmouseup', MWND, btn)
                mq.delay(2000, function() return not wndIsOpen(MWND) end)
            end
        end

        if wndIsOpen(MWND) then
            warn('Merchant window did not close; close it by hand.')
            return false
        end
        return true
    end

    return true
end

-- Step 1: target -------------------------------------------------------------
local function targetNPC()
    local spawn, used
    for _, query in ipairs(NPC_QUERIES) do
        local s = mq.TLO.Spawn(query)
        if s() and s.ID() > 0 then spawn, used = s, query break end
    end

    if not spawn then
        fail(('No NPC matching "%s" found in this zone.'):format(NPC_NAME))
        return nil
    end

    local found = spawn.CleanName() or '?'
    if found:lower() ~= NPC_NAME:lower() then
        warn(('Matched "%s" (query: %s), not an exact name match.'):format(found, used))
    end

    local id = spawn.ID()
    log(('Found %s (id %d) at %.0f units.'):format(found, id, spawn.Distance() or -1))

    mq.cmdf('/target id %d', id)
    if not waitFor(function() return mq.TLO.Target.ID() == id end, UI_TIMEOUT, 'target') then
        return nil
    end
    return id
end

-- Step 2: navigate -----------------------------------------------------------
local function navigateTo(id)
    local spawn = mq.TLO.Spawn(('id %d'):format(id))

    if (spawn.Distance() or 9999) <= STOP_DIST then
        log('Already in range.')
        return true
    end
    if not mq.TLO.Navigation.MeshLoaded() then
        fail('No navmesh loaded for this zone.')
        return false
    end
    if not mq.TLO.Navigation.PathExists('target')() then
        fail('MQ2Nav reports no path to the target.')
        return false
    end

    log('Navigating...')
    mq.cmd('/nav target')
    waitFor(function()
        return (spawn.Distance() or 9999) <= STOP_DIST or not mq.TLO.Navigation.Active()
    end, NAV_TIMEOUT, 'arrival')
    mq.cmd('/nav stop')
    mq.delay(500)

    local dist = spawn.Distance() or 9999
    if dist > STOP_DIST then
        fail(('Stopped %.0f units away; too far to trade.'):format(dist))
        return false
    end
    log(('Arrived (%.0f units).'):format(dist))
    return true
end

-- Step 3: open the vendor window and detect its type -------------------------
local function openWindow()
    if wndIsOpen(PWND) then MODE = 'point'
    elseif wndIsOpen(MWND) then MODE = 'merchant'
    else
        log('Opening vendor window...')
        mq.cmd('/click right target')
        mq.delay(UI_TIMEOUT, function()
            return wndIsOpen(PWND) or wndIsOpen(MWND)
        end)
        if wndIsOpen(PWND) then MODE = 'point'
        elseif wndIsOpen(MWND) then MODE = 'merchant' end
    end

    if not MODE then
        fail('Neither NewPointMerchantWnd nor MerchantWnd opened.')
        fail('Run:  /lua run wndscan   then right-click Adrienne, and send the dump.')
        return false
    end

    log(('Vendor window: %s (%s mode).')
        :format(MODE == 'point' and PWND or MWND, MODE))

    if MODE == 'point' then
        return waitFor(function()
            return (val(function() return pchild(C_LIST).Items() end) or 0) > 0
        end, UI_TIMEOUT, 'item list')
    else
        return waitFor(function() return mq.TLO.Merchant.ItemsReceived() end,
            UI_TIMEOUT, 'merchant inventory')
    end
end

-- Row lookup (point mode only) ----------------------------------------------
local function findRow()
    local idx = val(function()
        return pchild(C_LIST).List(('=%s,%d'):format(ITEM_NAME, COL_ITEM))()
    end)
    if type(idx) == 'number' and idx > 0 then return idx end
    return nil
end

local function rowPrice(idx)
    local text = val(function()
        return pchild(C_LIST).List(('%d,%d'):format(idx, COL_PRICE))()
    end)
    return tonumber(text)
end

local function selectRow(idx)
    local selected = function()
        return val(function() return pchild(C_LIST).SelectedIndex() end) == idx
    end
    pcall(function() pchild(C_LIST).Select(idx)() end)
    mq.delay(500, selected)
    if not selected() then
        mq.cmdf('/notify %s %s listselect %d', PWND, C_LIST, idx)
        mq.delay(1000, selected)
    end
    return selected()
end

-- Step 4: preflight ----------------------------------------------------------
-- Confirms the item is listed, works out the true unit cost, and resolves
-- QUANTITY from available currency. Returns cost, or nil to abort.
local function preflight()
    local cost = COST_EACH

    if MODE == 'point' then
        local idx = findRow()
        if not idx then
            fail(('"%s" is not listed on this vendor.'):format(ITEM_NAME))
            return nil
        end
        local shown = rowPrice(idx)
        if shown and shown > 0 then
            if shown ~= COST_EACH then
                warn(('Vendor lists %d each, script expects %d. Using the vendor price.')
                    :format(shown, COST_EACH))
            end
            cost = shown
        else
            warn(('Could not read the price column; using configured %d each.'):format(COST_EACH))
        end
        log(('Row %d: %s @ %d %s each.'):format(idx, ITEM_NAME, cost, CURRENCY_NAME))
    else
        if not mq.TLO.Merchant.Item('=' .. ITEM_NAME)() then
            fail(('"%s" is not on this merchant\'s list.'):format(ITEM_NAME))
            return nil
        end
        log(('%s @ configured %d %s each.'):format(ITEM_NAME, cost, CURRENCY_NAME))
    end

    local have, source = currencyOnHand()
    if not have then
        fail(('Could not read "%s" from any source (%s). Aborting rather than guessing.')
            :format(CURRENCY_NAME, source))
        return nil
    end
    log(('%s: %d on hand (source: %s).'):format(CURRENCY_NAME, have, source))

    local affordable = math.floor(have / cost)
    log(('Math: %d / %d = %d affordable (%d left over).')
        :format(have, cost, affordable, have % cost))

    if affordable < 1 then
        fail(('Cannot afford one: need %d, have %d (short by %d).')
            :format(cost, have, cost - have))
        return nil
    end

    if QUANTITY == nil then
        QUANTITY = affordable
        log(('No quantity given: buying the max, %d.'):format(QUANTITY))
        if have % cost > 0 then
            log(('Ceiling is %d because %d %s remain unspent (%d needed for one more).')
                :format(QUANTITY, have % cost, CURRENCY_NAME, cost - (have % cost)))
        end
    elseif QUANTITY > affordable then
        fail(('Asked for %d (%d needed) but can only afford %d. Aborting.')
            :format(QUANTITY, QUANTITY * cost, affordable))
        return nil
    end


    log(('Will spend %d of %d %s for %d x %s.')
        :format(QUANTITY * cost, have, CURRENCY_NAME, QUANTITY, ITEM_NAME))

    return cost
end

-- Step 5: buy one -----------------------------------------------------------
local function buyOne(cost)
    if not clearCursor() then return false end

    local curBefore  = select(1, currencyOnHand()) or 0
    local itemBefore = itemCount()

    if MODE == 'point' then
        local idx = findRow()
        if not idx then fail('Item no longer listed.') return false end
        if not selectRow(idx) then
            fail(('Could not select row %d in %s.'):format(idx, C_LIST))
            return false
        end
        if val(function() return pchild(C_BUY).Enabled() end) == false then
            fail('Purchase button is disabled after selecting. Not clicking.')
            return false
        end
        mq.cmdf('/notify %s %s leftmouseup', PWND, C_BUY)
    else
        local selected = function()
            local n = mq.TLO.Merchant.SelectedItem.Name()
            return n ~= nil and n:lower() == ITEM_NAME:lower()
        end
        pcall(function() mq.TLO.Merchant.SelectItem('=' .. ITEM_NAME)() end)
        mq.delay(500, selected)
        if not selected() then
            mq.cmdf('/selectitem "=%s"', ITEM_NAME)
            mq.delay(1000, selected)
        end
        if not selected() then
            fail('Could not select the item in the merchant window.')
            return false
        end
        mq.cmd('/buyitem 1')
    end

    if not confirmPurchase() then return false end

    local landed = function()
        local c = select(1, currencyOnHand())
        return (c and c <= curBefore - cost) or itemCount() > itemBefore
    end
    mq.delay(5000, landed)

    -- Stow before the next pass, and verify it actually cleared
    if not clearCursor() then return false end

    if not landed() then
        fail('No currency or inventory change detected after purchasing.')
        return false
    end
    return true
end

-- Main -----------------------------------------------------------------------
local function main()
    if QUANTITY then
        log(('Requested: %d x %s (%d %s each).')
            :format(QUANTITY, ITEM_NAME, COST_EACH, CURRENCY_NAME))
    else
        log(('Requested: as many %s as %s allows.'):format(ITEM_NAME, CURRENCY_NAME))
    end

    local id = targetNPC()
    if not id then return end
    if not navigateTo(id) then return end
    if not openWindow() then return end

    local cost = preflight()
    if not cost then return end

    warn(('Starting in 2s: %d purchase(s), %d %s total. \asType /lua stop to abort.\ax')
        :format(QUANTITY, QUANTITY * cost, CURRENCY_NAME))
    mq.delay(2000)

    local startItems = itemCount()
    local startCur   = select(1, currencyLive()) or 0
    local bought     = 0

    -- The currency readout is not always reliable, so QUANTITY may undercount.
    -- When buying "max", keep going in rounds until a purchase genuinely fails
    -- (buyOne only succeeds if the item count actually rose), rather than
    -- trusting the number. An explicit quantity is still honoured exactly.
    local rounds = 0
    repeat
        rounds = rounds + 1
        local roundStart = bought

        for i = 1, QUANTITY do
            log(('Purchase %d of %d%s...'):format(i, QUANTITY,
                rounds > 1 and (' (round %d)'):format(rounds) or ''))
            if not buyOne(cost) then
                log(('Purchase stopped after %d this round.'):format(bought - roundStart))
                break
            end
            bought = bought + 1
            mq.delay(400)
        end

        -- Only continue if we are in "max" mode, this round bought its full
        -- allotment (so nothing blocked us), and we are still under the cap.
        if not BUY_MAX or (bought - roundStart) < QUANTITY or rounds >= MAX_ROUNDS then
            break
        end

        local nowHave = select(1, currencyLive()) or 0
        local more = math.floor(nowHave / cost)
        if more < 1 then break end

        log(('Currency still reads %d -> %d more affordable. Continuing.'):format(nowHave, more))
        QUANTITY = more
    until false

    if bought > 0 and rounds >= MAX_ROUNDS then
        warn(('Hit the %d-round safety limit; run again to continue.'):format(MAX_ROUNDS))
    end

    local endItems = itemCount()
    local endCur   = select(1, currencyLive()) or 0

    log(('Bought %d. %s: %d -> %d. %s: %d -> %d (spent %d).')
        :format(bought, ITEM_NAME, startItems, endItems,
                CURRENCY_NAME, startCur, endCur, startCur - endCur))

    if bought == QUANTITY then log('\agDone.\ax') end
end

main()
closeWindow()   -- runs even if main() bailed out early
