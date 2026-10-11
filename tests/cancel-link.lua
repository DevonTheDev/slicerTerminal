-- Real server chat, selection, reservation and registry callbacks. Engine APIs
-- are synthetic; native multiplayer chat and door behavior still need GMod.
return function(gmod, test, equal)
    local function configured(env, owner, kind)
        local console = env.console(owner)
        assert(env.configure(owner, console, kind or "tools", 2))
        return console
    end
    local function say(env, owner, target, text)
        owner.target = target
        return env.fire("PlayerSay", owner, text or "!setEntity")
    end
    local function upvalue(callback, wanted)
        local index = 1
        while true do
            local name, value = debug.getupvalue(callback, index)
            if not name then error("Missing server state: " .. wanted) end
            if name == wanted then return value end
            index = index + 1
        end
    end
    -- Observe the actual private tables and their identities, allowing only
    -- this actor's pending pointer and private feedback to change.
    local function snapshot(env, actor, clears)
        local saved, seen = {}, {}
        local function visit(value)
            if type(value) ~= "table" or seen[value] or (actor and value == actor.chats) then return end
            seen[value] = true
            local fields = {}
            saved[#saved + 1] = {value = value, fields = fields}
            for key, item in pairs(value) do
                if not (clears and value == actor and key == "SlicerPendingConsole") then fields[key] = item end
                visit(item)
            end
        end
        visit(env.entities); visit(env.messages); visit(env.returnSpawnedEntities())
        visit(upvalue(env.hooks.PlayerUse.isUsingOurObject, "linkedDoors"))
        visit(upvalue(env.slicerConsoleHasActiveSession, "sessions"))
        visit(upvalue(env.retireSlicerSetupEdit, "editTickets"))
        visit(upvalue(env.hooks.PlayerSay.slicerListConsoles, "consoleListings"))
        local outgoing, serial = env.outgoing, env.slicerSetupEditSerial
        return function()
            equal(env.outgoing, outgoing, "Cancellation started a packet")
            equal(env.slicerSetupEditSerial, serial, "Cancellation changed edit authority")
            for _, record in ipairs(saved) do
                for key, item in pairs(record.fields) do equal(record.value[key], item, "Changed field " .. tostring(key)) end
                for key, item in pairs(record.value) do equal(item, record.fields[key], "Unexpected field " .. tostring(key)) end
            end
        end
    end
    local function cancel(env, owner)
        local unchanged, chats = snapshot(env, owner, true), #owner.chats
        equal(env.fire("PlayerSay", owner, "!cancelLink"), "", "Exact cancellation stays private")
        equal(owner.SlicerPendingConsole, nil, "Cancellation must clear the caller's pending selection")
        equal(#owner.chats, chats + 1, "Exactly one private reply")
        local text = owner.chats[#owner.chats]
        assert(#text > 0 and #text <= 255, "Cancellation reply must fit native chat")
        assert(not text:find("[%z\1-\31\127]"), "Cancellation reply contains controls")
        unchanged()
        return text
    end

    test("cancel automatic selection without a target or hacking tool", function()
        local env = gmod.new()
        local owner = env.player()
        local console = configured(env, owner)
        equal(owner.SlicerPendingConsole, console)
        owner.weapon, owner.target = nil, nil
        owner.GetEyeTrace = function() error("Cancellation traced a target") end
        owner.GetActiveWeapon = function() error("Cancellation required a weapon") end
        cancel(env, owner)
    end)

    test("cancel explicit selection retained after an invalid door retry", function()
        local env = gmod.new()
        local owner = env.player()
        local first, second = configured(env, owner), configured(env, owner)
        equal(say(env, owner, first), "")
        say(env, owner, env.entity("prop_physics"))
        equal(owner.SlicerPendingConsole, first)
        cancel(env, owner)
        local door = env.entity("func_door")
        say(env, owner, door)
        equal(first.SlicerDoor, nil); equal(second.SlicerDoor, nil); equal(#door.inputs, 0)
        equal(say(env, owner, second), ""); equal(say(env, owner, door), "")
        equal(second.SlicerDoor, door); equal(door.inputs[1], "Lock")
    end)

    local states = {
        {name = "deleted", change = function(env, owner, console) console:Remove(); owner.SlicerPendingConsole = console end},
        {name = "foreign", change = function(env, _, console) console.SlicerCreator = env.player() end},
        {name = "busy", change = function(_, _, console) console.SlicerInformation.inUse = true end},
        {name = "unconfigured", change = function(_, _, console) console.SlicerInformation = nil end},
        {name = "wrong class", change = function(_, _, console) console.class = "prop_physics" end},
        {name = "data folder", change = function(_, _, console) console.SlicerInformation.fileType = "data" end},
        {name = "server folder", change = function(_, _, console) console.SlicerInformation.fileType = "server" end},
        {name = "opaque stale pointer", change = function(_, owner)
            owner.SlicerPendingConsole = setmetatable({}, {__index = function() error("Cancellation dereferenced stale pointer") end})
        end},
    }
    for _, state in ipairs(states) do
        test("cancel clears " .. state.name .. " pending choice with constant feedback", function()
            local env = gmod.new()
            local owner = env.player()
            local console = configured(env, owner)
            local expected = cancel(env, owner)
            owner.SlicerPendingConsole = console
            state.change(env, owner, console)
            console.GetName = function() error("Cancellation read a console name") end
            console.GetClass = function() error("Cancellation inspected target eligibility") end
            equal(cancel(env, owner), expected, "Feedback must not disclose pending target state")
        end)
    end

    test("cancel with no selection is repeatable and privately explains the empty state", function()
        local env = gmod.new()
        local owner = env.player()
        local first = cancel(env, owner)
        equal(cancel(env, owner), first)
        assert(first:find("no", 1, true) and first:find("selection", 1, true), "Explain the absent selection")
    end)

    for _, kind in ipairs({"nil", "false", "nonplayer", "dead", "disconnected"}) do
        test("cancel refuses " .. kind .. " actor without state or feedback", function()
            local env = gmod.new()
            local owner = env.player()
            local console = configured(env, owner)
            local actor = owner
            if kind == "nil" then actor = nil
            elseif kind == "false" then actor = false
            elseif kind == "nonplayer" then actor = env.entity("prop_physics"); actor.SlicerPendingConsole = console
            elseif kind == "dead" then owner.alive = false
            else
                env.fire("PlayerDisconnected", owner); owner.valid = false
                owner.SlicerPendingConsole = console -- An invalid stale actor must remain untouched.
            end
            local unchanged, chats = snapshot(env, nil, false), #owner.chats
            equal(env.fire("PlayerSay", actor, "!cancelLink"), "")
            unchanged(); equal(#owner.chats, chats)
        end)
    end

    local malformed = {"!cancellink", "!CancelLink", "!cancelLink ", " !cancelLink", "!cancelLink\t", "!cancelLink\n",
        "!cancelLink 1", "!cancelLink alpha", "!cancelLink!", "/cancelLink", "cancelLink", "!cancelLink\0"}
    for _, text in ipairs(malformed) do
        test("cancel exact grammar ignores " .. string.format("%q", text), function()
            local env = gmod.new()
            local owner = env.player()
            configured(env, owner)
            local unchanged = snapshot(env, nil, false)
            equal(env.fire("PlayerSay", owner, text), nil)
            unchanged()
        end)
    end

    test("cancel changes only the calling creator while another creator can still link", function()
        local env = gmod.new()
        local first, second = env.player(), env.player()
        local alpha, beta = configured(env, first), configured(env, second)
        cancel(env, first)
        equal(second.SlicerPendingConsole, beta)
        local door = env.entity("func_door_rotating")
        equal(say(env, second, door), ""); equal(beta.SlicerDoor, door)
        equal(alpha.SlicerDoor, nil); equal(first.SlicerPendingConsole, nil)
    end)

    for _, kind in ipairs({"data", "server", "tools"}) do
        test("cancel preserves active " .. kind .. " session, registered door and original deadline", function()
            local env = gmod.new()
            local owner = env.player()
            local console = configured(env, owner, kind)
            local door
            if kind == "tools" then
                door = env.entity("func_door"); equal(say(env, owner, door), "")
            end
            env.now = 10; env.open(owner, console)
            owner.SlicerPendingConsole = console -- Includes a stale busy/linked selection.
            local sessions = upvalue(env.slicerConsoleHasActiveSession, "sessions")
            local session = assert(sessions[owner])
            cancel(env, owner)
            equal(sessions[owner], session); equal(session.completeAt, kind == "tools" and 12 or 14)
            equal(console.SlicerInformation.inUse, true)
            if door then equal(env.fire("PlayerUse", owner, door), false) end
            env.now = session.completeAt
            env.receive(kind == "tools" and "PlayerActivatedDoor" or "destroyOnServer", owner, console)
            equal(console.removed, true, "Original session can finish on its original deadline")
            if door then equal(#door.inputs, 2); equal(door.inputs[2], "Unlock") end
        end)
    end

    test("cancel clears before chat callback and preserves a reentrant fresh selection", function()
        local env = gmod.new()
        local owner = env.player()
        local first, fresh = configured(env, owner), configured(env, owner)
        equal(say(env, owner, first), "")
        local original, entered = owner.ChatPrint, false
        owner.ChatPrint = function(self, text)
            original(self, text)
            if entered then return end
            entered = true
            equal(self.SlicerPendingConsole, nil, "Old choice must be cleared before external feedback")
            equal(say(env, self, fresh), "")
        end
        equal(env.fire("PlayerSay", owner, "!cancelLink"), "")
        equal(owner.SlicerPendingConsole, fresh, "Outer cancellation must not overwrite nested selection")
        local door = env.entity("func_door")
        equal(say(env, owner, door), ""); equal(fresh.SlicerDoor, door); equal(first.SlicerDoor, nil)
    end)

    test("cancel retains its cleared pointer when private feedback throws", function()
        local env = gmod.new()
        local owner = env.player()
        configured(env, owner)
        owner.ChatPrint = function() error("synthetic feedback failure") end
        local ok, message = pcall(env.fire, "PlayerSay", owner, "!cancelLink")
        equal(ok, false); assert(message:find("synthetic feedback failure", 1, true))
        equal(owner.SlicerPendingConsole, nil)
    end)
end
