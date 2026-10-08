-- nonick_lib · init.lua
-- Entry point, included by CONSUMER resources via:
--   shared_scripts { '@nonick_lib/init.lua', ... }   (must come FIRST)
-- Loads the side-appropriate modules INTO THE CONSUMER'S Lua state, so
-- everything the modules register (NUI callbacks, DUI surfaces, event
-- handlers) belongs to the consuming resource — exactly like ox_lib's init.
-- Exposes the global `NN` table.

if NN and NN.__loaded then return end

NN = NN or {}
NN.__lib = 'nonick_lib'
NN.__version = '1.0.1'
NN.resource = GetCurrentResourceName()

local isServer = IsDuplicityVersion()

if GetResourceState(NN.__lib) ~= 'started' and GetResourceState(NN.__lib) ~= 'starting' then
    error(('[%s] the "%s" resource is not started. Add `ensure %s` BEFORE `ensure %s` in your server.cfg.')
        :format(NN.__lib, NN.__lib, NN.__lib, NN.resource))
end

local function include(path)
    local chunk = LoadResourceFile(NN.__lib, path)
    if not chunk then
        error(('[%s] missing file "%s" — is %s up to date (and the file listed in its fxmanifest files{})?')
            :format(NN.__lib, path, NN.__lib))
    end

    local fn, err = load(chunk, ('@@%s/%s'):format(NN.__lib, path))
    if not fn then
        error(('[%s] parse error in %s: %s'):format(NN.__lib, path, tostring(err)))
    end

    fn()
end

include('shared/utils.lua')

if isServer then
    include('server/version.lua')
    include('server/framework.lua')
    include('server/inventory.lua')
else
    include('client/dui.lua')
    include('client/tablet.lua')
    include('client/target.lua')
    include('client/notify.lua')
    include('client/inventory.lua')
end

NN.__loaded = true
