-- Run the actual PlayerSay callbacks. Display IDs never grant ownership.
return function(gmod, test, equal)
    local function contains(message, fragment)
        assert(message:find(fragment, 1, true), "Missing '" .. fragment .. "' in: " .. message)
    end

    local function lacks(message, fragment)
        assert(not message:find(fragment, 1, true), "Unexpected '" .. fragment .. "' in: " .. message)
    end

    local function configured(env, owner, kind, name)
        local console = env.console(owner)
        env.receive("AdminFinishedCreation", owner,
            {name or "terminal", 2, kind or "tools", "secret", console:GetName()})
        assert(console.SlicerInformation, "Fixture configuration failed")
        return console
    end

    local function link(env, owner, console, class)
        local door = env.entity(class or "func_door")
        owner.target = console
        equal(env.fire("PlayerSay", owner, "!setEntity"), "")
        owner.target = door
        equal(env.fire("PlayerSay", owner, "!setEntity"), "")
        equal(console.SlicerDoor, door)
        return door
    end

    -- Keep the original tables, including aliased configuration/registry data.
    -- Only the requester's ChatPrint log may grow during this operation.
    local function snapshot(env, requester)
        local saved, seen = {}, {}
        local function visit(value)
            if type(value) ~= "table" or seen[value] then return end
            seen[value] = true
            local fields = {}
            saved[#saved + 1] = {value = value, fields = fields}
            for key, item in pairs(value) do
                if value ~= requester or key ~= "chats" then
                    fields[key] = item
                    visit(item)
                end
            end
        end
        visit(env.entities)
        visit(env.messages)
        visit(env.returnSpawnedEntities())
        local serial, outgoing, now = env.slicerSetupEditSerial, env.outgoing, env.now
        return function()
            equal(env.slicerSetupEditSerial, serial, "Listing changed edit authority")
            equal(env.outgoing, outgoing, "Listing started a network packet")
            equal(env.now, now, "Listing changed the clock")
            for _, record in ipairs(saved) do
                for key, value in pairs(record.fields) do
                    equal(record.value[key], value, "Listing changed a saved field: " .. tostring(key))
                end
                for key, value in pairs(record.value) do
                    if record.value ~= requester or key ~= "chats" then
                        equal(value, record.fields[key], "Listing added a field: " .. tostring(key))
                    end
                end
            end
        end
    end

    local function listing(env, owner, text)
        local before, unchanged = #owner.chats, snapshot(env, owner)
        equal(env.fire("PlayerSay", owner, text or "!listConsoles"), "", "Recognized command must be consumed")
        local messages, rows = {}, {}
        for i = before + 1, #owner.chats do
            local message = owner.chats[i]
            assert(#message <= 255, "ChatPrint exceeded 255 bytes: " .. #message)
            assert(not message:find("[%z\1-\31\127]"), "ChatPrint contains an ASCII control")
            messages[#messages + 1] = message
            if message:match("^Console.*%(current ID #") then rows[#rows + 1] = message end
        end
        assert(#messages > 0, "Living owner received no private result")
        assert(#rows <= 5, "More than five console rows on one page")
        unchanged()
        return messages, rows
    end

    local function sameMessages(actual, expected)
        equal(#actual, #expected)
        for i, message in ipairs(expected) do equal(actual[i], message) end
    end

    local function owned(env, owner, count)
        local consoles = {}
        for i = 1, count do consoles[i] = configured(env, owner, "data", "console" .. i) end
        return consoles
    end

    test("console listing consumes bare command with one clear empty private result", function()
        local env = gmod.new()
        local owner, observer = env.player(), env.player()
        local messages, rows = listing(env, owner)
        equal(#messages, 1); equal(#rows, 0)
        contains(messages[1], "no consoles")
        equal(#observer.chats, 0)
        sameMessages(listing(env, owner, "!listConsoles 2"), messages)
    end)

    test("console listing accepts explicit page one without a trace or weapon", function()
        local env = gmod.new()
        local owner, observer = env.player(), env.player()
        owner.weapon = nil
        function owner:GetEyeTrace() error("Listing must not trace") end
        function owner:GetActiveWeapon() error("Listing must not inspect weapons") end
        configured(env, owner, "data", "one")
        local messages, rows = listing(env, owner)
        equal(#rows, 1); contains(rows[1], "'one'")
        contains(messages[1], "page 1 of 1")
        equal(#messages, 2)
        sameMessages(listing(env, owner, "!listConsoles 1"), messages)
        equal(#observer.chats, 0)
    end)

    test("console listing privately rejects malformed decimal page grammar", function()
        local env = gmod.new()
        local owner = env.player()
        owned(env, owner, 6)
        function env.ents.FindByClass() error("Malformed page must not enumerate") end
        for _, suffix in ipairs({" ", " 0", " 01", " -1", " +1", " 1.0", " 1e1", " 1 ", " 1 2", "  1", " 10000000", " ١"}) do
            local messages, rows = listing(env, owner, "!listConsoles" .. suffix)
            equal(#messages, 1); equal(#rows, 0)
            contains(messages[1], "Usage:")
            contains(messages[1], "!listConsoles")
        end
    end)

    test("console listing recognizes whitespace prefixes but requires one ASCII space", function()
        local env = gmod.new()
        local owner = env.player()
        for _, suffix in ipairs({"\t1", "\n1", "\r1", "\v1", "\f1", " \t1"}) do
            local messages, rows = listing(env, owner, "!listConsoles" .. suffix)
            equal(#messages, 1); equal(#rows, 0); contains(messages[1], "Usage:")
        end
    end)

    test("console listing rejects enormous input before numeric conversion or enumeration", function()
        local env = gmod.new()
        local owner = env.player()
        function env.ents.FindByClass() error("Huge malformed input must not enumerate") end
        function env.tonumber() error("Huge malformed input must not convert") end
        local messages, rows = listing(env, owner, "!listConsoles " .. string.rep("9", 200000))
        equal(#messages, 1); equal(#rows, 0); contains(messages[1], "Usage:")
    end)

    test("console listing preserves near matches and differently cased ordinary chat", function()
        local env = gmod.new()
        local owner = env.player()
        for _, text in ipairs({"!listConsolesNow", "!listConsoles1", "!listConsoles/2", "!listconsoles", "!LISTCONSOLES 1", " !listConsoles", "hello"}) do
            local unchanged, count = snapshot(env, owner), #owner.chats
            equal(env.fire("PlayerSay", owner, text), nil)
            equal(#owner.chats, count); unchanged()
        end
    end)

    for _, actorKind in ipairs({"missing", "invalid", "non-player", "dead"}) do
        test("console listing consumes valid and malformed commands for a " .. actorKind .. " caller", function()
            local env = gmod.new()
            local actor
            if actorKind ~= "missing" then
                actor = env.player()
                if actorKind == "invalid" then actor.valid = false
                elseif actorKind == "non-player" then actor.class = "prop_physics"
                else actor.alive = false end
                function actor:ChatPrint() error("Invalid caller received output") end
                function actor:GetEyeTrace() error("Invalid caller was traced") end
            end
            function env.ents.FindByClass() error("Invalid caller enumerated entities") end
            for _, text in ipairs({"!listConsoles", "!listConsoles 2", "!listConsoles 0", "!listConsoles\t1"}) do
                equal(env.fire("PlayerSay", actor, text), "")
            end
        end)
    end

    for _, count in ipairs({5, 6, 12}) do
        test("console listing paginates " .. count .. " consoles in five-row pages", function()
            local env = gmod.new()
            local owner = env.player()
            owned(env, owner, count)
            local pages = math.ceil(count / 5)
            for page = 1, pages do
                local messages, rows = listing(env, owner, "!listConsoles " .. page)
                equal(#rows, math.min(5, count - (page - 1) * 5))
                contains(messages[1], "page " .. page .. " of " .. pages)
                contains(messages[1], "(" .. count .. " total)")
                for i, row in ipairs(rows) do contains(row, "'console" .. ((page - 1) * 5 + i) .. "'") end
                assert(#messages <= 7, "Page exceeded header, five rows and one hint")
                if page < pages then contains(messages[#messages], "!listConsoles " .. (page + 1)) end
            end
        end)
    end

    test("console listing gives range feedback without rows for high valid pages", function()
        local env = gmod.new()
        local owner = env.player()
        owned(env, owner, 6)
        for _, page in ipairs({3, 9999999}) do
            local messages, rows = listing(env, owner, "!listConsoles " .. page)
            equal(#messages, 1); equal(#rows, 0)
            contains(messages[1], "between 1 and 2")
            lacks(messages[1], "Usage:")
        end
    end)

    test("console listing sorts its copied enumeration by current creation ID and entity index", function()
        local env = gmod.new()
        local owner = env.player()
        local consoles = owned(env, owner, 6)
        local ids = {10, 2, 2, 0, 10000000, 7}
        for i, console in ipairs(consoles) do console.id = ids[i] end
        local enumeration = {consoles[5], consoles[3], consoles[1], consoles[6], consoles[4], consoles[2]}
        local original = {}; for i, console in ipairs(enumeration) do original[i] = console end
        local calls = 0
        env.ents.FindByClass = function(class)
            equal(class, "consoleent"); calls = calls + 1
            return enumeration
        end
        assert(consoles[2]:EntIndex() < consoles[3]:EntIndex(), "Fixture index must remain independent of IDs")
        local _, rows = listing(env, owner)
        for i, index in ipairs({4, 2, 3, 6, 1}) do contains(rows[i], "'console" .. index .. "'") end
        local _, finalRows = listing(env, owner, "!listConsoles 2")
        contains(finalRows[1], "'console5'")
        for i, console in ipairs(original) do equal(enumeration[i], console, "Listing sorted source array") end
        equal(calls, 2, "Each invocation needs fresh enumeration")
    end)

    test("console listing retains separate same-name consoles with colliding creation IDs", function()
        local env = gmod.new()
        local owner, other = env.player(), env.player()
        local first = configured(env, owner, "data", "same")
        local second = configured(env, owner, "server", "same")
        local foreign = configured(env, other, "tools", "same")
        first.id, second.id, foreign.id = 0, 0, 0
        env.ents.FindByClass = function() return {foreign, second, first} end
        local _, rows = listing(env, owner)
        equal(#rows, 2)
        contains(rows[1], "'same'"); contains(rows[1], "configured for data")
        contains(rows[2], "'same'"); contains(rows[2], "configured for server")
    end)

    test("console listing filters exact live ownership while including unregistered unconfigured consoles", function()
        local env = gmod.new()
        local owner, other = env.player(), env.player()
        local unconfigured = env.console(owner)
        local configuredConsole = configured(env, owner, "tools", "kept")
        local foreign = configured(env, other, "data", "hiddenforeign")
        local ownerless = env.entity("consoleent")
        local removed = configured(env, owner, "data", "hiddenremoved"); removed:Remove()
        local prop = env.entity("prop_physics"); prop.SlicerCreator = owner
        env.ents.FindByClass = function() return {foreign, false, ownerless, removed, prop, configuredConsole, unconfigured} end
        local messages, rows = listing(env, owner)
        equal(#rows, 2); contains(messages[1], "(2 total)")
        contains(rows[1], "needs setup"); contains(rows[2], "'kept'")
        equal(#other.chats, 0)
    end)

    test("console listing refreshes current names, additions and removals between invocations", function()
        local env = gmod.new()
        local owner = env.player()
        local consoles = owned(env, owner, 6)
        local _, before = listing(env, owner, "!listConsoles 2")
        contains(before[1], "'console6'")
        consoles[1]:Remove()
        consoles[6].SlicerInformation.name = "renamed"
        local messages, rows = listing(env, owner)
        equal(#rows, 5); contains(messages[1], "page 1 of 1")
        contains(rows[5], "'renamed'")
        configured(env, owner, "data", "new")
        local _, added = listing(env, owner, "!listConsoles 2")
        contains(added[1], "'new'")
    end)

    local states = {
        {label = "unconfigured", state = "needs setup", setup = function(env, owner) return env.console(owner) end},
        {label = "data", state = "configured for data", kind = "data"},
        {label = "server", state = "configured for server", kind = "server"},
        {label = "never linked busy", state = "has never been linked", alter = function(env, owner, console) console.SlicerInformation.inUse = true end},
        {label = "removed door", state = "previous door is no longer available", alter = function(env, owner, console) link(env, owner, console):Remove() end},
        {label = "unregistered brush door", state = "no registered link can be confirmed", alter = function(env, owner, console) console.SlicerDoor = env.entity("func_door") end},
        {label = "unsupported door", state = "no registered link can be confirmed", alter = function(env, owner, console) console.SlicerDoor = env.entity("prop_door_rotating") end},
        {label = "registered sliding door", state = "registered link to func_door (", alter = function(env, owner, console) link(env, owner, console) end},
        {label = "registered rotating door", state = "registered link to func_door_rotating (", alter = function(env, owner, console) link(env, owner, console, "func_door_rotating") end},
        {label = "lost registry after reload", state = "no registered link can be confirmed", alter = function(env, owner, console) link(env, owner, console); env.include("entities/consoleent/init.lua") end},
    }
    for _, state in ipairs(states) do
        test("console listing reuses complete inspection state: " .. state.label, function()
            local env = gmod.new()
            local owner = env.player()
            local console = state.setup and state.setup(env, owner) or configured(env, owner, state.kind)
            if state.alter then state.alter(env, owner, console) end
            owner.target = console
            equal(env.fire("PlayerSay", owner, "!inspectLink"), "")
            local expected = owner.chats[#owner.chats]
            local _, rows = listing(env, owner)
            equal(#rows, 1); equal(rows[1], expected)
            contains(rows[1], state.state)
        end)
    end

    test("console listing handles malformed saved configuration without replacing or normalizing it", function()
        local cases = {
            false, 7, "legacy", {},
            {name = "valid", delay = 2, fileType = "unknown", fileName = "file"},
            {name = "valid", delay = "later", fileType = "tools", fileName = "file"},
            {name = {}, delay = 2, fileType = "tools", fileName = "file"},
            {name = "   ", delay = 2, fileType = "tools", fileName = "file"},
            {name = string.rep("x", 129), delay = 2, fileType = "tools", fileName = "file"},
        }
        for _, saved in ipairs(cases) do
            local env = gmod.new()
            local owner = env.player()
            local console = env.console(owner); console.SlicerInformation = saved
            local _, rows = listing(env, owner)
            equal(#rows, 1); contains(rows[1], "invalid configuration")
            equal(console.SlicerInformation, saved)
        end
    end)

    for _, case in ipairs({{label = "ASCII", name = string.rep("n", 128)}, {label = "multibyte", name = string.rep("界", 42) .. "é"}}) do
        test("console listing keeps the full 128-byte " .. case.label .. " name within every message limit", function()
            local env = gmod.new()
            local owner = env.player()
            local console = configured(env, owner, "tools", case.name)
            local door = link(env, owner, console, "func_door_rotating")
            console.id, door.id = 10000000, 10000000
            local _, rows = listing(env, owner)
            contains(rows[1], "'" .. case.name .. "'")
            contains(rows[1], "registered link to func_door_rotating (current ID #10000000)")
            lacks(rows[1], "busy"); lacks(rows[1], "locked")
        end)
    end

    test("console listing sanitizes controls in a displayed name without changing saved bytes", function()
        local name = "a\0b\1c\9d\10e\13f\31g\127h\194\133i\226\128\168j\226\128\169k"
        local env = gmod.new()
        local owner = env.player()
        local console = configured(env, owner, "tools", name)
        local original = console.SlicerInformation.name
        local _, rows = listing(env, owner)
        contains(rows[1], "a?b?c?d?e?f?g?h?i?j?k")
        lacks(rows[1], "\194\133"); lacks(rows[1], "\226\128\168"); lacks(rows[1], "\226\128\169")
        equal(console.SlicerInformation.name, original)
    end)

    test("console listing leaves pending selection, saved data, busy sessions, network and doors intact", function()
        local env = gmod.new()
        local owner, hacker = env.player(), env.player()
        local active = configured(env, owner, "tools", "active")
        local door = link(env, owner, active)
        local pending = configured(env, owner, "tools", "pending")
        local idle = configured(env, owner, "data", "idle")
        env.open(hacker, active)
        owner.target = idle
        equal(env.fire("PlayerSay", owner, "!editConsole"), "")
        local token = env.lastMessage("SlicerSetupEditOpen").values[3]
        local _, rows = listing(env, owner)
        equal(#rows, 3); equal(owner.SlicerPendingConsole, pending)
        equal(env.slicerConsoleHasActiveSession(active), true)
        equal(active.SlicerInformation.inUse, true); equal(#door.inputs, 1)
        env.receive("SlicerSetupEditSave", owner, idle, token, {name = "changed", fileName = "file", delay = 2})
        equal(env.lastMessage("SlicerSetupEditReply").values[2].ok, true, "Listing retired a valid edit ticket")
        equal(idle.SlicerInformation.name, "changed")
        env.receive("playerQuitConsole", hacker)
        equal(active.SlicerInformation.inUse, false)
        equal(#door.inputs, 1)
    end)

    test("console listing prepares every page reply before a ChatPrint callback mutates entities", function()
        local env = gmod.new()
        local owner = env.player()
        local consoles = owned(env, owner, 6)
        local expected = listing(env, owner)
        local before, mutated = #owner.chats, false
        function owner:ChatPrint(message)
            self.chats[#self.chats + 1] = message
            if mutated then return end
            mutated = true
            for _, console in ipairs(consoles) do
                console.SlicerInformation.name = "changed"
                console.SlicerCreator = nil
                console.id = 0
                console:Remove()
                function console:GetCreationID() error("Output reread removed entity") end
            end
        end
        equal(env.fire("PlayerSay", owner, "!listConsoles"), "")
        local actual = {}; for i = before + 1, #owner.chats do actual[#actual + 1] = owner.chats[i] end
        sameMessages(actual, expected)
        assert(mutated, "Fixture never ran the output callback")
    end)
end
