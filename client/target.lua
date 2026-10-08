-- nonick_lib · client/target.lua
-- Unified third-eye target adapter for ox_target / qb-target / qtarget.
--
-- Options use ONE schema and are translated per system:
--   {
--     name = 'unique_id',            -- optional (auto-generated for ox_target)
--     label = 'Do the thing',
--     icon = 'fa-solid fa-hand',     -- optional
--     canInteract = function() -> bool,   -- optional; distance handled here
--     onSelect = function() end,
--   }
--
--   NN.Target.addLocalEntity(entity, options, distance)
--   NN.Target.removeLocalEntity(entity)

NN.Target = NN.Target or {}

local seq = 0

-- Detect (or force) the target system. preferred: 'auto'|'ox_target'|'qb-target'|'qtarget'|'none'
function NN.Target.system(preferred)
    preferred = tostring(preferred or 'auto'):lower()
    if preferred ~= 'auto' then
        return preferred
    end

    if GetResourceState('ox_target') == 'started' then
        return 'ox_target'
    end

    if GetResourceState('qb-target') == 'started' then
        return 'qb-target'
    end

    if GetResourceState('qtarget') == 'started' then
        return 'qtarget'
    end

    return 'none'
end

function NN.Target.addLocalEntity(entity, options, distance, preferredSystem)
    local system = NN.Target.system(preferredSystem)
    distance = distance or 1.0

    if system == 'ox_target' then
        local converted = {}
        for index, opt in ipairs(options) do
            seq = seq + 1
            local canInteract = opt.canInteract
            converted[index] = {
                name = opt.name or ('nn_target_%d'):format(seq),
                label = opt.label,
                icon = opt.icon,
                distance = distance,
                bones = opt.bones,
                -- ox_target passes (entity, distance, ...); enforce the distance
                -- here so option callbacks stay system-agnostic.
                canInteract = canInteract and function(_entity, dist)
                    if dist and dist > distance then return false end
                    return canInteract()
                end or nil,
                onSelect = opt.onSelect,
            }
        end
        exports.ox_target:addLocalEntity(entity, converted)
        return system
    end

    if system == 'qb-target' or system == 'qtarget' then
        local converted = {}
        for index, opt in ipairs(options) do
            converted[index] = {
                label = opt.label,
                icon = opt.icon,
                canInteract = opt.canInteract,
                action = opt.onSelect,
            }
        end
        exports[system]:AddTargetEntity(entity, {
            options = converted,
            distance = distance,
        })
        return system
    end

    return 'none'
end

function NN.Target.removeLocalEntity(entity, preferredSystem)
    if not entity then return end

    local system = NN.Target.system(preferredSystem)

    if system == 'ox_target' then
        exports.ox_target:removeLocalEntity(entity)
    elseif system == 'qb-target' or system == 'qtarget' then
        exports[system]:RemoveTargetEntity(entity)
    end
end
