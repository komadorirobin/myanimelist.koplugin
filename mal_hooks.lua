local Hooks = {}
local unpack = unpack or table.unpack

local function notifyFiles(plugin, files)
    if type(files) ~= "table" then return end
    for key, value in pairs(files) do
        local file = type(key) == "string" and key or value
        if type(file) == "string" then plugin:onLocalStatusChanged(file) end
    end
end

local function resolveFile(doc_settings_or_file)
    if type(doc_settings_or_file) == "string" then return doc_settings_or_file end
    if type(doc_settings_or_file) == "table" and doc_settings_or_file.readSetting then
        local ok, file = pcall(doc_settings_or_file.readSetting, doc_settings_or_file, "doc_path")
        if ok then return file end
    end
    return nil
end

function Hooks.install(plugin)
    local ok_fm, fmutil = pcall(require, "apps/filemanager/filemanagerutil")
    if ok_fm and fmutil and not fmutil._myanimelist_status_patched then
        fmutil._myanimelist_status_patched = true
        local original_row = fmutil.genStatusButtonsRow
        if type(original_row) == "function" then
            fmutil.genStatusButtonsRow = function(doc_settings_or_file, callback, ...)
                local file = resolveFile(doc_settings_or_file)
                local wrapped = function(...)
                    if file then plugin:onLocalStatusChanged(file) end
                    if callback then return callback(...) end
                end
                return original_row(doc_settings_or_file, wrapped, ...)
            end
        end

        local original_multi = fmutil.genMultipleStatusButtonsRow
        if type(original_multi) == "function" then
            fmutil.genMultipleStatusButtonsRow = function(files, callback, ...)
                local wrapped = function(...)
                    notifyFiles(plugin, files)
                    if callback then return callback(...) end
                end
                return original_multi(files, wrapped, ...)
            end
        end
    end

    local ok_rs, ReaderStatus = pcall(require, "apps/reader/modules/readerstatus")
    if ok_rs and ReaderStatus and type(ReaderStatus.markBook) == "function"
            and not ReaderStatus._myanimelist_mark_patched then
        ReaderStatus._myanimelist_mark_patched = true
        local original = ReaderStatus.markBook
        ReaderStatus.markBook = function(instance, ...)
            local results = { original(instance, ...) }
            local file = instance.document and instance.document.file
            if file then plugin:onLocalStatusChanged(file) end
            return unpack(results)
        end
    end

    local ok_bsw, BookStatusWidget = pcall(require, "ui/widget/bookstatuswidget")
    if ok_bsw and BookStatusWidget and type(BookStatusWidget.onClose) == "function"
            and not BookStatusWidget._myanimelist_close_patched then
        BookStatusWidget._myanimelist_close_patched = true
        local original = BookStatusWidget.onClose
        BookStatusWidget.onClose = function(instance, ...)
            local updated = instance.updated
            local file = instance.ui and instance.ui.document and instance.ui.document.file
            if updated and file then
                local callback = instance.close_callback
                instance.close_callback = function(...)
                    plugin:onLocalStatusChanged(file)
                    if callback then return callback(...) end
                end
            end
            return original(instance, ...)
        end
    end

    local ok_bw, BookshelfWidget = pcall(require, "lib/bookshelf_widget")
    if ok_bw and BookshelfWidget and not BookshelfWidget._myanimelist_status_patched then
        BookshelfWidget._myanimelist_status_patched = true
        local original = BookshelfWidget._commitBookStatus
        if type(original) == "function" then
            BookshelfWidget._commitBookStatus = function(instance, book, status, ...)
                local results = { original(instance, book, status, ...) }
                if book and book.filepath then plugin:onLocalStatusChanged(book.filepath, status) end
                return unpack(results)
            end
        end
    end

    package.loaded.myanimelist_bridge = {
        notify = function(file, status) plugin:onLocalStatusChanged(file, status) end,
    }

    local registry_key = "bookshelf_folder_action_providers"
    local registry = package.loaded[registry_key]
    if type(registry) ~= "table" then
        registry = {}
        package.loaded[registry_key] = registry
    end
    registry.myanimelist = function(folder)
        return plugin:folderAction(folder)
    end

    local badge_registry_key = "bookshelf_folder_badge_providers"
    local badge_registry = package.loaded[badge_registry_key]
    if type(badge_registry) ~= "table" then
        badge_registry = {}
        package.loaded[badge_registry_key] = badge_registry
    end
    badge_registry.myanimelist = function(folder)
        return plugin:folderBadge(folder)
    end
end

return Hooks
