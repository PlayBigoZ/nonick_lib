NN = NN or {}
NN.Version = NN.Version or {}

local function parseVersion(str)
    local parts = {}
    for piece in tostring(str or ''):gmatch('%d+') do
        parts[#parts + 1] = tonumber(piece)
    end
    return parts
end

local function isNewer(remoteStr, localStr)
    local remote = parseVersion(remoteStr)
    local localV = parseVersion(localStr)
    if #remote == 0 then return false end

    for i = 1, math.max(#remote, #localV) do
        local r = remote[i] or 0
        local l = localV[i] or 0
        if r > l then return true end
        if r < l then return false end
    end

    return false
end

function NN.Version.check(opts)
    opts = opts or {}
    local resource = opts.resource or GetCurrentResourceName()

    if GetConvarInt(('%s_versioncheck'):format(resource), 1) ~= 1 then return end

    local requestUrl, mode
    if type(opts.url) == 'string' and opts.url ~= '' then
        requestUrl, mode = opts.url, 'json'
    elseif type(opts.repo) == 'string' and opts.repo ~= '' and not opts.repo:find('CHANGE_ME', 1, true) then
        requestUrl, mode = ('https://api.github.com/repos/%s/releases/latest'):format(opts.repo), 'github'
    else
        return
    end

    CreateThread(function()
        Wait(opts.delayMs or 3000)

        local current = GetResourceMetadata(resource, 'version', 0) or '0.0.0'

        PerformHttpRequest(requestUrl, function(status, body)

            if status ~= 200 or not body then return end

            local ok, data = pcall(json.decode, body)
            if not ok or type(data) ~= 'table' then return end

            if not (data.version or data.tag_name) and data[1] ~= nil then
                local merged = {}
                for _, entry in ipairs(data) do
                    if type(entry) == 'table' then
                        for k, v in pairs(entry) do merged[k] = v end
                    end
                end
                data = merged
            end

            local latest, link, notes
            if mode == 'github' then
                if not data.tag_name then return end
                latest = tostring(data.tag_name):gsub('^[vV]', '')
                link = opts.download or data.html_url
            else
                if not data.version then return end
                latest = tostring(data.version):gsub('^[vV]', '')

                link = data.url or opts.download
                notes = data.notes
            end

            if isNewer(latest, current) then
                print(('^3[%s] update available: ^1%s^3 -> ^2%s^7'):format(resource, current, latest))
                if link and link ~= '' then
                    print(('^3[%s] download: ^5%s^7'):format(resource, tostring(link)))
                end
                if notes and notes ~= '' then
                    print(('^3[%s] notes: ^7%s'):format(resource, tostring(notes)))
                end
            end
        end, 'GET', '', {

            ['User-Agent'] = 'nn-version-check',
            ['Accept'] = 'application/json',
        })
    end)
end
