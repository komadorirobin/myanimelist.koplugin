package.path = "./?.lua;" .. package.path

local Core = require("mal_core")

local function eq(actual, expected, message)
    if actual ~= expected then
        error((message or "values differ") .. ": expected " .. tostring(expected) .. ", got " .. tostring(actual))
    end
end

eq(Core.normalizeSeries("Demon Slayer_ Kimetsu no Yaiba"), "demon slayer kimetsu no yaiba")
eq(Core.cleanSeriesName("Attack on Titan / #31", 31), "Attack on Titan")
eq(Core.volumeFromText("Attack on Titan, Vol. 27"), 27)
eq(Core.volumeFromText("Manga_Name-003"), 3)
eq(Core.extractAuthorizationCode("https://example.test/callback?code=hello%2Fworld&state=x"), "hello/world")
eq(Core.extractQueryParameter("https://example.test/callback?code=x&state=hello%20world", "state"), "hello world")
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

print("core tests passed")
