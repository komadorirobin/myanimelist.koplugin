#!/bin/sh
set -eu
cd "$(dirname "$0")/.."

LUA_BIN="$(command -v lua5.1 || command -v lua)"
LUAC_BIN="$(command -v luac5.1 || command -v luac)"

"$LUA_BIN" tests/_test_core.lua
"$LUA_BIN" tests/_test_hooks.lua
"$LUAC_BIN" -p _meta.lua main.lua mal_client.lua mal_core.lua mal_hooks.lua mal_updater.lua
