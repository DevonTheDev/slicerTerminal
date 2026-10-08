-- Exercise the real server chat callback; IDs label entities, never authorize them.
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

    local function fixture(kind, name)
        local env = gmod.new()
        local owner = env.player()
        local console = configured(env, owner, kind, name)
        return env, owner, console
    end

    local function link(env, owner, console, class)
        local door = env.entity(class or "func_door")
        owner.target = console
        equal(env.fire("PlayerSay", owner, "!setEntity"), "")
        owner.target = door
        equal(env.fire("PlayerSay", owner, "!setEntity"), "")
        equal(console.SlicerDoor, door)
        equal(door.inputs[1], "Lock")
        return door
    end

    -- Preserve the real tables and all nested values. This catches both field
    -- writes and table replacement without cloning entity references as data.
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
        local serial, outgoing = env.slicerSetupEditSerial, env.outgoing
        return function()
            equal(env.slicerSetupEditSerial, serial, "Inspection changed editor authority")
            equal(env.outgoing, outgoing, "Inspection started a network packet")
            for _, record in ipairs(saved) do
                for key, value in pairs(record.fields) do
                    equal(record.value[key], value, "Inspection changed a saved field: " .. tostring(key))
                end
                for key, value in pairs(record.value) do
                    if record.value ~= requester or key ~= "chats" then
                        equal(value, record.fields[key], "Inspection added a field: " .. tostring(key))
                    end
                end
            end
        end
    end

    local function inspect(env, owner, target)
        owner.target = target
        local before, unchanged = #owner.chats, snapshot(env, owner)
        equal(env.fire("PlayerSay", owner, "!inspectLink"), "", "Recognized command must be consumed")
        equal(#owner.chats, before + 1, "One private result is enough")
        local message = owner.chats[#owner.chats]
        assert(#message <= 255, "ChatPrint result exceeded 255 bytes: " .. #message)
        assert(not message:find("[%z\1-\31\127]"), "ChatPrint contains a raw ASCII control")
        unchanged()
        return message
    end

    local function identity(message, console, name)
        contains(message, "'" .. (name or console.SlicerInformation.name) .. "'")
        contains(message, "current ID #" .. console:GetCreationID())
    end

    for _, class in ipairs({"func_door", "func_door_rotating"}) do
        for _, endpoint in ipairs({"console", "door"}) do
            test("link inspection identifies a registered " .. class .. " from its " .. endpoint, function()
                local env, owner, console = fixture("tools", "alpha")
                local observer = env.player()
                local door = link(env, owner, console, class)
                owner.weapon = nil
                local message = inspect(env, owner, endpoint == "console" and console or door)
                identity(message, console)
                contains(message, "registered link to " .. class)
                contains(message, "current ID #" .. door:GetCreationID())
                equal(#observer.chats, 0, "Inspection must stay private")
            end)
        end
    end

    test("link inspection distinguishes separate same-name consoles and door links", function()
        local env, owner, first = fixture()
        local firstDoor = link(env, owner, first)
        local second = configured(env, owner)
        local secondDoor = link(env, owner, second, "func_door_rotating")
        local firstMessage = inspect(env, owner, firstDoor)
        local secondMessage = inspect(env, owner, secondDoor)
        identity(firstMessage, first); identity(secondMessage, second)
        assert(firstMessage ~= secondMessage, "Same-name entities need distinct current labels")
        lacks(firstMessage, "current ID #" .. second:GetCreationID())
        lacks(secondMessage, "current ID #" .. first:GetCreationID())
    end)

    test("link inspection reports setup for an owned unconfigured console", function()
        local env = gmod.new()
        local owner = env.player()
        local console = env.console(owner)
        local message = inspect(env, owner, console)
        contains(message, "needs setup")
        contains(message, "Use it")
    end)

    for _, kind in ipairs({"data", "server"}) do
        test("link inspection reports the configured " .. kind .. " folder literally", function()
            local env, owner, console = fixture(kind)
            local message = inspect(env, owner, console)
            identity(message, console)
            contains(message, "configured for " .. kind)
            contains(message, "door linking is for tools consoles")
        end)

        test("link inspection reports legacy " .. kind .. " configuration without denying retained door authority", function()
            local name = string.rep("界", 42) .. "é"
            local env, owner, console = fixture("tools", name)
            local door = link(env, owner, console, "func_door_rotating")
            console.id, door.id = 10000000, 10000000
            console.SlicerInformation.fileType = kind
            equal(env.fire("PlayerUse", owner, door), false, "Existing registration still blocks Use")
            local message = inspect(env, owner, console)
            identity(message, console, name)
            contains(message, "configured for " .. kind)
            contains(message, "door linking is for tools consoles")
            lacks(message, "does not control a door")
            equal(env.fire("PlayerUse", owner, door), false, "Inspection preserves retained registration")
            equal(console.SlicerDoor, door)
            console:Remove()
            equal(#door.inputs, 2, "Registered cleanup must still unlock exactly once")
            equal(door.inputs[2], "Unlock")
            equal(env.fire("PlayerUse", owner, door), nil)
        end)
    end

    for _, busy in ipairs({false, true}) do
        test("link inspection reports a never-linked console with inUse=" .. tostring(busy), function()
            local env, owner, console = fixture()
            console.SlicerInformation.inUse = busy
            local message = inspect(env, owner, console)
            identity(message, console)
            contains(message, "never been linked")
            lacks(message, "!setEntity")
        end)
    end

    test("link inspection keeps a removed former door distinct from a never-linked console", function()
        local env, owner, console = fixture()
        local door = link(env, owner, console)
        door:Remove()
        local message = inspect(env, owner, console)
        contains(message, "previous door is no longer available")
        lacks(message, "never been linked"); lacks(message, "!setEntity")
        equal(console.SlicerDoor, door)
    end)

    for _, class in ipairs({"func_door", "func_door_rotating", "prop_door_rotating", "prop_physics"}) do
        test("link inspection cannot confirm a live unregistered " .. class .. " pointer", function()
            local env, owner, console = fixture()
            local door = env.entity(class)
            console.SlicerDoor = door
            local message = inspect(env, owner, console)
            contains(message, "no registered link can be confirmed")
            lacks(message, "registered link to")
            equal(env.fire("PlayerUse", owner, door), nil, "Inspection must not repair registration")
        end)
    end

    for _, targetKind in ipairs({"missing", "removed", "prop", "prop_door_rotating", "unregistered door", "foreign console", "foreign door"}) do
        test("link inspection gives private generic guidance for " .. targetKind, function()
            local env = gmod.new()
            local owner, other = env.player(), env.player()
            local hidden = configured(env, other, "tools", "privateownerlabel")
            local hiddenDoor = link(env, other, hidden)
            local baseline = inspect(env, owner, nil)
            local target
            if targetKind == "removed" then target = env.entity("consoleent"); target:Remove()
            elseif targetKind == "prop" then target = env.entity("prop_physics")
            elseif targetKind == "prop_door_rotating" then target = env.entity("prop_door_rotating")
            elseif targetKind == "unregistered door" then target = env.entity("func_door")
            elseif targetKind == "foreign console" then target = hidden
            elseif targetKind == "foreign door" then target = hiddenDoor end
            equal(inspect(env, owner, target), baseline)
            lacks(baseline, "privateownerlabel")
            lacks(baseline, "current ID")
        end)
    end

    test("link inspection rejects equal display names and equal creation IDs as ownership", function()
        local env, owner, own = fixture("tools", "same")
        local other = env.player()
        local foreign = configured(env, other, "tools", "same")
        local door = link(env, other, foreign)
        foreign.id = own.id
        equal(inspect(env, owner, foreign), inspect(env, owner, nil))
        equal(inspect(env, owner, door), inspect(env, owner, nil))
    end)

    for _, mismatch in ipairs({"nil", "other", "dead owner", "wrong class", "non-tools", "malformed"}) do
        test("link inspection hides a registered door with " .. mismatch .. " reverse authority", function()
            local env, owner, console = fixture("tools", "hiddenreverse")
            local door = link(env, owner, console)
            if mismatch == "nil" then console.SlicerDoor = nil
            elseif mismatch == "other" then console.SlicerDoor = env.entity("func_door")
            elseif mismatch == "dead owner" then console.valid = false
            elseif mismatch == "wrong class" then console.class = "prop_physics"
            elseif mismatch == "non-tools" then console.SlicerInformation.fileType = "data"
            elseif mismatch == "malformed" then console.SlicerInformation = false end
            local message = inspect(env, owner, door)
            equal(message, inspect(env, owner, nil))
            lacks(message, "hiddenreverse")
        end)
    end

    test("link inspection cannot confirm another console's live registered door pointer", function()
        local env, owner, console = fixture()
        local door = link(env, owner, console)
        local pretender = configured(env, owner, "tools", "pretender")
        pretender.SlicerDoor = door
        contains(inspect(env, owner, pretender), "no registered link can be confirmed")
        identity(inspect(env, owner, door), console)
        pretender:Remove()
        equal(#door.inputs, 1, "Inspection cannot grant the pretender cleanup authority")
    end)

    test("link inspection uses current registration after a stale owner is superseded", function()
        local env, owner, stale = fixture("tools", "stale")
        local door = link(env, owner, stale)
        stale.valid = false
        local current = configured(env, owner, "tools", "current")
        owner.target = door
        equal(env.fire("PlayerSay", owner, "!setEntity"), "")
        stale.valid = true
        contains(inspect(env, owner, stale), "no registered link can be confirmed")
        local message = inspect(env, owner, door)
        identity(message, current); lacks(message, "'stale'")
    end)

    test("link inspection reports surviving reload pointers without rebuilding authority", function()
        local env, owner, console = fixture()
        local door = link(env, owner, console)
        env.include("entities/consoleent/init.lua")
        contains(inspect(env, owner, console), "no registered link can be confirmed")
        equal(inspect(env, owner, door), inspect(env, owner, nil))
        equal(env.fire("PlayerUse", owner, door), nil)
        console:Remove()
        equal(#door.inputs, 1, "Unregistered reload state cannot unlock a door")
    end)

    for _, actorKind in ipairs({"missing", "invalid", "non-player", "dead"}) do
        test("link inspection consumes the command without feedback for a " .. actorKind .. " sender", function()
            local env = gmod.new()
            local actor
            if actorKind ~= "missing" then
                actor = env.player()
                if actorKind == "invalid" then actor.valid = false
                elseif actorKind == "non-player" then actor.class = "prop_physics"
                else actor.alive = false end
                function actor:GetEyeTrace() error("Invalid sender was traced") end
            end
            local before = #env.messages
            equal(env.fire("PlayerSay", actor, "!inspectLink"), "")
            equal(#env.messages, before)
            if actor then equal(#actor.chats, 0) end
        end)
    end

    for _, text in ipairs({"!inspectlink", "!INSPECTLINK", " !inspectLink", "!inspectLink ", "!inspectLink extra", "hello"}) do
        test("link inspection leaves unrelated chat unchanged: " .. text, function()
            local env, owner, console = fixture()
            owner.target = console
            local unchanged, before = snapshot(env, owner), #owner.chats
            equal(env.fire("PlayerSay", owner, text), nil)
            equal(#owner.chats, before)
            unchanged()
        end)
    end

    for _, invalid in ipairs({
        {label = "boolean", value = false},
        {label = "number", value = 7},
        {label = "string", value = "legacy"},
        {label = "empty table", value = {}},
        {label = "unknown folder", field = "fileType", value = "unknown"},
        {label = "nonnumeric delay", field = "delay", value = "later"},
        {label = "missing file", field = "fileName"},
        {label = "nonstring name", field = "name", value = {}},
        {label = "blank name", field = "name", value = "   "},
        {label = "oversized name", field = "name", value = string.rep("x", 129)},
    }) do
        test("link inspection handles malformed legacy configuration: " .. invalid.label, function()
            local env, owner, console = fixture()
            if invalid.field then console.SlicerInformation[invalid.field] = invalid.value
            else console.SlicerInformation = invalid.value end
            local message = inspect(env, owner, console)
            contains(message, "invalid configuration")
            lacks(message, "never been linked"); lacks(message, "registered link to")
        end)
    end

    for index, name in ipairs({string.rep("n", 128), string.rep("é", 64), string.rep("界", 42) .. "é", string.rep("🔐", 32)}) do
        test("link inspection preserves maximum-byte name case " .. index .. " without splitting characters", function()
            local env, owner, console = fixture("tools", name)
            local door = link(env, owner, console, "func_door_rotating")
            console.id, door.id = 10000000, 0
            local message = inspect(env, owner, door)
            identity(message, console, name)
            contains(message, "current ID #0")
            lacks(message, "unique"); lacks(message, "persistent")
        end)
    end

    test("link inspection sanitizes display controls without altering configured bytes", function()
        local name = "a\0b\1c\9d\10e\13f\31g\127h" .. "\194\133" .. "i\226\128\168j\226\128\169k"
        local env, owner, console = fixture("tools", name)
        local original = console.SlicerInformation.name
        local message = inspect(env, owner, console)
        lacks(message, "\194\133"); lacks(message, "\226\128\168"); lacks(message, "\226\128\169")
        equal(console.SlicerInformation.name, original)
        contains(message, "never been linked")
    end)
end
