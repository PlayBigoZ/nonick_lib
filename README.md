# nonick_lib

Shared NoNick library for FiveM scripts: **DUI/tablet** management,
**framework/inventory** integration (ESX · QBCore · Qbox · standalone),
**target** adapters (ox_target · qb-target · qtarget), and utilities.

## Installation

1. Place `nonick_lib` in `resources/` and start it **before** the resources that use it:

```cfg
ensure nonick_lib
ensure your_script
```

2. In your script's `fxmanifest.lua`, include the initialization file **first**:

```lua
shared_scripts {
    '@nonick_lib/init.lua',
    'config.lua',
    -- ...
}

dependencies { 'nonick_lib' }
```

Modules run **inside your script's Lua environment**, similarly to ox_lib:
NUI callbacks, DUI surfaces, and event handlers belong to your resource.

## Keymaster / Cfx Portal: keep the library files readable

Resources read the library modules using `LoadResourceFile`, so these files
**must remain readable**. Encrypting the dynamically loaded Lua files prevents
the resources that depend on them from loading the library.
The manifest already excludes these files through `escrow_ignore`; preserve
those exclusions when packaging or uploading it. Distributing the library
without escrow also keeps it readable. Your scripts that use the library can
remain protected by escrow.

## Version check and updates

On startup, the library checks the published version and prints an update
notice in the console when appropriate. It only notifies; it does not
automatically replace the code:

```text
[nonick_lib] update available: 1.0.0 -> 1.2.0
[nonick_lib] download: https://portal.cfx.re/assets/...
```

Configure one of these version sources in `server/versioncheck.lua`:

- **A hosted JSON file** (raw GitHub or your own website):
  `{ "version": "1.2.0", "url": "<asset page>", "notes": "..." }`.
- **GitHub Releases** from a public repository, using tags such as `v1.2.0`.
  The repository may contain only a changelog, without publishing your code.

Set `DOWNLOAD_LINK` to your asset page. The release workflow is: update
`version` in `fxmanifest.lua` → upload the release → update the JSON file or
publish the GitHub release. While the source settings are empty, the check
remains silently disabled. Server owners can disable it with:

```cfg
setr nonick_lib_versioncheck 0
```

The helper can be reused in any of your scripts:

```lua
NN.Version.check({
    url = 'https://raw.githubusercontent.com/yourname/nn-versions/main/myscript.json',
    download = 'https://portal.cfx.re/assets/...',  -- optional download link override
})
```

If you maintain a separate automatic update workflow, perform `git pull` or
download the release in your server startup script **before** booting the server.

## API — the `NN` global

### `NN.Utils` (shared)

`num(t,k,default)` · `clamp` · `round` · `snap(value,step)` · `trim` ·
`debugPrinter(prefix, isEnabledFn)` · `loadJson(path[,resource])` ·
`saveJson(path, data[,resource])`

### `NN.Dui` (client) — generic DUI surfaces

```lua
local w, h = NN.Dui.screenPixels(rectW, rectH, supersample --[[2.0]], maxDim --[[4096]])
local surface = NN.Dui.create({
    url = 'nui://my_resource/web/dist/index.html?dui=1',
    width = w, height = h,
    runtimeTxd = 'myscript_dui',                       -- optional
    replace = { txd = 'my_prop', texture = 'screen' }, -- replace the prop texture
})
surface:send('open', state)      -- JSON message sent to the page
surface:mouseMove(u, v)          -- normalized 0..1; also mouseDown/mouseUp/wheel(±150)
surface:rebindReplace()          -- once, after an external prop has loaded
surface:destroy()
```
`SendDuiMessage` reaches the page as a **JSON string**; parse it with
`JSON.parse`. A 2× supersampling factor improves text clarity on a 3D prop.
Avoid calling `setUrl` at runtime, as it invalidates the texture binding.

### `NN.Tablet` (client) — complete handheld tablet

A frozen prop, fixed camera, clamped cursor-to-DUI mapping, mouse wheel support,
keyboard input through an invisible NUI bridge, and acknowledged state delivery
to handle initialization races.

```lua
local tablet = NN.Tablet.new({
    config = function() return Config.Tablet end, -- same configuration schema as Weedshop
    getState = function() return currentState end,
    shouldPush = function() return isOpen end,
    onRequestClose = function() closeUi() end,
    notify = function(msg) ... end,
})
tablet:ensure()   -- pre-warm; recommended about 500 ms after resource startup
tablet:open()  tablet:close()  tablet:send(action, payload)  tablet:isActive()
```
Web page contract: `?dui=1[&flip=1]`, the `tabletOpenAck` acknowledgement,
the `tabletKbStart/Update/End` keyboard callbacks, and `kbCapture`/`kbValue`
messages. Refer to the Weedshop web implementation for the matching page logic.

### `NN.Target` (client)

```lua
NN.Target.addLocalEntity(entity, {
    { label = 'Action', icon = 'fa-solid fa-hand',
      canInteract = function() return true end,
      onSelect = function() ... end },
}, distance)
NN.Target.removeLocalEntity(entity)
```

### `NN.Notify` (client)

`NN.Notify.feed(message, prefix)` · `NN.Notify.help(message)`

### `NN.Framework` (server)

```lua
NN.Framework.detect(Config.Framework)     -- 'auto'|'esx'|'qbcore'|'qbox'|'standalone'
NN.Framework.getPlayer(src)   .getIdentifier(src)   .getPlayerName(src)   .getJob(src)
NN.Framework.isAllowed(src, allowedGroups, 'staff'|'admin', player?, extraAces?)
NN.Framework.getStaffGroup(src, allowedGroups)
NN.Framework.registerUsableItem('my_item', function(src) ... end)
```

### `NN.Inventory` / `NN.Money` (server)

```lua
NN.Inventory.detect(Config.Inventory, frameworkName)
NN.Inventory.addItem(src, item, count, metadata, opts)
NN.Inventory.removeItem(src, item, count, metadata, opts)   -- returns a boolean
NN.Inventory.getCount(src, item, opts)
NN.Inventory.canCarry(src, item, count, metadata, opts)
NN.Money.get(src, moneyConfig, opts)
NN.Money.remove(src, moneyConfig, amount, reason, opts)
-- opts: { player=?, playerData=? (standalone fallback), resource=? }
```
