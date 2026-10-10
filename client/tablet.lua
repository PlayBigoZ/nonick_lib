NN.Tablet = NN.Tablet or {}

local num = NN.Utils.num
local registeredCallbacks = {}

local function registerCallbackOnce(name, handler)
    if registeredCallbacks[name] then return end
    registeredCallbacks[name] = true
    RegisterNUICallback(name, handler)
end

function NN.Tablet.new(opts)
    opts = opts or {}
    assert(type(opts.config) == 'function', 'NN.Tablet.new: opts.config (function -> table) is required')

    local cfg = opts.config
    local callbacks = opts.callbacks or {}
    local cbOpenAck = callbacks.openAck or 'tabletOpenAck'
    local cbKbStart = callbacks.kbStart or 'tabletKbStart'
    local cbKbUpdate = callbacks.kbUpdate or 'tabletKbUpdate'
    local cbKbEnd = callbacks.kbEnd or 'tabletKbEnd'

    local self = {}

    local surface = nil
    local tabletProp = nil
    local tabletCam = nil
    local tabletActive = false
    local textureRebound = false
    local tabletAnim = nil
    local keyboardActive = false
    local pushSeq = 0
    local burstAcked = false
    local kbEditing = false
    local kbSeq = 0
    local kbSession = nil
    local stopKeyboard

    local function c() return cfg() or {} end

    local function resolveUrl()
        if type(opts.url) == 'function' then return opts.url() end
        if type(opts.url) == 'string' then return opts.url end

        local flip = (c().flipUi ~= false) and '&flip=1' or ''
        return ('nui://%s/web/dist/index.html?dui=1%s'):format(NN.resource, flip)
    end

    local function userNotify(msg)
        if opts.notify then opts.notify(msg) end
    end

    function self:isEnabled()
        return c().enabled == true
    end

    function self:isActive()
        return tabletActive == true
    end

    function self:getSurface()
        return surface
    end

    function self:send(action, payload)
        if surface then surface:send(action, payload) end
    end

    function self:pushStateBurst()
        pushSeq = pushSeq + 1
        local mySeq = pushSeq
        burstAcked = false
        CreateThread(function()
            local n = 0
            while tabletActive and mySeq == pushSeq and n < 20 and not burstAcked do
                if surface and (not opts.shouldPush or opts.shouldPush()) then
                    local state = opts.getState and opts.getState() or nil
                    if state then self:send('open', state) end
                end
                n = n + 1
                Wait(200)
            end
        end)
    end

    function self:ensure()
        if surface then return surface:isReady() end

        local conf = c()
        local w, h
        if conf.duiFullRes == false then
            w, h = conf.duiWidth or 1280, conf.duiHeight or 800
        else
            local r = conf.screenRect or {}
            w, h = NN.Dui.screenPixels(r.w or 0.63, r.h or 0.79, conf.duiSupersample or 2.0, 4096)
            if not w or w < 320 or h < 200 then
                w, h = conf.duiWidth or 1280, conf.duiHeight or 800
            end
        end

        surface = NN.Dui.create({
            url = resolveUrl(),
            width = w,
            height = h,
            runtimeTxd = opts.runtimeTxd,
            runtimeTxn = opts.runtimeTxn,
            replace = {
                txd = conf.txd or conf.model or 'prop_cs_tablet',
                texture = conf.targetTexture or 'tablet_screen',
            },
        })

        return surface:isReady()
    end

    local function spawnTabletProp()
        local conf = c()
        local ped = PlayerPedId()
        local modelName = conf.model or 'prop_cs_tablet'
        local model = joaat(modelName)

        local strings = opts.strings or {}

        if (IsModelInCdimage and not IsModelInCdimage(model)) or (IsModelValid and not IsModelValid(model)) then
            print(('[%s] tablet prop "%s" (hash %s) is NOT registered — no stream/ytyp provides this archetype.'):format(NN.resource, tostring(modelName), tostring(model)))
            userNotify(strings.modelMissing and strings.modelMissing(modelName)
                or ('Tablet: model "%s" not found (stream/ytyp).'):format(tostring(modelName)))
            return
        end

        RequestModel(model)
        local timeout = GetGameTimer() + 4000
        while not HasModelLoaded(model) and GetGameTimer() < timeout do Wait(10) end
        if not HasModelLoaded(model) then
            print(('[%s] tablet prop "%s" did not load within 4s (RequestModel timeout).'):format(NN.resource, tostring(modelName)))
            userNotify(strings.modelTimeout and strings.modelTimeout(modelName)
                or ('Tablet: timeout loading model "%s".'):format(tostring(modelName)))
            return
        end

        local coords = GetEntityCoords(ped)
        tabletProp = CreateObject(model, coords.x, coords.y, coords.z, true, true, false)
        AttachEntityToEntity(
            tabletProp, ped, GetPedBoneIndex(ped, conf.bone or 28422),
            num(conf.pos, 'x', 0.0), num(conf.pos, 'y', 0.0), num(conf.pos, 'z', 0.0),
            num(conf.rot, 'x', 0.0), num(conf.rot, 'y', 0.0), num(conf.rot, 'z', 0.0),
            true, true, false, true, 1, true
        )
        SetModelAsNoLongerNeeded(model)

        if not textureRebound and surface then
            surface:rebindReplace()
            textureRebound = true
        end

        local anim = conf.anim or {}
        local baseDict = anim.baseDict or 'anim@heists@heist_corona@team_idles@male_a'
        local baseClip = anim.baseClip or 'idle'
        local dict = anim.dict or 'amb@code_human_in_bus_passenger_idles@female@tablet@idle_a'
        local clip = anim.clip or 'idle_a'
        local flag = anim.flag or 49

        RequestAnimDict(baseDict)
        RequestAnimDict(dict)
        local animTo = GetGameTimer() + 2000
        while (not HasAnimDictLoaded(baseDict) or not HasAnimDictLoaded(dict)) and GetGameTimer() < animTo do Wait(10) end

        if HasAnimDictLoaded(baseDict) then
            TaskPlayAnim(ped, baseDict, baseClip, 4.0, -4.0, -1, 1, 0.0, false, false, false)
            local st = GetGameTimer() + 500
            while not IsEntityPlayingAnim(ped, baseDict, baseClip, 3) and GetGameTimer() < st do Wait(0) end
            SetEntityAnimCurrentTime(ped, baseDict, baseClip, 0.0)
            SetEntityAnimSpeed(ped, baseDict, baseClip, 0.0)
        end

        if HasAnimDictLoaded(dict) then
            local phase = num(conf, 'animPhase', 0.0)
            TaskPlayAnim(ped, dict, clip, 4.0, -4.0, -1, flag, 0.0, false, false, false)

            local startTo = GetGameTimer() + 500
            while not IsEntityPlayingAnim(ped, dict, clip, 3) and GetGameTimer() < startTo do Wait(0) end
            SetEntityAnimCurrentTime(ped, dict, clip, phase)
            SetEntityAnimSpeed(ped, dict, clip, 0.0)
            tabletAnim = { dict = dict, clip = clip, phase = phase, flag = flag, baseDict = baseDict, baseClip = baseClip }
        end
    end

    local function updateTabletCam()
        if not (tabletCam and tabletProp and DoesEntityExist(tabletProp)) then return end
        local cam = c().camera or {}
        local o = cam.offset or {}
        local p = cam.point or {}
        local camPos = GetOffsetFromEntityInWorldCoords(tabletProp,
            num(o, 'x', 0.0), num(o, 'y', -0.28), num(o, 'z', 0.0))
        local lookAt = GetOffsetFromEntityInWorldCoords(tabletProp,
            num(p, 'x', 0.0), num(p, 'y', 0.0), num(p, 'z', 0.0))
        SetCamCoord(tabletCam, camPos.x, camPos.y, camPos.z)
        PointCamAtCoord(tabletCam, lookAt.x, lookAt.y, lookAt.z)
        SetCamFov(tabletCam, cam.fov or 38.0)
    end

    local function startCamera()
        local cam = c().camera or {}
        if not (tabletProp and DoesEntityExist(tabletProp)) then return end

        tabletCam = CreateCam('DEFAULT_SCRIPTED_CAMERA', true)
        updateTabletCam()
        SetCamActive(tabletCam, true)
        RenderScriptCams(true, true, cam.blendMs or 600, true, true)

        CreateThread(function()
            local settleUntil = GetGameTimer() + 700
            while tabletActive and GetGameTimer() < settleUntil do
                updateTabletCam()
                Wait(0)
            end
        end)
    end

    local function startInputLoop()
        CreateThread(function()
            while tabletActive do
                Wait(0)

                if tabletAnim then
                    local ped = PlayerPedId()
                    if tabletAnim.baseDict and not IsEntityPlayingAnim(ped, tabletAnim.baseDict, tabletAnim.baseClip, 3) then
                        TaskPlayAnim(ped, tabletAnim.baseDict, tabletAnim.baseClip, 4.0, -4.0, -1, 1, 0.0, false, false, false)
                        SetEntityAnimCurrentTime(ped, tabletAnim.baseDict, tabletAnim.baseClip, 0.0)
                        SetEntityAnimSpeed(ped, tabletAnim.baseDict, tabletAnim.baseClip, 0.0)
                    end
                    if not IsEntityPlayingAnim(ped, tabletAnim.dict, tabletAnim.clip, 3) then
                        TaskPlayAnim(ped, tabletAnim.dict, tabletAnim.clip, 4.0, -4.0, -1, tabletAnim.flag or 49, 0.0, false, false, false)
                        SetEntityAnimCurrentTime(ped, tabletAnim.dict, tabletAnim.clip, tabletAnim.phase)
                        SetEntityAnimSpeed(ped, tabletAnim.dict, tabletAnim.clip, 0.0)
                    end
                end

                if not keyboardActive then
                    if SetMouseCursorActiveThisFrame then SetMouseCursorActiveThisFrame() end

                    DisableAllControlActions(0)

                    local conf = c()
                    local r = conf.screenRect or { x = 0.5, y = 0.5, w = 0.42, h = 0.62 }
                    local cx = GetDisabledControlNormal(0, 239)
                    local cy = GetDisabledControlNormal(0, 240)

                    local minX, maxX = r.x - r.w / 2.0, r.x + r.w / 2.0
                    local minY, maxY = r.y - r.h / 2.0, r.y + r.h / 2.0
                    local clX = math.min(math.max(cx, minX), maxX)
                    local clY = math.min(math.max(cy, minY), maxY)
                    if clX ~= cx or clY ~= cy then
                        SetCursorLocation(clX, clY)
                        cx, cy = clX, clY
                    end

                    local u = (cx - (r.x - r.w / 2.0)) / r.w
                    local v = (cy - (r.y - r.h / 2.0)) / r.h

                    if conf.flipUi ~= false then
                        u = 1.0 - u
                        v = 1.0 - v
                    end

                    if u >= 0.0 and u <= 1.0 and v >= 0.0 and v <= 1.0 and surface then
                        surface:mouseMove(u, v)
                        if IsDisabledControlJustPressed(0, 237) then surface:mouseDown('left') end
                        if IsDisabledControlJustReleased(0, 237) then surface:mouseUp('left') end

                        local wheelUp = IsDisabledControlJustPressed(0, 241) or IsDisabledControlJustPressed(0, 15)
                        local wheelDown = IsDisabledControlJustPressed(0, 242) or IsDisabledControlJustPressed(0, 14)
                        if wheelUp then surface:wheel(150, 0) end
                        if wheelDown then surface:wheel(-150, 0) end
                    end

                    if IsDisabledControlJustPressed(0, 200) or IsDisabledControlJustPressed(0, 177) then
                        if opts.onRequestClose then opts.onRequestClose() end
                    end
                end
            end
        end)
    end

    function self:open()
        if tabletActive then return true end

        SetNuiFocus(false, false)
        SendNUIMessage({ action = 'close' })

        self:ensure()
        spawnTabletProp()
        if not surface or not tabletProp or not DoesEntityExist(tabletProp) then
            if tabletProp and DoesEntityExist(tabletProp) then DeleteEntity(tabletProp) end
            tabletProp = nil
            return false
        end

        if tabletProp and DoesEntityExist(tabletProp) then
            local ped = PlayerPedId()
            FreezeEntityPosition(ped, true)
            SetPedCanHeadIk(ped, false)
            SetPedCanArmIk(ped, false)
            SetPedCanTorsoIk(ped, false)
            SetPedCanLegIk(ped, false)
            SetPedCanPlayAmbientAnims(ped, false)
            SetPedCanPlayAmbientBaseAnims(ped, false)
            SetPedCanPlayGestureAnims(ped, false)
        end

        startCamera()

        tabletActive = true
        startInputLoop()
        self:pushStateBurst()
        return true
    end

    function self:close()
        if not tabletActive then return end
        if stopKeyboard then stopKeyboard(nil, false) end
        tabletActive = false

        if tabletCam then
            RenderScriptCams(false, true, (c().camera and c().camera.blendMs) or 600, true, true)
            DestroyCam(tabletCam, false)
            tabletCam = nil
        end

        if tabletProp and DoesEntityExist(tabletProp) then
            DetachEntity(tabletProp, true, true)
            DeleteEntity(tabletProp)
        end
        tabletProp = nil
        tabletAnim = nil

        local ped = PlayerPedId()
        FreezeEntityPosition(ped, false)
        SetPedCanHeadIk(ped, true)
        SetPedCanArmIk(ped, true)
        SetPedCanTorsoIk(ped, true)
        SetPedCanLegIk(ped, true)
        SetPedCanPlayAmbientAnims(ped, true)
        SetPedCanPlayAmbientBaseAnims(ped, true)
        SetPedCanPlayGestureAnims(ped, true)
        ClearPedTasks(ped)

    end

    function self:dispose()
        self:close()
        if surface then
            surface:destroy()
            surface = nil
        end
        textureRebound = false
    end

    stopKeyboard = function(value, submit)
        if not kbEditing then return end
        kbEditing = false
        kbSeq = kbSeq + 1
        if surface then
            if submit and value ~= nil then
                self:send('kbValue', { value = tostring(value), done = true, session = kbSession })
            else
                self:send('kbValue', { done = true, session = kbSession })
            end
        end
        SendNUIMessage({ action = 'kbCapture', payload = { op = 'stop' } })
        SetNuiFocus(false, false)
        keyboardActive = false
        kbSession = nil
    end

    registerCallbackOnce(callbacks.pointer or 'tabletPointer', function(data, cb)
        data = data or {}
        if not tabletActive or not surface then cb({ok=false}); return end
        local x, y = tonumber(data.x), tonumber(data.y)
        if not x or not y or x ~= x or y ~= y then cb({ok=false}); return end
        local r = c().screenRect or {x=0.5,y=0.5,w=0.42,h=0.62}
        local u, v = (x-r.x+r.w/2)/r.w, (y-r.y+r.h/2)/r.h
        u, v = math.max(0,math.min(1,u)), math.max(0,math.min(1,v))
        if c().flipUi ~= false then u, v = 1-u, 1-v end
        surface:mouseMove(u,v)
        if data.op == 'down' then surface:mouseDown('left')
        elseif data.op == 'up' then surface:mouseUp('left')
        elseif data.op == 'wheel' then surface:wheel(math.max(-600,math.min(600,tonumber(data.delta) or 0)),0) end
        cb({ok=true})
    end)

    registerCallbackOnce(cbOpenAck, function(_, cb)
        burstAcked = true
        if cb then cb({ ok = true }) end
    end)

    registerCallbackOnce(cbKbStart, function(data, cb)
        if not tabletActive then cb({ ok = false }); return end
        data = data or {}
        kbEditing = true
        keyboardActive = true
        kbSeq = kbSeq + 1
        kbSession = data.session
        local mySeq = kbSeq

        if surface then surface:mouseUp('left') end
        SetNuiFocus(true, true)
        SetNuiFocusKeepInput(false)
        SendNUIMessage({ action = 'kbCapture', payload = { op = 'start', value = tostring(data.value or ''), session = kbSession,
            maxLength = math.max(1, math.min(4096,tonumber(data.maxLength) or 64)) } })
        cb({ ok = true })

        CreateThread(function()
            local started = GetGameTimer()
            while kbEditing and mySeq == kbSeq and tabletActive and (GetGameTimer() - started) < 30000 do
                Wait(200)
            end
            if kbEditing and mySeq == kbSeq then
                stopKeyboard(nil, false)
            end
        end)
    end)

    registerCallbackOnce(cbKbUpdate, function(data, cb)
        if kbEditing and surface and data and data.session == kbSession then
            self:send('kbValue', { value = tostring(data.value or ''), session = kbSession })
        end
        cb({ ok = true })
    end)

    registerCallbackOnce(cbKbEnd, function(data, cb)
        data = data or {}
        if data.session == kbSession then stopKeyboard(data.value, data.submit == true) end
        cb({ ok = true })
    end)

    AddEventHandler('onResourceStop', function(res)
        if res == NN.resource then
            self:dispose()
        end
    end)

    return self
end
