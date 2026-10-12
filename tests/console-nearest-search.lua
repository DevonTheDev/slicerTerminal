-- State/name/proximity intersections through real PlayerSay and row handlers.
-- API doubles cover observable contracts, not native engine accessor atomicity.
return function(gmod, test, equal)
    local support = dofile("tests/console-locator-support.lua")(gmod)
    local states = {"unlinked", "unconfirmed", "linked", "reserved"}
    local function say(env, owner, text) return env.fire("PlayerSay", owner, text) end
    local function contains(text, part) assert(text:find(part, 1, true), "Missing " .. part .. " in " .. text) end
    local function position(entity, x, calls)
        entity.position = support.vector(x, 0, 0)
        function entity:GetPos()
            calls[self] = (calls[self] or 0) + 1
            return self.position
        end
    end
    local function fixture()
        local env = support.server()
        local owner, other, calls = env.player(), env.player(), {}
        position(owner, 0, calls); position(other, 0, calls)
        return env, owner, other, calls
    end
    local function link(env, owner, console, class)
        local door = env.entity(class or "func_door")
        owner.target = console; equal(say(env, owner, "!setEntity"), "")
        owner.target = door; equal(say(env, owner, "!setEntity"), "")
        equal(console.SlicerDoor, door)
        return door
    end
    local function named(env, owner, name, state, x, calls)
        local console = env.console(owner)
        assert(env.configure(owner, console, state == "reserved" and "data" or "tools"))
        console.SlicerInformation.name = name
        if state == "unconfirmed" then console.SlicerDoor = env.entity("func_door") end
        if state == "linked" then link(env, owner, console) end
        local hacker
        if state == "reserved" then hacker = env.player(); env.open(hacker, console); assert(env.slicerConsoleHasActiveSession(console)) end
        position(console, x or 1, calls)
        return console, hacker
    end
    local function request(env, owner, command)
        local before, packets, outgoing = #owner.chats, #env.messages, env.outgoing
        equal(say(env, owner, command), "")
        equal(#env.messages, packets, "Listing sent a network packet"); equal(env.outgoing, outgoing)
        local messages, rows = {}, {}
        for i = before + 1, #owner.chats do
            local line = owner.chats[i]
            assert(#line <= 255 and not line:find("[%z\1-\31\127]"), "Invalid private output")
            messages[#messages + 1] = line
            if line:match("^[1-5]%. Console") then rows[#rows + 1] = line end
        end
        assert(#messages > 0, "Missing private reply")
        return messages, rows
    end
    local function search(env, owner, state, query, page)
        return request(env, owner, "!nearConsoles " .. (page or 1) .. " " .. state .. " " .. query)
    end
    local function rowsAre(env, owner, rows, expected)
        equal(#rows, #expected)
        for i, console in ipairs(expected) do equal(env.slicerListedConsole(owner, i), console, "Wrong exact listed entity") end
        equal(env.slicerListedConsole(owner, #expected + 1), nil)
    end
    local function locate(env, owner, console, row)
        local packets = #env.messages
        equal(say(env, owner, "!locateConsole " .. (row or 1)), "")
        if not console then equal(#env.messages, packets, "Stale row sent a location"); return end
        equal(#env.messages, packets + 1)
        local packet = env.lastMessage("SlicerConsoleLocation")
        equal(packet.player, owner); equal(packet.values[3].x, console.position.x)
        return packet
    end

    for _, state in ipairs(states) do
        test("nearest name " .. state .. " intersects before position samples and retains literal page guidance", function()
            local env, owner, other, calls = fixture()
            local query, matches = '2 setup [a].%  "Q"\\', {}
            for i = 1, 7 do matches[i] = named(env, owner, query .. i, state, 100 - 10 * i, calls) end
            local excluded = {
                named(env, owner, "irrelevant", state, 0, calls),
                named(env, owner, query, state == "unlinked" and "unconfirmed" or "unlinked", 0, calls),
                named(env, other, query, state, 0, calls), env.console(owner),
            }
            for _, console in ipairs(excluded) do function console:GetPos() error("Nonmatching position sampled") end end
            local otherChats = #other.chats
            function owner:IsAdmin() return true end
            function owner:GetEyeTrace() error("Listing traced") end
            function owner:GetActiveWeapon() error("Listing read weapon") end
            local messages, rows = search(env, owner, state, query)
            equal(messages[1], "Your matching consoles (nearest-first request snapshot; " .. state .. "): page 1 of 2 (7 matches). Locate: !locateConsole <row>.")
            rowsAre(env, owner, rows, {matches[7], matches[6], matches[5], matches[4], matches[3]})
            equal(messages[#messages], "Next page: !nearConsoles 2 " .. state .. " " .. query)
            equal(calls[owner], 1)
            for _, console in ipairs(matches) do equal(calls[console], 1) end
            messages, rows = search(env, owner, state, query, 2)
            rowsAre(env, owner, rows, {matches[2], matches[1]})
            equal(messages[#messages], "First page: !nearConsoles 1 " .. state .. " " .. query)
            messages, rows = search(env, owner, state, query, 3)
            rowsAre(env, owner, rows, {}); equal(#messages, 1)
            equal(messages[1], "Search page must be between 1 and 2. Use !nearConsoles <page> " .. state .. " " .. query)
            messages, rows = search(env, owner, state, "missing")
            rowsAre(env, owner, rows, {})
            equal(messages[1], "No matching console names (" .. state .. ") for 'missing'. Use !nearConsoles 1 " .. state .. " for all in that state.")
            equal(#other.chats, otherChats)
        end)
    end

    for _, state in ipairs(states) do
        test("nearest name " .. state .. " accepts one through 128 literal bytes and the longest page", function()
            local env, owner, _, calls = fixture()
            for _, query in ipairs({"x", "1", "setup", "linked", "--reserved", '[a].%+*?()^$  "Q"\\', string.rep("a", 128), string.rep("é", 64)}) do
                local console = named(env, owner, query, state, 1, calls)
                local _, rows = search(env, owner, state, query)
                rowsAre(env, owner, rows, {console})
                local messages = search(env, owner, state, query, 9999999)
                equal(messages[1], "Search page must be between 1 and 1. Use !nearConsoles <page> " .. state .. " " .. query)
                console:Remove()
            end
            local query = string.rep("x", 128)
            local messages = search(env, owner, state, query)
            contains(messages[1], query); contains(messages[1], "!nearConsoles 1 " .. state)
        end)
    end

    test("nearest names use ASCII folding without patterns or Unicode normalization", function()
        local env, owner, _, calls = fixture()
        local names = {"É", "é", "é", "Straße", "[a].%", "REACTOR west"}
        local consoles = {}
        for i, name in ipairs(names) do consoles[i] = named(env, owner, name, "unlinked", i, calls) end
        for i, name in ipairs(names) do
            local _, rows = search(env, owner, "unlinked", name)
            rowsAre(env, owner, rows, {consoles[i]})
        end
        for _, query in ipairs({"STRASSE", ".*", "secret", "?"}) do
            local _, rows = search(env, owner, "unlinked", query); rowsAre(env, owner, rows, {})
        end
        local _, rows = search(env, owner, "unlinked", "reactor WEST"); rowsAre(env, owner, rows, {consoles[6]})
        local raw = "front\0a\127b\194\133c\226\128\168d\226\128\169back"
        local console = named(env, owner, raw, "unlinked", 1, calls)
        _, rows = search(env, owner, "unlinked", "front")
        rowsAre(env, owner, rows, {console}); contains(rows[1], "front?a?b?c?d?back")
        equal(console.SlicerInformation.name, raw)
    end)

    test("nearest name rejects malformed queries before conversion folding enumeration RNG and sampling", function()
        local env, owner, _, calls = fixture()
        named(env, owner, "target", "unlinked", 1, calls)
        request(env, owner, "!nearConsoles")
        local function forbidden() error("Rejected query accessed game state or converted/folded input") end
        env.tonumber, env.string.char, env.ents.FindByClass, owner.GetPos = forbidden, forbidden, forbidden, forbidden
        env.math = setmetatable({random = forbidden}, {__index = math})
        local suffixes = {" unlinked x", " 0 unlinked x", " 01 unlinked x", " -1 unlinked x", " +1 unlinked x",
            " 1.0 unlinked x", " 1e1 unlinked x", " ١ unlinked x", " 10000000 unlinked x", "  1 unlinked x",
            " 1  unlinked x", " 1 unlinked  x", " 1 unlinked x ", " 1 unlinked ", " 1 UNLINKED x",
            " 1 unknown x", " 1 unlinkedx x", "\t1 unlinked x", "\n1 unlinked x", " 1\tunlinked x",
            " 1 unlinked\tx", " 1 unlinked " .. string.rep("x", 129), " 1 unlinked " .. string.rep("é", 65),
            " " .. string.rep("9", 200000) .. " unconfirmed x", " 1 unlinked " .. string.rep("x", 200000)}
        for byte = 0, 31 do suffixes[#suffixes + 1] = " 1 unlinked a" .. string.char(byte) .. "b" end
        suffixes[#suffixes + 1] = " 1 unlinked a\127b"
        for byte = 128, 159 do suffixes[#suffixes + 1] = " 1 unlinked a\194" .. string.char(byte) .. "b" end
        suffixes[#suffixes + 1] = " 1 unlinked a\226\128\168b"
        suffixes[#suffixes + 1] = " 1 unlinked a\226\128\169b"
        for _, state in ipairs(states) do
            for _, suffix in ipairs(suffixes) do
                local messages, rows = request(env, owner, "!nearConsoles" .. suffix:gsub("unlinked", state))
                equal(#messages, 1); contains(messages[1], "Usage:"); rowsAre(env, owner, rows, {})
            end
        end
        equal(calls[owner], 1)
    end)

    test("nearest setup with a text tail explains why the name cannot match and clears rows", function()
        local env, owner, _, calls = fixture()
        local setup = env.console(owner); position(setup, 1, calls)
        request(env, owner, "!nearConsoles 1 setup")
        function env.ents.FindByClass() error("Setup query enumerated") end
        function owner:GetPos() error("Setup query sampled") end
        function env.tonumber() error("Setup query converted") end
        local messages, rows = search(env, owner, "setup", "reactor")
        equal(messages[1], "Usage: !nearConsoles <page> setup. Setup consoles have no saved name to search.")
        rowsAre(env, owner, rows, {})
    end)

    test("nearest name near matches remain ordinary chat without replacing or renewing rows", function()
        local env, owner, _, calls = fixture()
        local console = named(env, owner, "target", "unlinked", 1, calls)
        env.now = 7; search(env, owner, "unlinked", "target")
        local chats = #owner.chats
        env.now = 66.999
        for _, command in ipairs({"!nearConsolesMore 1 unlinked target", "!nearConsoles1 unlinked target", "!nearConsoles/1 unlinked target", " !nearConsoles 1 unlinked target", "!NEARCONSOLES 1 unlinked target"}) do
            equal(say(env, owner, command), nil); equal(#owner.chats, chats)
        end
        equal(calls[owner], 1); equal(env.slicerListedConsole(owner, 1), console)
        env.now = 67; equal(env.slicerListedConsole(owner, 1), nil)
    end)

    test("nearest named ties unavailable coordinates and overflow preserve deterministic tail order", function()
        local env, owner, _, calls = fixture()
        local consoles, ids = {}, {8, 2, 2, 1, 4, 3, 5}
        for i = 1, 7 do consoles[i] = named(env, owner, "target", "unlinked", 5, calls); consoles[i].id = ids[i] end
        consoles[4].position.x = 0 / 0; consoles[5].position.x = math.huge
        consoles[6].position = nil; consoles[7].position.x = 1e308
        local all = {consoles[3], consoles[1], consoles[6], consoles[4], consoles[7], consoles[2], consoles[5]}
        function env.ents.FindByClass() return all end
        local _, rows = search(env, owner, "unlinked", "target")
        rowsAre(env, owner, rows, {consoles[2], consoles[3], consoles[1], consoles[4], consoles[6]})
        equal(all[1], consoles[3]); equal(all[7], consoles[5]); equal(calls[owner], 1)
        for _, console in ipairs(consoles) do equal(calls[console], 1) end
        _, rows = search(env, owner, "unlinked", "target", 2); rowsAre(env, owner, rows, {consoles[5], consoles[7]})
    end)

    test("nearest name captures one origin and resamples movement only on the next request", function()
        local env, owner, _, calls = fixture()
        local first = named(env, owner, "target", "unlinked", 10, calls)
        local second = named(env, owner, "target", "unlinked", 20, calls)
        local get = first.GetPos
        function first:GetPos() owner.position.x = 100; return get(self) end
        local _, rows = search(env, owner, "unlinked", "target")
        rowsAre(env, owner, rows, {first, second}); equal(calls[owner], 1)
        _, rows = search(env, owner, "unlinked", "target")
        rowsAre(env, owner, rows, {second, first}); equal(calls[owner], 2)
    end)

    for _, failure in ipairs({"throws", "missing", "nonfinite"}) do
        test("nearest name " .. failure .. " origin retains exact bounded retry query and revokes rows", function()
            local env, owner, _, calls = fixture()
            local query = string.rep("é", 64)
            named(env, owner, query, "unconfirmed", 1, calls)
            search(env, owner, "unconfirmed", query)
            if failure == "throws" then function owner:GetPos() error("No origin") end
            elseif failure == "missing" then owner.position = nil else owner.position.x = math.huge end
            function env.ents.FindByClass() error("Unavailable origin enumerated") end
            local messages, rows = search(env, owner, "unconfirmed", query, 9999999)
            equal(messages[1], "Your position is unavailable. Retry: !nearConsoles 9999999 unconfirmed " .. query)
            rowsAre(env, owner, rows, {})
        end)
    end

    for _, kind in ipairs({"missing", "invalid", "non-player", "dead"}) do
        test("nearest name rejects " .. kind .. " actors before state reads or position access", function()
            local env, owner, _, calls = fixture()
            named(env, owner, "target", "unlinked", 1, calls); search(env, owner, "unlinked", "target")
            local actor = owner
            if kind == "missing" then actor = nil elseif kind == "invalid" then owner.valid = false
            elseif kind == "non-player" then owner.class = "prop_physics" else owner.alive = false end
            local before = #owner.chats
            function owner:GetPos() error("Ineligible origin sampled") end
            function env.ents.FindByClass() error("Ineligible actor enumerated") end
            equal(say(env, actor, "!nearConsoles 1 unlinked target"), ""); equal(#owner.chats, before)
            owner.valid, owner.class, owner.alive = true, "player", true
            if actor then equal(env.slicerListedConsole(owner, 1), nil) end
        end)
    end

    test("nearest named rows retain exact identity through rename movement replacement and all row actions", function()
        local env, owner, _, calls = fixture()
        local far = named(env, owner, "target", "unlinked", 20, calls)
        local near = named(env, owner, "target", "unlinked", 1, calls)
        env.now = 7; search(env, owner, "unlinked", "target")
        near.SlicerInformation.name = "renamed"; near.position.x = 100; far.position.x = 0
        local replacement = named(env, owner, "target", "unlinked", 0, calls); replacement.id = near.id
        function env.ents.FindByClass() error("Row action reran name/state/distance search") end
        env.now = 66.999; contains(locate(env, owner, near).values[2], "renamed")
        local first = #owner.chats + 1
        equal(say(env, owner, "!inspectConsole 1"), ""); contains(owner.chats[first], "renamed")
        equal(say(env, owner, "!editConsole 1"), ""); equal(env.lastMessage("SlicerSetupEditOpen").values[1], near)
        equal(say(env, owner, "!setEntity 1"), ""); equal(owner.SlicerPendingConsole, near)
        equal(far.SlicerDoor, nil); equal(replacement.SlicerDoor, nil); equal(calls[owner], 1)
        env.now = 67; equal(env.slicerListedConsole(owner, 1), nil); locate(env, owner)
    end)

    for _, invalidation in ipairs({"removed", "owner", "class", "expiry", "death", "disconnect", "invalid", "setup text", "empty", "range"}) do
        test("nearest name lease rejects stale rows after " .. invalidation, function()
            local env, owner, other, calls = fixture()
            local console = named(env, owner, "target", "unlinked", 1, calls)
            local foreign = named(env, other, "target", "unlinked", 2, calls)
            local _, rows = search(env, owner, "unlinked", "target"); rowsAre(env, owner, rows, {console})
            search(env, other, "unlinked", "target")
            if invalidation == "removed" then console:Remove(); named(env, owner, "target", "unlinked", 1, calls).id = console.id
            elseif invalidation == "owner" then console.SlicerCreator = other
            elseif invalidation == "class" then console.class = "prop_physics"
            elseif invalidation == "expiry" then env.now = 60
            elseif invalidation == "death" then env.fire("PlayerDeath", owner)
            elseif invalidation == "disconnect" then env.fire("PlayerDisconnected", owner)
            elseif invalidation == "invalid" then request(env, owner, "!nearConsoles 01 unlinked target")
            elseif invalidation == "setup text" then search(env, owner, "setup", "target")
            elseif invalidation == "empty" then search(env, owner, "unlinked", "missing")
            else search(env, owner, "unlinked", "target", 2) end
            locate(env, owner)
            local packets, selected = #env.messages, owner.SlicerPendingConsole
            equal(say(env, owner, "!editConsole 1"), ""); equal(#env.messages, packets)
            equal(say(env, owner, "!setEntity 1"), ""); equal(owner.SlicerPendingConsole, selected)
            if invalidation ~= "expiry" then locate(env, other, foreign) end
        end)
    end

    for _, newer in ipairs({"!nearConsoles 1 unlinked renamed", "!nearConsoles 1 unlinked missing", "!nearConsoles 1 setup x",
        "!nearConsoles 01 unlinked target", "!nearConsoles 2 unlinked renamed", "!listConsoles", "!findConsoles 1 renamed", "!listConsoles 1 unlinked renamed"}) do
        test("nearest name prepared output preserves newer request authority: " .. newer, function()
            local env, owner, _, calls = fixture()
            local first = named(env, owner, "target one", "unlinked", 1, calls)
            local second = named(env, owner, "target two", "unlinked", 2, calls)
            local chat, entered = owner.ChatPrint, false
            function owner:ChatPrint(message)
                chat(self, message)
                if not entered then
                    entered = true; equal(env.slicerListedConsole(self, 1), first)
                    first:Remove(); second.SlicerInformation.name = "renamed"
                    function first:GetCreationID() error("Removed row reread during prepared output") end
                    equal(say(env, self, newer), "")
                end
            end
            search(env, owner, "unlinked", "target")
            owner.ChatPrint = chat
            contains(table.concat(owner.chats, "\n"), "'target one'")
            contains(table.concat(owner.chats, "\n"), "'target two'")
            if newer:find("missing", 1, true) or newer:find("setup", 1, true) or newer:find("01", 1, true) or newer:find(" 2 ", 1, true) then locate(env, owner)
            else locate(env, owner, second) end
            locate(env, owner, nil, 2)
        end)
    end

    test("nearest named reserved uses the live session despite stale flags and retains released row identity", function()
        local env, owner, _, calls = fixture()
        local console, hacker = named(env, owner, "target", "reserved", 10, calls)
        local stale = named(env, owner, "target", "unlinked", 1, calls)
        console.SlicerInformation.inUse = false; stale.SlicerInformation.inUse = true
        console.SlicerInformation.delay = {}
        env.now = 7
        local _, rows = search(env, owner, "reserved", "TARGET"); rowsAre(env, owner, rows, {console})
        equal(calls[stale], nil)
        equal(say(env, hacker, "!quitConsole"), "")
        equal(env.slicerConsoleHasActiveSession(console), false)
        console.SlicerInformation.name = "renamed"
        named(env, owner, "target", "reserved", 1, calls).id = console.id
        env.now = 66.999; locate(env, owner, console)
        env.now = 67; locate(env, owner)
    end)

    test("nearest name fixed browse help advertises the exact state and text combination", function()
        local env, owner = fixture()
        local messages = request(env, owner, "!slicerHelp browse")
        contains(table.concat(messages, "\n"), "!nearConsoles <page> <state> <text>")
        contains(table.concat(messages, "\n"), "setup does not accept text")
    end)
end
