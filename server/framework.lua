-- nonick_lib · server/framework.lua
-- Framework bridge: detection, player identity/job, staff-group permission
-- checks (groups + ACE) and usable-item registration for ESX / QBCore / QBox,
-- with a 'standalone' fallback. Detection is cached on NN.Framework.name/.object.

NN.Framework = NN.Framework or {}

local function trim(v) return NN.Utils.trim(v) end

-- ── detection ────────────────────────────────────────────────────────────────

-- preferred: 'auto' (default) or an explicit 'esx'|'qbcore'|'qbox'|'standalone'.
function NN.Framework.detect(preferred)
    local name = 'standalone'
    local object = nil

    preferred = tostring(preferred or 'auto'):lower()
    NN.Framework.__preferred = preferred
    if preferred ~= 'auto' and preferred ~= '' then
        name = preferred
    elseif GetResourceState('es_extended') == 'started' then
        name = 'esx'
    elseif GetResourceState('qbx_core') == 'started' then
        name = 'qbox'
    elseif GetResourceState('qb-core') == 'started' then
        name = 'qbcore'
    end

    -- Guard the export calls: if the framework resource isn't fully started yet,
    -- don't let an exception abort detection — degrade gracefully instead.
    if name == 'esx' then
        local ok, obj = pcall(function() return exports['es_extended']:getSharedObject() end)
        object = ok and obj or nil
    elseif name == 'qbcore' then
        local ok, obj = pcall(function() return exports['qb-core']:GetCoreObject() end)
        object = ok and obj or nil
    end

    NN.Framework.name = name
    NN.Framework.object = object
    return name, object
end

-- Cached accessor (detects with 'auto' on first use).
function NN.Framework.get()
    if not NN.Framework.name then
        NN.Framework.detect(NN.Framework.__preferred or 'auto')
    end

    -- Heal a POISONED early detection: with 'auto', detecting before the
    -- framework resource finished starting yields 'standalone' — and standalone
    -- typically auto-grants staff permissions (allowedGroups.standalone), so a
    -- stale cache silently makes EVERY player an admin. If a framework is up
    -- NOW, re-detect and drop the stale result.
    if NN.Framework.name == 'standalone' and (NN.Framework.__preferred or 'auto') == 'auto' then
        if GetResourceState('es_extended') == 'started'
            or GetResourceState('qbx_core') == 'started'
            or GetResourceState('qb-core') == 'started' then
            NN.Framework.detect('auto')
        end
    end

    return NN.Framework.name, NN.Framework.object
end

-- ── player identity ──────────────────────────────────────────────────────────

function NN.Framework.getPlayer(source)
    local name, object = NN.Framework.get()

    if name == 'esx' then
        return object and object.GetPlayerFromId(source) or nil
    end

    if name == 'qbcore' then
        return object and object.Functions.GetPlayer(source) or nil
    end

    if name == 'qbox' then
        return exports.qbx_core:GetPlayer(source)
    end

    return nil
end

function NN.Framework.getIdentifier(source, player)
    local name = NN.Framework.get()
    player = player or NN.Framework.getPlayer(source)

    if name == 'esx' and player and player.identifier then
        return player.identifier
    end

    if (name == 'qbcore' or name == 'qbox') and player and player.PlayerData and player.PlayerData.citizenid then
        return player.PlayerData.citizenid
    end

    -- A framework character must be loaded before assigning persistent state.
    if name ~= 'standalone' then return nil end

    for _, identifier in ipairs(GetPlayerIdentifiers(source)) do
        if identifier:find('license:') == 1 then
            return identifier
        end
    end

    return nil
end

function NN.Framework.getPlayerName(source, player)
    local name = NN.Framework.get()
    player = player or NN.Framework.getPlayer(source)

    if name == 'esx' and player then
        return player.getName and player.getName() or GetPlayerName(source)
    end

    if (name == 'qbcore' or name == 'qbox') and player and player.PlayerData then
        local charInfo = player.PlayerData.charinfo or {}
        local fullName = trim((charInfo.firstname or '') .. ' ' .. (charInfo.lastname or ''))
        return fullName ~= '' and fullName or GetPlayerName(source)
    end

    return GetPlayerName(source) or ('Player ' .. source)
end

function NN.Framework.getJob(source, player)
    local name = NN.Framework.get()
    player = player or NN.Framework.getPlayer(source)

    if name == 'esx' and player and player.job then
        return { name = player.job.name, grade = tonumber(player.job.grade) or 0 }
    end

    if (name == 'qbcore' or name == 'qbox') and player and player.PlayerData and player.PlayerData.job then
        local grade = player.PlayerData.job.grade
        local level = type(grade) == 'table' and (grade.level or grade.grade or 0) or grade
        return { name = player.PlayerData.job.name, grade = tonumber(level) or 0 }
    end

    return { name = 'standalone', grade = 999 }
end

-- ── staff groups / permissions ───────────────────────────────────────────────

local function normalizeStaffGroup(value)
    if type(value) ~= 'string' then return nil end
    value = value:lower():gsub('^%s+', ''):gsub('%s+$', '')
    if value == '' then return nil end
    return value
end

local function isStaffGroupAllowed(groupName, allowedGroups)
    local normalized = normalizeStaffGroup(groupName)
    if not normalized then return false end

    for allowedName, allowed in pairs(allowedGroups or {}) do
        if allowed == true and normalizeStaffGroup(allowedName) == normalized then
            return true
        end
    end

    return false
end

local function addStaffGroup(groups, value)
    local normalized = normalizeStaffGroup(value)
    if normalized then groups[normalized] = true end
end

local function hasAceAccess(source, aceChecks)
    for _, ace in ipairs(aceChecks) do
        if IsPlayerAceAllowed(source, ace) then
            return true
        end
    end
    return false
end

NN.Framework.STAFF_ACES = {
    'group.admin', 'group.superadmin', 'group.owner', 'group.mod', 'group.staff',
}

NN.Framework.ADMIN_ACES = {
    'group.admin', 'group.superadmin', 'group.owner',
}

local function collectEsxStaffGroups(source, player, frameworkObject, allowedGroups)
    local groups = {}

    if not player and frameworkObject and frameworkObject.GetPlayerFromId then
        player = frameworkObject.GetPlayerFromId(source)
    end

    if player then
        if type(player.getGroup) == 'function' then
            local ok, group = pcall(function() return player.getGroup() end)
            if ok then addStaffGroup(groups, group) end
        end

        addStaffGroup(groups, player.group)

        if type(player.get) == 'function' then
            local ok, group = pcall(function() return player.get('group') end)
            if ok then addStaffGroup(groups, group) end
        end

        if type(player.variables) == 'table' then
            addStaffGroup(groups, player.variables.group)
        end

        if type(player.hasGroup) == 'function' and type(allowedGroups) == 'table' then
            for groupName, allowed in pairs(allowedGroups) do
                if allowed == true then
                    local ok, hasGroup = pcall(function() return player.hasGroup(groupName) end)
                    if ok and hasGroup then addStaffGroup(groups, groupName) end
                end
            end
        end
    end

    -- Player state bags are client writable. Never use them for permissions.

    if frameworkObject then
        if type(frameworkObject.IsPlayerAdmin) == 'function' then
            local ok, isAdmin = pcall(frameworkObject.IsPlayerAdmin, source)
            if ok and isAdmin then addStaffGroup(groups, 'admin') end
        end

        if type(frameworkObject.DoesPlayerHaveGroup) == 'function' and type(allowedGroups) == 'table' then
            for groupName, allowed in pairs(allowedGroups) do
                if allowed == true then
                    local ok, hasGroup = pcall(frameworkObject.DoesPlayerHaveGroup, source, groupName)
                    if ok and hasGroup then addStaffGroup(groups, groupName) end
                end
            end
        end
    end

    local ok, isAdmin = pcall(function() return exports['es_extended']:IsPlayerAdmin(source) end)
    if ok and isAdmin then addStaffGroup(groups, 'admin') end

    return groups
end

local function collectQbcoreStaffGroups(source, player, allowedGroups)
    local groups = {}

    if not player then
        local ok, qbPlayer = pcall(function()
            return exports['qb-core']:GetCoreObject().Functions.GetPlayer(source)
        end)
        if ok then player = qbPlayer end
    end

    if player and player.PlayerData then
        addStaffGroup(groups, player.PlayerData.group)
        addStaffGroup(groups, player.PlayerData.permission)

        local metadata = player.PlayerData.metadata
        if type(metadata) == 'table' then
            addStaffGroup(groups, metadata.group)
            addStaffGroup(groups, metadata.permission)
        end
    end

    local ok, qbCore = pcall(function() return exports['qb-core']:GetCoreObject() end)
    if ok and qbCore and qbCore.Functions then
        if type(qbCore.Functions.GetPermission) == 'function' then
            local permOk, permission = pcall(qbCore.Functions.GetPermission, source)
            if permOk then addStaffGroup(groups, permission) end
        end

        for _, permission in ipairs({ 'god', 'admin', 'mod', 'staff' }) do
            if type(qbCore.Functions.HasPermission) == 'function' then
                local permOk, allowed = pcall(qbCore.Functions.HasPermission, source, permission)
                if permOk and allowed then addStaffGroup(groups, permission) end
            end
        end
    end

    return groups
end

local function collectQboxStaffGroups(source, player)
    local groups = {}

    if not player then
        local ok, qboxPlayer = pcall(function() return exports.qbx_core:GetPlayer(source) end)
        if ok then player = qboxPlayer end
    end

    if player and player.PlayerData then
        addStaffGroup(groups, player.PlayerData.group)
        addStaffGroup(groups, player.PlayerData.permission)

        local metadata = player.PlayerData.metadata
        if type(metadata) == 'table' then
            addStaffGroup(groups, metadata.group)
            addStaffGroup(groups, metadata.permission)
        end
    end

    for _, permission in ipairs({ 'god', 'admin', 'mod', 'staff' }) do
        local ok, allowed = pcall(function() return exports.qbx_core:HasPermission(source, permission) end)
        if ok and allowed then addStaffGroup(groups, permission) end
    end

    local groupOk, hasGroup = pcall(function()
        return exports.qbx_core:HasGroup(source, 'admin') or exports.qbx_core:HasGroup(source, 'god')
    end)
    if groupOk and hasGroup then addStaffGroup(groups, 'admin') end

    return groups
end

local function collectStaffGroups(source, allowedGroups, player)
    local name, object = NN.Framework.get()

    if name == 'esx' then
        return collectEsxStaffGroups(source, player, object, allowedGroups)
    end

    if name == 'qbcore' then
        return collectQbcoreStaffGroups(source, player, allowedGroups)
    end

    if name == 'qbox' then
        return collectQboxStaffGroups(source, player)
    end

    return {}
end

-- First staff group the player holds (for diagnostics/UI). 'user' when none.
function NN.Framework.getStaffGroup(source, allowedGroups, player)
    local name = NN.Framework.get()

    if name == 'standalone' then
        return 'standalone'
    end

    local groups = collectStaffGroups(source, allowedGroups, player)
    for groupName in pairs(groups) do
        return groupName
    end

    return 'user'
end

-- Permission gate: console (source 0) always passes; then ACE aces (plus any
-- `extraAces`), then framework staff groups vs `allowedGroups` ({ name=true }).
-- tier: 'staff' (default, broader ACE list) or 'admin' (stricter ACE list).
function NN.Framework.isAllowed(source, allowedGroups, tier, player, extraAces)
    if source == 0 then
        return true
    end

    local aces = (tier == 'admin') and NN.Framework.ADMIN_ACES or NN.Framework.STAFF_ACES
    if hasAceAccess(source, aces) then
        return true
    end

    if type(extraAces) == 'table' and hasAceAccess(source, extraAces) then
        return true
    end

    local name = NN.Framework.get()
    if name == 'esx' or name == 'qbcore' or name == 'qbox' then
        local groups = collectStaffGroups(source, allowedGroups, player)
        for groupName in pairs(groups) do
            if isStaffGroupAllowed(groupName, allowedGroups) then
                return true
            end
        end
        return false
    end

    -- standalone (or unknown): allow when the framework name itself is listed.
    return (allowedGroups or {})[name] == true or (allowedGroups or {}).standalone == true
end

-- ── usable items ─────────────────────────────────────────────────────────────

-- Register `itemName` as a USABLE inventory item; callback(source) runs when a
-- player uses it. Returns true when a framework accepted the registration.
function NN.Framework.registerUsableItem(itemName, callback)
    local name, object = NN.Framework.get()

    if name == 'esx' and object and object.RegisterUsableItem then
        object.RegisterUsableItem(itemName, function(source)
            callback(source)
        end)
        return true
    end

    if name == 'qbcore' and object and object.Functions and object.Functions.CreateUseableItem then
        object.Functions.CreateUseableItem(itemName, function(source)
            callback(source)
        end)
        return true
    end

    if name == 'qbox' then
        local ok = pcall(function()
            exports.qbx_core:CreateUseableItem(itemName, function(source)
                callback(source)
            end)
        end)
        return ok
    end

    return false
end
