fx_version 'cerulean'
game 'gta5'
lua54 'yes'
name 'nonick_lib'
author 'NoNick'
version '1.0.1'
description 'NoNick shared library: DUI/tablet management, framework & inventory bridge, target adapter, utilities.'

files {
    'init.lua',
    'shared/*.lua',
    'client/*.lua'
}

escrow_ignore {
    'fxmanifest.lua',
    'init.lua',
    'README.md',
    'shared/*.lua',
    'client/*.lua',
    'server/*.lua'
}

server_scripts {
    'server/version.lua',
    'server/versioncheck.lua'
}
