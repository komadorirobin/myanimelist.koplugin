package.path = "./?.lua;" .. package.path

local Core = require("mal_core")

local function eq(actual, expected, message)
    if actual ~= expected then
        error((message or "values differ") .. ": expected " .. tostring(expected) .. ", got " .. tostring(actual))
    end
end

eq(Core.normalizeSeries("Demon Slayer_ Kimetsu no Yaiba"), "demon slayer kimetsu no yaiba")
eq(Core.isMangaPath("/storage/emulated/0/ePubs/Manga/Attack on Titan", "/storage/emulated/0/ePubs/Manga"), true)
eq(Core.isMangaPath("/sdcard/ePubs/Manga/Attack on Titan", "/storage/emulated/0/ePubs/Manga"), true,
    "a storage alias must still be recognized as manga")
eq(Core.isMangaPath("Manga/Attack on Titan/01.epub", "/storage/emulated/0/ePubs/Manga"), true,
    "relative Bookshelf paths must be recognized")
eq(Core.isMangaPath("/storage/emulated/0/ePubs/Fiktion/Book.epub", "/storage/emulated/0/ePubs/Manga"), false)
eq(Core.pathInside("/sdcard/ePubs/Manga/Series/02.epub",
    "/storage/emulated/0/ePubs/Manga/Series"), true,
    "linked folders must match Android storage aliases")
local folder_mapping = { mal_id = 42, local_folder = "/storage/emulated/0/ePubs/Manga/Localized Series" }
local found_mapping, found_key = Core.findMappingForFile({
    ["localized series"] = folder_mapping,
}, "different embedded metadata", "/sdcard/ePubs/Manga/Localized Series/02.epub")
eq(found_mapping, folder_mapping, "live sync must fall back to the explicitly linked folder")
eq(found_key, "localized series")
eq(Core.cleanSeriesName("Attack on Titan / #31", 31), "Attack on Titan")
eq(Core.volumeFromText("Attack on Titan, Vol. 27"), 27)
eq(Core.volumeFromText("Manga_Name-003"), 3)
eq(Core.mapLocalVolume(4, { omnibus = true, omnibus_size = 3, total_volumes = 37 }), 12)
eq(Core.mapLocalVolume(13, { omnibus = true, omnibus_size = 3, total_volumes = 37 }), 37,
    "a final partial omnibus must be capped at the official MAL total")
eq(Core.mapLocalVolume(37, { omnibus = true, omnibus_size = 3, total_volumes = 37 }), 37,
    "a final standalone volume must also be capped safely")
eq(Core.mapLocalVolume(13, { omnibus = false, omnibus_size = 3, total_volumes = 37 }), 13)
eq(Core.mapLocalVolume(1, {
    omnibus = true, omnibus_mode = "ratio",
    omnibus_local_count = 2, omnibus_mal_count = 5,
}), 2, "a partial 2-to-5 ratio must round down")
eq(Core.mapLocalVolume(2, {
    omnibus = true, omnibus_mode = "ratio",
    omnibus_local_count = 2, omnibus_mal_count = 5,
}), 5)
eq(Core.mapLocalVolume(3, {
    omnibus = true, omnibus_mode = "ratio",
    omnibus_local_count = 2, omnibus_mal_count = 5,
}), 7)
eq(Core.mapLocalVolume(6, {
    omnibus = true, omnibus_mode = "ratio",
    omnibus_local_count = 6, omnibus_mal_count = 10,
}), 10, "six Master Edition volumes must map to ten MAL volumes")
eq(Core.mapLocalVolume(7, {
    omnibus = true, omnibus_mode = "ratio",
    omnibus_local_count = 2, omnibus_mal_count = 5, total_volumes = 16,
}), 16, "ratio progress must be capped at MAL's official total")
local highest, matched = Core.finishedVolume(3, "attack on titan", {
    key = "attack on titan", volume = 21,
}, "complete")
eq(highest, 21, "finished scan should use the highest matching volume")
eq(matched, true)
highest, matched = Core.finishedVolume(highest, "attack on titan", {
    key = "another series", volume = 30,
}, "complete")
eq(highest, 21, "another series must not affect the scan")
eq(matched, false)
highest, matched = Core.finishedVolume(highest, "attack on titan", {
    key = "localized metadata name", volume = 22,
}, "complete", true)
eq(highest, 22, "an explicitly linked folder may use a different metadata series name")
eq(matched, true)
highest = Core.finishedVolume(highest, "attack on titan", {
    key = "attack on titan", volume = 22,
}, "reading")
eq(highest, 22, "unfinished volumes must not affect the scan")
eq(Core.extractAuthorizationCode("https://example.test/callback?code=hello%2Fworld&state=x"), "hello/world")
eq(Core.extractQueryParameter("https://example.test/callback?code=x&state=hello%20world", "state"), "hello world")
local token_form = Core.authorizationCodeForm({
    client_id = "client",
    client_secret = "secret",
    redirect_uri = "https://example.test/callback",
    pkce_verifier = "verifier",
}, "authorization-code")
eq(token_form.client_id, "client")
eq(token_form.client_secret, "secret")
eq(token_form.code, "authorization-code")
eq(token_form.code_verifier, "verifier")
eq(token_form.grant_type, "authorization_code")
eq(token_form.redirect_uri, nil, "MAL token exchange must not include redirect_uri")
local verifier = Core.newPkceVerifier(123)
eq(#verifier, 64, "PKCE verifier length")
assert(not verifier:find("[^A-Za-z0-9%-%._~]"), "PKCE verifier contains invalid characters")

local queued = Core.mergeQueue({ mal_id = 1, volumes_read = 8 }, { mal_id = 1, volumes_read = 6 })
eq(queued.volumes_read, 8, "queue must never regress")
queued = Core.mergeQueue(queued, { mal_id = 1, volumes_read = 9 })
eq(queued.volumes_read, 9)

local plan = Core.planUpdate({ volumes_read = 8 }, { num_volumes_read = 10, status = "reading" }, 12, 9)
eq(plan.volumes_read, 10, "remote progress must never regress")
eq(plan.changed, false)
plan = Core.planUpdate({ volumes_read = 12 }, { num_volumes_read = 10, status = "reading" }, 12, 10)
eq(plan.status, "completed")
eq(plan.changed, true)
plan = Core.planUpdate({ volumes_read = 39 }, { num_volumes_read = 36, status = "reading" }, 37, 36)
eq(plan.volumes_read, 37, "queued omnibus progress must be capped when MAL details arrive")
eq(plan.status, "completed")

print("core tests passed")
