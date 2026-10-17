-- Eight registered cases; all variants remain inside their frozen case IDs.
return function(gmod, test, equal)
    local H = dofile("tests/intel-archive-support.lua")(gmod, equal)
    local unavailable = "[name unavailable]"

    test("S1 immutable duplicate awards append newest first with safe raw-name projections", function()
        local env, owner, player = H.fixture()
        local first, source = H.award(env, owner, player, "Identical body", "data", "same", "same")
        local second = H.award(env, owner, player, "Identical body", "data", "same", "same")
        assert(first.values[1] ~= second.values[1])
        source.SlicerInformation.name, source.SlicerInformation.fileName = "changed", "changed"
        local list = H.ask(env, player, 1)
        equal(list.count, 2); equal(list.entries[1].award, second.values[1]); equal(list.entries[2].award, first.values[1])
        local old = H.ask(env, player, 2, first.values[1])
        equal(old.record.consoleName, "same"); equal(old.record.fileName, "same"); equal(old.record.body, "Identical body")
        env.now = env.now + 1; env.fire("PlayerSay", player, "!readIntel")
        equal(env.lastMessage("SlicerIntel").values[1], second.values[1])
        for _, names in ipairs({{"  café 日本語  ", "  café 日本語  "}, {"a\0b", unavailable},
            {"bad\255", unavailable}, {"line\nname", unavailable}, {"c1\194\128", unavailable}}) do
            local packet = H.award(env, owner, player, "Unchanged body", "server", names[1], names[1])
            equal(packet.values[2], names[1]); equal(packet.values[3], names[1], "Raw latest metadata remains immutable")
            list = H.ask(env, player, 1)
            equal(list.entries[1].award, packet.values[1]); equal(list.entries[1].consoleName, names[2])
            equal(list.entries[1].fileName, names[2])
            local read = H.ask(env, player, 2, packet.values[1])
            equal(read.record.consoleName, names[2]); equal(read.record.fileName, names[2]); equal(read.record.body, "Unchanged body")
        end
        equal(H.ask(env, player, 1).count, 7, "Unsupported names do not omit awards")
    end)

    test("S2 ten maximum bodies retain 40960 bytes and the eleventh evicts exactly the oldest", function()
        local env, owner, player = H.fixture()
        local awards, body = {}, string.rep("x", 4096)
        for i = 1, 10 do awards[i] = H.award(env, owner, player, body).values[1] end
        local list, total = H.ask(env, player, 1), 0
        equal(list.count, 10)
        for i = 1, 10 do
            equal(list.entries[i].award, awards[11 - i])
            total = total + #H.ask(env, player, 2, awards[i]).record.body
        end
        equal(total, 40960)
        awards[11] = H.award(env, owner, player, body).values[1]
        list = H.ask(env, player, 1); equal(list.count, 10)
        for i = 1, 10 do equal(list.entries[i].award, awards[12 - i]) end
        equal(H.ask(env, player, 2, awards[1]).status, 1)
        equal(H.ask(env, player, 2, awards[2]).record.body, body)
        env.now = env.now + 1; env.fire("PlayerSay", player, "!readIntel")
        equal(env.lastMessage("SlicerIntel").values[1], awards[11])
    end)

    test("S3 owned retained IDs and exact request byte budgets reject foreign malformed and omitted fields", function()
        local env, owner, player, stranger = H.fixture()
        local award = H.award(env, owner, player, "Private body").values[1]
        equal(H.ask(env, stranger, 1).count, 0)
        for _, id in ipairs({award, "99"}) do
            local reply, packet = H.ask(env, stranger, 2, id)
            equal(reply.status, 1); equal(reply.record, nil); assert(not packet.bytes:find("Private body", 1, true))
        end
        local untouched = env.player()
        local calls, original = 0, untouched.GetCreationID
        untouched.GetCreationID = function(self) calls = calls + 1; return original(self) end
        local valid = H.request(1, "1", "")
        local bad = {
            {H.request(0, "1", "")}, {H.request(3, "1", "")}, {H.request(1, "0", "")},
            {H.request(1, "01", "")}, {H.request(1, "9007199254740992", "")},
            {H.request(1, "1", "2")}, {H.request(2, "1", "")}, {H.request(2, "1", "01")},
            {H.request(2, "1", "9007199254740992")},
            {string.char(1) .. H.z("1")}, -- Required final empty-award NUL is absent.
            {string.char(1) .. "1"}, {""}, {valid:sub(1, -2)}, {valid .. "x"},
            {valid, #valid * 8 - 1}, {valid, #valid * 8 + 1}, {valid, (#valid + 1) * 8},
            {valid, (#valid - 1) * 8}, {string.rep("x", 36)},
        }
        local before = #env.messages
        for _, variant in ipairs(bad) do env.receiveBytes(H.requestName, untouched, variant[1], variant[2]) end
        equal(#env.messages, before); equal(calls, 0, "Malformed requests never reach state allocation/getters")
        for _, transform in ipairs({function(bytes) return bytes:sub(1, -2) end,
            function(bytes) return bytes .. "x" end, function() return nil end,
            function() error("modeled byte reader failure") end}) do
            env.archiveReadTransform = transform
            env.receiveBytes(H.requestName, untouched, valid)
            equal(#env.messages, before); equal(calls, 0)
        end
        env.archiveReadTransform = nil
        equal(H.ask(env, untouched, 1, nil, false).status, 0, "Rejected requests did not spend a throttle")
        equal(H.ask(env, player, 2, award).record.body, "Private body")
    end)

    test("S4 encoded list read and error bounds include real NUL fields with consistent safe projections", function()
        local env, owner, player = H.fixture()
        H.setAwardSerial(env, 9007199254740970)
        local name, body, latest = string.rep("é", 64), string.rep("b", 4096)
        for i = 1, 10 do latest = H.award(env, owner, player, body, "server", name, name) end
        local token = "9007199254740991"
        env.receiveBytes(H.requestName, player, H.request(1, token, ""))
        local packet = env.lastMessage(H.replyName)
        equal(packet.bytes, H.reply(1, token, 0, (function()
            local rows = {}; for i = 10, 1, -1 do rows[#rows + 1] = H.entry(string.format("%.0f", 9007199254740970 + i), name, name, "server") end
            return rows
        end)()))
        equal(#packet.bytes, 2780); assert(not packet.bytes:find(body, 1, true))
        local list = H.decode(packet.bytes); equal(list.count, 10)
        env.receiveBytes(H.requestName, player, H.request(2, token, latest.values[1]))
        packet = env.lastMessage(H.replyName)
        equal(packet.bytes, H.reply(2, token, 0, H.entry(latest.values[1], name, name, "server", body)))
        equal(#packet.bytes, 4392); equal(#H.request(2, token, latest.values[1]), 35)
        env.receiveBytes(H.requestName, player, H.request(2, token, latest.values[1]))
        packet = env.lastMessage(H.replyName); equal(#packet.bytes, 19)
        equal(packet.bytes, H.reply(2, token, 2)); equal(H.decode(packet.bytes).record, nil)
        env.now = env.now + 1
        env.receiveBytes(H.requestName, player, H.request(2, token, "9007199254740991"))
        equal(env.lastMessage(H.replyName).bytes, H.reply(2, token, 1))
        for _, raw in ipairs({"a\0b", "bad\255", "bad\127", "bad\194\159"}) do
            local award = H.award(env, owner, player, "Private projection body", "data", raw, raw)
            local projected = H.ask(env, player, 1).entries[1]
            local read = H.ask(env, player, 2, award.values[1]).record
            equal(projected.consoleName, unavailable); equal(projected.fileName, unavailable)
            equal(read.consoleName, projected.consoleName); equal(read.fileName, projected.fileName)
            equal(read.award, projected.award); equal(read.body, "Private projection body")
        end
    end)

    test("S5 player lifecycle generation and final-send reentry cannot leak captured records or clear replacements", function()
        for _, event in ipairs({"PlayerDisconnected", "PlayerInitialSpawn", "generation", "index"}) do
            local env, owner, player, stranger = H.fixture()
            local old = H.award(env, owner, player, "Old private").values[1]
            local other = H.award(env, owner, stranger, "Other private").values[1]
            H.ask(env, player, 1)
            if event == "generation" or event == "index" then
                local key = event == "generation" and "GetCreationID" or "EntIndex"
                local original = player[key]; player[key] = function(self) return original(self) + 1000 end
            else env.fire(event, player) end
            equal(H.ask(env, player, 2, old).status, 1)
            equal(H.ask(env, player, 1).count, 0)
            equal(H.ask(env, stranger, 2, other).record.body, "Other private")
        end
        for _, timing in ipairs({"getter", "serialization"}) do
            for _, replacement in ipairs({"state", "record"}) do
                local env, owner, player = H.fixture()
                local old = H.award(env, owner, player, "Captured old body").values[1]
                local newest, triggered, calls
                calls = 0
                local originalGetter, originalWrite = player.GetCreationID, env.net.WriteString
                local function replace()
                    if triggered then return end
                    triggered = true
                    player.GetCreationID, env.net.WriteString = originalGetter, originalWrite
                    local outgoing = env.outgoing
                    if replacement == "state" then env.fire("PlayerDisconnected", player) end
                    for i = 1, (replacement == "state" and 1 or 10) do
                        newest = H.award(env, owner, player, "Replacement " .. i).values[1]
                    end
                    env.outgoing = outgoing
                end
                if timing == "getter" then
                    player.GetCreationID = function(self)
                        calls = calls + 1
                        if calls == 3 then
                            replace()
                            if replacement == "state" then return originalGetter(self) + 1000 end
                        end
                        return originalGetter(self)
                    end
                else
                    env.net.WriteString = function(value)
                        originalWrite(value)
                        if value == "Captured old body" then replace() end
                    end
                end
                local before = #env.messages
                env.receiveBytes(H.requestName, player, H.request(2, "1", old))
                assert(triggered, "Required reentry seam was not exercised")
                equal(#H.packets(env, H.replyName, before + 1), 0, "Captured record must not reach Send")
                equal(H.ask(env, player, 2, newest).record.body, replacement == "state" and "Replacement 1" or "Replacement 10")
                equal(H.ask(env, player, 2, old).status, 1)
                equal(H.ask(env, player, 1).count, replacement == "state" and 1 or 10, "Stale cleanup preserved the replacement")
            end
        end
    end)

    test("S6 ordinary includes retain the full archive and monotonic awards while a fresh map starts empty", function()
        local env, owner, player = H.fixture()
        local first = H.award(env, owner, player, "First").values[1]
        local second = H.award(env, owner, player, "Second").values[1]
        for _, path in ipairs({"autorun/server/sv_slicer_intel.lua", "autorun/server/sv_config.lua", "entities/consoleent/init.lua"}) do env.include(path) end
        local list = H.ask(env, player, 1); equal(list.count, 2)
        equal(list.entries[1].award, second); equal(list.entries[2].award, first)
        equal(H.ask(env, player, 2, first).record.body, "First")
        local third = H.award(env, owner, player, "Third").values[1]
        assert(tonumber(third) > tonumber(second))
        local fresh, _, freshPlayer = H.fixture()
        equal(freshPlayer:GetCreationID(), player:GetCreationID())
        equal(H.ask(fresh, freshPlayer, 1).count, 0)
        equal(H.ask(fresh, freshPlayer, 2, first).status, 1)
    end)

    test("S7 list read and legacy chat throttles are independent and retry remains explicit", function()
        local env, owner, player, stranger = H.fixture()
        local award = H.award(env, owner, player, "Private").values[1]
        local at = env.now
        equal(H.ask(env, player, 1, nil, false).status, 0)
        equal(H.ask(env, player, 2, award, false).status, 0)
        local before = #H.packets(env, "SlicerIntel")
        env.fire("PlayerSay", player, "!readIntel"); equal(#H.packets(env, "SlicerIntel"), before + 1)
        for _, operation in ipairs({1, 2}) do
            local reply, packet = H.ask(env, player, operation, operation == 2 and award or nil, false)
            equal(reply.status, 2); assert(#packet.bytes <= 19); equal(reply.record, nil)
        end
        equal(H.ask(env, stranger, 1, nil, false).status, 0)
        env.now = at + 0.999; equal(H.ask(env, player, 1, nil, false).status, 2)
        env.now = at + 1; local messages = #env.messages
        equal(#env.messages, messages, "Advancing time alone does not retry")
        equal(H.ask(env, player, 1, nil, false).status, 0)
        equal(H.ask(env, player, 2, award, false).status, 0)
        env.fire("PlayerSay", player, "!readIntel"); equal(#H.packets(env, "SlicerIntel"), before + 2)
    end)

    test("S8 final exact award succeeds and exhaustion preserves all ten records and unconsumed console", function()
        local env, owner, player = H.fixture()
        local ids = {}
        for i = 1, 9 do ids[i] = H.award(env, owner, player, "Saved " .. i).values[1] end
        H.setAwardSerial(env, 9007199254740990)
        ids[10] = H.award(env, owner, player, "Final exact").values[1]
        equal(ids[10], "9007199254740991")
        local remaining = H.add(env, owner, "Cannot wrap")
        local completed = #H.packets(env, "SlicerCompleted")
        equal(H.finish(env, player, remaining), nil); equal(remaining.removed, nil)
        equal(remaining.SlicerInformation.inUse, false); equal(env.slicerIntel.GetBody(remaining), "Cannot wrap")
        equal(#H.packets(env, "SlicerCompleted"), completed)
        env.include("autorun/server/sv_slicer_intel.lua")
        equal(H.finish(env, player, remaining), nil); equal(remaining.removed, nil)
        local list = H.ask(env, player, 1); equal(list.count, 10)
        for i = 1, 10 do equal(list.entries[i].award, ids[11 - i]) end
        equal(H.ask(env, player, 2, ids[1]).record.body, "Saved 1")
        equal(H.ask(env, player, 2, ids[10]).record.body, "Final exact")
    end)
end
