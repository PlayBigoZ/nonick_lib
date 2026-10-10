NN.Inventory = NN.Inventory or {}

function NN.Inventory.openStashLocal(id)
    if GetResourceState('ox_inventory') == 'started' then
        exports.ox_inventory:openInventory('stash', id)
        return true
    end

    return false
end

RegisterNetEvent('nn_lib:openStash', function(id)
    if type(id) == 'string' and id ~= '' then
        NN.Inventory.openStashLocal(id)
    end
end)
