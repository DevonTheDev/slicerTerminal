-- State/nearest intersection through actual production chat and row handlers.
-- Existing predicate and nearest suites retain the underlying boundary matrix.
return function(gmod, test, equal)
    local support = dofile("tests/console-locator-support.lua")(gmod)
    local states = {"setup", "unlinked", "unconfirmed", "linked", "reserved"}
    local function say(env, owner, text) return env.fire("PlayerSay", owner, text) end
    local function position(entity, x, calls)
        entity.position = support.vector(x, 0, 0)
        function entity:GetPos()
            calls[self] = (calls[self] or 0) + 1
            return self.position
        end
    end
    local function fixture()
        local env = support.server()
        local owner, other, calls = env.player(), env.player(), {}
        position(owner, 0, calls)
        return env, owner, other, calls
    end
    local function configured(env, owner, folder)
        local console = env.console(owner)
        assert(env.configure(owner, console, folder or "tools"))
        return console
    end
    local function link(env, owner, console, class)
        local door = env.entity(class or "func_door")
        owner.target = console; equal(say(env, owner, "!setEntity"), "")
        owner.target = door; equal(say(env, owner, "!setEntity"), "")
        equal(console.SlicerDoor, door)
        return door
    end
    local function matching(env, owner, state)
        if state == "setup" then return env.console(owner) end
        local console = configured(env, owner, state == "reserved" and "data" or "tools")
        if state == "unconfirmed" then console.SlicerDoor = env.entity("func_door") end
        if state == "linked" then link(env, owner, console) end
        if state == "reserved" then env.open(env.player(), console); assert(env.slicerConsoleHasActiveSession(console)) end
        return console
    end
    local function request(env, owner, text)
        local first, packets, outgoing = #owner.chats + 1, #env.messages, env.outgoing
        equal(say(env, owner, text), "")
        equal(#env.messages, packets, "Nearest state listing sent a packet")
        equal(env.outgoing, outgoing)
        local messages, rows = {}, {}
        for i = first, #owner.chats do
            local line = owner.chats[i]
            assert(#line <= 255 and not line:find("[%z\1-\31\127]"), "Invalid private output")
            messages[#messages + 1] = line
            if line:match("^[1-5]%. Console") then rows[#rows + 1] = line end
        end
        assert(#messages > 0, "Missing private reply")
        assert(#rows <= 5, "More than five rows")
        return messages, rows
    end
    local function rowsAre(env, owner, rows, expected)
        equal(#rows, #expected)
        for i, console in ipairs(expected) do equal(env.slicerListedConsole(owner, i), console) end
        equal(env.slicerListedConsole(owner, #expected + 1), nil)
    end
    local function upvalue(callback, wanted)
        for i = 1, 100 do
            local name, value = debug.getupvalue(callback, i)
            if name == wanted then return value end
            if not name then break end
        end
        error("Missing state " .. wanted)
    end

    for _, state in ipairs(states) do
        test("nearest " .. state .. " filters before sampling and pagination and retains all page guidance", function()
            local env, owner, other, calls = fixture()
            local consoles = {}
            -- Nonmatches are geometrically closer and must not consume page slots.
            local excluded = state == "setup" and configured(env, owner, "data") or env.console(owner)
            function excluded:GetPos() error("Nonmatching console position sampled") end
            for i = 1, 7 do
                consoles[i] = matching(env, owner, state)
                position(consoles[i], 100 - 10 * i, calls)
            end
            local foreign = matching(env, other, state)
            function foreign:GetPos() error("Foreign console position sampled") end
            local privateChats = #other.chats
            function owner:IsAdmin() return true end
            function owner:GetEyeTrace() error("Nearest state listing traced") end
            function owner:GetActiveWeapon() error("Nearest state listing read weapon") end
            local messages, rows = request(env, owner, "!nearConsoles 1 " .. state)
            equal(messages[1], "Your consoles (nearest-first request snapshot; " .. state .. "): page 1 of 2 (7 total). Locate: !locateConsole <row>.")
            rowsAre(env, owner, rows, {consoles[7], consoles[6], consoles[5], consoles[4], consoles[3]})
            equal(messages[#messages], "Next page: !nearConsoles 2 " .. state .. ".")
            equal(calls[owner], 1)
            for _, console in ipairs(consoles) do equal(calls[console], 1) end
            messages, rows = request(env, owner, "!nearConsoles 2 " .. state)
            rowsAre(env, owner, rows, {consoles[2], consoles[1]})
            equal(messages[#messages], "First page: !nearConsoles 1 " .. state .. ".")
            messages, rows = request(env, owner, "!nearConsoles 3 " .. state)
            equal(#messages, 1); rowsAre(env, owner, rows, {})
            equal(messages[1], "Console page must be between 1 and 2. Use !nearConsoles <page> " .. state .. ".")
            equal(calls[owner], 3)
            for _, console in ipairs(consoles) do equal(calls[console], 3) end
            equal(#other.chats, privateChats, "Listing exposed private feedback")
        end)
    end

    test("nearest state grammar rejects invalid variants before conversion enumeration and origin access", function()
        local env, owner = fixture()
        function env.tonumber() error("Invalid state grammar converted") end
        function env.ents.FindByClass() error("Invalid state grammar enumerated") end
        function owner:GetPos() error("Invalid state grammar sampled") end
        for _, suffix in ipairs({" setup", " reserved", " 0 setup", " 01 setup", " -1 setup", " +1 setup",
            " 1.0 setup", " 1e1 setup", " ١ setup", "  1 setup", " 1  setup", " 1 setup ",
            " 1 SETUP", " 1 Setup",
            " 1 unknown", " 1 set", " 1 unconfirmedx", " 10000000 unconfirmed", " 1 ",
            "\t1 setup", "\n1 setup", " 1\tsetup", " 1\nsetup", " 1 setup\0", " 1 setup\127",
            " 1 setup\194\133", " 1 setup\226\128\168", " 1 setup\226\128\169", " " .. string.rep("9", 200000) .. " setup"}) do
            local messages, rows = request(env, owner, "!nearConsoles" .. suffix)
            equal(#messages, 1); rowsAre(env, owner, rows, {})
            assert(messages[1]:find("Usage:", 1, true)); assert(messages[1]:find("<state>", 1, true))
            assert(messages[1]:find("1-7", 1, true)); assert(messages[1]:find("no leading zero", 1, true))
        end
    end)

    test("nearest state accepts its longest bounded command and empty matches clear earlier rows", function()
        local env, owner, _, calls = fixture()
        local console = matching(env, owner, "unconfirmed"); position(console, 1, calls)
        request(env, owner, "!nearConsoles 1 unconfirmed")
        equal(env.slicerListedConsole(owner, 1), console)
        local messages, rows = request(env, owner, "!nearConsoles 9999999 unconfirmed")
        equal(messages[1], "Console page must be between 1 and 1. Use !nearConsoles <page> unconfirmed.")
        rowsAre(env, owner, rows, {})
        request(env, owner, "!nearConsoles 1 unconfirmed")
        messages, rows = request(env, owner, "!nearConsoles 1 reserved")
        equal(messages[1], "You have no consoles matching state 'reserved'.")
        rowsAre(env, owner, rows, {})
    end)

    test("nearest filtered ties and unavailable distances retain the original deterministic ordering", function()
        local env, owner, _, calls = fixture()
        local consoles, ids = {}, {8, 2, 2, 1, 4, 3}
        for i = 1, 6 do consoles[i] = matching(env, owner, "unlinked"); position(consoles[i], 5, calls); consoles[i].id = ids[i] end
        consoles[4].position.x = 0 / 0
        consoles[5].position.x = math.huge
        consoles[6].position = nil
        local enumeration = {consoles[3], consoles[1], consoles[6], consoles[4], consoles[2], consoles[5]}
        function env.ents.FindByClass() return enumeration end
        local _, rows = request(env, owner, "!nearConsoles 1 unlinked")
        rowsAre(env, owner, rows, {consoles[2], consoles[3], consoles[1], consoles[4], consoles[6]})
        equal(enumeration[1], consoles[3]); equal(enumeration[6], consoles[5])
        for _, console in ipairs(consoles) do equal(calls[console], 1) end
        equal(calls[owner], 1)
        _, rows = request(env, owner, "!nearConsoles 2 unlinked")
        rowsAre(env, owner, rows, {consoles[5]})
    end)

    test("nearest filtered requests copy one origin and resample later movement", function()
        local env, owner, _, calls = fixture()
        local a, b = matching(env, owner, "unlinked"), matching(env, owner, "unlinked")
        position(a, 10, calls); position(b, 20, calls)
        local get = a.GetPos
        function a:GetPos() owner.position.x = 100; return get(self) end
        local _, rows = request(env, owner, "!nearConsoles 1 unlinked")
        rowsAre(env, owner, rows, {a, b}); equal(calls[owner], 1)
        equal(env.slicerListedConsole(owner, 1), a, "Movement cannot remap existing rows")
        _, rows = request(env, owner, "!nearConsoles 1 unlinked")
        rowsAre(env, owner, rows, {b, a}); equal(calls[owner], 2)
    end)

    test("nearest filtered origin failure preserves its retry syntax and revokes prior rows", function()
        local env, owner, _, calls = fixture()
        local console = matching(env, owner, "setup"); position(console, 1, calls)
        request(env, owner, "!nearConsoles 1 setup")
        owner.position.x = math.huge
        function env.ents.FindByClass() error("Unavailable origin enumerated") end
        local messages, rows = request(env, owner, "!nearConsoles 2 setup")
        equal(messages[1], "Your position is unavailable. Try !nearConsoles 2 setup again.")
        rowsAre(env, owner, rows, {})
    end)

    test("nearest filtered admission stays private and living-player only and malformed input replaces authority", function()
        local env, owner, other, calls = fixture()
        local console = matching(env, owner, "setup"); position(console, 1, calls)
        request(env, owner, "!nearConsoles 1 setup")
        local before = #owner.chats
        owner.alive = false
        equal(say(env, owner, "!nearConsoles 1 setup"), "")
        equal(#owner.chats, before); equal(calls[owner], 1)
        owner.alive = true; equal(env.slicerListedConsole(owner, 1), nil)
        for _, actor in ipairs({other, env.entity("prop_physics")}) do
            actor.valid = false; equal(say(env, actor, "!nearConsoles 1 setup"), "")
        end
        request(env, owner, "!nearConsoles 1 setup")
        request(env, owner, "!nearConsoles 01 setup")
        equal(env.slicerListedConsole(owner, 1), nil)
        equal(#other.chats, 0)
    end)

    test("nearest state snapshots retain exact rows after state changes and recheck current action authority", function()
        local env, owner, other, calls = fixture()
        local console = matching(env, owner, "unlinked"); position(console, 1, calls)
        env.now = 10; request(env, owner, "!nearConsoles 1 unlinked")
        link(env, owner, console, "func_door_rotating")
        equal(env.slicerListedConsole(owner, 1), console, "State transition must not remap printed row")
        env.now = 69.99
        equal(say(env, owner, "!locateConsole 1"), ""); equal(env.lastMessage("SlicerConsoleLocation").values[3].x, 1)
        equal(say(env, owner, "!editConsole 1"), ""); equal(env.lastMessage("SlicerSetupEditOpen").values[1], console)
        equal(say(env, owner, "!setEntity 1"), ""); equal(owner.SlicerPendingConsole, nil)
        env.now = 70; equal(env.slicerListedConsole(owner, 1), nil, "Actions cannot renew the original sixty seconds")
        request(env, owner, "!nearConsoles 1 linked")
        console.SlicerCreator = other
        local packets = #env.messages
        equal(say(env, owner, "!editConsole 1"), ""); equal(#env.messages, packets)
        equal(env.slicerListedConsole(owner, 1), nil)
    end)

    test("nearest setup rows open exact modern drafts and state changes do not authorize another setup", function()
        local env, owner, _, calls = fixture()
        local far, near = matching(env, owner, "setup"), matching(env, owner, "setup")
        position(far, 20, calls); position(near, 1, calls)
        request(env, owner, "!nearConsoles 1 setup")
        local packets = #env.messages
        equal(say(env, owner, "!setupConsole 1"), "")
        equal(#env.messages, packets + 1)
        local packet = env.lastMessage("PlayerSpawnedConsole")
        assert(packet, "Listed setup must open a draft")
        equal(packet.values[2], near:GetName())
        env.configure(owner, near, "data")
        equal(env.slicerListedConsole(owner, 1), near)
        local before = #env.messages
        equal(say(env, owner, "!setupConsole 1"), ""); equal(#env.messages, before)
        equal(far.SlicerInformation, nil)
    end)

    test("nearest state requests preserve reservations deadlines selections edits and locator packets", function()
        local env, owner, hacker, calls = fixture()
        local reserved = configured(env, owner, "data"); position(reserved, 1, calls)
        local editable = configured(env, owner, "server"); position(editable, 2, calls)
        local selected = configured(env, owner, "tools"); position(selected, 3, calls)
        local setup = env.console(owner); position(setup, 4, calls)
        env.open(hacker, reserved)
        local sessions = upvalue(env.slicerConsoleHasActiveSession, "sessions")
        local session, information = sessions[hacker], reserved.SlicerInformation
        local deadline = session.completeAt
        owner.SlicerPendingConsole = selected
        owner.target = editable; equal(say(env, owner, "!editConsole"), "")
        local editPacket = env.lastMessage("SlicerSetupEditOpen")
        request(env, owner, "!nearConsoles 1 unlinked")
        equal(say(env, owner, "!locateConsole 1"), "")
        local marker = env.lastMessage("SlicerConsoleLocation")
        -- A stale flag is not a reservation; a real reservation survives flag changes.
        information.inUse = false; editable.SlicerInformation.inUse = true
        for _, state in ipairs(states) do
            request(env, owner, "!nearConsoles 1 " .. state)
            equal(sessions[hacker], session); equal(session.completeAt, deadline)
            equal(reserved.SlicerInformation, information); equal(information.inUse, false)
            equal(editable.SlicerInformation.inUse, true)
            equal(owner.SlicerPendingConsole, selected)
            equal(env.lastMessage("SlicerConsoleLocation"), marker)
            equal(env.lastMessage("SlicerSetupEditOpen"), editPacket)
        end
        equal(env.slicerListedConsole(owner, 1), reserved, "Reserved predicate must use the real session")
        editable.SlicerInformation.inUse = false
        env.receive("SlicerSetupEditSave", owner, editable, editPacket.values[3], {name = "saved", delay = 3, fileName = "file"})
        equal(env.lastMessage("SlicerSetupEditReply").values[2].ok, true)
        env.now = deadline; env.receive("destroyOnServer", hacker, reserved)
        equal(reserved.removed, true)
        equal(setup.SlicerInformation, nil)
    end)

    test("nearest state callbacks cannot replace newer rows with an older prepared page", function()
        local env, owner, _, calls = fixture()
        local setup, unlinked = matching(env, owner, "setup"), matching(env, owner, "unlinked")
        position(setup, 1, calls); position(unlinked, 2, calls)
        local chat, entered = owner.ChatPrint, false
        function owner:ChatPrint(message)
            chat(self, message)
            if not entered then
                entered = true
                equal(env.slicerListedConsole(self, 1), setup, "Rows must be installed before output")
                equal(say(env, self, "!nearConsoles 1 unlinked"), "")
            end
        end
        request(env, owner, "!nearConsoles 1 setup")
        equal(env.slicerListedConsole(owner, 1), unlinked)
    end)
end
