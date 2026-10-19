# nonick_lib

Libreria condivisa NoNick per script FiveM: gestione **DUI/tablet**, bridge
**framework/inventory** (ESX · QBCore · QBox · standalone), adapter **target**
(ox_target · qb-target · qtarget) e utility.

## Installazione

1. Metti `nonick_lib` in `resources/` e avviala **prima** dei consumer:

```cfg
ensure nonick_lib
ensure il_tuo_script
```

2. Nel `fxmanifest.lua` del tuo script, includi l'init **per primo**:

```lua
shared_scripts {
    '@nonick_lib/init.lua',
    'config.lua',
    -- ...
}

dependencies { 'nonick_lib' }
```

I moduli girano **nello stato Lua del tuo script** (stile ox_lib): le NUI
callback, le superfici DUI e gli event handler appartengono alla tua resource.

## ⚠️ Keymaster: carica la lib SENZA escrow

I consumer leggono i moduli con `LoadResourceFile`, che **non può leggere file
criptati**: se la lib venisse caricata con escrow attivo, ogni resource che la
usa si romperebbe. Il manifest ha già `escrow_ignore` su tutti i file come rete
di sicurezza — ma caricala comunque come asset non protetto. (I tuoi script che
la USANO possono invece restare escrowed normalmente.)

## Version check (aggiornamenti)

All'avvio la lib controlla la versione pubblicata e avvisa in console se ne
esiste una più nuova (solo notifica — mai auto-sostituzione del codice, vietata
dalle policy Cfx.re):

```
[nonick_lib] update available: 1.0.0 -> 1.2.0
[nonick_lib] download: https://portal.cfx.re/assets/...
```

Keymaster non ha un'API versioni, quindi in `server/versioncheck.lua` configuri
UNA di queste sorgenti:
- **JSON ospitato ovunque** (raw GitHub, tuo sito):
  `{ "version": "1.2.0", "url": "<pagina keymaster>", "notes": "..." }`
- **GitHub Releases** di un repo pubblico (può contenere solo changelog, zero
  codice): release taggate `v1.2.0`.

più `DOWNLOAD_LINK` = la tua pagina keymaster. Flusso di release: bump di
`version` nel `fxmanifest.lua` → upload su keymaster → aggiorni il JSON (o crei
la release GitHub). Finché le sorgenti restano vuote il check è disattivato in
silenzio; gli owner possono zittirlo con `setr nonick_lib_versioncheck 0`.

Il helper è riusabile in QUALSIASI tuo script (weedshop incluso):

```lua
NN.Version.check({
    url = 'https://raw.githubusercontent.com/tuonome/nn-versions/main/mioscript.json',
    download = 'https://portal.cfx.re/assets/...',  -- opzionale, sovrascrive il link
})
```

Per l'aggiornamento davvero automatico: `git pull` / download release nello
script di avvio del server, PRIMA del boot.

## API — global `NN`

### `NN.Utils` (shared)
`num(t,k,default)` · `clamp` · `round` · `snap(value,step)` · `trim` ·
`debugPrinter(prefix, isEnabledFn)` · `loadJson(path[,resource])` ·
`saveJson(path, data[,resource])`

### `NN.Dui` (client) — superfici DUI generiche
```lua
local w, h = NN.Dui.screenPixels(rectW, rectH, supersample --[[2.0]], maxDim --[[4096]])
local surface = NN.Dui.create({
    url = 'nui://mia_resource/web/dist/index.html?dui=1',
    width = w, height = h,
    runtimeTxd = 'mioscript_dui',                       -- opzionale
    replace = { txd = 'mio_prop', texture = 'screen' }, -- override texture prop
})
surface:send('open', state)      -- messaggio JSON alla pagina
surface:mouseMove(u, v)          -- 0..1 · mouseDown/mouseUp/wheel(±150)
surface:rebindReplace()          -- una volta, dopo il load di un prop esterno
surface:destroy()
```
Nota: `SendDuiMessage` arriva alla pagina come **stringa JSON** (fare
`JSON.parse`). Il supersample ×2 esatto è ciò che rende nitido il testo su un
prop 3D. Evita `setUrl` a runtime: invalida il binding della texture.

### `NN.Tablet` (client) — tablet in mano completo
Prop congelato senza tremolii, camera fissa, cursore→DUI con clamp, rotella,
ponte tastiera via NUI invisibile, burst di stato anti-race con ACK.
```lua
local tablet = NN.Tablet.new({
    config = function() return Config.Tablet end, -- stesso schema del weedshop
    getState = function() return currentState end,
    shouldPush = function() return isOpen end,
    onRequestClose = function() closeUi() end,
    notify = function(msg) ... end,
})
tablet:ensure()   -- pre-warm (consigliato ~500ms dopo lo start)
tablet:open()  tablet:close()  tablet:send(action, payload)  tablet:isActive()
```
Contratto pagina web: `?dui=1[&flip=1]`, ack `tabletOpenAck`, tastiera
`tabletKbStart/Update/End` + messaggi `kbCapture`/`kbValue` (vedi la pagina del
weedshop come riferimento).

### `NN.Target` (client)
```lua
NN.Target.addLocalEntity(entity, {
    { label = 'Azione', icon = 'fa-solid fa-hand',
      canInteract = function() return true end,
      onSelect = function() ... end },
}, distanza)
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
NN.Framework.registerUsableItem('mio_item', function(src) ... end)
```

### `NN.Inventory` / `NN.Money` (server)
```lua
NN.Inventory.detect(Config.Inventory, frameworkName)
NN.Inventory.addItem(src, item, count, metadata, opts)
NN.Inventory.removeItem(src, item, count, metadata, opts)   -- -> bool
NN.Inventory.getCount(src, item, opts)
NN.Inventory.canCarry(src, item, count, metadata, opts)
NN.Money.get(src, moneyConfig, opts)
NN.Money.remove(src, moneyConfig, amount, reason, opts)
-- opts: { player=?, playerData=? (fallback standalone), resource=? }
```
