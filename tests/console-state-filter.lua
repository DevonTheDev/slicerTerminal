-- Exercise actual PlayerSay callbacks and exact-reference location packets.
return function(gmod, test, equal)
    local support = dofile("tests/console-locator-support.lua")(gmod)
    local states = {"setup", "unlinked", "unconfirmed"}
    local function contains(text, part)
        assert(text:find(part, 1, true), "Missing '" .. part .. "' in " .. text)
    end
    local function configured(env, owner, folder, name)
        local ent = env.console(owner)
        assert(env.configure(owner, ent, folder or "tools"))
        ent.SlicerInformation.name = name or "same"
        return ent
    end
    local function link(env, owner, ent, class)
        local door = env.entity(class or "func_door")
        owner.target = ent; equal(env.fire("PlayerSay", owner, "!setEntity"), "")
        owner.target = door; equal(env.fire("PlayerSay", owner, "!setEntity"), "")
        equal(ent.SlicerDoor, door)
        return door
    end
    local function matching(env, owner, state)
        if state == "setup" then return env.console(owner) end
        local ent = configured(env, owner)
        if state == "unconfirmed" then ent.SlicerDoor = env.entity("func_door") end
        return ent
    end
    local function request(env, owner, text)
        local chats, packets, outgoing = #owner.chats, #env.messages, env.outgoing
        local observers = {}
        for _, ent in ipairs(env.entities) do
            if ent:IsPlayer() and ent ~= owner then observers[ent] = #ent.chats end
        end
        equal(env.fire("PlayerSay", owner, text), "")
        equal(#env.messages, packets, "Inventory sent a packet"); equal(env.outgoing, outgoing)
        for ent, count in pairs(observers) do equal(#ent.chats, count, "Inventory exposed private output") end
        local messages, rows = {}, {}
        for index = chats + 1, #owner.chats do
            local line = owner.chats[index]
            assert(#line <= 255 and not line:find("[%z\1-\31\127]"), "Invalid chat line")
            messages[#messages + 1] = line
            if line:match("^[1-5]%. Console") then rows[#rows + 1] = line end
        end
        assert(#messages >= 1, "No private reply")
        return rows, messages
    end
    local function filtered(env, owner, state, page)
        return request(env, owner, "!listConsoles " .. (page or 1) .. " " .. state)
    end
    local function locate(env, owner, ent, row)
        local count = #env.messages
        equal(env.fire("PlayerSay", owner, "!locateConsole " .. (row or 1)), "")
        if not ent then equal(#env.messages, count, "Unavailable row sent location"); return end
        equal(#env.messages, count + 1)
        local packet = env.messages[#env.messages]
        equal(packet.name, "SlicerConsoleLocation"); equal(packet.player, owner)
        equal(packet.values[1], true); equal(packet.values[3].x, ent.position.x)
        return packet
    end

    test("filtered setup lists a live unconfigured console and excludes configured inventory", function()
        local env = support.server(); local owner = env.player()
        configured(env, owner, "data")
        local deferred = env.console(owner)
        local rows, messages = filtered(env, owner, "setup")
        equal(#rows, 1, "Setup filter must enumerate its matching console")
        contains(rows[1], "needs setup"); contains(messages[1], "setup")
        locate(env, owner, deferred)
    end)

    test("state grammar rejects malformed or huge input before number conversion and enumeration", function()
        local env = support.server(); local owner = env.player(); env.console(owner)
        local suffixes = {" setup", " unlinked", " unconfirmed", " 0 setup", " 01 setup", " -1 setup", " +1 setup",
            " 1.0 setup", " 1e1 setup", " ١ setup", "  1 setup", " 1  setup", " 1 setup ", " 1 setup extra",
            " 1 SETUP", " 1 Setup", " 1 unknown", " 1 set", " 1 unconfirmedx", " 10000000 setup",
            " 1 ", "\t1 setup", "\n1 setup", "\r1 setup", "\v1 setup", "\f1 setup", " 1\tsetup", " 1\nsetup",
            " 1 setup\0", " 1 setup\127", " 1 setup\194\133", " 1 setup\226\128\168", " 1 setup\226\128\169",
            " " .. string.rep("9", 200000) .. " setup", " 1 " .. string.rep("s", 200000)}
        local enumerate, convert = env.ents.FindByClass, env.tonumber
        for _, suffix in ipairs(suffixes) do
            request(env, owner, "!listConsoles")
            function env.ents.FindByClass() error("Malformed request enumerated entities") end
            function env.tonumber() error("Malformed request converted a number") end
            local rows, messages = request(env, owner, "!listConsoles" .. suffix)
            equal(#rows, 0); equal(#messages, 1); contains(messages[1], "Usage:")
            env.tonumber = convert; locate(env, owner)
            env.ents.FindByClass = enumerate
        end
        local rows, messages = filtered(env, owner, "setup", 9999999)
        equal(#rows, 0); contains(messages[1], "between 1 and 1"); contains(messages[1], "setup")
    end)

    test("state command near matches stay ordinary chat and preserve the last rows", function()
        local env = support.server(); local owner = env.player(); local ent = env.console(owner)
        request(env, owner, "!listConsoles")
        local chats = #owner.chats
        for _, text in ipairs({"!listConsolesNow 1 setup", "!listConsoles1 setup", "!listConsoles/1 setup",
            "!listconsoles 1 setup", "!LISTCONSOLES 1 setup", " !listConsoles 1 setup"}) do
            equal(env.fire("PlayerSay", owner, text), nil); equal(#owner.chats, chats)
        end
        locate(env, owner, ent)
    end)

    for _, kind in ipairs({"missing", "invalid", "non-player", "dead"}) do
        test("state filters safely consume " .. kind .. " callers", function()
            local env = support.server(); local owner = env.player(); env.console(owner)
            request(env, owner, "!listConsoles")
            local actor = owner
            if kind == "missing" then actor = nil elseif kind == "invalid" then owner.valid = false
            elseif kind == "non-player" then owner.class = "prop_physics" else owner.alive = false end
            local original = owner.ChatPrint
            function owner:ChatPrint() error("Ineligible caller got private output") end
            function env.ents.FindByClass() error("Ineligible caller enumerated") end
            for _, state in ipairs(states) do equal(env.fire("PlayerSay", actor, "!listConsoles 1 " .. state), "") end
            owner.ChatPrint, owner.valid, owner.class, owner.alive = original, true, "player", true
            if actor then locate(env, owner) end
        end)
    end

    test("state filters distinguish nil from every malformed nonnil configuration", function()
        local env = support.server(); local owner = env.player(); local setup = env.console(owner)
        for _, value in ipairs({false, 0, "tools", {}, {fileType = "tools"},
            {name = "bad", fileName = "file", fileType = "tools", delay = 0}}) do
            local ent = env.console(owner); ent.SlicerInformation = value
            ent.SlicerDoor = env.entity("func_door")
        end
        equal(#filtered(env, owner, "setup"), 1); locate(env, owner, setup)
        equal(#filtered(env, owner, "unlinked"), 0); equal(#filtered(env, owner, "unconfirmed"), 0)
        local rows, messages = request(env, owner, "!listConsoles 2")
        equal(#rows, 2); contains(messages[1], "7 total"); contains(rows[1], "invalid configuration")
    end)

    test("tools false door is nonnil unconfirmed while data and server legacy pointers never match", function()
        local env = support.server(); local owner = env.player()
        local tools = configured(env, owner); tools.SlicerDoor = false
        for _, folder in ipairs({"data", "server"}) do
            for _, pointer in ipairs({false, env.entity("func_door"), env.entity("prop_physics")}) do
                local ent = configured(env, owner, folder); ent.SlicerDoor = pointer
            end
            configured(env, owner, folder)
        end
        equal(#filtered(env, owner, "setup"), 0); equal(#filtered(env, owner, "unlinked"), 0)
        local rows = filtered(env, owner, "unconfirmed"); equal(#rows, 1)
        contains(rows[1], "previous door is no longer available"); locate(env, owner, tools)
    end)

    for _, class in ipairs({"func_door", "func_door_rotating"}) do
        test("tools filters distinguish nil removed unsupported mismatched and registered " .. class .. " links", function()
            local env = support.server(); local owner = env.player()
            local unlinked, deliberately = configured(env, owner), configured(env, owner)
            local relinquished = link(env, owner, deliberately, class)
            owner.target = deliberately; env.fire("PlayerSay", owner, "!unlinkConsole")
            equal(deliberately.SlicerDoor, nil); equal(relinquished.inputs[2], "Unlock")
            local removed = configured(env, owner); local old = link(env, owner, removed, class); old:Remove()
            local unsupported = configured(env, owner); unsupported.SlicerDoor = env.entity("prop_physics")
            local absent = configured(env, owner); absent.SlicerDoor = env.entity(class)
            local registered = configured(env, owner); local door = link(env, owner, registered, class)
            local mismatch = configured(env, owner); mismatch.SlicerDoor = door
            for _, folder in ipairs({"data", "server"}) do
                local data = configured(env, owner, folder); data.SlicerDoor = old
            end
            local rows = filtered(env, owner, "unlinked"); equal(#rows, 2)
            locate(env, owner, unlinked, 1); locate(env, owner, deliberately, 2)
            rows = filtered(env, owner, "unconfirmed"); equal(#rows, 4)
            contains(rows[1], "previous door is no longer available")
            for row, ent in ipairs({removed, unsupported, absent, mismatch}) do
                if row > 1 then contains(rows[row], "no registered link can be confirmed") end
                locate(env, owner, ent, row)
            end
            equal(#filtered(env, owner, "setup"), 0)
            equal(registered.SlicerDoor, door); equal(#door.inputs, 1); equal(#old.inputs, 1)
            equal(#relinquished.inputs, 2)
        end)
    end

    for _, state in ipairs(states) do
        for _, count in ipairs({0, 1, 5, 6, 12}) do
            test(state .. " filter paginates " .. count .. " matching rows before totals", function()
                local env = support.server(); local owner, observer = env.player(), env.player()
                local entities = {}
                for index = 1, count do
                    configured(env, owner, "data", "irrelevant")
                    entities[index] = matching(env, owner, state)
                    matching(env, observer, state)
                end
                local pages = math.ceil(count / 5)
                for page = 1, math.max(1, pages) do
                    local rows, messages = filtered(env, owner, state, page)
                    equal(#rows, math.min(5, math.max(0, count - (page - 1) * 5)))
                    contains(messages[1], state)
                    if count == 0 then equal(#messages, 1); locate(env, owner)
                    else
                        contains(messages[1], "page " .. page .. " of " .. pages); contains(messages[1], count .. " total")
                        for row = 1, #rows do locate(env, owner, entities[(page - 1) * 5 + row], row) end
                        if page < pages then contains(messages[#messages], "!listConsoles " .. (page + 1) .. " " .. state)
                        elseif page > 1 then contains(messages[#messages], "!listConsoles 1 " .. state) end
                    end
                end
                local rows, messages = filtered(env, owner, state, pages + 1)
                equal(#rows, 0); equal(#messages, 1); contains(messages[1], state); locate(env, owner)
                if count > 0 then contains(messages[1], "between 1 and " .. pages) end
            end)
        end
    end

    test("state filtering checks eligibility before all private reads and sorts only the result array", function()
        local env = support.server(); local owner, other = env.player(), env.player()
        local a, b, c = configured(env, owner), configured(env, owner), configured(env, owner)
        a.id, b.id, c.id = 10, 1, 1
        local foreign, ownerless, removed, wrong = env.console(other), env.console(owner), env.console(owner), env.console(owner)
        ownerless.SlicerCreator = nil; removed:Remove(); wrong.class = "prop_physics"
        for _, ent in ipairs({foreign, ownerless, removed, wrong}) do
            setmetatable(ent, {__index = function(_, key)
                if key == "SlicerInformation" or key == "SlicerDoor" then error("Ineligible private field read") end
            end})
        end
        local all = {a, foreign, c, removed, ownerless, wrong, b}
        function env.ents.FindByClass(class) equal(class, "consoleent"); return all end
        equal(#filtered(env, owner, "unlinked"), 3)
        locate(env, owner, b, 1); locate(env, owner, c, 2); locate(env, owner, a, 3)
        for _, state in ipairs({"setup", "unconfirmed"}) do equal(#filtered(env, owner, state), 0) end
        for index, ent in ipairs({a, foreign, c, removed, ownerless, wrong, b}) do equal(all[index], ent) end
    end)

    test("deferred unregistered pasted consoles are setup matches owned by their copier", function()
        local env = support.server(); local owner, copier = env.player(), env.player()
        local original = env.console(owner); local data = {}; original:OnEntityCopyTableFinish(data)
        local copy = setmetatable(env.entity("consoleent"), {__index = env.ENT})
        copy:Initialize(); copy:OnDuplicated(data); copy:PostEntityPaste(copier, copy, {})
        copy.position = support.vector(900, 0, 0); function copy:WorldSpaceCenter() return self.position end
        equal(#env.returnSpawnedEntities(), 0)
        equal(#filtered(env, copier, "setup"), 1); locate(env, copier, copy)
        equal(#filtered(env, owner, "setup"), 1); locate(env, owner, original)
    end)

    test("filtered list and literal name search replace the same snapshot without search state syntax", function()
        local env = support.server(); local owner, other = env.player(), env.player()
        local named = configured(env, owner, "data", "1 setup [a].%")
        local setup, unlinked = env.console(owner), configured(env, owner)
        local foreign = env.console(other); filtered(env, other, "setup")
        filtered(env, owner, "setup"); locate(env, owner, setup)
        request(env, owner, "!findConsoles 1 1 setup [a].%"); locate(env, owner, named)
        filtered(env, owner, "unlinked"); locate(env, owner, unlinked)
        request(env, owner, "!listConsoles"); locate(env, owner, named)
        request(env, owner, "!findConsoles 1 unlinked"); locate(env, owner)
        filtered(env, owner, "setup"); locate(env, other, foreign)
    end)

    for _, invalidation in ipairs({"removed", "owner", "class", "expiry", "death", "disconnect", "invalid", "empty", "range"}) do
        test("filtered snapshot rejects stale rows after " .. invalidation, function()
            local env = support.server(); local owner = env.player(); local ent = env.console(owner)
            filtered(env, owner, "setup")
            if invalidation == "removed" then ent:Remove(); local replacement = env.console(owner); replacement.id = ent.id
            elseif invalidation == "owner" then ent.SlicerCreator = env.player()
            elseif invalidation == "class" then ent.class = "prop_physics"
            elseif invalidation == "expiry" then env.now = 60
            elseif invalidation == "death" then env.fire("PlayerDeath", owner)
            elseif invalidation == "disconnect" then env.fire("PlayerDisconnected", owner)
            elseif invalidation == "invalid" then request(env, owner, "!listConsoles 1 Setup")
            elseif invalidation == "empty" then filtered(env, owner, "unlinked")
            else filtered(env, owner, "setup", 2) end
            locate(env, owner)
        end)
    end

    test("filtered exact rows survive setup name and link changes until their original expiry", function()
        local env = support.server(); local owner = env.player(); local ent = env.console(owner)
        filtered(env, owner, "setup"); env.now = 10
        assert(env.configure(owner, ent, "tools")); ent.SlicerInformation.name = "renamed"
        local door = link(env, owner, ent, "func_door_rotating")
        function env.ents.FindByClass() error("Locate must not rerun state filter") end
        env.now = 59.99; contains(locate(env, owner, ent).values[2], "renamed")
        ent.SlicerDoor = nil; locate(env, owner, ent)
        equal(#door.inputs, 1); env.now = 60; locate(env, owner)
    end)

    for _, newer in ipairs({"!listConsoles", "!listConsoles 1 unlinked", "!findConsoles 1 renamed", "!listConsoles 1 invalid"}) do
        test("prepared filtered rows keep nested newer request authoritative: " .. newer, function()
            local env = support.server(); local owner = env.player()
            local first, second = configured(env, owner, "tools", "before one"), configured(env, owner, "tools", "before two")
            local original, fired = owner.ChatPrint, false
            function owner:ChatPrint(text)
                original(self, text)
                if not fired then
                    fired = true; first:Remove(); second.SlicerInformation.name = "renamed"
                    function first:GetCreationID() error("Removed entity reread during output") end
                    equal(env.fire("PlayerSay", owner, newer), "")
                end
            end
            local rows = filtered(env, owner, "unlinked")
            local rendered = table.concat(rows, "\n")
            contains(rendered, "'before one'"); contains(rendered, "'before two'"); owner.ChatPrint = original
            if newer == "!listConsoles 1 invalid" then locate(env, owner) else locate(env, owner, second) end
            locate(env, owner, nil, 2)
        end)
    end

    test("filtered rows keep existing full names cleanup and inspection descriptions", function()
        local env = support.server(); local owner = env.player()
        local ent = configured(env, owner, "tools", string.rep("é", 64))
        local rows = filtered(env, owner, "unlinked"); contains(rows[1], string.rep("é", 64))
        ent.SlicerInformation.name = "front\0a\127b\194\133c\226\128\168d\226\128\169back"
        rows = filtered(env, owner, "unlinked"); contains(rows[1], "front?a?b?c?d?back")
        owner.target = ent; local count = #owner.chats; env.fire("PlayerSay", owner, "!inspectLink")
        equal(rows[1], "1. " .. owner.chats[count + 1])
        equal(ent.SlicerInformation.name, "front\0a\127b\194\133c\226\128\168d\226\128\169back")
    end)
end
