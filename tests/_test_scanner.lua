package.path = "./?.lua;" .. package.path

local entries = {
    ["/library/Manga"] = { ".", "..", "Demon Slayer_ Kimetsu no Yaiba", "Other", "Localized Folder" },
    ["/library/Manga/Demon Slayer_ Kimetsu no Yaiba"] = { ".", "..", "Vol. 1.epub", "Vol. 2.cbz", "notes.jpg" },
    ["/library/Manga/Other"] = { ".", "..", "Other Vol. 1.epub" },
    ["/library/Manga/Localized Folder"] = { ".", "..", "Localized Vol. 1.epub" },
}

local modes = { ["/library/Manga"] = "directory" }
for path, names in pairs(entries) do
    modes[path] = "directory"
    for name_index, name in ipairs(names) do
        if name ~= "." and name ~= ".." then
            local child = path .. "/" .. name
            if entries[child] then
                modes[child] = "directory"
            elseif name:match("%.[^.]+$") then
                modes[child] = "file"
            end
        end
    end
end

package.preload["libs/libkoreader-lfs"] = function()
    return {
        attributes = function(path, attribute)
            if attribute == "mode" then return modes[path] end
            return modes[path] and { mode = modes[path] } or nil
        end,
        dir = function(path)
            local values = assert(entries[path], "unknown directory: " .. tostring(path))
            local index = 0
            return function()
                index = index + 1
                return values[index]
            end
        end,
    }
end

local Scanner = require("mal_scanner")
local files = Scanner.findSeriesFiles(
    "/library/Manga", "demon slayer kimetsu no yaiba", nil)

assert(#files == 2, "only supported books in the matching series folder should be returned")
assert(files[1]:match("Vol%. 1%.epub$"))
assert(files[2]:match("Vol%. 2%.cbz$"))

local linked_files = Scanner.findSeriesFiles(
    "/library/Manga", "metadata name that does not match", nil,
    "/library/Manga/Localized Folder")
assert(#linked_files == 1, "an explicitly linked folder must be scanned even when its name differs")
assert(linked_files[1]:match("Localized Vol%. 1%.epub$"))
assert(Scanner._test.isInside("/library/Manga/Series", "/library/Manga"))
assert(not Scanner._test.isInside("/library/Manga2/Series", "/library/Manga"))

print("scanner tests passed")
