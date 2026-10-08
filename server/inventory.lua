-- nonick_lib · server/inventory.lua
-- Inventory + money bridge for ox_inventory / qb-inventory / framework-native
-- inventories, with a 'standalone' fallback backed by a plain `playerData`
-- table ({ inventory = {}, money = n }) that the caller owns/persists.
--
-- Common `opts` (all optional):
--   player       framework player object (fetched when omitted)
--   playerData   standalone fallback table ({ inventory = {}, money = n })
--   resource     attribution for qb add/remove (defaults to the consumer)

NN.Inventory = NN.Inventory or {}
NN.Money = NN.Money or {}
local function qbInventory(name)
    return name == 'qb-inventory' or name == 'ps-inventory' or name == 'lj-inventory'
end

-- ── detection ────────────────────────────────────────────────────────────────

-- preferred: 'auto' (default) or explicit 'ox_inventory'|'qb-inventory'|'framework'|'standalone'.
function NN.Inventory.detect(preferred, frameworkName)
    preferred = tostring(preferred or 'auto'):lower()
    NN.Inventory.__preferred = preferred

    local name
    if preferred ~= 'auto' and preferred ~= '' then
        name = preferred
    elseif GetResourceState('ox_inventory') == 'started' then
        name = 'ox_inventory'
    elseif GetResourceState('qb-inventory') == 'started' then
        name = 'qb-inventory'
    elseif GetResourceState('ps-inventory') == 'started' then
        name = 'ps-inventory'
    elseif GetResourceState('lj-inventory') == 'started' then
        name = 'lj-inventory'
    else
        frameworkName = frameworkName or (NN.Framework and NN.Framework.get())
        if frameworkName == 'esx' or frameworkName == 'qbcore' or frameworkName == 'qbox' then
            name = 'framework'
        else
            name = 'standalone'
        end
    end

    NN.Inventory.name = name
    return name
end

function NN.Inventory.get()
    if not NN.Inventory.name then
        NN.Inventory.detect(NN.Inventory.__preferred or 'auto')
    end

    -- Heal a poisoned early detection (same rationale as NN.Framework.get):
    -- 'standalone' picked with 'auto' before the inventory/framework resources
    -- finished starting must not stick for the whole session.
    if NN.Inventory.name == 'standalone' and (NN.Inventory.__preferred or 'auto') == 'auto' then
        if GetResourceState('ox_inventory') == 'started'
            or GetResourceState('qb-inventory') == 'started'
            or GetResourceState('ps-inventory') == 'started'
            or GetResourceState('lj-inventory') == 'started'
            or (NN.Framework and select(1, NN.Framework.get()) ~= 'standalone') then
            NN.Inventory.detect('auto')
        end
    end

    return NN.Inventory.name
end

local function resolve(source, opts)
    opts = opts or {}
    -- Prefer the lib's self-healing getters over a cached 'standalone' handed in
    -- by the consumer: a detection made before the framework/inventory resources
    -- finished starting must not stick for the whole session (items would keep
    -- going to the in-memory fallback table). When the consumer explicitly
    -- configured 'standalone', get() returns 'standalone' anyway (no heal).
    local inventoryName = opts.inventory
    if not inventoryName or inventoryName == 'standalone' then
        inventoryName = NN.Inventory.get()
    end
    local frameworkName = opts.framework
    if not frameworkName or frameworkName == 'standalone' then
        frameworkName = (NN.Framework and NN.Framework.get()) or 'standalone'
    end
    local player = opts.player
    if not player and NN.Framework then
        player = NN.Framework.getPlayer(source)
    end
    return inventoryName, frameworkName, player, opts.playerData or {}, opts.resource or NN.resource
end

-- ── items ────────────────────────────────────────────────────────────────────

function NN.Inventory.addItem(source, itemName, count, metadata, opts)
    local inventoryName, frameworkName, player, playerData, resource = resolve(source, opts)

    if inventoryName == 'ox_inventory' then
        return exports.ox_inventory:AddItem(source, itemName, count, metadata or {})
    end

    if qbInventory(inventoryName) then
        -- Guarded: old qb-inventory builds (pre-2024 rewrite) have no AddItem
        -- export — fall back to the QBCore player functions.
        local ok, result = pcall(function()
            return exports[inventoryName]:AddItem(source, itemName, count, false, metadata or {}, resource)
        end)
        if ok then return result end
        if player and player.Functions and player.Functions.AddItem then
            return player.Functions.AddItem(itemName, count, false, metadata or {}) and true or false
        end
        return false
    end

    if inventoryName == 'framework' and frameworkName == 'esx' and player then
        player.addInventoryItem(itemName, count)
        return true
    end

    if inventoryName == 'framework' and (frameworkName == 'qbcore' or frameworkName == 'qbox') and player and player.Functions and player.Functions.AddItem then
        return player.Functions.AddItem(itemName, count, false, metadata or {}, resource)
    end

    if inventoryName ~= 'standalone' then return false end
    playerData.inventory = playerData.inventory or {}
    playerData.inventory[itemName] = (playerData.inventory[itemName] or 0) + count
    return true
end

function NN.Inventory.getCount(source, itemName, opts)
    local inventoryName, frameworkName, player, playerData = resolve(source, opts)

    if inventoryName == 'ox_inventory' then
        return exports.ox_inventory:GetItemCount(source, itemName) or 0
    end

    if inventoryName == 'framework' and frameworkName == 'esx' and player then
        local item = player.getInventoryItem and player.getInventoryItem(itemName) or nil
        return item and (item.count or item.amount or 0) or 0
    end

    if inventoryName == 'framework' and (frameworkName == 'qbcore' or frameworkName == 'qbox') and player then
        if player.PlayerData and type(player.PlayerData.items) == 'table' then
            local total = 0
            for _, item in pairs(player.PlayerData.items) do
                if item.name == itemName then total = total + (tonumber(item.amount or item.count) or 0) end
            end
            return total
        end
        local item = player.Functions and player.Functions.GetItemByName and player.Functions.GetItemByName(itemName)
        return item and (item.amount or item.count or 0) or 0
    end

    if qbInventory(inventoryName) then
        -- Indexing a missing export does NOT fail — only the call does, and old
        -- qb-inventory builds have no GetItemCount export. pcall + core fallback.
        local ok, total = pcall(function()
            return exports[inventoryName]:GetItemCount(source, itemName)
        end)
        if ok then return tonumber(total) or 0 end

        if player and player.Functions and player.Functions.GetItemByName then
            local item = player.Functions.GetItemByName(itemName)
            return item and (item.amount or item.count or 0) or 0
        end

        return 0
    end

    if inventoryName ~= 'standalone' then return 0 end
    return (playerData.inventory or {})[itemName] or 0
end

function NN.Inventory.removeItem(source, itemName, count, metadata, opts)
    local inventoryName, frameworkName, player, playerData, resource = resolve(source, opts)

    -- metadata DEVE restare nil quando il chiamante non lo specifica: ox filtra
    -- gli slot per corrispondenza esatta, e un {} matcha solo gli item SENZA
    -- metadata (le canne rollate e le cime raccolte ne hanno sempre).
    if inventoryName == 'ox_inventory' then
        return exports.ox_inventory:RemoveItem(source, itemName, count, metadata) == true
    end

    if qbInventory(inventoryName) then
        -- qb-inventory's RemoveItem takes (identifier, item, amount, slot, reason):
        -- no metadata filter, and `reason` must be a string (it may get logged via
        -- concatenation). Guarded for old builds without the export.
        local ok, result = pcall(function()
            return exports[inventoryName]:RemoveItem(source, itemName, count, opts and opts.slot or false, ('%s'):format(resource or NN.resource))
        end)
        if ok then return result == true end
        if player and player.Functions and player.Functions.RemoveItem then
            return player.Functions.RemoveItem(itemName, count, opts and opts.slot or false) and true or false
        end
        return false
    end

    if inventoryName == 'framework' and frameworkName == 'esx' and player then
        player.removeInventoryItem(itemName, count)
        return true
    end

    if inventoryName == 'framework' and (frameworkName == 'qbcore' or frameworkName == 'qbox') and player and player.Functions and player.Functions.RemoveItem then
        return player.Functions.RemoveItem(itemName, count, opts and opts.slot or false, resource)
    end

    if inventoryName ~= 'standalone' then return false end
    playerData.inventory = playerData.inventory or {}
    local current = playerData.inventory[itemName] or 0
    if current < count then
        return false
    end

    playerData.inventory[itemName] = current - count
    if playerData.inventory[itemName] <= 0 then
        playerData.inventory[itemName] = nil
    end

    return true
end

function NN.Inventory.canCarry(source, itemName, count, metadata, opts)
    local inventoryName, frameworkName, player = resolve(source, opts)

    if inventoryName == 'ox_inventory' then
        return exports.ox_inventory:CanCarryItem(source, itemName, count, metadata or {})
    end

    if qbInventory(inventoryName) then
        local ok, result = pcall(function()
            return exports[inventoryName]:CanAddItem(source, itemName, count)
        end)
        if ok then return result end
        return true -- old build without the export: no reliable check, allow
    end

    if inventoryName == 'framework' and frameworkName == 'esx' and player and player.canCarryItem then
        return player.canCarryItem(itemName, count)
    end

    return true
end

-- ── stash ────────────────────────────────────────────────────────────────────

local STASH_ADAPTERS = {
    { resource = 'ox_inventory', kind = 'ox' },
    { resource = 'qb-inventory', kind = 'qb' },
    { resource = 'ps-inventory', kind = 'qb' },
    { resource = 'lj-inventory', kind = 'qb' },
}

function NN.Inventory.stashAdapter()
    local selected = NN.Inventory.get()
    for _, adapter in ipairs(STASH_ADAPTERS) do
        if selected == adapter.resource and GetResourceState(adapter.resource) == 'started' then
            return adapter.kind, adapter.resource
        end
    end
    return nil
end

function NN.Inventory.stashSupported()
    return NN.Inventory.stashAdapter() ~= nil
end

function NN.Inventory.registerStash(id, label, slots, maxWeight, owner, coords)
    local kind, resource = NN.Inventory.stashAdapter()
    if not kind then return false end

    if kind == 'ox' then
        local ok, result = pcall(function()
            return exports.ox_inventory:RegisterStash(id, label, slots, maxWeight, owner, nil, coords)
        end)
        return ok and result ~= false
    end

    local ok, result = pcall(function()
        return exports[resource]:CreateInventory(id, { label = label, maxweight = maxWeight, slots = slots })
    end)
    return ok and result ~= false
end

function NN.Inventory.stashAddItem(id, itemName, count, metadata)
    local kind, resource = NN.Inventory.stashAdapter()
    if not kind then return false end

    if kind == 'ox' then
        local ok, result = pcall(function()
            return exports.ox_inventory:AddItem(id, itemName, count, metadata or {})
        end)
        return ok and result == true
    end

    local ok, result = pcall(function()
        return exports[resource]:AddItem(id, itemName, count, false, metadata or {}, NN.resource)
    end)
    return ok and result == true
end

function NN.Inventory.stashRemoveItem(id, itemName, count, metadata, slot)
    local kind, resource = NN.Inventory.stashAdapter()
    if not kind then return false end

    if kind == 'ox' then
        local ok, result = pcall(function()
            return exports.ox_inventory:RemoveItem(id, itemName, count, metadata, slot)
        end)
        return ok and result == true
    end

    local ok, result = pcall(function()
        return exports[resource]:RemoveItem(id, itemName, count, slot, ('%s'):format(NN.resource or 'nonick_lib'))
    end)
    return ok and result == true
end

function NN.Inventory.stashItems(id)
    local kind, resource = NN.Inventory.stashAdapter()
    local out = {}
    if not kind then return nil end

    if kind == 'ox' then
        local ok, items = pcall(function() return exports.ox_inventory:GetInventoryItems(id) end)
        if ok and type(items) == 'table' then
            for _, item in pairs(items) do
                if type(item) == 'table' and item.name and (tonumber(item.count) or 0) > 0 then
                    out[#out + 1] = { item = item.name, count = item.count, metadata = item.metadata, slot = item.slot }
                end
            end
        end
        return ok and type(items) == 'table' and out or nil
    end

    local ok, inventory = pcall(function() return exports[resource]:GetInventory(id) end)
    local items = ok and type(inventory) == 'table' and (inventory.items or inventory) or nil

    if type(items) == 'table' then
        for _, item in pairs(items) do
            local count = type(item) == 'table' and (tonumber(item.amount) or tonumber(item.count) or 0) or 0
            if type(item) == 'table' and item.name and count > 0 then
                out[#out + 1] = { item = item.name, count = count, metadata = item.info or item.metadata, slot = item.slot }
            end
        end
    end

    return type(items) == 'table' and out or nil
end

-- Preserve metadata and slot identity while consuming crafting ingredients.
-- On failure the caller restores the returned partial receipt.
function NN.Inventory.takeItems(source, itemName, count, opts)
    local inventoryName, frameworkName, player = resolve(source, opts)
    local slots
    if inventoryName == 'ox_inventory' then
        local ok, result = pcall(function() return exports.ox_inventory:Search(source, 'slots', itemName) end)
        if not ok or type(result) ~= 'table' then return { ok = false, items = {} } end
        slots = result
    elseif (frameworkName == 'qbcore' or frameworkName == 'qbox') and player and player.PlayerData then
        slots = player.PlayerData.items or {}
    end
    local receipt, remaining = {}, count
    if slots then
        -- Snapshot slots: inventory exports may mutate the framework table.
        local selected = {}
        for _, slot in pairs(slots) do
            if slot.name == itemName then
                selected[#selected + 1] = { slot = slot.slot, count = tonumber(slot.count or slot.amount) or 0,
                    metadata = slot.metadata or slot.info }
            end
        end
        table.sort(selected, function(a, b) return (tonumber(a.slot) or 0) < (tonumber(b.slot) or 0) end)
        for _, slot in ipairs(selected) do
            local amount = math.min(remaining, slot.count)
            if amount > 0 then
                local ok
                if inventoryName == 'ox_inventory' then
                    ok = exports.ox_inventory:RemoveItem(source, itemName, amount, slot.metadata, slot.slot)
                else
                    local slotOpts = {}
                    for key, value in pairs(opts or {}) do slotOpts[key] = value end
                    slotOpts.slot = slot.slot
                    ok = NN.Inventory.removeItem(source, itemName, amount, slot.metadata, slotOpts)
                end
                if not ok then return { ok = false, items = receipt } end
                receipt[#receipt + 1] = { item = itemName, count = amount, metadata = slot.metadata }
                remaining = remaining - amount
                if remaining == 0 then break end
            end
        end
        return { ok = remaining == 0, items = receipt }
    end
    if NN.Inventory.getCount(source, itemName, opts) < count
        or not NN.Inventory.removeItem(source, itemName, count, nil, opts) then
        return { ok = false, items = {} }
    end
    return { ok = true, items = { { item = itemName, count = count } } }
end

function NN.Money.add(source, moneyConfig, amount, reason, opts)
    local _, frameworkName, player, playerData = resolve(source, opts)
    moneyConfig = moneyConfig or {}
    amount = tonumber(amount) or 0
    if amount < 0 or amount ~= amount or amount == math.huge then return false end
    if frameworkName == 'esx' and player then
        player.addAccountMoney(moneyConfig.esxAccount or 'money', amount, reason)
        return true
    elseif frameworkName == 'qbcore' and player then
        return player.Functions.AddMoney(moneyConfig.qbType or 'cash', amount, reason) == true
    elseif frameworkName == 'qbox' then
        return exports.qbx_core:AddMoney(source, moneyConfig.qboxType or 'cash', amount, reason) == true
    elseif frameworkName ~= 'standalone' then
        return false
    end
    playerData.money = (playerData.money or 0) + amount
    return true
end

function NN.Inventory.openStash(source, id, label, slots, maxWeight)
    local kind, resource = NN.Inventory.stashAdapter()
    if not kind then return false end

    if kind == 'ox' then
        TriggerClientEvent('nn_lib:openStash', source, id)
        return true
    end

    local ok, result = pcall(function()
        return exports[resource]:OpenInventory(source, id, { label = label, maxweight = maxWeight, slots = slots })
    end)
    return ok and result ~= false
end

-- ── money ────────────────────────────────────────────────────────────────────
-- moneyConfig: { esxAccount = 'money', qbType = 'cash', qboxType = 'cash' }

function NN.Money.get(source, moneyConfig, opts)
    local _, frameworkName, player, playerData = resolve(source, opts)
    moneyConfig = moneyConfig or {}

    if frameworkName == 'esx' and player then
        local account = player.getAccount(moneyConfig.esxAccount or 'money')
        return account and account.money or 0
    end

    if frameworkName == 'qbcore' and player then
        return player.PlayerData.money[moneyConfig.qbType or 'cash'] or 0
    end

    if frameworkName == 'qbox' then
        return exports.qbx_core:GetMoney(source, moneyConfig.qboxType or 'cash') or 0
    end

    return playerData.money or 0
end

function NN.Money.remove(source, moneyConfig, amount, reason, opts)
    local _, frameworkName, player, playerData = resolve(source, opts)
    moneyConfig = moneyConfig or {}
    if type(amount) ~= 'number' or amount < 0 or amount ~= amount or amount == math.huge then return false end

    if frameworkName == 'esx' and player then
        player.removeAccountMoney(moneyConfig.esxAccount or 'money', amount, reason)
        return true
    end

    if frameworkName == 'qbcore' and player then
        return player.Functions.RemoveMoney(moneyConfig.qbType or 'cash', amount, reason)
    end

    if frameworkName == 'qbox' then
        return exports.qbx_core:RemoveMoney(source, moneyConfig.qboxType or 'cash', amount, reason)
    end

    if frameworkName ~= 'standalone' or (playerData.money or 0) < amount then return false end
    playerData.money = (playerData.money or 0) - amount
    return true
end
