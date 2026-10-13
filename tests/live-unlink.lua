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
    local function unlink(env, owner, console, door, row)
        owner.target = console
        local unchanged = snapshot(env, owner, door and console, door)
        local count = #owner.chats
        equal(env.fire("PlayerSay", owner, row and ("!unlinkConsole " .. row) or "!unlinkConsole"), "", "Exact unlink command must be consumed")
        equal(#owner.chats, count + 1, "One private unlink reply")
        local reply = owner.chats[#owner.chats]
        assert(#reply <= 255, "Reply exceeds native ChatPrint byte limit")
        assert(not reply:find("[%z\1-\31\127]"), "Reply contains raw control characters")
        unchanged()
        return reply
    end

    -- Removing the listed branch, loosening its grammar, resolving by labels,
    -- or omitting its final original-page guard must fail these callback tests.
    local function list(env, owner, command)
        equal(env.fire("PlayerSay", owner, command or "!listConsoles"), "")
    end
    local function noTarget(owner)
        function owner:GetEyeTrace() error("Listed unlink must not read an eye target") end
        function owner:GetActiveWeapon() error("Listed unlink must not read a weapon") end
    end
    local function unavailable(text)
        for _, command in ipairs({"!listConsoles", "!findConsoles", "!nearConsoles", "!unlinkConsole <row>"}) do
            contains(text, command)
        end
    end

    for _, listed in ipairs({false, true}) do
        for _, state in ipairs({"no link", "removed door", "live door"}) do
            test((listed and "listed" or "aimed") .. " unlink recovery wording for " .. state, function()
                for _, name in ipairs({string.rep("n", 128), string.rep("界", 42) .. "é"}) do
                    local env = gmod.new()
                    local owner, observer = env.player(), env.player()
                    local console = configured(env, owner, name)
                    local door
                    if state ~= "no link" then door = link(env, owner, console) end
                    if state == "removed door" then door:Remove() end
                    console.id = 10000000
                    if listed then list(env, owner); noTarget(owner) end
                    local others = #observer.chats
                    local text = unlink(env, owner, console, state == "live door" and door or nil, listed and 1 or nil)
                    local label = "Console '" .. name .. "' (current ID #10000000): "
                    local message
                    if listed then
                        if state == "live door" then
                            message = "old link cleared; Unlock sent. If still unlinked, !listConsoles; find it; !setEntity <row>"
                        elseif state == "removed door" then
                            message = "door no longer available. !listConsoles again; find this console, then !resetLink <row>."
                        else
                            message = "has no door link. !listConsoles again; find this console, then !setEntity <row>."
                        end
                    else
                        if state == "live door" then
                            message = "old link cleared; Unlock sent. If still unlinked, use !setEntity here, then on a door."
                        elseif state == "removed door" then
                            message = "previous door is no longer available. Use !resetLink on this console."
                        else
                            message = "has no door link. Use !setEntity to select it."
                        end
                    end
                    equal(text, label .. message)
                    equal(console.SlicerInformation.name, name); equal(#observer.chats, others)
                end
            end)
        end
    end

    test("listed unlink accepts exactly rows one through five with no eye target or tool reads", function()
        local env = gmod.new()
        local owner, other, consoles, doors = env.player(), env.player(), {}, {}
        for row = 1, 5 do
            consoles[row] = configured(env, owner)
            doors[row] = link(env, owner, consoles[row], row % 2 == 0 and "func_door_rotating" or "func_door")
        end
        list(env, owner); noTarget(owner)
        local others = #other.chats
        for row = 1, 5 do
            contains(unlink(env, owner, consoles[row], doors[row], row), "Unlock sent")
            equal(consoles[row].SlicerDoor, nil); equal(#doors[row].inputs, 2)
            contains(unlink(env, owner, consoles[row], nil, row), "has no door link")
            equal(#doors[row].inputs, 2, "Repeated unlink must not resend Unlock")
        end
        equal(#other.chats, others, "Replies must remain private")
        for _, command in ipairs({"!unlinkConsole 0", "!unlinkConsole 6", "!unlinkConsole 01", "!unlinkConsole +1",
            "!unlinkConsole -1", "!unlinkConsole 1.0", "!unlinkConsole 1e0", "!unlinkConsole  1",
            "!unlinkConsole 1 ", " !unlinkConsole 1", "!unlinkconsole 1", "!UnlinkConsole 1",
            "!unlinkConsole\t1", "!unlinkConsole 1\n", "!unlinkConsole 1 extra", "!unlinkConsole １"}) do
            local unchanged = snapshot(env)
            equal(env.fire("PlayerSay", owner, command), nil, command); unchanged()
        end
    end)

    for _, command in ipairs({"!listConsoles 1 linked terminal", "!findConsoles 1 terminal", "!nearConsoles 1 linked terminal"}) do
        test("listed unlink preserves exact filtered entities despite duplicate labels via " .. command, function()
            local env = gmod.new()
            local owner, consoles, doors = env.player(), {}, {}
            function owner:GetPos() return {x = 0, y = 0, z = 0} end
            for row = 1, 3 do
                consoles[row] = configured(env, owner)
                doors[row] = link(env, owner, consoles[row])
                consoles[row].id = 42
                consoles[row].GetPos = function() return {x = 1, y = 0, z = 0} end
            end
            list(env, owner, command)
            for row = 1, 3 do equal(env.slicerListedConsole(owner, row), consoles[row]) end
            consoles[1]:Remove()
            local replacement = configured(env, owner); replacement.id = 42
            noTarget(owner)
            unavailable(unlink(env, owner, consoles[1], nil, 1))
            consoles[2].SlicerInformation.name = "renamed"
            contains(unlink(env, owner, consoles[2], doors[2], 2), "'renamed'")
            equal(consoles[3].SlicerDoor, doors[3]); equal(#doors[3].inputs, 1)
            equal(replacement.SlicerDoor, nil); equal(owner.SlicerPendingConsole, replacement)
        end)
    end

    test("listed unlink refuses absent stale foreign and reowned rows without target fallback", function()
        for _, reason in ipairs({"missing page", "missing row", "removed", "reowned", "wrong class", "other player page"}) do
            local env, owner, console = fixture()
            local actor = owner
            if reason ~= "missing page" then list(env, owner) end
            if reason == "removed" then console:Remove()
            elseif reason == "reowned" then console.SlicerCreator = env.player()
            elseif reason == "wrong class" then console.class = "prop_physics"
            elseif reason == "other player page" then actor = env.player() end
            noTarget(actor)
            unavailable(unlink(env, actor, console, nil, reason == "missing row" and 5 or 1))
        end
    end)

    test("listed unlink rejects ineligible actors before looking up a page", function()
        for _, reason in ipairs({"missing", "invalid", "non-player", "dead"}) do
            local env, owner = fixture()
            list(env, owner); noTarget(owner)
            local actor = owner
            if reason == "missing" then actor = nil
            elseif reason == "invalid" then actor.valid = false
            elseif reason == "non-player" then actor.class = "prop_physics"
            else actor.alive = false end
            env.slicerListedConsole = function() error("Ineligible actor resolved a row") end
            local unchanged = snapshot(env)
            equal(env.fire("PlayerSay", actor, "!unlinkConsole 1"), ""); unchanged()
        end
    end)

    test("listed unlink keeps the original deadline at 59.99 and refuses exactly 60 without Think", function()
        local env, owner, console, door = fixture()
        local second = configured(env, owner, "second")
        local secondDoor = link(env, owner, second)
        list(env, owner); noTarget(owner)
        local listings = upvalue(env.slicerListedConsole, "consoleListings")
        local page = listings[owner]
        equal(page.expires, 60)
        env.now = 59.99
        unlink(env, owner, console, door, 1)
        equal(listings[owner], page); equal(page.expires, 60)
        env.now = 60
        unavailable(unlink(env, owner, second, nil, 2))
        equal(second.SlicerDoor, secondDoor); equal(#secondDoor.inputs, 1)
        equal(listings[owner], nil)
    end)

    test("listed unlink respects fresh empty and malformed page replacement", function()
        local env, owner, first, firstDoor = fixture()
        local second = configured(env, owner, "second")
        local secondDoor = link(env, owner, second)
        list(env, owner); list(env, owner, "!findConsoles 1 second"); noTarget(owner)
        unlink(env, owner, second, secondDoor, 1)
        equal(first.SlicerDoor, firstDoor)
        for _, command in ipairs({"!findConsoles 1 missing", "!listConsoles 0", "!nearConsoles 0"}) do
            list(env, owner); list(env, owner, command)
            unavailable(unlink(env, owner, first, nil, 1)); equal(#firstDoor.inputs, 1)
        end
    end)

    test("listed unlink retains setup folder raw-busy and door authority refusals", function()
        for _, reason in ipairs({"unconfigured", "data", "server", "malformed", "busy", "legacy busy",
            "unsupported", "unregistered", "foreign registry", "removed door", "no door"}) do
            local env, owner, console, door = fixture()
            list(env, owner)
            if reason == "unconfigured" then console.SlicerInformation = nil
            elseif reason == "data" or reason == "server" then console.SlicerInformation.fileType = reason
            elseif reason == "malformed" then console.SlicerInformation.delay = "2"
            elseif reason == "busy" then console.SlicerInformation.inUse = true
            elseif reason == "legacy busy" then console.SlicerInformation.inUse = 0
            elseif reason == "unsupported" then console.SlicerDoor = env.entity("prop_door_rotating")
            elseif reason == "unregistered" then console.SlicerDoor = env.entity("func_door")
            elseif reason == "foreign registry" then
                local other = env.player()
                console.SlicerDoor = link(env, other, configured(env, other, "privateownerlabel"))
            elseif reason == "removed door" then door:Remove()
            else console.SlicerDoor = nil end
            noTarget(owner)
            local text = unlink(env, owner, console, nil, 1)
            assert(not text:find("privateownerlabel", 1, true))
            equal(#door.inputs, 1)
            if reason == "removed door" then contains(text, "!resetLink")
            elseif reason == "no door" then contains(text, "!setEntity")
            elseif reason == "unsupported" or reason == "unregistered" or reason == "foreign registry" then
                contains(text, "no registered link")
            else contains(text, "cannot be unlinked") end
        end
    end)

    test("listed unlink refuses an actual session despite cleared raw busy without moving its deadline", function()
        local env, owner, console, door = fixture()
        local hacker = env.player()
        env.now = 10; env.open(hacker, console); env.updateInUse(console:GetName(), false)
        list(env, owner); noTarget(owner)
        contains(unlink(env, owner, console, nil, 1), "cannot be unlinked")
        equal(upvalue(env.slicerConsoleHasActiveSession, "sessions")[hacker].completeAt, 12)
        env.now = 12; env.receive("PlayerActivatedDoor", hacker, console)
        equal(console.removed, true); equal(#door.inputs, 2); equal(door.inputs[2], "Unlock")
    end)

    for _, stage in ipairs({"resolver", "label", "door class", "final clock"}) do
        test("listed unlink rejects a replacement page during " .. stage .. " before mutation", function()
            local env, owner, console, door = fixture()
            list(env, owner); noTarget(owner)
            local listings = upvalue(env.slicerListedConsole, "consoleListings")
            local originalPage = listings[owner]
            local function replace() list(env, owner) end
            if stage == "resolver" then
                local resolve = env.slicerListedConsole
                env.slicerListedConsole = function(actor, row)
                    local found = resolve(actor, row); replace(); return found
                end
            elseif stage == "label" then
                local getter = console.GetCreationID
                function console:GetCreationID() self.GetCreationID = getter; replace(); return getter(self) end
            elseif stage == "door class" then
                local getter = door.GetClass
                function door:GetClass() self.GetClass = getter; replace(); return getter(self) end
            else
                local clock, calls = env.CurTime, 0
                env.CurTime = function()
                    calls = calls + 1
                    if calls == 2 then env.CurTime = clock; replace() end
                    return clock()
                end
            end
            equal(env.fire("PlayerSay", owner, "!unlinkConsole 1"), "")
            unavailable(owner.chats[#owner.chats])
            equal(console.SlicerDoor, door); equal(#door.inputs, 1)
            assert(listings[owner] ~= originalPage)
            equal(listings[owner].rows[1], console, "A new lease for the same entity must not authorize the old request")
        end)
    end

    for _, stage in ipairs({"resolver", "label", "door class"}) do
        test("listed unlink rejects original expiry reached during " .. stage .. " before mutation", function()
            local env, owner, console, door = fixture()
            list(env, owner); noTarget(owner)
            local listings = upvalue(env.slicerListedConsole, "consoleListings")
            local page = listings[owner]
            if stage == "resolver" then
                local resolve = env.slicerListedConsole
                env.slicerListedConsole = function(actor, row)
                    local found = resolve(actor, row); env.now = 60; return found
                end
            elseif stage == "label" then
                local getter = console.GetCreationID
                function console:GetCreationID() env.now = 60; return getter(self) end
            else
                local getter = door.GetClass
                function door:GetClass() env.now = 60; return getter(self) end
            end
            unavailable(unlink(env, owner, console, nil, 1))
            equal(console.SlicerDoor, door); equal(#door.inputs, 1)
            equal(listings[owner], page); equal(page.expires, 60)
        end)
    end

    test("listed Unlock reentry sees both deletions and cannot resend before removal", function()
        local env, owner, console, door = fixture()
        list(env, owner); noTarget(owner)
        local fire = door.Fire
        function door:Fire(input)
            fire(self, input)
            equal(console.SlicerDoor, nil)
            equal(env.fire("PlayerUse", owner, self), nil, "Registration must clear before Unlock")
            contains(unlink(env, owner, console, nil, 1), "has no door link")
            console:Remove()
            function console:GetCreationID() error("Removed console was inspected") end
        end
        equal(env.fire("PlayerSay", owner, "!unlinkConsole 1"), "")
        equal(console.removed, true); equal(#door.inputs, 2)
    end)

    for _, fails in ipairs({false, true}) do
        test("listed unlink preserves a newer link after " .. (fails and "failed" or "successful") .. " Unlock", function()
            local env, owner, console, oldDoor = fixture()
            local replacement = env.entity("func_door_rotating")
            local pending = configured(env, owner, "other")
            list(env, owner)
            local fire, beforeReply = oldDoor.Fire
            local observer = env.player()
            local others = #observer.chats
            function oldDoor:Fire(input)
                fire(self, input)
                equal(env.fire("PlayerSay", owner, "!setEntity 1"), "")
                equal(say(env, owner, replacement, "!setEntity"), "")
                equal(env.fire("PlayerSay", owner, "!setEntity 2"), "")
                list(env, owner, "!findConsoles 1 other")
                beforeReply = #owner.chats
                if fails then error("private engine failure detail") end
            end
            equal(env.fire("PlayerSay", owner, "!unlinkConsole 1"), "")
            equal(console.SlicerDoor, replacement); equal(#oldDoor.inputs, 2); equal(#replacement.inputs, 1)
            equal(owner.SlicerPendingConsole, pending); equal(env.slicerListedConsole(owner, 1), pending)
            equal(env.fire("PlayerUse", owner, oldDoor), nil); equal(env.fire("PlayerUse", owner, replacement), false)
            local text = owner.chats[#owner.chats]
            contains(text, fails and "Unlock failed" or "If still unlinked")
            equal(#owner.chats, beforeReply + 1, "Replaced page still receives exactly one final private reply")
            equal(#observer.chats, others)
            if fails then
                contains(text, "old link cleared; Unlock failed. Check the previous door before using !setEntity.")
            else
                contains(text, "old link cleared; Unlock sent. If still unlinked, !listConsoles; find it; !setEntity <row>")
                assert(not text:find("!setEntity 1", 1, true), "Replaced row must not be suggested for reuse")
            end
            assert(not text:find("private engine failure", 1, true))
            console:Remove(); equal(#oldDoor.inputs, 2); equal(#replacement.inputs, 2)
        end)
    end

    test("listed unlink failure stays cleared and repeated requests do not retry native input", function()
        local env, owner, console, door = fixture()
        list(env, owner); noTarget(owner)
        local calls = 0
        function door:Fire() calls = calls + 1; error("private engine failure detail") end
        equal(env.fire("PlayerSay", owner, "!unlinkConsole 1"), "")
        contains(owner.chats[#owner.chats], "Unlock failed")
        equal(console.SlicerDoor, nil); equal(calls, 1)
        contains(unlink(env, owner, console, nil, 1), "has no door link")
        equal(calls, 1); equal(env.fire("PlayerUse", owner, door), nil)
    end)

    for _, row in ipairs({false, 1}) do
    for _, class in ipairs({"func_door", "func_door_rotating"}) do
        test((row and "listed " or "") .. "unlink clears only the current registered " .. class .. " while preserving edits and other sessions", function()
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
            if row then list(env, owner); noTarget(owner) end
            local reply = unlink(env, owner, console, door, row)
            contains(reply, "'terminal'"); contains(reply, "current ID #" .. console:GetCreationID())
            contains(reply, "!setEntity"); contains(reply, "Unlock")
            equal(console.valid, true); equal(console:GetName(), identity)
            equal(console.SlicerInformation, info); equal(record.information, info)
            equal(console.SlicerDoor, nil); equal(owner.SlicerPendingConsole, pending)
            equal(env.fire("PlayerUse", owner, door), nil)
            equal(env.fire("PlayerUse", owner, otherDoor), false)
            equal(upvalue(env.slicerConsoleHasActiveSession, "sessions")[hacker].completeAt, 12)
            contains(unlink(env, owner, console, nil, row), "!setEntity")
            env.receive("SlicerSetupEditSave", owner, console, editor.values[3], {name = "renamed", delay = 2, fileName = "secret"})
            equal(env.lastMessage("SlicerSetupEditReply").values[2].ok, true)
            equal(console.SlicerInformation.name, "renamed")
            console:Remove()
            equal(#door.inputs, 2, "Removal after unlink must not send another Unlock")
            equal(#otherDoor.inputs, 1); equal(env.slicerConsoleHasActiveSession(otherConsole), true)
        end)
    end

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
