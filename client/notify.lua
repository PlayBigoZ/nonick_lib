-- nonick_lib · client/notify.lua
-- Minimal native feedback helpers (no dependency on any notify resource).

NN.Notify = NN.Notify or {}

-- GTA feed ticker, optionally prefixed: "[MyScript] message".
function NN.Notify.feed(message, prefix)
    local text = prefix and ('[%s] %s'):format(prefix, message) or tostring(message)
    BeginTextCommandThefeedPost('STRING')
    AddTextComponentSubstringPlayerName(text)
    EndTextCommandThefeedPostTicker(false, false)
end

-- Top-left help text (the "press ~INPUT~ to ..." box).
function NN.Notify.help(message)
    BeginTextCommandDisplayHelp('STRING')
    AddTextComponentSubstringPlayerName(tostring(message))
    EndTextCommandDisplayHelp(0, false, false, -1)
end
