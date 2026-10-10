NN.Notify = NN.Notify or {}

function NN.Notify.feed(message, prefix)
    local text = prefix and ('[%s] %s'):format(prefix, message) or tostring(message)
    BeginTextCommandThefeedPost('STRING')
    AddTextComponentSubstringPlayerName(text)
    EndTextCommandThefeedPostTicker(false, false)
end

function NN.Notify.help(message)
    BeginTextCommandDisplayHelp('STRING')
    AddTextComponentSubstringPlayerName(tostring(message))
    EndTextCommandDisplayHelp(0, false, false, -1)
end
