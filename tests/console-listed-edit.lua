-- Real public chat/network/lifecycle callbacks. Entity and transport doubles do
-- not establish native GMod behavior or expose the private listing/ticket tables.
return function(gmod, test, equal)
    local support = dofile("tests/console-locator-support.lua")(gmod)
    local function say(env, owner, text) return env.fire("PlayerSay", owner, text) end
    local function list(env, owner, text) equal(say(env, owner, text or "!listConsoles"), "") end
    local function contains(text, part) assert(text:find(part, 1, true), "Missing " .. part .. " in " .. text) end
    local function fixture(count, folder)
        local env = support.server()
        local owner, other = env.player(), env.player()
        local consoles = {}
        for i = 1, count or 2 do
            consoles[i] = env.console(owner)
            assert(env.configure(owner, consoles[i], folder))
        end
        owner.target = consoles[1]
        function owner:GetEyeTrace() error("Listed editing must never use the eye trace") end
        return env, owner, other, consoles
    end
    local function open(env, owner, row, expected)
        local before, chats = #env.messages, #owner.chats
        local handled = say(env, owner, "!editConsole" .. (row and " " .. row or ""))
        equal(#env.messages, before + 1, "Listed edit must send one existing editor-open packet")
        equal(handled, "", "Recognized edit is consumed")
        equal(#owner.chats, chats)
        local packet = env.messages[#env.messages]
        equal(packet.name, "SlicerSetupEditOpen"); equal(packet.player, owner)
        equal(#packet.values, 4); equal(packet.values[1], expected); equal(packet.values[2], owner)
        equal(packet.values[4].fileType, expected.SlicerInformation.fileType)
        return packet.values[3], packet.values[4]
    end
    local function reject(env, owner, row, guidance)
        local before, chats = #env.messages, owner and #owner.chats or 0
        equal(say(env, owner, "!editConsole " .. row), "")
        equal(#env.messages, before, "Rejected row cannot open an editor or use eye-trace fallback")
        if guidance then
            equal(#owner.chats, chats + 1, "One private failure instruction")
            contains(owner.chats[#owner.chats], guidance)
        end
    end
    local function save(env, owner, console, token)
        env.receive("SlicerSetupEditSave", owner, console, token, {name = "updated", delay = 3, fileName = "new"})
        local reply = env.lastMessage("SlicerSetupEditReply")
        equal(reply.player, owner); equal(reply.values[1], token)
        return reply.values[2].ok
    end

    test("listed edit public callback opens the exact second same-name console", function()
        local env, owner, _, consoles = fixture()
        list(env, owner)
        local token, payload = open(env, owner, 2, consoles[2])
        equal(payload.name, "terminal"); equal(payload.fileName, "secret")
        equal(payload.displayIdentity.entityIndex, consoles[2]:EntIndex())
        equal(save(env, owner, consoles[2], token), true)
        equal(consoles[1].SlicerInformation.name, "terminal")
        equal(consoles[2].SlicerInformation.name, "updated")
    end)

    test("listed edit accepts all five exact rows while malformed edit text remains ordinary chat", function()
        local env, owner, _, consoles = fixture(5)
        list(env, owner)
        for row = 1, 5 do open(env, owner, row, consoles[row]) end
        local before, chats = #env.messages, #owner.chats
        for _, text in ipairs({"!editconsole 1", "!EditConsole 1", " !editConsole 1", "!editConsole ",
            "!editConsole 0", "!editConsole 6", "!editConsole 01", "!editConsole -1", "!editConsole +1",
            "!editConsole 1.0", "!editConsole  1", "!editConsole\t1", "!editConsole 1 ", "!editConsole 1\n",
            "!editConsole 1\0", "!editConsole 1 2", "!editConsole1", "!editConsoleNow", "!editConsole extra",
            "!editConsole " .. string.rep("1", 200000)}) do
            equal(say(env, owner, text), nil, "Malformed edit-like text passes through")
        end
        equal(#env.messages, before); equal(#owner.chats, chats)
        open(env, owner, 5, consoles[5])
    end)

    test("listed edit shares exact current page and search replacement with locator", function()
        local env, owner, other, consoles = fixture(7)
        local foreign = env.console(other); env.configure(other, foreign)
        list(env, owner)
        open(env, owner, 5, consoles[5])
        list(env, owner, "!listConsoles 2")
        open(env, owner, 1, consoles[6]); reject(env, owner, 3, "!listConsoles")
        consoles[3].SlicerInformation.name, consoles[7].SlicerInformation.name = "match", "match"
        list(env, owner, "!findConsoles 1 match")
        open(env, owner, 2, consoles[7])
        list(env, other)
        open(env, other, 1, foreign)
        open(env, owner, 1, consoles[3])
        equal(say(env, owner, "!locateConsole 2"), "")
        equal(env.lastMessage("SlicerConsoleLocation").values[3].x, consoles[7].position.x)
    end)

    for _, invalidation in ipairs({"!listConsoles 01", "!listConsoles 2", "!listConsoles 1 setup",
        "!listConsoles 1 reserved missing", "!listConsoles 1 Linked", "!findConsoles 1 missing",
        "!findConsoles 01 terminal", "!findConsoles 2 terminal", "!findConsoles 1 "}) do
        test("listed edit loses prior lease on recognized relisting " .. invalidation, function()
            local env, owner, _, consoles = fixture()
            list(env, owner); local token = open(env, owner, 2, consoles[2])
            list(env, owner, invalidation)
            reject(env, owner, 2, "!listConsoles")
            equal(save(env, owner, consoles[2], token), true, "Relisting does not revoke an existing editor")
        end)
    end

    test("listed edit never renews or consumes the lease and clear retains it until exact expiry", function()
        local env, owner, _, consoles = fixture()
        list(env, owner)
        local token = open(env, owner, 2, consoles[2])
        env.now = 59.99
        equal(say(env, owner, "!locateConsole clear"), "")
        equal(open(env, owner, 2, consoles[2]), token)
        equal(say(env, owner, "!locateConsole 2"), "")
        equal(open(env, owner, 2, consoles[2]), token)
        env.now = 60 -- No Think sweep: the access check itself must expire it.
        reject(env, owner, 2, "!listConsoles")
        local before = #env.messages
        equal(say(env, owner, "!locateConsole 2"), ""); equal(#env.messages, before)
        equal(save(env, owner, consoles[2], token), true, "Lease expiry does not revoke an open editor")
    end)

    test("listed edit preserves exact references after ID collisions shifts renaming and filter changes", function()
        local env, owner, _, consoles = fixture(3, "tools")
        consoles[1].id, consoles[2].id = 0, 0
        list(env, owner, "!findConsoles 1 terminal")
        consoles[1]:Remove()
        local replacement = env.console(owner); env.configure(owner, replacement); replacement.id = 0
        consoles[2].SlicerInformation.name = "renamed outside the search"
        open(env, owner, 2, consoles[2]); reject(env, owner, 1, "!listConsoles")
        list(env, owner, "!listConsoles 1 unlinked")
        local door = env.entity("func_door")
        function owner:GetEyeTrace() return {Entity = owner.target} end
        owner.target = consoles[2]; equal(say(env, owner, "!setEntity"), "")
        owner.target = door; equal(say(env, owner, "!setEntity"), "")
        equal(consoles[2].SlicerDoor, door)
        function owner:GetEyeTrace() error("Listed editing must never use the eye trace") end
        local token = open(env, owner, 1, consoles[2])
        equal(save(env, owner, consoles[2], token), true)
        open(env, owner, 1, consoles[2])
    end)

    for _, kind in ipairs({"removed", "reowned", "reclassified", "death", "disconnect"}) do
        test("listed edit rejects a row after " .. kind, function()
            local env, owner, other, consoles = fixture()
            list(env, owner)
            if kind == "removed" then consoles[2]:Remove()
            elseif kind == "reowned" then consoles[2].SlicerCreator = other
            elseif kind == "reclassified" then consoles[2].class = "prop_physics"
            elseif kind == "death" then env.fire("PlayerDeath", owner)
            else env.fire("PlayerDisconnected", owner) end
            reject(env, owner, 2, "!listConsoles")
        end)
    end

    for _, kind in ipairs({"missing", "invalid", "non-player", "dead"}) do
        test("listed edit rejects " .. kind .. " actors without trace or output", function()
            local env, owner = fixture(); list(env, owner)
            if kind == "missing" then owner = nil
            elseif kind == "invalid" then owner.valid = false
            elseif kind == "non-player" then owner.class = "prop_physics"
            else owner.alive = false end
            if owner then function owner:ChatPrint() error("Invalid actor output") end end
            reject(env, owner, 1)
        end)
    end

    for _, kind in ipairs({"setup", "non-normalized", "missing registry", "duplicate registry", "wrong registry",
        "busy flag", "actual reservation"}) do
        test("listed edit keeps existing authority for " .. kind, function()
            local env, owner, hacker, consoles = fixture()
            local console = consoles[2]
            if kind == "setup" then console = env.console(owner) end
            list(env, owner)
            if kind == "non-normalized" then console.SlicerInformation.name = " Not Normalized "
            elseif kind == "missing registry" then
                for key, entry in pairs(env.spawnedEntities) do if entry.entity == console then env.spawnedEntities[key] = nil end end
            elseif kind == "duplicate registry" then
                env.spawnedEntities[#env.spawnedEntities + 1] = {entity = console, entityName = console:GetName(), information = console.SlicerInformation}
            elseif kind == "wrong registry" then
                for _, entry in pairs(env.spawnedEntities) do if entry.entity == console then entry.entityName = "wrong" end end
            elseif kind == "busy flag" then console.SlicerInformation.inUse = true
            elseif kind == "actual reservation" then env.open(hacker, console); env.updateInUse(console:GetName(), false) end
            reject(env, owner, kind == "setup" and 3 or 2, "configured, idle")
            if kind == "actual reservation" then
                env.now = 4; env.receive("destroyOnServer", hacker, console)
                equal(console.removed, true, "The rejected edit preserves the actual hacking session")
            end
        end)
    end

    test("listed edit fails closed for absent or nonfunction dynamic helper while bare edit works", function()
        local env, owner, _, consoles = fixture()
        list(env, owner)
        local resolve = assert(env.slicerListedConsole, "Shared row resolver must exist")
        for _, replacement in ipairs({false, "not a function", {}}) do
            env.slicerListedConsole = replacement
            reject(env, owner, 2, "!listConsoles")
        end
        env.slicerListedConsole = nil; reject(env, owner, 2, "!listConsoles")
        function owner:GetEyeTrace() return {Entity = consoles[1]} end
        local token = open(env, owner, nil, consoles[1])
        env.slicerListedConsole = resolve
        open(env, owner, 2, consoles[2])
        equal(open(env, owner, 1, consoles[1]), token)
    end)

    test("shared row resolver validates integer bounds living player and current entity without granting edits", function()
        local env, owner, _, consoles = fixture()
        list(env, owner)
        local resolve = assert(env.slicerListedConsole)
        local before = #env.messages
        for _, row in ipairs({0, 6, -1, 1.5, "1", false, {}, math.huge, 0/0}) do equal(resolve(owner, row), nil) end
        equal(resolve(owner, nil), nil); equal(resolve(nil, 1), nil)
        equal(resolve(owner, 2), consoles[2]); equal(#env.messages, before)
        owner.alive = false; equal(resolve(owner, 2), nil)
        owner.alive = true; reject(env, owner, 2, "!listConsoles")
    end)

    test("config reinclude retains listing dynamically but retires tickets with monotonic serial", function()
        local env, owner, _, consoles = fixture()
        list(env, owner); local token = open(env, owner, 2, consoles[2])
        env.include("autorun/server/sv_config.lua")
        equal(save(env, owner, consoles[2], token), false)
        local replacement = open(env, owner, 2, consoles[2])
        assert(tonumber(replacement) > tonumber(token))
        equal(save(env, owner, consoles[2], replacement), true)
    end)

    test("entity init reinclude replaces listing closure and retires tickets", function()
        local env, owner, _, consoles = fixture()
        list(env, owner); local token = open(env, owner, 2, consoles[2])
        local resolve = env.slicerListedConsole
        env.include("entities/consoleent/init.lua")
        assert(env.slicerListedConsole ~= resolve)
        reject(env, owner, 2, "!listConsoles")
        equal(save(env, owner, consoles[2], token), false)
        list(env, owner)
        local replacement = open(env, owner, 2, consoles[2])
        assert(tonumber(replacement) > tonumber(token))
    end)

    test("listed entry reuses bare tickets and replaces changed snapshots without reviving them", function()
        local env, owner, _, consoles = fixture()
        function owner:GetEyeTrace() return {Entity = consoles[2]} end
        local token = open(env, owner, nil, consoles[2])
        list(env, owner)
        equal(open(env, owner, 2, consoles[2]), token)
        consoles[2].SlicerInformation.name = "new setup"
        local replacement, payload = open(env, owner, 2, consoles[2])
        assert(replacement ~= token); equal(payload.name, "new setup")
        equal(save(env, owner, consoles[2], token), false)
        equal(open(env, owner, nil, consoles[2]), replacement)
        equal(save(env, owner, consoles[2], replacement), true)
    end)

    test("hacking permanently retires listed editor even after quitting", function()
        local env, owner, hacker, consoles = fixture()
        list(env, owner); local token = open(env, owner, 2, consoles[2])
        env.open(hacker, consoles[2]); env.receive("playerQuitConsole", hacker)
        equal(save(env, owner, consoles[2], token), false)
        local replacement = open(env, owner, 2, consoles[2]); assert(replacement ~= token)
        equal(save(env, owner, consoles[2], replacement), true)
    end)
end
