NN.Dui = NN.Dui or {}

local surfaceSeq = 0

function NN.Dui.screenPixels(rectW, rectH, supersample, maxDim)

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

    local handle = GetDuiHandle(self.duiObject)
    local txd = CreateRuntimeTxd(self.runtimeTxd)
    CreateRuntimeTextureFromDuiHandle(txd, self.runtimeTxn, handle)

    function self:isReady()
        return self.ready and self.duiObject ~= nil
    end

    function self:getSize()
        return self.width, self.height
    end

    function self:send(action, payload)
        if not self.duiObject then return end
        SendDuiMessage(self.duiObject, json.encode({ action = action, payload = payload }))
    end

    function self:sendRaw(str)
        if not self.duiObject then return end
        SendDuiMessage(self.duiObject, tostring(str))
    end

    function self:bindReplace(targetTxd, targetTexture)
        self.boundTxd = targetTxd
        self.boundTexture = targetTexture
        AddReplaceTexture(targetTxd, targetTexture, self.runtimeTxd, self.runtimeTxn)
    end

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

    function self:wheel(deltaY, deltaX)
        if not self.duiObject then return end
        SendDuiMouseWheel(self.duiObject, deltaY or 0, deltaX or 0)
    end

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
