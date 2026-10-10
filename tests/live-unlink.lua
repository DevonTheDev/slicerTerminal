-- Real server hooks own all decisions. API doubles expose door inputs; they do
-- not establish native engine/protection/map-output behavior.
return function(gmod, test, equal)
    local function contains(text, part)
        assert(text:find(part, 1, true), "Missing '" .. part .. "' in: " .. text)
    end
    local function say(env, actor, target, command)
        actor.target = target
        return env.fire("PlayerSay", actor, command)
    end
    local function configured(env, owner, name, folder)
        local console = env.console(owner)
        env.receive("AdminFinishedCreation", owner, {name or "terminal", 2, folder or "tools", "secret", console:GetName()})
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
        return env, owner, console, link(env, owner, console, class)
    end
    local function upvalue(callback, wanted)
        for index = 1, 100 do
            local name, value = debug.getupvalue(callback, index)
            if name == wanted then return value end
            if not name then break end
        end
        error("Missing server state: " .. wanted)
    end
    -- Exact graph comparison permits just the two owned-link deletions, one
    -- old-door input and the actor's private reply. Everything else is retained.
    local function snapshot(env, actor, console, door)
        local links = upvalue(env.hooks.PlayerUse.isUsingOurObject, "linkedDoors")
        local records, seen = {}, {}
        local function visit(value)
            if type(value) ~= "table" or seen[value] or (actor and value == actor.chats) then return end
            seen[value] = true
            local fields = {}
            records[#records + 1] = {value, fields}
            for key, item in pairs(value) do fields[key] = item; visit(item) end
            if value == console then fields.SlicerDoor = nil end
            if value == links and door then fields[door] = nil end
            if door and value == door.inputs then fields[#fields + 1] = "Unlock" end
        end
        visit(env.entities); visit(env.messages); visit(env.returnSpawnedEntities()); visit(links)
        visit(upvalue(env.slicerConsoleHasActiveSession, "sessions"))
        visit(upvalue(env.retireSlicerSetupEdit, "editTickets"))
        local serial, outgoing = env.slicerSetupEditSerial, env.outgoing
        return function()
            equal(env.slicerSetupEditSerial, serial, "Unlink changed edit serial")
            equal(env.outgoing, outgoing, "Unlink started a network packet")
            for _, record in ipairs(records) do
                for key, value in pairs(record[2]) do equal(record[1][key], value, "Changed saved field " .. tostring(key)) end
                for key, value in pairs(record[1]) do equal(value, record[2][key], "Unexpected field " .. tostring(key)) end
            end
        end
    end
    local function unlink(env, owner, console, door)
        owner.target = console
        local unchanged = snapshot(env, owner, door and console, door)
        local count = #owner.chats
        equal(env.fire("PlayerSay", owner, "!unlinkConsole"), "", "Exact unlink command must be consumed")
        equal(#owner.chats, count + 1, "One private unlink reply")
        local reply = owner.chats[#owner.chats]
        assert(#reply <= 255, "Reply exceeds native ChatPrint byte limit")
        assert(not reply:find("[%z\1-\31\127]"), "Reply contains raw control characters")
        unchanged()
        return reply
    end

    for _, class in ipairs({"func_door", "func_door_rotating"}) do
        test("unlink clears only the current registered " .. class .. " while preserving edits and other sessions", function()
            local env, owner, console, door = fixture(class)
            local other = env.player()
            local otherConsole = configured(env, other, "privateownerlabel")
            local otherDoor = link(env, other, otherConsole)
            local hacker = env.player(); env.now = 10; env.open(hacker, otherConsole)
            local pending = configured(env, owner, "pending")
            say(env, owner, console, "!editConsole")
            local editor = env.lastMessage("SlicerSetupEditOpen")
            local info, identity, record = console.SlicerInformation, console:GetName(), env.returnSpawnedEntities()[1]
            info.extra = {retained = true}; console.custom = {retained = true}
            owner.weapon = nil
            local reply = unlink(env, owner, console, door)
            contains(reply, "'terminal'"); contains(reply, "current ID #" .. console:GetCreationID())
            contains(reply, "!setEntity"); contains(reply, "Unlock")
            equal(console.valid, true); equal(console:GetName(), identity)
            equal(console.SlicerInformation, info); equal(record.information, info)
            equal(console.SlicerDoor, nil); equal(owner.SlicerPendingConsole, pending)
            equal(env.fire("PlayerUse", owner, door), nil)
            equal(env.fire("PlayerUse", owner, otherDoor), false)
            equal(upvalue(env.slicerConsoleHasActiveSession, "sessions")[hacker].completeAt, 12)
            contains(unlink(env, owner, console), "!setEntity")
            env.receive("SlicerSetupEditSave", owner, console, editor.values[3], {name = "renamed", delay = 2, fileName = "secret"})
            equal(env.lastMessage("SlicerSetupEditReply").values[2].ok, true)
            equal(console.SlicerInformation.name, "renamed")
            console:Remove()
            equal(#door.inputs, 2, "Removal after unlink must not send another Unlock")
            equal(#otherDoor.inputs, 1); equal(env.slicerConsoleHasActiveSession(otherConsole), true)
        end)
    end

    for _, kind in ipairs({"foreign", "unconfigured", "data", "malformed", "busy", "legacy busy"}) do
        test("unlink refuses " .. kind .. " console without changing state or disclosing foreign identity", function()
            local env, owner, console = fixture()
            if kind == "foreign" then owner = env.player()
            elseif kind == "unconfigured" then console = env.console(owner)
            elseif kind == "data" then console.SlicerInformation.fileType = "data"
            elseif kind == "malformed" then console.SlicerInformation.delay = "2"
            elseif kind == "busy" then console.SlicerInformation.inUse = true
            else console.SlicerInformation.inUse = 0 end
            local reply = unlink(env, owner, console)
            assert(not reply:find("'terminal'", 1, true), "Ineligible target label was disclosed")
        end)
    end

    for _, kind in ipairs({"missing", "invalid", "non-player", "dead"}) do
        test("unlink rejects a " .. kind .. " actor before targeting", function()
            local env, owner = fixture()
            local actor = owner
            if kind == "missing" then actor = nil
            elseif kind == "invalid" then actor.valid = false
            elseif kind == "non-player" then actor.class = "prop_physics"
            else actor.alive = false end
            function owner:GetEyeTrace() error("Ineligible actor was traced") end
            local unchanged = snapshot(env)
            equal(env.fire("PlayerSay", actor, "!unlinkConsole"), "")
            unchanged()
        end)
    end

    test("an actual reservation vetoes unlink when legacy updateInUse clears the raw flag", function()
        local env, owner, console, door = fixture()
        local hacker = env.player(); env.now = 10; env.open(hacker, console)
        env.updateInUse(console:GetName(), false)
        equal(console.SlicerInformation.inUse, false)
        equal(env.slicerConsoleHasActiveSession(console), true)
        unlink(env, owner, console)
        equal(upvalue(env.slicerConsoleHasActiveSession, "sessions")[hacker].completeAt, 12)
        env.receive("playerQuitConsole", hacker)
        unlink(env, owner, console, door)
    end)

    test("unlink refuses unsupported, missing and foreign registry authority without repair", function()
        local env, owner, console, original = fixture()
        local other = env.player()
        local foreign = configured(env, other, "privateownerlabel")
        local foreignDoor = link(env, other, foreign, "func_door_rotating")
        for _, door in ipairs({env.entity("prop_door_rotating"), env.entity("func_door"), foreignDoor}) do
            console.SlicerDoor = door
            local reply = unlink(env, owner, console)
            contains(reply, "no registered link")
            assert(not reply:find("privateownerlabel", 1, true))
            equal(env.fire("PlayerUse", owner, original), false)
            equal(env.fire("PlayerUse", owner, foreignDoor), false)
        end
    end)

    test("removed doors retain reset guidance and reset still refuses a live registered door", function()
        local env, owner, console, door = fixture()
        say(env, owner, console, "!resetLink")
        equal(console.SlicerDoor, door); equal(#door.inputs, 1)
        door:Remove()
        contains(unlink(env, owner, console), "!resetLink")
        say(env, owner, console, "!resetLink")
        equal(console.SlicerDoor, nil)
        contains(unlink(env, owner, console), "!setEntity")
    end)

    test("only exact unlink chat is consumed", function()
        local env, owner, console = fixture()
        owner.target = console
        local unchanged = snapshot(env)
        for _, command in ipairs({"!unlinkconsole", " !unlinkConsole", "!unlinkConsole ", "!unlinkConsole extra"}) do
            equal(env.fire("PlayerSay", owner, command), nil)
        end
        unchanged()
    end)

    test("unlink preserves saved text and bounds sanitized private replies", function()
        for _, name in ipairs({string.rep("界", 42) .. "é", "A\0B\9C\10D\127E\194\133F\226\128\168G"}) do
            local env, owner, console, door = fixture()
            console.SlicerInformation.name = name; console.id = 10000000
            local reply = unlink(env, owner, console, door)
            equal(console.SlicerInformation.name, name)
            assert(not reply:find("\194\133", 1, true)); assert(not reply:find("\226\128\168", 1, true))
        end
    end)

    test("Unlock reentry cannot double-unlock and removal never dereferences a dead console", function()
        local env, owner, console, door = fixture()
        local fire = door.Fire
        function door:Fire(input)
            fire(self, input)
            equal(console.SlicerDoor, nil, "Pointer must clear before native input")
            equal(env.fire("PlayerUse", owner, self), nil, "Registry must clear before native input")
            contains(unlink(env, owner, console), "!setEntity")
            console:Remove()
            function console:GetCreationID() error("Removed console was inspected") end
        end
        equal(say(env, owner, console, "!unlinkConsole"), "")
        equal(console.removed, true); equal(#door.inputs, 2)
    end)

    test("a failing Unlock preserves a newer reentrant link and gives safe private feedback", function()
        local env, owner, console, oldDoor = fixture()
        local newDoor = env.entity("func_door_rotating")
        local fire = oldDoor.Fire
        function oldDoor:Fire(input)
            fire(self, input)
            say(env, owner, console, "!setEntity"); say(env, owner, newDoor, "!setEntity")
            error("private engine failure detail")
        end
        equal(say(env, owner, console, "!unlinkConsole"), "")
        equal(console.SlicerDoor, newDoor); equal(#oldDoor.inputs, 2); equal(#newDoor.inputs, 1)
        equal(env.fire("PlayerUse", owner, oldDoor), nil); equal(env.fire("PlayerUse", owner, newDoor), false)
        local reply = owner.chats[#owner.chats]
        contains(reply, "Unlock"); contains(reply, "failed")
        assert(not reply:find("private engine failure", 1, true)); assert(#reply <= 255)
        console:Remove()
        equal(#oldDoor.inputs, 2); equal(#newDoor.inputs, 2)
    end)

    test("successful Unlock reentry retains a newer link and uses conditional relink guidance", function()
        local env, owner, console, oldDoor = fixture()
        local newDoor = env.entity("func_door_rotating")
        local fire = oldDoor.Fire
        function oldDoor:Fire(input)
            fire(self, input)
            say(env, owner, console, "!setEntity"); say(env, owner, newDoor, "!setEntity")
        end
        equal(say(env, owner, console, "!unlinkConsole"), "")
        equal(console.SlicerDoor, newDoor); equal(#oldDoor.inputs, 2); equal(#newDoor.inputs, 1)
        contains(owner.chats[#owner.chats], "If still unlinked")
        equal(env.fire("PlayerUse", owner, newDoor), false)
    end)

    test("actor removal during Unlock cannot send chat through an invalid player", function()
        local env, owner, console, door = fixture()
        local fire, chats = door.Fire, #owner.chats
        function door:Fire(input)
            fire(self, input); owner:Remove()
            function owner:ChatPrint() error("Invalid player received a private reply") end
        end
        equal(say(env, owner, console, "!unlinkConsole"), "")
        equal(#owner.chats, chats); equal(console.SlicerDoor, nil); equal(#door.inputs, 2)
    end)
end
