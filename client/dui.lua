-- nonick_lib · client/dui.lua
-- Generic DUI surface management: create a CEF page, expose it as a runtime
-- texture, optionally override an existing texture (prop screens, TVs, ...),
-- and forward input/messages to it. Distilled from a production tablet: every
-- quirk documented here was paid for in debugging time.
--
--   local surface = NN.Dui.create({
--       url = 'nui://my_resource/web/dist/index.html?dui=1',
--       width = 1213, height = 854,                  -- or use NN.Dui.screenPixels
--       runtimeTxd = 'myscript_dui', runtimeTxn = 'tex',
--       replace = { txd = 'my_prop', texture = 'screen' },  -- optional override
--   })
--   surface:send('open', state)          -- JSON message to the page
--   surface:mouseMove(u, v)              -- normalized 0..1
--   surface:destroy()

NN.Dui = NN.Dui or {}

local surfaceSeq = 0

-- Pixels a normalized screen rectangle (w/h fractions of the monitor) covers,
-- times an EXACT supersample factor. Why supersample: a 3D quad is never
-- pixel-aligned to the monitor, so at ~1:1 every screen pixel lands BETWEEN
-- texels and bilinear blends them 50/50 — uniform blur. A non-integer ratio
-- (e.g. 1.58x) aliases into grain instead. At an exact 2:1 the downscale
-- averages 4 texels per pixel like proper anti-aliasing: text comes out clean.
-- Returns w, h or nil when the resolution can't be read.
function NN.Dui.screenPixels(rectW, rectH, supersample, maxDim)
    -- Prefer the ACTUAL window resolution: GetActiveScreenResolution reports a
    -- 16:9-normalised size on some aspect ratios, which breaks the 1:1 mapping.
    local sw, sh
    if GetActualScreenResolution then
        sw, sh = GetActualScreenResolution()
    end
    if not (type(sw) == 'number' and sw > 0) then
        sw, sh = GetActiveScreenResolution()
    end
    if not (type(sw) == 'number' and sw > 0 and type(sh) == 'number' and sh > 0) then
        return nil
    end

    local rw = math.floor(sw * (rectW or 1.0) + 0.5)
    local rh = math.floor(sh * (rectH or 1.0) + 0.5)
    local ss = tonumber(supersample) or 2.0
    if ss < 1.0 then ss = 1.0 elseif ss > 4.0 then ss = 4.0 end

    local cap = tonumber(maxDim) or 4096
    while ss > 1.0 and (rw * ss > cap or rh * ss > cap) do
        ss = ss - 0.5
    end

    return math.floor(rw * ss + 0.5), math.floor(rh * ss + 0.5)
end

function NN.Dui.create(opts)
    opts = opts or {}
    assert(type(opts.url) == 'string' and opts.url ~= '', 'NN.Dui.create: opts.url is required')

    surfaceSeq = surfaceSeq + 1

    local self = {
        url = opts.url,
        width = math.floor(opts.width or 1280),
        height = math.floor(opts.height or 720),
        runtimeTxd = opts.runtimeTxd or ('%s_dui_%d'):format(NN.resource, surfaceSeq),
        runtimeTxn = opts.runtimeTxn or 'tex',
        duiObject = nil,
        ready = false,
        boundTxd = nil,
        boundTexture = nil,
    }

    self.duiObject = CreateDui(self.url, self.width, self.height)

    local timeout = GetGameTimer() + (opts.timeoutMs or 8000)
    while not IsDuiAvailable(self.duiObject) and GetGameTimer() < timeout do
        Wait(15)
    end
    self.ready = IsDuiAvailable(self.duiObject)

    -- CreateRuntimeTextureFromDuiHandle needs the txd HANDLE returned by
    -- CreateRuntimeTxd, not the name string; texture overrides below use names.
    local handle = GetDuiHandle(self.duiObject)
    local txd = CreateRuntimeTxd(self.runtimeTxd)
    CreateRuntimeTextureFromDuiHandle(txd, self.runtimeTxn, handle)

    function self:isReady()
        return self.ready and self.duiObject ~= nil
    end

    function self:getSize()
        return self.width, self.height
    end

    -- JSON message to the page. NOTE: SendDuiMessage arrives in the page as a
    -- raw STRING on the window 'message' event (NUI messages arrive as parsed
    -- objects) — the page listener must JSON.parse string payloads.
    function self:send(action, payload)
        if not self.duiObject then return end
        SendDuiMessage(self.duiObject, json.encode({ action = action, payload = payload }))
    end

    function self:sendRaw(str)
        if not self.duiObject then return end
        SendDuiMessage(self.duiObject, tostring(str))
    end

    -- Override an existing texture (prop screen) with this surface. Registering
    -- the override BEFORE the target prop ever streams in is fine — it applies
    -- when the TXD loads. Keep it bound for the surface's lifetime: repeatedly
    -- re-registering the (experimental) override is an FPS sink.
    function self:bindReplace(targetTxd, targetTexture)
        self.boundTxd = targetTxd
        self.boundTexture = targetTexture
        AddReplaceTexture(targetTxd, targetTexture, self.runtimeTxd, self.runtimeTxn)
    end

    -- One extra Remove+Add cycle. Needed exactly ONCE when the target prop is
    -- streamed by ANOTHER resource: a pre-warm bind can run before that TXD
    -- exists and never land (the prop keeps its baked texture). Call this after
    -- the prop model has actually loaded.
    function self:rebindReplace()
        if not (self.boundTxd and self.boundTexture) then return end
        RemoveReplaceTexture(self.boundTxd, self.boundTexture)
        AddReplaceTexture(self.boundTxd, self.boundTexture, self.runtimeTxd, self.runtimeTxn)
    end

    function self:unbindReplace()
        if not (self.boundTxd and self.boundTexture) then return end
        RemoveReplaceTexture(self.boundTxd, self.boundTexture)
        self.boundTxd = nil
        self.boundTexture = nil
    end

    -- Cursor forwarding. u/v are normalized 0..1 over the page.
    function self:mouseMove(u, v)
        if not self.duiObject then return end
        SendDuiMouseMove(self.duiObject, math.floor(u * self.width), math.floor(v * self.height))
    end

    function self:mouseMovePx(x, y)
        if not self.duiObject then return end
        SendDuiMouseMove(self.duiObject, math.floor(x), math.floor(y))
    end

    function self:mouseDown(button)
        if not self.duiObject then return end
        SendDuiMouseDown(self.duiObject, button or 'left')
    end

    function self:mouseUp(button)
        if not self.duiObject then return end
        SendDuiMouseUp(self.duiObject, button or 'left')
    end

    -- CEF wheel deltas are in PIXELS: ±1 is imperceptible (scroll looks broken).
    -- ~150 ≈ one comfortable notch.
    function self:wheel(deltaY, deltaX)
        if not self.duiObject then return end
        SendDuiMouseWheel(self.duiObject, deltaY or 0, deltaX or 0)
    end

    -- AVOID at runtime when the surface backs a texture override: navigating a
    -- DUI invalidates the runtime-texture binding and turns the prop black.
    -- Destroy + create a new surface instead when possible.
    function self:setUrl(url)
        if not self.duiObject then return end
        self.url = url
        SetDuiUrl(self.duiObject, url)
    end

    function self:destroy()
        self:unbindReplace()
        if self.duiObject then
            DestroyDui(self.duiObject)
            self.duiObject = nil
        end
        self.ready = false
    end

    if opts.replace and opts.replace.txd and opts.replace.texture then
        self:bindReplace(opts.replace.txd, opts.replace.texture)
    end

    return self
end
