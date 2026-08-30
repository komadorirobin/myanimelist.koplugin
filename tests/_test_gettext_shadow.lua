local files = {
    "main.lua",
    "mal_async.lua",
    "mal_client.lua",
    "mal_core.lua",
    "mal_hooks.lua",
    "mal_scanner.lua",
    "mal_updater.lua",
}

for file_index, path in ipairs(files) do
    local handle = assert(io.open(path, "rb"))
    local source = handle:read("*a")
    handle:close()

    assert(not source:find("for%s+_,"), path .. " shadows gettext with a loop variable")
    assert(not source:find("for%s+_%s+in"), path .. " shadows gettext with a loop variable")
end

print("gettext shadow tests passed")
