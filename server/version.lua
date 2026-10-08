-- nonick_lib · server/version.lua
-- Generic update-notice helper (NN.Version.check). Keymaster has no public
-- version API, so the check reads either a tiny JSON you host anywhere, or the
-- GitHub Releases of a (public, even code-less) repo — and the console notice
-- links owners to your keymaster asset page.
--
-- NOTIFY-ONLY by design: never download/replace code at runtime (against the
-- Cfx.re platform rules and a supply-chain risk).
--
-- Dependency-free on purpose: it is loaded both by consumers (via init.lua)
-- and by nonick_lib's own version check script.

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

-- NN.Version.check({
--     url      = 'https://.../mio_script.json',  -- JSON: { "version": "1.2.0", "url": "<keymaster>", "notes": "..." }
--     repo     = 'owner/repo',                   -- alternative: GitHub Releases (tag v1.2.0)
--     download = 'https://portal.cfx.re/...',    -- optional: overrides the link shown
--     resource = 'name',                         -- optional (default: calling resource)
--     delayMs  = 3000,                           -- optional boot grace
-- })
-- Server owners can silence any check with: setr <resource>_versioncheck 0
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
        return -- not configured: stay silent
    end

    CreateThread(function()
        Wait(opts.delayMs or 3000)

        local current = GetResourceMetadata(resource, 'version', 0) or '0.0.0'

        PerformHttpRequest(requestUrl, function(status, body)
            -- Network hiccup / missing file / no releases: a version check must
            -- never pollute the console with its own failures.
            if status ~= 200 or not body then return end

            local ok, data = pcall(json.decode, body)
            if not ok or type(data) ~= 'table' then return end

            -- Canonical format is ONE object { version, url, notes }, but be
            -- tolerant of a hand-written ARRAY of one-key objects like
            -- [ {"version": "1.0.0"}, {"notes": "..."} ] — merge it.
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
                -- per-release URL from the JSON wins; opts.download is the fallback
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
            -- GitHub's API rejects requests without a User-Agent; harmless elsewhere.
            ['User-Agent'] = 'nn-version-check',
            ['Accept'] = 'application/json',
        })
    end)
end
