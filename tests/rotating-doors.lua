-- Exercise the real selection/session/duplication callbacks with GMod API
-- doubles. Native brush I/O, eye traces and map/protection behavior still need
-- a fresh-server smoke test; the doubles only record Lock and Unlock inputs.
return function(gmod, test, equal)
    local unpackValues = table.unpack or unpack

    local function command(env, owner, target)
        owner.target = target
        return env.fire("PlayerSay", owner, "!setEntity")
    end

    local function bothBrushClasses(message)
        local words = {}
        for word in (message or ""):gmatch("[%w_]+") do words[word] = true end
        assert(words.func_door and words.func_door_rotating,
            "Guidance must name both supported brush classes: " .. tostring(message))
        assert(message:find("!setEntity", 1, true), "Guidance must explain the command")
    end

    local function fixture(class, delay)
        local env = gmod.new()
        local owner, hacker = env.player(), env.player()
        local console = env.console(owner)
        local info = assert(env.configure(owner, console, "tools", delay or 2))
        local door = env.entity(class or "func_door_rotating")
        command(env, owner, door)
        equal(console.SlicerDoor, door, "Actual author command links the brush door")
        equal(#door.inputs, 1); equal(door.inputs[1], "Lock")
        return env, owner, hacker, console, info, door
    end

    local function secondTerminal(env, owner, class)
        local console = env.console(owner)
        assert(env.configure(owner, console, "tools"))
        local door = env.entity(class or "func_door")
        command(env, owner, door)
        equal(console.SlicerDoor, door)
        return console, door
    end

    local function stillLocked(console, door)
        equal(console.removed, nil, "Terminal remains available")
        equal(#door.inputs, 1, "No repeated Lock or premature Unlock")
        equal(door.inputs[1], "Lock")
    end

    -- Relay actual setup-form output, keeping the authenticated server sender
    -- distinct from fields supplied by the client.
    local function setup(server, client, owner, console)
        local first, entries, choice, done, frame = #client.panels + 1, {}
        client.receive("PlayerSpawnedConsole", nil, owner, console:GetName())
        for i = first, #client.panels do
            local panel = client.panels[i]
            if panel.class == "DTextEntry" then entries[#entries + 1] = panel
            elseif panel.class == "DFrame" then frame = panel
            elseif panel.class == "DComboBox" then choice = panel
            elseif panel.class == "DButton" and panel.text == "Done" then done = panel end
        end
        entries[1]:SetText("Rotating")
        entries[2]:SetText("3.5")
        entries[3]:SetText("OpenDoor")
        choice.selected = "tools"
        done:DoClick()
        local packet = assert(client.lastMessage("AdminFinishedCreation"))
        equal(frame.valid, true, "Initial setup remains visible pending acceptance")
        local before = #server.messages
        server.receive(packet.name, owner, unpackValues(packet.values))
        equal(#server.messages, before + 1)
        local reply = assert(server.lastMessage("SlicerInitialSetupReply"))
        equal(reply.player, owner); equal(reply.values[1], packet.values[1][6])
        equal(reply.values[2].ok, true)
        client.receive(reply.name, nil, unpackValues(reply.values))
        equal(frame.valid, false, "Matching acceptance closes initial setup")
        return assert(console.SlicerInformation)
    end

    for _, class in ipairs({"func_door", "func_door_rotating"}) do
        test(class .. " automatic selection locks once and intercepts only its exact entity", function()
            local env, owner, hacker, console, _, door = fixture(class)
            equal(owner.SlicerPendingConsole, nil)
            local unrelated = env.entity(class)
            unrelated:SetName(door:GetName())
            equal(env.fire("PlayerUse", hacker, unrelated), nil)
            equal(env.fire("PlayerUse", hacker, door), false)
            equal(env.lastMessage("PlayerAlert").player, hacker)
            command(env, owner, door)
            command(env, owner, console)
            equal(console.SlicerDoor, door)
            equal(owner.SlicerPendingConsole, nil, "A linked terminal cannot be selected again")
            stillLocked(console, door)
        end)
    end

    test("explicit selection links an older terminal to a rotating brush door", function()
        local env = gmod.new()
        local owner, other = env.player(), env.player()
        local older, latest = env.console(owner), env.console(owner)
        env.configure(owner, older, "tools"); env.configure(owner, latest, "tools")
        local foreign = env.console(other); env.configure(other, foreign, "tools")
        equal(command(env, owner, older), "")
        bothBrushClasses(owner.chats[#owner.chats])
        local door = env.entity("func_door_rotating")
        equal(command(env, owner, door), "")
        equal(older.SlicerDoor, door); equal(latest.SlicerDoor, nil)
        equal(owner.SlicerPendingConsole, nil)
        equal(other.SlicerPendingConsole, foreign, "Only the linking creator's pending choice is cleared")
        equal(#door.inputs, 1); equal(door.inputs[1], "Lock")
    end)

    test("unsupported and removed targets preserve selection and explain both brush choices", function()
        local env = gmod.new()
        local owner = env.player()
        local console = env.console(owner); env.configure(owner, console, "tools")
        for _, class in ipairs({"prop_door_rotating", "prop_physics", "func_door_rotating_custom", "removed"}) do
            local target = env.entity(class == "removed" and "func_door_rotating" or class)
            if class == "removed" then target:Remove() end
            command(env, owner, target)
            equal(console.SlicerDoor, nil, class .. " must not link")
            equal(owner.SlicerPendingConsole, console)
            equal(#target.inputs, 0)
            equal(env.fire("PlayerUse", owner, target), nil)
            bothBrushClasses(owner.chats[#owner.chats])
        end
        local door = env.entity("func_door_rotating")
        command(env, owner, door)
        equal(console.SlicerDoor, door, "Valid retry uses the preserved selection")
    end)

    test("a claimed rotating door preserves the retry selection and its original owner", function()
        local env, owner, _, original, _, claimed = fixture()
        local retry = env.console(owner); env.configure(owner, retry, "tools")
        command(env, owner, claimed)
        equal(owner.SlicerPendingConsole, retry)
        equal(retry.SlicerDoor, nil); equal(original.SlicerDoor, claimed)
        bothBrushClasses(owner.chats[#owner.chats])
        stillLocked(original, claimed)
        local free = env.entity("func_door")
        command(env, owner, free)
        equal(retry.SlicerDoor, free)
        retry:Remove()
        equal(free.inputs[2], "Unlock")
        stillLocked(original, claimed)
        equal(env.fire("PlayerUse", owner, claimed), false)
    end)

    test("rotating targets do not bypass final creator configuration idle or prior-link checks", function()
        local changes = {
            {name = "foreign creator", apply = function(env, console) console.SlicerCreator = env.player() end},
            {name = "missing configuration", apply = function(_, console) console.SlicerInformation = nil end},
            {name = "data folder", apply = function(_, console) console.SlicerInformation.fileType = "data" end},
            {name = "busy terminal", apply = function(_, console) console.SlicerInformation.inUse = true end},
            {name = "prior door", apply = function(env, console) console.SlicerDoor = env.entity("func_door_rotating") end},
            {name = "removed prior door", apply = function(env, console)
                console.SlicerDoor = env.entity("func_door_rotating"); console.SlicerDoor:Remove()
            end},
            {name = "stale terminal", apply = function(_, console) console:Remove() end},
        }
        for _, change in ipairs(changes) do
            local env = gmod.new()
            local owner = env.player()
            local console = env.console(owner); env.configure(owner, console, "tools")
            command(env, owner, console)
            change.apply(env, console)
            local pending, oldDoor = owner.SlicerPendingConsole, console.SlicerDoor
            local target = env.entity("func_door_rotating")
            command(env, owner, target)
            equal(console.SlicerDoor, oldDoor, change.name)
            equal(owner.SlicerPendingConsole, pending, change.name .. " cannot select a replacement")
            equal(#target.inputs, 0, change.name .. " must not lock")
            equal(env.fire("PlayerUse", owner, target), nil)
        end
    end)

    test("a forged legacy selector and another creator cannot acquire a rotating door", function()
        local env = gmod.new()
        local owner, attacker = env.player(), env.player()
        local console = env.console(owner); env.configure(owner, console, "tools")
        command(env, attacker, console)
        local door = env.entity("func_door_rotating")
        env.receive("ServerWaitingForEntity", attacker, owner, console)
        command(env, attacker, door)
        equal(attacker.SlicerPendingConsole, nil)
        equal(owner.SlicerPendingConsole, console)
        equal(console.SlicerDoor, nil); equal(#door.inputs, 0)
        command(env, owner, door)
        equal(console.SlicerDoor, door)
    end)

    test("rotating brush completion runs through real setup client commands and server acceptance", function()
        local server, client = gmod.new(), gmod.client()
        local owner, hacker = server.player(), server.player()
        local console = server.console(owner)
        local info = setup(server, client, owner, console)
        equal(info.delay, 3.5); equal(owner.SlicerPendingConsole, console)
        local door = server.entity("func_door_rotating")
        command(server, owner, door)
        equal(console.SlicerDoor, door)
        local other, otherDoor = secondTerminal(server, owner, "func_door")
        server.open(hacker, console)
        local opening = assert(server.lastMessage("ServerSendsEntityInformation"))
        equal(opening.values[1], console); equal(opening.player, hacker)
        client.receive(opening.name, nil, unpackValues(opening.values))
        client.command("/a[rotating]"); client.fireTimer("AccessDelay")
        client.command("/a[rotating]/{_tools}"); client.command("/r{_tools}/opendoor.exe")
        local request = assert(client.lastMessage("PlayerActivatedDoor"))
        equal(request.values[1], console)
        equal(#client.chatMessages, 0, "A request alone cannot announce success")
        stillLocked(console, door)
        -- A different eye-trace target after selection cannot redirect the
        -- terminal's exact registered door identity at completion time.
        hacker.target = otherDoor
        server.now = 3.5
        server.receive(request.name, hacker, unpackValues(request.values))
        equal(console.removed, true); equal(info.inUse, false)
        equal(#door.inputs, 2); equal(door.inputs[2], "Unlock")
        stillLocked(other, otherDoor)
        equal(server.fire("PlayerUse", hacker, door), nil)
        equal(server.fire("PlayerUse", hacker, otherDoor), false)
        local accepted = assert(server.lastMessage("SlicerCompleted"))
        equal(accepted.player, hacker)
        client.receive(accepted.name, nil, unpackValues(accepted.values))
        equal(#client.chatMessages, 1); client.assertClosed()
        local count = #server.messages
        server.receive(request.name, hacker, unpackValues(request.values))
        equal(#server.messages, count, "Completion replay has no effect")
        equal(#door.inputs, 2, "Completion cannot unlock twice")
    end)

    for _, reason in ipairs({"early", "missing tool", "wrong completion type"}) do
        test("rotating " .. reason .. " completion releases only its session without unlocking", function()
            local env, owner, hacker, console, info, door = fixture(nil, 3.5)
            local other, otherDoor = secondTerminal(env, owner)
            local otherHacker = env.player(); env.open(otherHacker, other)
            env.open(hacker, console)
            equal(info.inUse, true)
            env.now = reason == "early" and 3.49 or 3.5
            if reason == "missing tool" then hacker.weapon = nil end
            env.receive(reason == "wrong completion type" and "destroyOnServer" or "PlayerActivatedDoor", hacker, console)
            equal(info.inUse, false)
            equal(other.SlicerInformation.inUse, true)
            stillLocked(console, door); stillLocked(other, otherDoor)
            equal(env.lastMessage("SlicerCompleted"), nil)
            equal(env.lastMessage("PlayerDied").player, hacker)
        end)
    end

    test("foreign senders and wrong terminal identities cannot complete a rotating session", function()
        local env, owner, hacker, console, info, door = fixture()
        local other, otherDoor = secondTerminal(env, owner)
        local attacker = env.player()
        env.open(hacker, console); env.open(attacker, other)
        env.now = 2
        local count = #env.messages
        env.receive("PlayerActivatedDoor", attacker, console)
        env.receive("PlayerActivatedDoor", hacker, other)
        equal(#env.messages, count)
        equal(info.inUse, true); equal(other.SlicerInformation.inUse, true)
        stillLocked(console, door); stillLocked(other, otherDoor)
    end)

    for _, stop in ipairs({"quit", "death"}) do
        test("rotating " .. stop .. " leaves both mixed door links locked and independent", function()
            local env, owner, hacker, console, info, door = fixture()
            local other, otherDoor = secondTerminal(env, owner)
            local otherHacker = env.player()
            env.open(hacker, console); env.open(otherHacker, other)
            if stop == "quit" then env.receive("playerQuitConsole", hacker, otherHacker, other)
            else hacker.alive = false; env.fire("PlayerDeath", hacker) end
            equal(info.inUse, false); equal(other.SlicerInformation.inUse, true)
            env.now = 2; env.receive("PlayerActivatedDoor", hacker, console)
            stillLocked(console, door); stillLocked(other, otherDoor)
            equal(env.lastMessage("SlicerCompleted"), nil)
            equal(env.fire("PlayerUse", owner, door), false)
        end)
    end

    test("a removed rotating door cannot be redirected to a same-name replacement", function()
        local env, owner, hacker, console, info, door = fixture()
        env.open(hacker, console); door:Remove()
        local replacement = env.entity("func_door_rotating")
        replacement:SetName(door:GetName())
        owner.SlicerPendingConsole = console -- Stale external selection must be rechecked.
        command(env, owner, replacement)
        equal(console.SlicerDoor, door); equal(info.inUse, true)
        env.now = 2; env.receive("PlayerActivatedDoor", hacker, console)
        equal(info.inUse, false); equal(console.removed, nil)
        equal(env.lastMessage("SlicerCompleted"), nil)
        equal(#replacement.inputs, 0)
        equal(env.fire("PlayerUse", owner, replacement), nil)
        console:Remove()
        equal(#door.inputs, 1, "Removed door receives no Unlock")
        equal(#replacement.inputs, 0, "Removal cannot unlock an unregistered replacement")
    end)

    test("stale rotating claims can be reacquired without old cleanup unlocking the new owner", function()
        local env, owner, _, old, _, door = fixture()
        old.valid = false -- Model a stale registry entry whose owner is no longer valid.
        local current = env.console(owner); env.configure(owner, current, "tools")
        command(env, owner, door)
        equal(current.SlicerDoor, door)
        equal(#door.inputs, 2); equal(door.inputs[2], "Lock")
        old:OnRemove()
        equal(#door.inputs, 2, "Old cleanup cannot unlock a newly owned door")
        equal(env.fire("PlayerUse", owner, door), false)
        current:Remove(); current:OnRemove()
        equal(#door.inputs, 3); equal(door.inputs[3], "Unlock")
        equal(env.fire("PlayerUse", owner, door), nil)
    end)

    test("removing a busy rotating terminal unlocks only its own door and clears its session", function()
        local env, owner, hacker, console, info, door = fixture()
        local other, otherDoor = secondTerminal(env, owner)
        local otherHacker = env.player()
        env.open(hacker, console); env.open(otherHacker, other)
        console:Remove()
        equal(info.inUse, false); equal(other.SlicerInformation.inUse, true)
        equal(env.lastMessage("PlayerDied").player, hacker)
        equal(#door.inputs, 2); equal(door.inputs[2], "Unlock")
        stillLocked(other, otherDoor)
        equal(#env.returnSpawnedEntities(), 1)
        equal(env.returnSpawnedEntities()[1].entity, other)
        equal(env.fire("PlayerUse", hacker, door), nil)
        env.now = 2; env.receive("PlayerActivatedDoor", hacker, console)
        equal(#door.inputs, 2); stillLocked(other, otherDoor)
    end)

    -- Match the existing duplicator callback boundary: generic data may alias
    -- information and retain entity references; hooks must remove authority.
    local function paste(env, actor, data, modifier)
        local duplicate = setmetatable(env.entity("consoleent"), {__index = env.ENT})
        duplicate:Initialize()
        duplicate.SlicerInformation = data.SlicerInformation
        duplicate.SlicerCreator, duplicate.SlicerDoor = data.SlicerCreator, data.SlicerDoor
        duplicate:OnDuplicated(data)
        if modifier then modifier(duplicate) end
        duplicate:PostEntityPaste(actor, duplicate, {})
        return duplicate
    end

    test("a copied busy rotating terminal needs explicit relinking and completes independently", function()
        local env, owner, hacker, original, info, door = fixture()
        env.open(hacker, original)
        local data = {SlicerInformation = info, SlicerCreator = owner, SlicerDoor = door}
        original:OnEntityCopyTableFinish(data)
        equal(data.SlicerDoor, nil); equal(data.SlicerCreator, nil)
        assert(data.SlicerInformation ~= info)
        equal(data.SlicerInformation.inUse, false); equal(info.inUse, true)
        local actor = env.player()
        local pending = env.console(actor); env.configure(actor, pending, "tools")
        local duplicate = paste(env, actor, data)
        equal(duplicate.SlicerCreator, actor); equal(duplicate.SlicerDoor, nil)
        equal(actor.SlicerPendingConsole, pending)
        assert(duplicate.SlicerInformation ~= info)
        bothBrushClasses(actor.chats[#actor.chats])
        env.open(actor, duplicate)
        equal(duplicate.SlicerInformation.inUse, false, "Copy cannot hack without its own link")
        command(env, actor, duplicate); command(env, actor, door)
        equal(actor.SlicerPendingConsole, duplicate, "Claim rejection preserves explicit copy selection")
        equal(duplicate.SlicerDoor, nil); stillLocked(original, door)
        local copyDoor = env.entity("func_door_rotating")
        command(env, actor, copyDoor)
        equal(duplicate.SlicerDoor, copyDoor)
        env.open(actor, duplicate)
        env.now = 2
        env.receive("PlayerActivatedDoor", hacker, duplicate)
        equal(info.inUse, true); equal(duplicate.SlicerInformation.inUse, true)
        env.receive("PlayerActivatedDoor", actor, duplicate)
        equal(duplicate.removed, true)
        equal(#copyDoor.inputs, 2); equal(copyDoor.inputs[2], "Unlock")
        equal(info.inUse, true); stillLocked(original, door)
        env.receive("playerQuitConsole", hacker)
        equal(info.inUse, false); stillLocked(original, door)
        original:Remove()
        equal(#door.inputs, 2); equal(door.inputs[2], "Unlock")
        equal(#copyDoor.inputs, 2, "Original cleanup cannot unlock the copy again")
    end)

    test("legacy and modifier-restored rotating links are cleared before copied cleanup", function()
        local env, owner, _, original, info, door = fixture()
        local actor = env.player()
        local legacy = {SlicerInformation = info, SlicerCreator = owner, SlicerDoor = door}
        local duplicate = paste(env, actor, legacy, function(copy)
            equal(copy.SlicerDoor, nil, "OnDuplicated clears legacy link before modifiers")
            equal(copy.SlicerCreator, nil)
            copy.SlicerCreator, copy.SlicerDoor = owner, door
        end)
        equal(duplicate.SlicerDoor, nil, "PostEntityPaste clears a modifier-restored link")
        equal(duplicate.SlicerCreator, actor)
        duplicate:Remove()
        stillLocked(original, door)
        equal(env.fire("PlayerUse", actor, door), false)
        -- Even a foreign stale pointer added after paste is not registry ownership.
        local stale = paste(env, actor, legacy)
        stale.SlicerDoor = door
        stale:Remove()
        stillLocked(original, door)
        equal(env.fire("PlayerUse", actor, door), false)
    end)
end
