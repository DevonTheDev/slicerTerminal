-- Exercise the real chat callback and compare the original server-owned state.
-- Only Garry's Mod entity/transport APIs are doubled; no link logic is copied.
return function(gmod, test, equal)
    local function contains(text, part)
        assert(text:find(part, 1, true), "Missing '" .. part .. "' in: " .. text)
    end
    local function say(env, actor, target, text)
        actor.target = target
        return env.fire("PlayerSay", actor, text)
    end
    local function configured(env, owner, kind, name)
        local console = env.console(owner)
        env.receive("AdminFinishedCreation", owner,
            {name or "terminal", 2, kind or "tools", "secret", console:GetName()})
        assert(console.SlicerInformation)
        return console
    end
    local function link(env, owner, console, class)
        local door = env.entity(class or "func_door")
        equal(say(env, owner, console, "!setEntity"), "")
        equal(say(env, owner, door, "!setEntity"), "")
        equal(console.SlicerDoor, door); equal(#door.inputs, 1); equal(door.inputs[1], "Lock")
        return door
    end
    local function fixture(class)
        local env = gmod.new()
        local owner = env.player()
        local console = configured(env, owner)
        local door = link(env, owner, console, class)
        door:Remove()
        return env, owner, console, door
    end
    -- Read-only snapshots include the actual private tables, so replacing or
    -- clearing unrelated registry/session/ticket entries cannot go unnoticed.
    local function upvalue(callback, wanted)
        local index = 1
        while true do
            local name, value = debug.getupvalue(callback, index)
            if not name then error("Missing server state: " .. wanted) end
            if name == wanted then return value end
            index = index + 1
        end
    end
    local function snapshot(env, actor, clearedConsole, clearedDoor)
        local links = upvalue(env.hooks.PlayerUse.isUsingOurObject, "linkedDoors")
        local saved, seen = {}, {}
        local function expected(tableValue, key, value)
            if tableValue == clearedConsole and key == "SlicerDoor" then return nil end
            if tableValue == links and key == clearedDoor and value == clearedConsole then return nil end
            return value
        end
        local function visit(value)
            if type(value) ~= "table" or seen[value] or (actor and value == actor.chats) then return end
            seen[value] = true
            local fields = {}
            saved[#saved + 1] = {table = value, fields = fields}
            for key, item in pairs(value) do
                fields[key] = expected(value, key, item)
                visit(item)
            end
        end
        visit(env.entities); visit(env.messages); visit(env.returnSpawnedEntities())
        visit(links)
        visit(upvalue(env.slicerConsoleHasActiveSession, "sessions"))
        visit(upvalue(env.retireSlicerSetupEdit, "editTickets"))
        local serial, outgoing = env.slicerSetupEditSerial, env.outgoing
        local function sameValue(actual, expectedValue, message)
            if type(expectedValue) == "number" and expectedValue ~= expectedValue then
                assert(type(actual) == "number" and actual ~= actual, message)
            else equal(actual, expectedValue, message) end
        end
        return function()
            equal(env.slicerSetupEditSerial, serial, "Reset changed edit serial")
            equal(env.outgoing, outgoing, "Reset started a network packet")
            for _, record in ipairs(saved) do
                for key, item in pairs(record.fields) do
                    sameValue(record.table[key], item, "Reset changed unrelated state: " .. tostring(key))
                end
                for key, item in pairs(record.table) do
                    sameValue(item, record.fields[key], "Reset added or retained unexpected state: " .. tostring(key))
                end
            end
        end
    end
    local function reset(env, actor, console, door)
        actor.target = console
        local unchanged = snapshot(env, actor, door and console, door)
        local count = #actor.chats
        equal(env.fire("PlayerSay", actor, "!resetLink"), "", "Exact reset command must be consumed")
        equal(#actor.chats, count + 1, "Reset sends exactly one private chat reply")
        local text = actor.chats[#actor.chats]
        assert(#text <= 255, "Reset reply exceeds ChatPrint's byte limit: " .. #text)
        assert(not text:find("[%z\1-\31\127]"), "Reset reply contains a raw control")
        unchanged()
        return text
    end

    for _, class in ipairs({"func_door", "func_door_rotating"}) do
        test("reset recovers only the removed " .. class .. " binding without selecting a replacement", function()
            local env, owner, console, door = fixture(class)
            local observer = env.player()
            local pending = configured(env, owner, "tools", "pending")
            local other = configured(env, observer, "tools", "other")
            local liveDoor = link(env, observer, other)
            local hacker = env.player(); env.open(hacker, other)
            console.SlicerInformation.extra = {kept = true}
            console.custom = {kept = "unchanged"}
            local info, records = console.SlicerInformation, env.returnSpawnedEntities()
            say(env, owner, console, "!setEntity")
            equal(owner.SlicerPendingConsole, pending, "Ordinary selection must reject the old assignment")
            equal(console.SlicerDoor, door)
            env.open(owner, console)
            equal(env.slicerConsoleHasActiveSession(console), false, "Removed door currently prevents Use")
            owner.weapon = nil
            local text = reset(env, owner, console, door)
            contains(text, "'terminal'"); contains(text, "current ID #" .. console:GetCreationID())
            contains(text, "!setEntity")
            equal(console.SlicerDoor, nil); equal(console.SlicerInformation, info)
            equal(env.returnSpawnedEntities(), records)
            equal(owner.SlicerPendingConsole, pending)
            equal(env.fire("PlayerUse", owner, door), nil, "Only the removed door's owned registry key is cleared")
            equal(env.fire("PlayerUse", owner, liveDoor), false)
            equal(env.slicerConsoleHasActiveSession(other), true)
            contains(reset(env, owner, console), "!setEntity")
            equal(owner.SlicerPendingConsole, pending, "Repeated reset must not auto-select")
        end)
    end

    test("inspection and listing privately explain explicit recovery for a removed link", function()
        local env, owner, console = fixture()
        console.SlicerInformation.name = string.rep("界", 42) .. "é"
        console.id = 10000000
        owner.target = console
        local unchanged = snapshot(env, owner)
        equal(env.fire("PlayerSay", owner, "!inspectLink"), "")
        local text = owner.chats[#owner.chats]
        contains(text, "previous door is no longer available"); contains(text, "!resetLink")
        assert(#text <= 255); unchanged()
        local first = #owner.chats + 1
        equal(env.fire("PlayerSay", owner, "!listConsoles"), "")
        local found
        for index = first, #owner.chats do
            local row = owner.chats[index]
            assert(#row <= 255)
            if row:find("previous door is no longer available", 1, true) then
                contains(row, "!resetLink"); found = true
            end
        end
        assert(found, "Listing omitted the removed-door state")
    end)

    test("a never-linked console receives harmless explicit selection guidance", function()
        local env = gmod.new()
        local owner = env.player()
        local console = configured(env, owner)
        local pending = configured(env, owner, "tools", "pending")
        contains(reset(env, owner, console), "!setEntity")
        equal(owner.SlicerPendingConsole, pending)
    end)

    for _, kind in ipairs({"missing", "removed", "prop", "foreign console", "foreign door", "data", "server", "unconfigured"}) do
        test("reset rejects a " .. kind .. " target without changing or disclosing another console", function()
            local env, owner, console = fixture()
            local other = env.player()
            local hidden = configured(env, other, "tools", "privateownerlabel")
            local hiddenDoor = link(env, other, hidden)
            local target = console
            if kind == "missing" then target = nil
            elseif kind == "removed" then console:Remove()
            elseif kind == "prop" then target = env.entity("prop_physics")
            elseif kind == "foreign console" then target = hidden
            elseif kind == "foreign door" then target = hiddenDoor
            elseif kind == "unconfigured" then target = env.console(owner)
            else console.SlicerInformation.fileType = kind end
            local text = reset(env, owner, target)
            assert(not text:find("privateownerlabel", 1, true), "Foreign name leaked")
            assert(not text:find("#" .. hidden:GetCreationID() .. "%f[%D]"), "Foreign identity leaked")
        end)
    end

    for _, invalid in ipairs({
        {name = "missing information"}, {name = "boolean information", value = false},
        {name = "number information", value = 7}, {name = "string information", value = "legacy"},
        {name = "empty information", value = {}},
        {name = "unknown folder", field = "fileType", value = "unknown"},
        {name = "missing filename", field = "fileName"},
        {name = "blank name", field = "name", value = " \t "},
        {name = "oversized name", field = "name", value = string.rep("x", 129)},
        {name = "nonnumeric delay", field = "delay", value = "2"},
        {name = "zero delay", field = "delay", value = 0},
        {name = "negative delay", field = "delay", value = -1},
        {name = "infinite delay", field = "delay", value = math.huge},
        {name = "NaN delay", field = "delay", value = 0 / 0},
    }) do
        test("reset validates existing configuration: " .. invalid.name, function()
            local env, owner, console = fixture()
            if invalid.field then console.SlicerInformation[invalid.field] = invalid.value
            else console.SlicerInformation = invalid.value end
            reset(env, owner, console)
        end)
    end

    for _, busy in ipairs({true, 0, 1, "busy"}) do
        test("reset refuses the raw busy flag " .. tostring(busy), function()
            local env, owner, console = fixture()
            console.SlicerInformation.inUse = busy
            reset(env, owner, console)
        end)
    end

    for _, class in ipairs({"func_door", "func_door_rotating", "prop_door_rotating", "prop_physics"}) do
        test("reset preserves every live " .. class .. " pointer including unregistered ones", function()
            local env = gmod.new()
            local owner = env.player()
            local console = configured(env, owner)
            if class == "func_door" or class == "func_door_rotating" then
                link(env, owner, console, class)
                reset(env, owner, console)
            end
            console.SlicerDoor = env.entity(class)
            reset(env, owner, console)
        end)
    end

    test("reset preserves foreign and unrelated registry entries even with inconsistent pointers", function()
        local env = gmod.new()
        local owner, other = env.player(), env.player()
        local first = configured(env, owner)
        local firstDoor = link(env, owner, first)
        local second = configured(env, other)
        local secondDoor = link(env, other, second, "func_door_rotating")
        first.SlicerDoor = secondDoor
        secondDoor:Remove()
        reset(env, owner, first, secondDoor)
        equal(env.fire("PlayerUse", owner, firstDoor), false, "Unrelated old registration is unchanged")
        equal(env.fire("PlayerUse", owner, secondDoor), false, "A foreign key must not be deleted")
        equal(second.SlicerDoor, secondDoor)
        reset(env, other, second, secondDoor)
        equal(env.fire("PlayerUse", other, secondDoor), nil)
        equal(#firstDoor.inputs, 1); equal(#secondDoor.inputs, 1)
    end)

    test("reset clears an unavailable unregistered pointer without inventing registry authority", function()
        local env, owner, console = fixture()
        local stale = env.entity("func_door_rotating"); stale:Remove()
        console.SlicerDoor = stale
        reset(env, owner, console, stale)
        equal(env.fire("PlayerUse", owner, stale), nil)
        equal(#stale.inputs, 0)
    end)

    for _, actorKind in ipairs({"missing", "invalid", "non-player", "dead"}) do
        test("reset guards a " .. actorKind .. " actor before reading its eye trace", function()
            local env, owner, console = fixture()
            local actor = owner
            if actorKind == "missing" then actor = nil
            elseif actorKind == "invalid" then actor.valid = false
            elseif actorKind == "non-player" then actor.class = "prop_physics"
            else actor.alive = false end
            function owner:GetEyeTrace() error("Ineligible actor was traced") end
            local unchanged, count = snapshot(env), #owner.chats
            equal(env.fire("PlayerSay", actor, "!resetLink"), "")
            equal(#owner.chats, count); unchanged()
        end)
    end

    for _, text in ipairs({"!resetlink", "!RESETLINK", " !resetLink", "!resetLink ", "!resetLink\n", "!resetLink extra", "!resetLinks", "hello"}) do
        test("reset leaves non-exact chat untouched: " .. string.format("%q", text), function()
            local env, owner, console = fixture()
            owner.target = console
            local unchanged = snapshot(env)
            equal(env.fire("PlayerSay", owner, text), nil)
            unchanged()
        end)
    end

    test("reset preserves saved name bytes while sanitizing a bounded private reply", function()
        for _, name in ipairs({"  Mixed CASE  ", string.rep("n", 128), string.rep("界", 42) .. "é", string.rep("🔐", 32),
            "a\0b\1c\9d\10e\13f\31g\127h\194\133i\226\128\168j\226\128\169k"}) do
            local env, owner, console, door = fixture()
            console.SlicerInformation.name = name
            console.SlicerInformation.fileName = "  Saved FILE  "
            console.id = 10000000
            local text = reset(env, owner, console, door)
            equal(console.SlicerInformation.name, name)
            assert(not text:find("\194\133", 1, true)); assert(not text:find("\226\128\168", 1, true))
            assert(not text:find("\226\128\169", 1, true))
        end
    end)

    test("a real session independently vetoes reset after legacy updateInUse clears its flag", function()
        local env = gmod.new()
        local owner, hacker = env.player(), env.player()
        local console = configured(env, owner)
        local door = link(env, owner, console)
        env.now = 10; env.open(hacker, console)
        door:Remove(); env.updateInUse(console:GetName(), false)
        equal(console.SlicerInformation.inUse, false)
        equal(env.slicerConsoleHasActiveSession(console), true)
        local sessions = upvalue(env.slicerConsoleHasActiveSession, "sessions")
        equal(sessions[hacker].completeAt, 12)
        reset(env, owner, console)
        equal(sessions[hacker].completeAt, 12, "Reset must not restart or cancel an existing deadline")
        equal(env.slicerConsoleHasActiveSession(console), true)
        env.receive("playerQuitConsole", hacker)
        equal(env.slicerConsoleHasActiveSession(console), false)
        reset(env, owner, console, door)
    end)
end
