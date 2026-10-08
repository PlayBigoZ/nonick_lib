fx_version 'cerulean'
game 'gta5'
lua54 'yes'
name 'nonick_lib'
author 'NoNick'
version '1.0.1'
description 'NoNick shared library: DUI/tablet management, framework & inventory bridge, target adapter, utilities.'

-- This resource ships NO scripts of its own: it is a LIBRARY. Consumers load it
-- into their own Lua state by putting this FIRST in their manifest:
--
--   shared_scripts { '@nonick_lib/init.lua', ... }
--   dependencies  { 'nonick_lib' }
--
-- init.lua then pulls in the side-appropriate modules below and exposes the
-- global `NN` table (NN.Utils / NN.Dui / NN.Tablet / NN.Target / NN.Notify /
-- NN.Framework / NN.Inventory / NN.Money). Running inside the consumer's state
-- is what lets NN.Tablet register NUI callbacks against the consumer's ui_page.

-- files{} = what CLIENTS may download: init + client/shared modules only.
-- server/*.lua stays server-side (LoadResourceFile reads it from disk there).
files {
    'init.lua',
    'shared/*.lua',
    'client/*.lua'
}

-- CRITICAL for Keymaster: this library MUST stay plaintext. Consumers load its
-- modules via LoadResourceFile, which cannot read escrow-encrypted files — an
-- escrowed upload would break every resource that depends on it. Listing
-- everything here keeps the files readable even if escrow gets enabled.
escrow_ignore {
    'fxmanifest.lua',
    'init.lua',
    'README.md',
    'shared/*.lua',
    'client/*.lua',
    'server/*.lua'
}

-- The only scripts this resource runs itself: the update notice for the lib
-- (notify-only — configure in server/versioncheck.lua; owners can disable with
-- `setr nonick_lib_versioncheck 0`). version.lua must load first: it defines
-- the generic NN.Version.check helper the check (and consumers) use.
server_scripts {
    'server/version.lua',
    'server/versioncheck.lua'
}
