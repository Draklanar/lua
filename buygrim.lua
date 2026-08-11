--[[
    buygrimoire.lua
    Navigates to "Incarnation of Cazic" and buys N x
    "Grimoire of Profound Experience" from the point-merchant window,
    paying in "Ancient Fragments of Knowledge".

    Usage:  /lua run buygrimoire        -- buy as many as currency allows
            /lua run buygrimoire max    -- same as above, explicit
            /lua run buygrimoire 5      -- buy at most 5

    Requires: MQ2Nav loaded, with a navmesh for the current zone.

    This vendor uses NewPointMerchantWnd -- NOT MerchantWnd. That means
    /buyitem and Merchant.SelectItem do not apply here (both are scoped to
    the regular merchant window). We drive the UI directly instead.

    Control names below were read off the live client with wndscan.lua:
      NewPointMerchantWnd
        NewPointMerchant_NameLabel            (Label)   vendor name
        NewPointMerchant_ItemList             (Listbox) col1=item, col2=price
        NewPointMerchant_PointsNameLabel      (Label)   currency name
        NewPointMerchant_PointsAvailableValue (Label)   currency amount
        NewPointMerchant_PurchaseButton       (Button)
        NewPointMerchant_DoneButton           (Button)

    References (verified):
      window datatype  https://docs.macroquest.org/reference/data-types/datatype-window/
                       Open, Enabled, Items, SelectedIndex, List[Text,Col],
                       Text, methods Select[Index] / LeftMouseUp
      /notify          https://docs.macroquest.org/reference/commands/notify/
                       "listselect" for lists, "leftmouseup" for buttons
      mq.delay / args  https://docs.macroquest.org/lua/
      Navigation TLO   https://www.redguides.com/docs/projects/mq2nav/
]]

local mq = require('mq')
local args = {...}

-- Config -------------------------------------------------------------------
local NPC_NAME      = 'Incarnation of Cazic'
local ITEM_NAME     = 'Grimoire of Profound Experience'
local CURRENCY_NAME = 'Ancient Fragments of Knowledge'

local WND      = 'NewPointMerchantWnd'
local C_LIST   = 'NewPointMerchant_ItemList'
local C_CURNAM = 'NewPointMerchant_PointsNameLabel'
local C_CURVAL = 'NewPointMerchant_PointsAvailableValue'
local C_BUY    = 'NewPointMerchant_PurchaseButton'
local C_DONE   = 'NewPointMerchant_DoneButton'

local COL_ITEM  = 1
local COL_PRICE = 2

-- Purchase raises a confirmation dialog. /yes is only an ini ALIAS, not a
-- built-in command, so we drive the dialog ourselves. These are the stock EQ
-- dialog windows (the same ones the shipped /yes alias targets); if the
-- server uses a custom one we find the Yes button by its text instead.
local DIALOG_WNDS = { 'ConfirmationDialogBox', 'LargeDialogWindow' }
local DIALOG_YES  = { 'CD_Yes_Button', 'CD_OK_Button', 'LDW_YesButton', 'LDW_OKButton' }
local DIALOG_WAIT = 3000

local STOP_DIST   = 15
local NAV_TIMEOUT = 60000
local UI_TIMEOUT  = 5000

local NPC_QUERIES = {
    'npc ' .. NPC_NAME:gsub(' ', '_'),
    'npc ' .. NPC_NAME:match('^(%S+)'),
}

local function log(msg)  printf('\ag[buygrim]\ax %s', msg) end
local function warn(msg) printf('\ay[buygrim]\ax %s', msg) end
local function fail(msg) printf('\ar[buygrim]\ax %s', msg) end

-- Argument parsing ----------------------------------------------------------
-- No argument (or "max"/"all") = buy as many as the currency allows.
-- A number = buy at most that many.
local QUANTITY = nil   -- nil means "resolve from currency in preflight"

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
    end
end

-- Helpers -------------------------------------------------------------------
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

local function child(name) return mq.TLO.Window(WND).Child(name) end

local function wndOpen()
    return val(function() return mq.TLO.Window(WND).Open() end) == true
end

-- Read the currency counter straight off the window label
local function currencyOnHand()
    local text = val(function() return child(C_CURVAL).Text() end)
    if type(text) ~= 'string' then return nil end
    return tonumber((text:gsub('[,%s]', '')))
end

-- Find the row index of our item in the listbox (1-based, 0/nil = not found)
local function findRow()
    local idx = val(function()
        return child(C_LIST).List(('=%s,%d'):format(ITEM_NAME, COL_ITEM))()
    end)
    if type(idx) == 'number' and idx > 0 then return idx end
    return nil
end

local function rowPrice(idx)
    local text = val(function()
        return child(C_LIST).List(('%d,%d'):format(idx, COL_PRICE))()
    end)
    return tonumber(text)
end

-- Select a listbox row. Try the Select method, fall back to /notify listselect.
local function selectRow(idx)
    local selected = function()
        return val(function() return child(C_LIST).SelectedIndex() end) == idx
    end

    pcall(function() child(C_LIST).Select(idx)() end)
    mq.delay(500, selected)

    if not selected() then
        mq.cmdf('/notify %s %s listselect %d', WND, C_LIST, idx)
        mq.delay(1000, selected)
    end

    return selected()
end

-- Confirmation dialog -------------------------------------------------------
-- Recursively look for a Button child whose text is "Yes" (or "OK").
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

-- Wait briefly for a confirmation dialog; if one appears, accept it.
-- Returns true if we handled it (or none appeared), false if we saw a dialog
-- we could not drive.
local function confirmPurchase()
    local openDialog = nil
    mq.delay(DIALOG_WAIT, function()
        for _, name in ipairs(DIALOG_WNDS) do
            local w = mq.TLO.Window(name)
            if val(function() return w() end) and val(function() return w.Open() end) then
                openDialog = name
                return true
            end
        end
        return false
    end)

    if not openDialog then
        return true  -- no confirmation required for this purchase
    end

    -- Prefer a button whose text actually reads Yes/OK
    local btn = findYesButton(mq.TLO.Window(openDialog), 1)

    -- Otherwise fall back to the stock button names
    if not btn then
        for _, name in ipairs(DIALOG_YES) do
            local c = mq.TLO.Window(openDialog).Child(name)
            if val(function() return c() end) then btn = name break end
        end
    end

    if not btn then
        fail(('Dialog "%s" opened but no Yes button found.'):format(openDialog))
        fail(('Run:  /lua run wndscan %s   and send me the dump.'):format(openDialog))
        return false
    end

    log(('Confirming: %s / %s'):format(openDialog, btn))
    mq.cmdf('/notify %s %s leftmouseup', openDialog, btn)

    -- Wait for the dialog to go away so the next click isn't swallowed
    mq.delay(3000, function()
        return val(function() return mq.TLO.Window(openDialog).Open() end) ~= true
    end)

    if val(function() return mq.TLO.Window(openDialog).Open() end) == true then
        fail('Confirmation dialog did not close.')
        return false
    end
    return true
end

-- Cursor -------------------------------------------------------------------
local function cursorEmpty()
    return (val(function() return mq.TLO.Cursor.ID() end) or 0) == 0
end

-- Stow whatever is on the cursor and CONFIRM it actually left.
-- Returns false if we cannot clear it (full bags, no-drop prompt, etc).
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
    fail(('Could not clear cursor (still holding "%s").'):format(held))
    fail('Bags are probably full. Stopping so nothing is lost.')
    return false
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

-- Step 3: open the point-merchant window -------------------------------------
local function openWindow()
    if wndOpen() then
        log('Vendor window already open.')
    else
        log('Opening vendor window...')
        mq.cmd('/click right target')
        if not waitFor(wndOpen, UI_TIMEOUT, WND) then return false end
    end

    -- let the list populate
    if not waitFor(function()
        return (val(function() return child(C_LIST).Items() end) or 0) > 0
    end, UI_TIMEOUT, 'item list') then
        return false
    end

    return true
end

-- Step 4: preflight ----------------------------------------------------------
-- Returns row index and unit price, or nil on any problem.
local function preflight()
    local idx = findRow()
    if not idx then
        fail(('"%s" is not listed on this vendor.'):format(ITEM_NAME))
        return nil
    end

    local price = rowPrice(idx)
    if not price then
        fail('Could not read the price column. Aborting rather than guessing.')
        return nil
    end

    -- Confirm the currency label is what we expect before trusting the amount
    local curName = val(function() return child(C_CURNAM).Text() end)
    if type(curName) == 'string' and #curName > 0 then
        if curName:lower() ~= CURRENCY_NAME:lower() then
            warn(('Vendor currency is "%s", expected "%s".'):format(curName, CURRENCY_NAME))
        end
    end

    local have = currencyOnHand()
    if not have then
        fail('Could not read the currency amount. Aborting rather than guessing.')
        return nil
    end

    if price < 1 then
        fail(('Price reads as %s; refusing to compute a quantity from that.'):format(tostring(price)))
        return nil
    end

    local label = type(curName) == 'string' and #curName > 0 and curName or CURRENCY_NAME
    local affordable = math.floor(have / price)

    log(('Row %d: %s @ %d each.'):format(idx, ITEM_NAME, price))
    log(('%s: %d available -> can afford %d.'):format(label, have, affordable))

    if affordable < 1 then
        fail(('Cannot afford even one (need %d, have %d).'):format(price, have))
        return nil
    end

    if QUANTITY == nil then
        QUANTITY = affordable
        log(('No quantity given: buying the max, %d.'):format(QUANTITY))
    elseif QUANTITY > affordable then
        fail(('Asked for %d but can only afford %d. Aborting.'):format(QUANTITY, affordable))
        return nil
    end

    -- Soft warning only: bag space may not be readable on every build
    local free = val(function() return mq.TLO.Me.FreeInventory() end)
    if type(free) == 'number' and free < QUANTITY then
        warn(('Only %d free inventory slot(s) for %d items; may stop early.')
            :format(free, QUANTITY))
    end

    log(('Will spend %d of %d %s.'):format(QUANTITY * price, have, label))

    return idx, price
end

-- Step 5: buy ----------------------------------------------------------------
local function buyOne(price)
    -- Never click Purchase with something on the cursor; a held item makes
    -- the click behave unpredictably and can swallow the purchase.
    if not clearCursor() then return false end

    -- Re-find the row each pass; the list can re-sort or shift after a purchase
    local idx = findRow()
    if not idx then
        fail('Item no longer listed.')
        return false
    end

    if not selectRow(idx) then
        fail(('Could not select row %d in %s.'):format(idx, C_LIST))
        return false
    end

    if val(function() return child(C_BUY).Enabled() end) == false then
        fail('Purchase button is disabled after selecting. Not clicking.')
        return false
    end

    local curBefore  = currencyOnHand() or 0
    local itemBefore = mq.TLO.FindItemCount('=' .. ITEM_NAME)() or 0

    mq.cmdf('/notify %s %s leftmouseup', WND, C_BUY)

    if not confirmPurchase() then
        return false
    end

    -- Success = currency dropped by the price, or the item count went up
    local landed = function()
        local c = currencyOnHand()
        local i = mq.TLO.FindItemCount('=' .. ITEM_NAME)() or 0
        return (c and c <= curBefore - price) or i > itemBefore
    end
    mq.delay(5000, landed)

    -- If it landed on the cursor instead of a bag, stow it and VERIFY.
    -- This must succeed before the next purchase is attempted.
    if not clearCursor() then
        return false
    end

    if not landed() then
        fail('No currency or inventory change detected after clicking Purchase.')
        return false
    end
    return true
end

-- Main -----------------------------------------------------------------------
local function main()
    if QUANTITY then
        log(('Requested: %d x %s'):format(QUANTITY, ITEM_NAME))
    else
        log(('Requested: as many %s as currency allows.'):format(ITEM_NAME))
    end

    local id = targetNPC()
    if not id then return end
    if not navigateTo(id) then return end
    if not openWindow() then return end

    local idx, price = preflight()
    if not idx then return end

    -- Spending is irreversible, so give a moment to bail out
    warn(('Starting in 5s: %d purchase(s). \asType /lua stop to abort.\ax'):format(QUANTITY))
    mq.delay(5000)

    local startItems = mq.TLO.FindItemCount('=' .. ITEM_NAME)() or 0
    local startCur   = currencyOnHand() or 0
    local bought     = 0

    for i = 1, QUANTITY do
        log(('Purchase %d of %d...'):format(i, QUANTITY))
        if not buyOne(price) then
            fail(('Stopping after %d successful purchase(s).'):format(bought))
            break
        end
        bought = bought + 1
        mq.delay(400)
    end

    local endItems = mq.TLO.FindItemCount('=' .. ITEM_NAME)() or 0
    local endCur   = currencyOnHand() or 0

    log(('Bought %d. Inventory %d -> %d. Currency %d -> %d (spent %d).')
        :format(bought, startItems, endItems, startCur, endCur, startCur - endCur))

    if bought == QUANTITY then
        log('\agDone.\ax')
    end

    -- Leave the window open. Uncomment to close when finished:
    -- mq.cmdf('/notify %s %s leftmouseup', WND, C_DONE)
end

main()
