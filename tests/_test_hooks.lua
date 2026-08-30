package.path = "./?.lua;" .. package.path

local calls = {}
local callbacks = 0
local plugin = {
    onLocalStatusChanged = function(_, file, status)
        calls[#calls + 1] = { file = file, status = status }
    end,
    folderAction = function(_, folder)
        return {
            text = "Link " .. folder.label,
            callback = function() callbacks = callbacks + 1 end,
        }
    end,
    folderBadge = function(_, folder)
        return { text = "★" .. folder.score }
    end,
}

local fmutil = {
    genStatusButtonsRow = function(_, callback)
        return function() return callback("single-result") end
    end,
    genMultipleStatusButtonsRow = function(_, callback)
        return function() return callback("multi-result") end
    end,
}
local ReaderStatus = {
    markBook = function() return "reader-result" end,
}
local BookStatusWidget = {
    onClose = function(instance)
        if instance.close_callback then instance.close_callback("close-result") end
        return "widget-result"
    end,
}
local BookshelfWidget = {
    _commitBookStatus = function() return "bookshelf-result" end,
}

package.preload["apps/filemanager/filemanagerutil"] = function() return fmutil end
package.preload["apps/reader/modules/readerstatus"] = function() return ReaderStatus end
package.preload["ui/widget/bookstatuswidget"] = function() return BookStatusWidget end
package.preload["lib/bookshelf_widget"] = function() return BookshelfWidget end

local Hooks = require("mal_hooks")
Hooks.install(plugin)

local single = fmutil.genStatusButtonsRow("/Manga/Series/01.epub", function(value)
    callbacks = callbacks + 1
    return value
end)
assert(single() == "single-result")

local multi = fmutil.genMultipleStatusButtonsRow({
    ["/Manga/Series/02.epub"] = true,
    "/Manga/Series/03.epub",
}, function(value)
    callbacks = callbacks + 1
    return value
end)
assert(multi() == "multi-result")

local reader_result = ReaderStatus.markBook({ document = { file = "/Manga/Series/04.epub" } })
assert(reader_result == "reader-result")

local close_callbacks = 0
local widget_result = BookStatusWidget.onClose({
    updated = true,
    ui = { document = { file = "/Manga/Series/05.epub" } },
    close_callback = function(value)
        close_callbacks = close_callbacks + 1
        assert(value == "close-result")
    end,
})
assert(widget_result == "widget-result")
assert(close_callbacks == 1)

local shelf_result = BookshelfWidget._commitBookStatus({}, {
    filepath = "/Manga/Series/06.epub",
}, "complete")
assert(shelf_result == "bookshelf-result")

package.loaded.myanimelist_bridge.notify("/Manga/Series/07.epub", "complete")
local folder_action = package.loaded.bookshelf_folder_action_providers.myanimelist({ label = "Series" })
assert(folder_action.text == "Link Series")
folder_action.callback()
local folder_badge = package.loaded.bookshelf_folder_badge_providers.myanimelist({ score = "8.72" })
assert(folder_badge.text == "★8.72")

local expected = {
    ["/Manga/Series/01.epub"] = true,
    ["/Manga/Series/02.epub"] = true,
    ["/Manga/Series/03.epub"] = true,
    ["/Manga/Series/04.epub"] = true,
    ["/Manga/Series/05.epub"] = true,
    ["/Manga/Series/06.epub"] = true,
    ["/Manga/Series/07.epub"] = true,
}
assert(callbacks == 3)
assert(#calls == 7, "expected seven hook notifications, got " .. tostring(#calls))
for call_index, call in ipairs(calls) do
    assert(expected[call.file], "unexpected file notification: " .. tostring(call.file))
    expected[call.file] = nil
end
assert(calls[6].status == "complete")
assert(calls[7].status == "complete")
for file in pairs(expected) do error("missing notification: " .. file) end

print("hook tests passed")
