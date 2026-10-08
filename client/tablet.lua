-- nonick_lib · client/tablet.lua
-- Full in-hand tablet system on top of NN.Dui: prop attached to the hand with a
-- dead-still frozen pose, a fixed scripted camera framing the screen, cursor →
-- DUI forwarding (clamped to the screen), an invisible-NUI keyboard bridge for
-- typing into DUI <input>s, and a state re-push burst that beats the React
-- mount race. Every non-obvious line below exists because the naive version
-- visibly failed (tremor, blur, stolen keybinds, lost first state, ...).
--
--   local tablet = NN.Tablet.new({
--       config = function() return Config.Tablet end,   -- live table, see keys below
--       url = function() return 'nui://...' end,        -- or a plain string
--       getState = function() return currentState end,  -- payload for 'open' pushes
--       shouldPush = function() return isOpen end,      -- gate for the burst
--       onRequestClose = function() closeUi() end,      -- ESC/Backspace handler
--       notify = function(msg) ... end,                 -- optional user feedback
--       runtimeTxd = 'myscript_dui',                    -- optional (default derived)
--   })
--   tablet:ensure()  tablet:open()  tablet:close()  tablet:send(action, payload)
--
-- config() keys (same schema as the weedshop's Config.Tablet):
--   enabled, model, txd, targetTexture, duiFullRes, duiSupersample, duiWidth,
--   duiHeight, bone, pos{x,y,z}, rot{x,y,z}, animPhase, screenRect{x,y,w,h},
--   flipUi, camera{ offset{x,y,z}, point{x,y,z}, fov, blendMs },
--   anim{ baseDict, baseClip, dict, clip, flag }  (optional overrides)
--
-- Web page contract (unchanged from the weedshop page):
--   - page loaded with ?dui=1[&flip=1]; DUI messages arrive as JSON strings
--   - page ACKs the first applied 'open' by fetching <callback openAck>
--   - focusing an input fetches kbStart {value}; live values come back as
--     'kbValue' {value[, done]}; the NUI overlay mirrors keys via kbUpdate/kbEnd
--   - the fullscreen NUI listens for 'kbCapture' {op:'start'|'stop', value}

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

    local surface = nil          -- NN.Dui surface
    local tabletProp = nil
    local tabletCam = nil
    local tabletActive = false
    local textureRebound = false -- one-shot rebind after the (externally streamed) prop model first loads
    local tabletAnim = nil       -- frozen hold pose descriptor (pinned once, watched by the input loop)
    local keyboardActive = false -- invisible NUI keyboard capture is up (pauses the input loop)
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
        -- sensible default: the consumer's ui page in DUI mode
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

    -- Push a state/message into the DUI page (mirrors SendNUIMessage).
    function self:send(action, payload)
        if surface then surface:send(action, payload) end
    end

    -- Re-push the live state for a few seconds: the first 'open' can land BEFORE
    -- the page's message listener attaches (React mounts asynchronously and a
    -- DUI silently drops messages posted to a not-yet-listening document). The
    -- page ACKs the first applied 'open' (openAck callback) and the burst stops
    -- IMMEDIATELY — keeping it running overwrote the user's optimistic UI
    -- navigation every 200ms, so fast clicking "went back".
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

    -- Create the DUI + runtime texture once and reuse across opens. Registering
    -- the texture override at pre-warm (before the prop ever streams in) is what
    -- makes it apply on the very first open.
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

        -- Loud diagnostics: if the archetype isn't registered (missing stream /
        -- wrong name), RequestModel can never succeed and the tablet shows
        -- NOTHING — which reads as "the DUI doesn't load".
        -- Player-facing texts are localizable via opts.strings.<key>(modelName);
        -- the English literals below are only fallbacks (console prints stay
        -- English on purpose: they are developer diagnostics).
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

        -- One extra Remove+Add of the texture override, ONCE, now that the prop
        -- model has definitely loaded. Needed when the prop is streamed by
        -- ANOTHER resource (the pre-warm bind can predate its TXD and never
        -- land); once only because re-registering per open is an FPS sink.
        if not textureRebound and surface then
            surface:rebindReplace()
            textureRebound = true
        end

        -- Freeze the skeleton in TWO pinned layers:
        -- 1) a neutral full-body STANDING clip (primary slot) frozen at speed 0
        --    — replaces the ped's breathing base idle, which keeps swaying the
        --    spine under a secondary anim (SetPedCanPlayAmbientBaseAnims can't
        --    stop an idle that's already running);
        -- 2) the tablet hold as upper-body secondary (flag 49) frozen on top.
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
            -- Wait until the clip actually plays, THEN pin the frame — ONCE.
            -- (Re-pinning every frame pops the skeleton = whole-view tremor.)
            local startTo = GetGameTimer() + 500
            while not IsEntityPlayingAnim(ped, dict, clip, 3) and GetGameTimer() < startTo do Wait(0) end
            SetEntityAnimCurrentTime(ped, dict, clip, phase)
            SetEntityAnimSpeed(ped, dict, clip, 0.0)
            tabletAnim = { dict = dict, clip = clip, phase = phase, flag = flag, baseDict = baseDict, baseClip = baseClip }
        end
    end

    -- Camera FIXED in the world, framed from the prop's LOCAL offset/point (so
    -- prop-relative calibration keeps working). It tracks the prop only during a
    -- short settle window at open (the prop is still easing onto the hand), then
    -- FREEZES: a fixed-coordinate camera cannot tremble — unlike
    -- AttachCamToEntity on a bone-attached prop (cam vs bone update at different
    -- points in the frame = micro-jitter).
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

    -- Forward the on-screen cursor + clicks to the DUI. screenRect maps the game
    -- cursor (0..1) onto the tablet screen region, then to DUI pixels.
    local function startInputLoop()
        CreateThread(function()
            while tabletActive do
                Wait(0)

                -- The hold pose is pinned ONCE at spawn (speed 0). Only RESTART
                -- it if some other script cleared it — never re-pin per frame.
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

                -- While the invisible NUI keyboard captures text, hand ALL input
                -- to it: Enter/Esc must reach the capture input, not the tablet.
                if not keyboardActive then
                    if SetMouseCursorActiveThisFrame then SetMouseCursorActiveThisFrame() end

                    -- Block EVERY game control + other resources' keybinds while
                    -- the tablet is open (letters/F-keys/numbers must NOT leak).
                    -- The mouse is then read via the *disabled* variants.
                    DisableAllControlActions(0)

                    local conf = c()
                    local r = conf.screenRect or { x = 0.5, y = 0.5, w = 0.42, h = 0.62 }
                    local cx = GetDisabledControlNormal(0, 239) -- cursor X
                    local cy = GetDisabledControlNormal(0, 240) -- cursor Y

                    -- CONFINE the cursor to the tablet screen.
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

                    -- The page is rotated 180° (flipUi): invert the mapping so
                    -- clicks land where the user actually points.
                    if conf.flipUi ~= false then
                        u = 1.0 - u
                        v = 1.0 - v
                    end

                    if u >= 0.0 and u <= 1.0 and v >= 0.0 and v <= 1.0 and surface then
                        surface:mouseMove(u, v)
                        if IsDisabledControlJustPressed(0, 237) then surface:mouseDown('left') end
                        if IsDisabledControlJustReleased(0, 237) then surface:mouseUp('left') end
                        -- Wheel: ±150px ≈ one comfortable notch (CEF deltas are
                        -- pixels; ±1 looks like scrolling is broken). Controls
                        -- 14/15 are what the wheel raises on some setups while
                        -- everything is disabled.
                        local wheelUp = IsDisabledControlJustPressed(0, 241) or IsDisabledControlJustPressed(0, 15)
                        local wheelDown = IsDisabledControlJustPressed(0, 242) or IsDisabledControlJustPressed(0, 14)
                        if wheelUp then surface:wheel(150, 0) end
                        if wheelDown then surface:wheel(-150, 0) end
                    end

                    -- ESC / Backspace close (fallback to the in-UI close button).
                    if IsDisabledControlJustPressed(0, 200) or IsDisabledControlJustPressed(0, 177) then
                        if opts.onRequestClose then opts.onRequestClose() end
                    end
                end
            end
        end)
    end

    function self:open()
        if tabletActive then return true end

        -- The panel lives on the DUI; keep the fullscreen NUI hidden/unfocused.
        SetNuiFocus(false, false)
        SendNUIMessage({ action = 'close' })

        self:ensure()
        spawnTabletProp()
        if not surface or not tabletProp or not DoesEntityExist(tabletProp) then
            if tabletProp and DoesEntityExist(tabletProp) then DeleteEntity(tabletProp) end
            tabletProp = nil
            return false
        end

        -- Lock the ped BEFORE sampling the prop for the fixed camera. Also kill
        -- IK (mouse-driven head/torso "look" propagates down the arms = hand
        -- tremor) and ambient idles (breath/weight-shift sway).
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

        -- Only mark active once setup succeeded, so an error never leaves a stuck flag.
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

        -- DUI, runtime texture AND the override stay alive for the next open:
        -- removing/re-adding per open occasionally showed the prop's original
        -- texture on the next open, and the prop is deleted here anyway.
    end

    function self:dispose()
        self:close()
        if surface then
            surface:destroy()
            surface = nil
        end
        textureRebound = false
    end

    -- ── invisible-NUI keyboard bridge ────────────────────────────────────────
    -- A DUI surface can't receive keyboard input. When the user focuses a field
    -- on the DUI page, the page calls <kbStart>; we focus the (blank) fullscreen
    -- NUI so CEF grabs the keyboard — which also blocks every other keybind —
    -- and its invisible input mirrors each keystroke back via <kbUpdate>, which
    -- we relay into the DUI as 'kbValue'. <kbEnd> (Enter/Esc) releases focus.

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

    -- While typing, NUI owns the mouse. Forward its normalized pointer to the
    -- same DUI mapping instead of forcing Enter before another field can click.
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
        -- Focusing the first DUI field may pause its native input loop before
        -- the initiating mouse-up. Release it before handing pointer ownership over.
        if surface then surface:mouseUp('left') end
        SetNuiFocus(true, true)
        SetNuiFocusKeepInput(false)
        SendNUIMessage({ action = 'kbCapture', payload = { op = 'start', value = tostring(data.value or ''), session = kbSession,
            maxLength = math.max(1, math.min(4096,tonumber(data.maxLength) or 64)) } })
        cb({ ok = true })

        -- Watchdog: never leave the player stuck with focus grabbed.
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
