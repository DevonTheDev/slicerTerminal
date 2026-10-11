-- Exercise the public chat handlers; rows authorize exact entities, never names.
return function(gmod, test, equal)
    local support = dofile("tests/console-locator-support.lua")(gmod)
    local function contains(text, part)
        assert(text:find(part, 1, true), "Missing '" .. part .. "' in " .. text)
    end
    local link
    local function named(env, owner, name, state, folder)
        local ent = env.console(owner)
        assert(env.configure(owner, ent, folder or "tools"))
        ent.SlicerInformation.name = name or "target"
        if state == "unconfirmed" then ent.SlicerDoor = env.entity("func_door") end
        if state == "linked" then link(env, owner, ent, "func_door") end
        return ent
    end
    local function say(env, owner, text) return env.fire("PlayerSay", owner, text) end
    local function request(env, owner, text)
        local chats, packets, outgoing = #owner.chats, #env.messages, env.outgoing
        local observers = {}
        for _, ent in ipairs(env.entities) do
            if ent:IsPlayer() and ent ~= owner then observers[ent] = #ent.chats end
        end
        equal(say(env, owner, text), "", "Command was not privately consumed")
        equal(#env.messages, packets, "Search sent a packet"); equal(env.outgoing, outgoing)
        for ent, count in pairs(observers) do equal(#ent.chats, count, "Observer received private search output") end
        local rows, messages = {}, {}
        for index = chats + 1, #owner.chats do
            local line = owner.chats[index]
            assert(#line <= 255 and not line:find("[%z\1-\31\127]"), "Invalid chat line")
            messages[#messages + 1] = line
            if line:match("^[1-5]%. Console") then rows[#rows + 1] = line end
        end
        assert(#messages >= 1, "Missing private reply")
        return rows, messages
    end
    local function search(env, owner, state, query, page)
        return request(env, owner, "!listConsoles " .. (page or 1) .. " " .. state .. " " .. query)
    end
    local function locate(env, owner, ent, row)
        local count = #env.messages
        equal(say(env, owner, "!locateConsole " .. (row or 1)), "")
        if not ent then equal(#env.messages, count, "Unavailable row sent a position"); return end
        equal(#env.messages, count + 1)
        local packet = env.messages[#env.messages]
        equal(packet.name, "SlicerConsoleLocation"); equal(packet.player, owner)
        equal(packet.values[1], true); equal(packet.values[3].x, ent.position.x)
        return packet
    end
    link = function(env, owner, ent, class)
        local door = env.entity(class)
        owner.target = ent; equal(say(env, owner, "!setEntity"), "")
        owner.target = door; equal(say(env, owner, "!setEntity"), "")
        equal(ent.SlicerDoor, door)
        return door
    end

    test("combined search intersects saved names with the selected current state", function()
        local env = support.server(); local owner = env.player()
        local unlinked = named(env, owner, "reactor west")
        local unconfirmed = named(env, owner, "reactor west", "unconfirmed")
        local linked = named(env, owner, "reactor west", "linked")
        named(env, owner, "unrelated"); named(env, owner, "unrelated", "unconfirmed")
        for _, pair in ipairs({{"unlinked", unlinked}, {"unconfirmed", unconfirmed}, {"linked", linked}}) do
            local rows, messages = search(env, owner, pair[1], "REACTOR")
            equal(#rows, 1, "Combined name/state request must return its one intersected match")
            contains(messages[1], pair[1]); contains(messages[1], "1 matches")
            locate(env, owner, pair[2])
        end
    end)

    test("combined query tails remain literal including numeric state flag and punctuation prefixes", function()
        local env = support.server(); local owner = env.player()
        for _, name in ipairs({"2 setup [a].%", "unlinked reactor", "unconfirmed reactor", "--setup 2", 'reactor  "Q".%\\path'}) do
            local ent = named(env, owner, name)
            equal(#search(env, owner, "unlinked", name), 1); locate(env, owner, ent)
            equal(#request(env, owner, "!findConsoles 1 " .. name), 1); locate(env, owner, ent)
        end
        equal(#search(env, owner, "unlinked", "reactor Q"), 0)
        equal(#search(env, owner, "unlinked", ".*"), 0)
        equal(#search(env, owner, "unlinked", "Secret"), 0) -- Not the saved file name.
    end)

    test("combined queries preserve Unicode distinctions and saved control bytes", function()
        local env = support.server(); local owner = env.player()
        for _, name in ipairs({"É", "é", "é", "Straße"}) do
            local ent = named(env, owner, name)
            equal(#search(env, owner, "unlinked", name), 1); locate(env, owner, ent)
        end
        equal(#search(env, owner, "unlinked", "STRASSE"), 0)
        local original = "front\0a\127b\194\133c\226\128\168d\226\128\169back"
        local ent = named(env, owner, original)
        local rows = search(env, owner, "unlinked", "front"); equal(#rows, 1)
        contains(rows[1], "front?a?b?c?d?back")
        owner.target = ent; local before = #owner.chats; say(env, owner, "!inspectLink")
        equal(rows[1], "1. " .. owner.chats[before + 1]); equal(ent.SlicerInformation.name, original)
        equal(#search(env, owner, "unlinked", "?"), 0)
    end)

    test("combined malformed grammar is bounded before conversion enumeration or folding", function()
        local env = support.server(); local owner = env.player(); named(env, owner)
        request(env, owner, "!listConsoles")
        function env.ents.FindByClass() error("Malformed request enumerated") end
        function env.tonumber() error("Malformed request converted") end
        function env.string.char() error("Malformed request folded") end
        local suffixes = {" unlinked x", " 0 unlinked x", " 01 unlinked x", " -1 unlinked x", " +1 unlinked x",
            " 1.0 unlinked x", " 1e1 unlinked x", " ١ unlinked x", " 10000000 unlinked x", "  1 unlinked x",
            " 1  unlinked x", " 1 unlinked  x", " 1 unlinked x ", " 1 unlinked ", " 1 UNLINKED x",
            " 1 unknown x", " 1 unlinkedx x", "\t1 unlinked x", "\n1 unlinked x", " 1\tunlinked x",
            " 1 unlinked\tx", " 1 unlinked " .. string.rep("x", 129),
            " " .. string.rep("9", 200000) .. " unconfirmed x", " 1 unlinked " .. string.rep("x", 200000)}
        for byte = 0, 31 do suffixes[#suffixes + 1] = " 1 unconfirmed a" .. string.char(byte) .. "b" end
        suffixes[#suffixes + 1] = " 1 unconfirmed a\127b"
        for byte = 128, 159 do suffixes[#suffixes + 1] = " 1 unconfirmed a\194" .. string.char(byte) .. "b" end
        suffixes[#suffixes + 1] = " 1 unconfirmed a\226\128\168b"
        suffixes[#suffixes + 1] = " 1 unconfirmed a\226\128\169b"
        -- Reuse the shared grammar matrix for the newly accepted state.
        local existing = #suffixes
        for i = 1, existing do
            local linked = suffixes[i]:gsub("unlinked", "linked"):gsub("unconfirmed", "linked"):gsub("UNLINKED", "LINKED")
            if linked ~= suffixes[i] then suffixes[#suffixes + 1] = linked end
        end
        for _, suffix in ipairs(suffixes) do
            local rows, messages = request(env, owner, "!listConsoles" .. suffix)
            equal(#rows, 0); equal(#messages, 1); contains(messages[1], "Usage:")
        end
        env.tonumber = tonumber; locate(env, owner)
    end)

    test("setup with a text tail explains the missing saved name without enumerating", function()
        local env = support.server(); local owner = env.player(); env.console(owner)
        request(env, owner, "!listConsoles 1 setup")
        function env.ents.FindByClass() error("Setup name request enumerated") end
        function env.tonumber() error("Setup name request converted") end
        local rows, messages = search(env, owner, "setup", "reactor")
        equal(#rows, 0); equal(#messages, 1); contains(messages[1], "Usage:")
        contains(messages[1], "no saved name"); contains(messages[1], "!listConsoles <page> setup")
        env.tonumber = tonumber; locate(env, owner)
    end)

    test("combined near matches remain ordinary chat and keep the exact prior rows", function()
        local env = support.server(); local owner = env.player(); local ent = named(env, owner)
        search(env, owner, "unlinked", "target"); locate(env, owner, ent)
        local chats = #owner.chats
        for _, text in ipairs({"!listConsolesNow 1 unlinked target", "!listConsoles1 unlinked target",
            "!listConsoles/1 unlinked target", " !listConsoles 1 unlinked target", "!LISTCONSOLES 1 unlinked target"}) do
            equal(say(env, owner, text), nil); equal(#owner.chats, chats)
        end
        locate(env, owner, ent)
    end)

    for _, kind in ipairs({"missing", "invalid", "non-player", "dead"}) do
        test("combined requests safely consume " .. kind .. " callers before private reads", function()
            local env = support.server(); local owner = env.player(); named(env, owner)
            request(env, owner, "!listConsoles")
            local actor, original = owner, owner.ChatPrint
            if kind == "missing" then actor = nil elseif kind == "invalid" then owner.valid = false
            elseif kind == "non-player" then owner.class = "prop_physics" else owner.alive = false end
            function owner:ChatPrint() error("Ineligible caller received output") end
            function owner:GetEyeTrace() error("Ineligible caller traced") end
            function owner:GetActiveWeapon() error("Ineligible caller weapon read") end
            function env.ents.FindByClass() error("Ineligible caller enumerated") end
            for _, text in ipairs({"!listConsoles 1 unlinked target", "!listConsoles 1 setup target", "!listConsoles 01 unconfirmed x", "!listConsoles 1 linked target"}) do
                equal(say(env, actor, text), "")
            end
            owner.ChatPrint, owner.valid, owner.class, owner.alive = original, true, "player", true
            if actor then locate(env, owner) end
        end)
    end

    for _, state in ipairs({"unlinked", "unconfirmed", "linked"}) do
        for _, count in ipairs({0, 1, 5, 6, 12}) do
            test(state .. " name search privately paginates " .. count .. " intersections with exact hints", function()
                local env = support.server(); local owner, other = env.player(), env.player()
                local query, matches = '2 setup [a].%  "Q"\\', {}
                for index = 1, count do matches[index] = named(env, owner, query .. index, state) end
                named(env, owner, "irrelevant", state); named(env, other, query, state)
                named(env, owner, query, state == "unlinked" and "unconfirmed" or "unlinked")
                local pages = math.ceil(count / 5)
                for page = 1, math.max(1, pages) do
                    local rows, messages = search(env, owner, state, query, page)
                    assert(#messages <= 7); equal(#rows, math.min(5, count - (page - 1) * 5))
                    contains(messages[1], state)
                    if count == 0 then
                        equal(#messages, 1); contains(messages[1], "No matching console names")
                        contains(messages[1], "!listConsoles 1 " .. state); locate(env, owner)
                    else
                        contains(messages[1], "page " .. page .. " of " .. pages)
                        contains(messages[1], "(" .. count .. " matches)"); contains(messages[1], "!locateConsole <row>")
                        for row = 1, #rows do locate(env, owner, matches[(page - 1) * 5 + row], row) end
                        if page < pages then
                            equal(messages[#messages], "Next page: !listConsoles " .. (page + 1) .. " " .. state .. " " .. query)
                        elseif page > 1 then equal(messages[#messages], "First page: !listConsoles 1 " .. state .. " " .. query) end
                    end
                end
                local rows, messages = search(env, owner, state, query, 9999999)
                equal(#rows, 0); equal(#messages, 1); contains(messages[1], state)
                if count > 0 then
                    contains(messages[1], "between 1 and " .. pages)
                    contains(messages[1], "!listConsoles <page> " .. state .. " <text>")
                end
                locate(env, owner)
            end)
        end
    end

    for _, state in ipairs({"unconfirmed", "linked"}) do
        test(state .. " combined 128-byte ASCII and multibyte queries accept the command boundary", function()
            local env = support.server(); local owner = env.player()
            for _, name in ipairs({string.rep("a", 128), string.rep("é", 64)}) do
                local first = named(env, owner, name, state)
                for _ = 1, 5 do named(env, owner, name, state) end
                local rows, messages = search(env, owner, state, name)
                equal(#rows, 5); contains(rows[1], "'" .. name .. "'")
                equal(messages[#messages], "Next page: !listConsoles 2 " .. state .. " " .. name)
                locate(env, owner, first)
                local command = "!listConsoles 9999999 " .. state .. " " .. name
                equal(#command, state == "unconfirmed" and 162 or 157) -- Longest state fills the ceiling.
                rows, messages = request(env, owner, command)
                equal(#rows, 0); contains(messages[1], "between 1 and 2")
            end
        end)
    end

    for _, class in ipairs({"func_door", "func_door_rotating"}) do
        test("combined AND filters preserve all existing " .. class .. " state predicates", function()
            local env = support.server(); local owner = env.player()
            local unlinked, deliberate = named(env, owner), named(env, owner)
            link(env, owner, deliberate, class); owner.target = deliberate; say(env, owner, "!unlinkConsole")
            local removed = named(env, owner); local old = link(env, owner, removed, class); old:Remove()
            local unsupported = named(env, owner); unsupported.SlicerDoor = env.entity("prop_physics")
            local absent = named(env, owner); absent.SlicerDoor = env.entity(class)
            local registered = named(env, owner); local door = link(env, owner, registered, class)
            local mismatch = named(env, owner); mismatch.SlicerDoor = door
            local falseDoor = named(env, owner); falseDoor.SlicerDoor = false
            for _, folder in ipairs({"data", "server"}) do named(env, owner, "target", nil, folder).SlicerDoor = old end
            for _, state in ipairs({"unlinked", "unconfirmed"}) do
                local bad = named(env, owner, "target", state); bad.SlicerInformation.delay = {}
                local rows = search(env, owner, state, "bad"); equal(#rows, 0)
            end
            local rows = search(env, owner, "unlinked", "TARGET"); equal(#rows, 2)
            locate(env, owner, unlinked); locate(env, owner, deliberate, 2)
            rows = search(env, owner, "unconfirmed", "target"); equal(#rows, 5)
            for row, ent in ipairs({removed, unsupported, absent, mismatch, falseDoor}) do locate(env, owner, ent, row) end
            contains(rows[1], "previous door is no longer available")
            contains(rows[2], "no registered link can be confirmed")
            rows = search(env, owner, "linked", "TARGET"); equal(#rows, 1)
            contains(rows[1], "registered link to " .. class); locate(env, owner, registered)
            equal(#door.inputs, 1); equal(#old.inputs, 1); equal(registered.SlicerDoor, door)
        end)
    end

    test("named malformed configuration stays findable but is excluded from combined states", function()
        local env = support.server(); local owner = env.player()
        local ent = named(env, owner, "broken settings"); ent.SlicerInformation.delay = {}
        equal(#request(env, owner, "!findConsoles 1 broken settings"), 1); locate(env, owner, ent)
        equal(#search(env, owner, "unlinked", "broken settings"), 0)
        ent.SlicerDoor = env.entity("func_door")
        equal(#search(env, owner, "unconfirmed", "broken settings"), 0)
    end)

    test("combined searches check ownership before private fields and retain stable collision ordering", function()
        local env = support.server(); local owner, other = env.player(), env.player()
        local a, b, c = named(env, owner), named(env, owner), named(env, owner)
        a.id, b.id, c.id = 10, 0, 0
        local foreign, ownerless, removed, wrong = env.console(other), env.console(owner), env.console(owner), env.console(owner)
        ownerless.SlicerCreator = nil; removed:Remove(); wrong.class = "prop_physics"
        for _, ent in ipairs({foreign, ownerless, removed, wrong}) do
            setmetatable(ent, {__index = function(_, key)
                if key == "SlicerInformation" or key == "SlicerDoor" then error("Ineligible private field read") end
            end})
        end
        local all = {a, foreign, c, removed, ownerless, wrong, b}
        function env.ents.FindByClass(class) equal(class, "consoleent"); return all end
        equal(#search(env, owner, "unlinked", "target"), 3)
        locate(env, owner, b); locate(env, owner, c, 2); locate(env, owner, a, 3)
        equal(#search(env, owner, "unconfirmed", "target"), 0)
        for _, ent in ipairs({a, b, c}) do link(env, owner, ent, "func_door_rotating") end
        equal(#search(env, owner, "linked", "TARGET"), 3)
        locate(env, owner, b); locate(env, owner, c, 2); locate(env, owner, a, 3)
        for index, ent in ipairs({a, foreign, c, removed, ownerless, wrong, b}) do equal(all[index], ent) end
    end)

    test("each combined page uses fresh names states ownership and entities", function()
        local env = support.server(); local owner = env.player(); local entries = {}
        for i = 1, 6 do entries[i] = named(env, owner) end
        equal(#search(env, owner, "unlinked", "target"), 5)
        entries[1].SlicerInformation.name = "renamed"; entries[2].SlicerDoor = env.entity("func_door")
        entries[3].SlicerCreator = env.player(); entries[4]:Remove()
        local added = named(env, owner)
        local rows, messages = search(env, owner, "unlinked", "target", 2)
        equal(#rows, 0); contains(messages[1], "between 1 and 1"); locate(env, owner)
        equal(#search(env, owner, "unlinked", "target"), 3)
        locate(env, owner, entries[5]); locate(env, owner, entries[6], 2); locate(env, owner, added, 3)
    end)

    test("combined and existing inventory commands replace one owner-specific row lease", function()
        local env = support.server(); local owner, other = env.player(), env.player()
        local plain = named(env, owner, "plain", nil, "data")
        local setup, target = env.console(owner), named(env, owner)
        local foreign = named(env, other); search(env, other, "unlinked", "target")
        for _, text in ipairs({"!listConsoles", "!findConsoles 1 plain", "!listConsoles 1 setup"}) do
            search(env, owner, "unlinked", "target"); locate(env, owner, target)
            request(env, owner, text); locate(env, owner, text == "!listConsoles 1 setup" and setup or plain)
        end
        search(env, owner, "unlinked", "target"); locate(env, other, foreign)
        request(env, owner, "!findConsoles"); locate(env, owner)
    end)

    for _, invalidation in ipairs({"removed", "owner", "class", "expiry", "death", "disconnect", "invalid", "setup text", "empty", "range"}) do
        test("combined leases refuse stale exact rows after " .. invalidation, function()
            local env = support.server(); local owner = env.player(); local ent = named(env, owner)
            search(env, owner, "unlinked", "target"); locate(env, owner, ent)
            if invalidation == "removed" then ent:Remove(); local replacement = named(env, owner); replacement.id = ent.id
            elseif invalidation == "owner" then ent.SlicerCreator = env.player()
            elseif invalidation == "class" then ent.class = "prop_physics"
            elseif invalidation == "expiry" then env.now = 60
            elseif invalidation == "death" then env.fire("PlayerDeath", owner)
            elseif invalidation == "disconnect" then env.fire("PlayerDisconnected", owner)
            elseif invalidation == "invalid" then request(env, owner, "!listConsoles 01 unlinked target")
            elseif invalidation == "setup text" then search(env, owner, "setup", "target")
            elseif invalidation == "empty" then search(env, owner, "unlinked", "missing")
            else search(env, owner, "unlinked", "target", 2) end
            locate(env, owner)
        end)
    end

    test("combined exact rows survive rename and relink until the original 60-second boundary", function()
        local env = support.server(); local owner = env.player(); local ent = named(env, owner)
        env.now = 7; search(env, owner, "unlinked", "target")
        env.now = 20; ent.SlicerInformation.name = "renamed"; local door = link(env, owner, ent, "func_door_rotating")
        function env.ents.FindByClass() error("Locate must not rerun either filter") end
        env.now = 66.999; contains(locate(env, owner, ent).values[2], "renamed")
        say(env, owner, "!locateConsole clear"); equal(env.messages[#env.messages].values[1], false)
        locate(env, owner, ent); equal(#door.inputs, 1)
        env.now = 67; locate(env, owner)
    end)

    for _, query in ipairs({"", " TARGET [a].%"}) do
        test("linked rows retain exact identity after unlink without renewing their lease" .. query, function()
            local env = support.server(); local owner = env.player()
            local ent = named(env, owner, "target [a].%", "linked")
            local door = ent.SlicerDoor
            env.now = 7; local rows = request(env, owner, "!listConsoles 1 linked" .. query)
            equal(#rows, 1); locate(env, owner, ent)
            env.now = 20; owner.target = ent; say(env, owner, "!unlinkConsole")
            equal(ent.SlicerDoor, nil); equal(#door.inputs, 2)
            local replacement = named(env, owner, "target [a].%", "linked"); replacement.id = ent.id
            ent.SlicerInformation.name = "renamed"
            function env.ents.FindByClass() error("Locate reran the linked filter") end
            env.now = 66.999; contains(locate(env, owner, ent).values[2], "renamed")
            env.now = 67; locate(env, owner)
            equal(#door.inputs, 2); equal(#replacement.SlicerDoor.inputs, 1)
        end)
    end

    for _, newer in ipairs({"!listConsoles", "!findConsoles 1 renamed", "!listConsoles 1 unlinked",
        "!listConsoles 1 unlinked renamed", "!listConsoles 1 setup x", "!listConsoles 1 unlinked missing"}) do
        test("combined prepared replies preserve nested request authority: " .. newer, function()
            local env = support.server(); local owner = env.player()
            local first, second = named(env, owner, "target one"), named(env, owner, "target two")
            local original, fired = owner.ChatPrint, false
            function owner:ChatPrint(text)
                original(self, text)
                if not fired then
                    fired = true; first:Remove(); second.SlicerInformation.name = "renamed"
                    function first:GetCreationID() error("Removed entity reread during output") end
                    equal(say(env, owner, newer), "")
                end
            end
            local rows = search(env, owner, "unlinked", "target")
            local rendered = table.concat(rows, "\n")
            contains(rendered, "'target one'"); contains(rendered, "'target two'")
            owner.ChatPrint = original
            if newer:find("setup", 1, true) or newer:find("missing", 1, true) then locate(env, owner)
            else locate(env, owner, second) end
            locate(env, owner, nil, 2)
        end)
    end
end
