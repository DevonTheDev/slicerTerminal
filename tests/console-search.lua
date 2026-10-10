-- Real PlayerSay callbacks; search never grants authority by name or ID.
return function(gmod, test, equal)
    local support = dofile("tests/console-locator-support.lua")(gmod)
    local function contains(text, part)
        assert(text:find(part, 1, true), "Missing '" .. part .. "' in " .. text)
    end
    local function named(env, owner, name, folder)
        local ent = env.console(owner)
        local info = assert(env.configure(owner, ent, folder or "data"))
        info.name = name -- Saved-byte fixtures, including legacy/malformed records.
        return ent
    end
    local function say(env, owner, text) return env.fire("PlayerSay", owner, text) end
    local function search(env, owner, text)
        local chats, packets, outgoing = #owner.chats, #env.messages, env.outgoing
        local observers = {}
        for _, ent in ipairs(env.entities) do
            if ent:IsPlayer() and ent ~= owner then observers[ent] = #ent.chats end
        end
        equal(say(env, owner, text), "", "Search is consumed privately")
        equal(#env.messages, packets, "Search sends no packets"); equal(env.outgoing, outgoing)
        for ent, count in pairs(observers) do equal(#ent.chats, count, "Observer received search output") end
        local messages, rows = {}, {}
        for index = chats + 1, #owner.chats do
            local line = owner.chats[index]
            assert(#line <= 255 and not line:find("[%z\1-\31\127]"), "Invalid private chat line")
            messages[#messages + 1] = line
            if line:match("^[1-5]%. Console") then rows[#rows + 1] = line end
        end
        assert(#messages >= 1 and #messages <= 7, "Expected one bounded private page")
        return rows, messages
    end
    local function find(env, owner, query, page)
        return search(env, owner, "!findConsoles " .. (page or 1) .. " " .. query)
    end
    local function locate(env, owner, ent, row)
        local before = #env.messages
        equal(say(env, owner, "!locateConsole " .. (row or 1)), "")
        if not ent then equal(#env.messages, before, "Stale row sent a position"); return end
        equal(#env.messages, before + 1)
        local packet = env.messages[#env.messages]
        equal(packet.name, "SlicerConsoleLocation"); equal(packet.player, owner)
        equal(packet.values[1], true); equal(packet.values[3].x, ent.position.x)
        return packet
    end

    test("search matches only literal saved name bytes with ASCII case folding", function()
        local env = support.server(); local owner = env.player()
        local ent = named(env, owner, "REACTOR  west 2 [a].% \\\"Q\\\" \\path É é é Straße")
        for _, query in ipairs({"reactor", "REACTOR  WEST", "2", "[a].%", "\\\"Q\\\"", "\\path", "É", "é", "é", "Straße"}) do
            local rows = find(env, owner, query); equal(#rows, 1); locate(env, owner, ent)
        end
        for _, query in ipairs({"reactor west", "[b]", ".*", "STRASSE", "filename", "configured", "data", ent:GetName()}) do
            local rows, messages = find(env, owner, query); equal(#rows, 0); equal(#messages, 1)
            contains(messages[1], "!listConsoles"); locate(env, owner)
        end
        equal(ent.SlicerInformation.name, "REACTOR  west 2 [a].% \\\"Q\\\" \\path É é é Straße")
    end)

    test("search keeps non-ASCII case and composed versus decomposed names distinct", function()
        local env = support.server(); local owner = env.player()
        local upper, lower, decomposed = named(env, owner, "É"), named(env, owner, "é"), named(env, owner, "é")
        for _, pair in ipairs({{"É", upper}, {"é", lower}, {"é", decomposed}}) do
            equal(#find(env, owner, pair[1]), 1); locate(env, owner, pair[2])
        end
    end)

    test("search rejects malformed bounded grammar before enumeration or conversion", function()
        local env = support.server(); local owner = env.player()
        local ent = named(env, owner, "reactor")
        say(env, owner, "!listConsoles")
        function env.ents.FindByClass() error("Malformed input enumerated entities") end
        function env.tonumber() error("Malformed input converted a number") end
        local suffixes = {"", " ", " reactor", " 1", " 1 ", " 0 x", " 01 x", " -1 x", " +1 x", " 1.0 x",
            " 1e1 x", " ١ x", "  1 x", " 1  x", " 1 x ", "\t1 x", "\n1 x", "\r1 x", "\v1 x", "\f1 x",
            " 1\tx", " 10000000 x", " 1 " .. string.rep("x", 129), " " .. string.rep("9", 200000) .. " x"}
        for byte = 0, 31 do suffixes[#suffixes + 1] = " 1 a" .. string.char(byte) .. "b" end
        suffixes[#suffixes + 1] = " 1 a\127b"
        for byte = 128, 159 do suffixes[#suffixes + 1] = " 1 a\194" .. string.char(byte) .. "b" end
        suffixes[#suffixes + 1] = " 1 a\226\128\168b"; suffixes[#suffixes + 1] = " 1 a\226\128\169b"
        for _, suffix in ipairs(suffixes) do
            local rows, messages = search(env, owner, "!findConsoles" .. suffix)
            equal(#rows, 0); equal(#messages, 1); contains(messages[1], "Usage:")
        end
        env.tonumber = tonumber
        locate(env, owner) -- Even a syntax failure clears the earlier inventory.
        equal(ent.removed, nil)
    end)

    test("search near matches stay ordinary chat and retain previous rows", function()
        local env = support.server(); local owner = env.player(); local ent = named(env, owner, "reactor")
        say(env, owner, "!listConsoles")
        local chats = #owner.chats
        for _, text in ipairs({"!findConsolesNow", "!findConsoles1", "!findConsoles/2", "!findconsoles 1 reactor",
            "!FINDCONSOLES 1 reactor", " !findConsoles 1 reactor", "ordinary chat"}) do
            equal(say(env, owner, text), nil); equal(#owner.chats, chats)
        end
        locate(env, owner, ent)
    end)

    for _, kind in ipairs({"missing", "invalid", "non-player", "dead"}) do
        test("search safely consumes " .. kind .. " callers and clears their rows", function()
            local env = support.server(); local owner = env.player(); named(env, owner, "reactor")
            say(env, owner, "!listConsoles")
            local actor = owner
            if kind == "missing" then actor = nil
            elseif kind == "invalid" then owner.valid = false
            elseif kind == "non-player" then owner.class = "prop_physics"
            else owner.alive = false end
            local original = owner.ChatPrint
            function owner:ChatPrint() error("Invalid caller received output") end
            function owner:GetEyeTrace() error("Invalid caller traced") end
            function owner:GetActiveWeapon() error("Invalid caller weapon read") end
            function env.ents.FindByClass() error("Invalid caller enumerated") end
            local count = #env.messages
            for _, text in ipairs({"!findConsoles", "!findConsoles 1 reactor", "!findConsoles 01 x"}) do
                equal(say(env, actor, text), "")
            end
            equal(#env.messages, count)
            owner.ChatPrint, owner.valid, owner.class, owner.alive = original, true, "player", true
            if actor then locate(env, owner) end
        end)
    end

    for _, count in ipairs({0, 1, 5, 6, 12}) do
        test("search privately pages " .. count .. " matches with repeatable literal hints", function()
            local env = support.server(); local owner, other = env.player(), env.player()
            local query, matches = 'reactor  "2".%\\', {}
            for index = 1, count do matches[index] = named(env, owner, query .. index) end
            named(env, owner, "unrelated"); named(env, other, query)
            local pages = math.ceil(count / 5)
            for page = 1, math.max(1, pages) do
                local rows, messages = find(env, owner, query, page)
                equal(#rows, math.min(5, count - (page - 1) * 5))
                if count == 0 then
                    equal(#messages, 1); contains(messages[1], "!listConsoles")
                else
                    contains(messages[1], "page " .. page .. " of " .. pages); contains(messages[1], "(" .. count .. " matches)")
                    contains(messages[1], "!locateConsole <row>")
                    for row = 1, #rows do locate(env, owner, matches[(page - 1) * 5 + row], row) end
                    if page < pages then equal(messages[#messages], "Next page: !findConsoles " .. (page + 1) .. " " .. query)
                    elseif page > 1 then equal(messages[#messages], "First page: !findConsoles 1 " .. query) end
                end
            end
            local rows, messages = find(env, owner, query, 9999999)
            equal(#rows, 0); equal(#messages, 1)
            contains(messages[1], count == 0 and "!listConsoles" or "between 1 and " .. pages)
            locate(env, owner)
        end)
    end

    test("search admits 128-byte ASCII and multibyte queries and complete bounded names", function()
        local env = support.server(); local owner = env.player()
        for _, name in ipairs({string.rep("a", 128), string.rep("é", 64)}) do
            local first = named(env, owner, name)
            for _ = 1, 5 do named(env, owner, name) end
            local rows, messages = find(env, owner, name)
            equal(#rows, 5); contains(rows[1], "'" .. name .. "'")
            equal(messages[#messages], "Next page: !findConsoles 2 " .. name)
            locate(env, owner, first)
            rows, messages = find(env, owner, name, 9999999) -- 150-byte command is syntactically valid.
            equal(#rows, 0); contains(messages[1], "between 1 and 2")
        end
    end)

    test("search filters current ownership before reading names and sorts a separate matching array", function()
        local env = support.server(); local owner, other = env.player(), env.player()
        local a, b, c = named(env, owner, "same"), named(env, owner, "same"), named(env, owner, "same")
        a.id, b.id, c.id = 10, 0, 0
        local foreign, ownerless = env.console(other), env.console(owner)
        ownerless.SlicerCreator = nil
        for _, ent in ipairs({foreign, ownerless}) do
            setmetatable(ent, {__index = function(_, key) if key == "SlicerInformation" then error("Foreign name read") end end})
        end
        local removed, wrong = named(env, owner, "same"), named(env, owner, "same")
        removed:Remove(); wrong.class = "prop_physics"
        local all = {a, foreign, c, removed, ownerless, wrong, b}
        function env.ents.FindByClass(class) equal(class, "consoleent"); return all end
        local rows = find(env, owner, "SAME"); equal(#rows, 3)
        locate(env, owner, b, 1); locate(env, owner, c, 2); locate(env, owner, a, 3)
        for i, ent in ipairs({a, foreign, c, removed, ownerless, wrong, b}) do equal(all[i], ent) end
    end)

    test("search skips malformed names but includes named busy invalid and broken-link consoles", function()
        local env = support.server(); local owner = env.player()
        local expected = {}
        for _, folder in ipairs({"data", "server", "tools"}) do expected[#expected + 1] = named(env, owner, "target", folder) end
        expected[1].SlicerInformation.inUse = true
        local bad = named(env, owner, "target"); bad.SlicerInformation.delay = {}; expected[#expected + 1] = bad
        local broken = named(env, owner, "target", "tools")
        broken.SlicerDoor = env.entity("func_door"); broken.SlicerDoor:Remove(); expected[#expected + 1] = broken
        for _, name in ipairs({false, {}, 123, "", " \t ", string.rep("x", 129)}) do named(env, owner, name) end
        env.console(owner); local malformed = env.console(owner); malformed.SlicerInformation = "target"
        local rows = find(env, owner, "TARGET"); equal(#rows, 5)
        contains(rows[4], "invalid configuration"); contains(rows[5], "previous door is no longer available")
        for row, ent in ipairs(expected) do locate(env, owner, ent, row) end
    end)

    test("search uses saved control bytes rather than the sanitized display alias", function()
        local env = support.server(); local owner = env.player()
        local original = "front\0a\127b\194\133c\226\128\168d\226\128\169back"
        local ent = named(env, owner, original)
        local rows = find(env, owner, "front"); equal(#rows, 1); contains(rows[1], "front?a?b?c?d?back")
        equal(#find(env, owner, "?"), 0); equal(#find(env, owner, "back"), 1)
        equal(ent.SlicerInformation.name, original)
    end)

    test("fresh search and full inventory replace one snapshot without retaining a query", function()
        local env = support.server(); local owner, other = env.player(), env.player()
        local unnamed, first, second = env.console(owner), named(env, owner, "match"), named(env, owner, "match")
        local foreign = named(env, other, "match")
        find(env, other, "match"); find(env, owner, "match"); locate(env, owner, first)
        first.SlicerInformation.name = "renamed"; first.id = 999
        local packet = locate(env, owner, first); contains(packet.values[2], "renamed")
        find(env, owner, "match"); locate(env, owner, second)
        local third = named(env, owner, "match"); second:Remove()
        find(env, owner, "match"); locate(env, owner, third)
        say(env, owner, "!listConsoles"); locate(env, owner, unnamed)
        find(env, owner, "renamed"); locate(env, owner, first)
        locate(env, other, foreign)
        function env.ents.FindByClass() error("Locate must not rerun search") end
        locate(env, owner, first)
    end)

    for _, invalidation in ipairs({"removed", "owner", "class", "expired", "death", "disconnect", "invalid search", "empty search", "range search"}) do
        test("search snapshot refuses stale row after " .. invalidation, function()
            local env = support.server(); local owner = env.player(); local ent = named(env, owner, "target")
            find(env, owner, "target")
            if invalidation == "removed" then
                ent:Remove(); local replacement = named(env, owner, "target"); replacement.id = ent.id; replacement.position = ent.position
            elseif invalidation == "owner" then ent.SlicerCreator = env.player()
            elseif invalidation == "class" then ent.class = "prop_physics"
            elseif invalidation == "expired" then env.now = 60
            elseif invalidation == "death" then env.fire("PlayerDeath", owner)
            elseif invalidation == "disconnect" then env.fire("PlayerDisconnected", owner)
            elseif invalidation == "invalid search" then search(env, owner, "!findConsoles")
            elseif invalidation == "empty search" then find(env, owner, "missing")
            else find(env, owner, "target", 2) end
            locate(env, owner)
        end)
    end

    test("search snapshot lasts 60 seconds while clear leaves rows and cleanup releases references", function()
        local env = support.server(); local owner = env.player(); local ent = named(env, owner, "target")
        find(env, owner, "target"); env.now = 59.99; locate(env, owner, ent)
        say(env, owner, "!locateConsole clear"); equal(env.messages[#env.messages].values[1], false)
        locate(env, owner, ent); env.now = 60; locate(env, owner)
        find(env, owner, "target")
        local weak = setmetatable({ent}, {__mode = "v"})
        ent:Remove(); table.remove(env.entities, #env.entities); ent = nil
        collectgarbage("collect"); assert(weak[1], "Snapshot did not retain the reference")
        env.now = 125; env.fire("Think"); collectgarbage("collect"); equal(weak[1], nil)
    end)

    test("search prepares rows before chat mutation and lets reentrant requests supersede its snapshot", function()
        local env = support.server(); local owner = env.player()
        local first, second = named(env, owner, "target one"), named(env, owner, "target two")
        local original, fired = owner.ChatPrint, false
        function owner:ChatPrint(text)
            original(self, text)
            if not fired then
                fired = true; first:Remove(); second.SlicerInformation.name = "renamed"
                function first:GetCreationID() error("Removed entity reread during output") end
                equal(say(env, owner, "!findConsoles 1 renamed"), "")
            end
        end
        local rows = find(env, owner, "target")
        local rendered = table.concat(rows, "\n")
        contains(rendered, "'target one'"); contains(rendered, "'target two'"); contains(rendered, "'renamed'")
        owner.ChatPrint = original; locate(env, owner, second); locate(env, owner, nil, 2)
    end)
end
