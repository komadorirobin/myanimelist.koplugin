local lfs = require("libs/libkoreader-lfs")

local Core = require("mal_core")

local Scanner = {}

local BOOK_EXTENSIONS = {
    azw = true,
    azw3 = true,
    cb7 = true,
    cbr = true,
    cbt = true,
    cbz = true,
    djv = true,
    djvu = true,
    epub = true,
    fb2 = true,
    mobi = true,
    pdf = true,
}

local function normalizePath(path)
    return tostring(path or ""):gsub("\\", "/"):gsub("/+$", "")
end

local function dirname(path)
    return normalizePath(path):match("^(.*)/[^/]+$")
end

local function mode(path)
    local ok, value = pcall(lfs.attributes, path, "mode")
    return ok and value or nil
end

local function eachDirectory(path, callback)
    local ok, iterator, state = pcall(lfs.dir, path)
    if not ok or type(iterator) ~= "function" then return end
    for entry in iterator, state do
        if entry ~= "." and entry ~= ".." then callback(entry) end
    end
end

local function isInside(path, root)
    path, root = normalizePath(path), normalizePath(root)
    return path == root or path:sub(1, #root + 1) == root .. "/"
end

local function isBookFile(path)
    local extension = tostring(path or ""):lower():match("%.([^.]+)$")
    return extension and BOOK_EXTENSIONS[extension] == true or false
end

local function addDirectory(directories, seen, path, root)
    path = normalizePath(path)
    if path == "" or seen[path] or not isInside(path, root) or mode(path) ~= "directory" then return end
    seen[path] = true
    directories[#directories + 1] = path
end

local function findNamedDirectories(path, root, target_key, directories, seen, depth)
    if depth < 0 or mode(path) ~= "directory" then return end
    eachDirectory(path, function(entry)
        local child = normalizePath(path .. "/" .. entry)
        if mode(child) == "directory" then
            if Core.normalizeSeries(entry) == target_key then
                addDirectory(directories, seen, child, root)
            elseif depth > 0 and entry:sub(1, 1) ~= "." then
                findNamedDirectories(child, root, target_key, directories, seen, depth - 1)
            end
        end
    end)
end

local function collectBooks(path, files, seen, depth)
    if depth < 0 or mode(path) ~= "directory" then return end
    eachDirectory(path, function(entry)
        if entry:sub(1, 1) == "." then return end
        local child = normalizePath(path .. "/" .. entry)
        local child_mode = mode(child)
        if child_mode == "directory" and depth > 0 then
            collectBooks(child, files, seen, depth - 1)
        elseif child_mode == "file" and isBookFile(child) and not seen[child] then
            seen[child] = true
            files[#files + 1] = child
        end
    end)
end

function Scanner.findSeriesFiles(root, series_key, example_file)
    root = normalizePath(root)
    if root == "" or mode(root) ~= "directory" then return {}, "manga_root_unavailable" end

    local directories, seen_directories = {}, {}
    local example_directory = dirname(example_file)
    if example_directory and isInside(example_directory, root) then
        addDirectory(directories, seen_directories, example_directory, root)
    end

    -- Typical libraries keep each manga in a direct child of the manga root.
    -- A few extra levels cover category folders without scanning book metadata.
    findNamedDirectories(root, root, series_key, directories, seen_directories, 3)

    local files, seen_files = {}, {}
    for _, directory in ipairs(directories) do
        collectBooks(directory, files, seen_files, 6)
    end
    table.sort(files)
    return files
end

Scanner._test = {
    isBookFile = isBookFile,
    isInside = isInside,
}

return Scanner
