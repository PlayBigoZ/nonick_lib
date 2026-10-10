local VERSION_JSON_URL = 'https://raw.githubusercontent.com/leodeveloper500-ops/ResourcesVersion/main/nonick-lib.json'

local GITHUB_REPO = ''

local DOWNLOAD_LINK = 'https://portal.cfx.re/assets/granted-assets?search=nonick_lib'

NN.Version.check({
    url = VERSION_JSON_URL ~= '' and VERSION_JSON_URL or nil,
    repo = GITHUB_REPO ~= '' and GITHUB_REPO or nil,
    download = DOWNLOAD_LINK ~= '' and DOWNLOAD_LINK or nil,
})
