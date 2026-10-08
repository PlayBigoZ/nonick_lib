-- nonick_lib · server/versioncheck.lua
-- Self version check for THIS library (runs once, inside nonick_lib's own
-- state; consumers never load this file). The generic helper lives in
-- server/version.lua (NN.Version.check) and is available to consumers too.
--
-- The asset is distributed on Keymaster, which has no version API: publish the
-- CURRENT version in ONE of the two sources below and the notice will point
-- owners to your keymaster page.

-- Option A — a tiny JSON you host anywhere (raw GitHub file, your site, ...):
--   { "version": "1.2.0", "url": "https://portal.cfx.re/assets/...", "notes": "..." }
local VERSION_JSON_URL = 'https://raw.githubusercontent.com/leodeveloper500-ops/ResourcesVersion/main/nonick-lib.json'

-- Option B — GitHub Releases of a public repo (can be docs/changelog only,
-- no code needed): create releases tagged v1.2.0.
local GITHUB_REPO = ''        -- e.g. 'leodeveloper500-ops/nonick_lib'

-- Link shown to server owners when an update exists: the Cfx.re Portal page
-- where granted/purchased assets are downloaded, pre-filtered on this asset
-- via the ?search= deep-link. The "url" field in the JSON above (when present)
-- takes precedence over this fallback.
local DOWNLOAD_LINK = 'https://portal.cfx.re/assets/granted-assets?search=nonick_lib'

NN.Version.check({
    url = VERSION_JSON_URL ~= '' and VERSION_JSON_URL or nil,
    repo = GITHUB_REPO ~= '' and GITHUB_REPO or nil,
    download = DOWNLOAD_LINK ~= '' and DOWNLOAD_LINK or nil,
})
