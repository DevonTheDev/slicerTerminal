-- Exercise the actual PlayerSay hook and server-owned sessions. These doubles
-- do not certify native chat delivery or know the client's current UI stage.
return function(gmod, test, equal)
    local function contains(text, part)
        assert(text:find(part, 1, true), "Missing '" .. part .. "' in: " .. text)
    end
    local function upvalue(callback, wanted)
        for index = 1, math.huge do
            local name, value = debug.getupvalue(callback, index)
            if not name then error("Missing server state: " .. wanted) end
            if name == wanted then return value end
        end
    end
    local function configure(env, owner, folder, name)
        local console = env.console(owner)
        local information = assert(env.configure(owner, console, folder or "data", 2))
        information.name = name or "terminal"
        if folder == "tools" then
            owner.target = console; equal(env.fire("PlayerSay", owner, "!setEntity"), "")
            owner.target = env.entity("func_door_rotating")
            equal(env.fire("PlayerSay", owner, "!setEntity"), "")
        end
        return console, information
    end
    local function fixture(folder)
        local env = gmod.new()
        local owner, hacker = env.player(), env.player()
        local console, information = configure(env, owner, folder)
        env.now = 10; env.open(hacker, console)
        return env, owner, hacker, console, information, upvalue(env.ENT.AcceptInput, "sessions")
    end
    local function unchanged(env, requester, sessions)
        local records, seen = {}, {}
        local function visit(value)
            if type(value) ~= "table" or seen[value] then return end
            seen[value] = true
            local fields = {}; records[#records + 1] = {value, fields}
            for key, child in pairs(value) do
                if value ~= requester or key ~= "chats" then fields[key] = child; visit(child) end
            end
        end
        visit(env.entities); visit(env.messages); visit(env.returnSpawnedEntities()); visit(sessions)
        local outgoing, serial = env.outgoing, env.slicerSetupEditSerial
        local function same(actual, expected)
            if type(actual) == "number" and actual ~= actual and type(expected) == "number" and expected ~= expected then return end
            equal(actual, expected, "Status changed state")
        end
        return function()
            equal(env.outgoing, outgoing); equal(env.slicerSetupEditSerial, serial)
            for _, record in ipairs(records) do
                for key, value in pairs(record[2]) do same(record[1][key], value) end
                for key, value in pairs(record[1]) do
                    if record[1] ~= requester or key ~= "chats" then same(value, record[2][key]) end
                end
            end
        end
    end
    local function status(env, requester, count)
        local before = #requester.chats
        local check = unchanged(env, requester, upvalue(env.ENT.AcceptInput, "sessions"))
        equal(env.fire("PlayerSay", requester, "!hackStatus"), "", "Exact status must be consumed privately")
        equal(#requester.chats, before + (count or 3), "Status must have bounded private feedback")
        local lines = {}
        for index = before + 1, #requester.chats do
            local line = requester.chats[index]
            assert(#line > 0 and #line <= 240, "Status exceeds private chat budget")
            assert(not line:find("[%z\1-\31\127]") and not line:find("\194[\128-\159]")
                and not line:find("\226\128[\168\169]"), "Status contains display controls")
            lines[#lines + 1] = line
        end
        check()
        return lines
    end

    test("status privately reports absence without a tool or console", function()
        local env = gmod.new()
        local player, other = env.player(), env.player()
        player.weapon = nil
        equal(status(env, player, 1)[1], "You are not in a hacking session.")
        equal(#other.chats, 0)
    end)
    for _, folder in ipairs({"data", "server", "tools"}) do
        for _, offset in ipairs({-0.1, 0, 10}) do
            test(folder .. " status reports the server minimum at deadline offset " .. offset, function()
                local env, owner, hacker, console, info, sessions = fixture(folder)
                local deadline = 10 + (folder == "tools" and 2 or 4)
                equal(sessions[hacker].completeAt, deadline)
                env.now = deadline + offset
                local function forbidden() error("Status requested action eligibility") end
                hacker.weapon, hacker.target = nil, nil
                hacker.GetActiveWeapon, hacker.GetEyeTrace, hacker.GetPos = forbidden, forbidden, forbidden
                console.GetCreationID, console.GetName, console.GetPos = forbidden, forbidden, forbidden
                local lines = status(env, hacker)
                contains(lines[1], "'terminal'")
                if offset < 0 then equal(lines[2], "Server minimum wait: 1 seconds remaining.")
                else contains(lines[2], "minimum wait has elapsed"); contains(lines[2], "does not mean the hack is complete") end
                contains(lines[3], "terminal steps"); contains(lines[3], "!quitConsole")
                equal(info.inUse, true); equal(console.removed, nil)
                equal(sessions[hacker].completeAt, deadline)
            end)
        end
    end
    test("status uses the captured server deadline rather than changed configuration", function()
        local env, _, hacker, _, information, sessions = fixture()
        information.delay, information.inUse = 100, false
        env.now = 10.2
        equal(status(env, hacker)[2], "Server minimum wait: 4 seconds remaining.")
        equal(sessions[hacker].completeAt, 14)
    end)
    test("status isolates concurrent players even with equal console IDs and names", function()
        local env, owner, hacker, first, _, sessions = fixture()
        first.SlicerInformation.name = "first secret"
        local second = configure(env, hacker, "server", "second secret")
        second.id, second.name = first.id, first.name
        env.now = 11; env.open(owner, second)
        contains(status(env, hacker)[1], "first secret")
        contains(status(env, owner)[1], "second secret")
        equal(sessions[hacker].console, first); equal(sessions[owner].console, second)
    end)
    test("status accepts only the exact bare command under both hook orders", function()
        local env, _, hacker = fixture()
        local names = {}; for name in pairs(env.hooks.PlayerSay) do names[#names + 1] = name end
        table.sort(names)
        for _, reverse in ipairs({false, true}) do
            for _, command in ipairs({"!hackstatus", "!HackStatus", "!hackStatus ", " !hackStatus", "!hackStatus 1",
                "!hackStatus\t", "!hackStatus\n", "!hackStatus\0", "!hackStatusMore", "!hackStatus" .. string.rep("x", 1000)}) do
                local before, check = #hacker.chats, unchanged(env, hacker, upvalue(env.ENT.AcceptInput, "sessions"))
                for step = 1, #names do
                    equal(env.hooks.PlayerSay[names[reverse and (#names - step + 1) or step]](hacker, command), nil)
                end
                equal(#hacker.chats, before); check()
            end
        end
        status(env, hacker)
    end)
    test("status consumes invalid dead and nonplayer requesters silently", function()
        local env, _, hacker = fixture()
        local nonplayer = env.entity("prop_physics")
        function nonplayer:ChatPrint() error("Nonplayer received status") end
        local before = #hacker.chats
        hacker.alive = false; equal(env.fire("PlayerSay", hacker, "!hackStatus"), "")
        hacker.alive, hacker.valid = true, false; equal(env.fire("PlayerSay", hacker, "!hackStatus"), "")
        equal(env.fire("PlayerSay", nil, "!hackStatus"), "")
        equal(env.fire("PlayerSay", nonplayer, "!hackStatus"), "")
        equal(#hacker.chats, before)
    end)
    test("the status callback ignores nonstring input without requester access", function()
        local env = gmod.new()
        local callback = assert(env.hooks.PlayerSay.slicerHackStatus, "Missing status callback")
        env.IsValid = function() error("Nonmatch accessed requester") end
        equal(callback(nil, nil), nil)
        for _, value in ipairs({false, true, 0, {}, function() end}) do equal(callback(nil, value), nil) end
    end)
    test("status preserves list expiry pending selection edit authority and hack timing", function()
        local env, owner, hacker, active, _, sessions = fixture()
        local selected = configure(env, hacker, "tools", "selection")
        -- A separate idle console retains its edit ticket through status reads.
        local editable = configure(env, hacker, "data", "editable")
        hacker.target = editable; equal(env.fire("PlayerSay", hacker, "!editConsole"), "")
        local edit = assert(env.lastMessage("SlicerSetupEditOpen"))
        hacker.SlicerPendingConsole = selected
        equal(env.fire("PlayerSay", hacker, "!listConsoles"), "")
        env.now = 13.9; status(env, hacker)
        equal(env.slicerListedConsole(hacker, 1), selected)
        equal(sessions[hacker].completeAt, 14)
        env.now = 14; status(env, hacker)
        env.receive("destroyOnServer", hacker, active)
        equal(active.removed, true, "Inspection must retain completion at the original deadline")
        env.receive("SlicerSetupEditSave", hacker, editable, edit.values[3], {name = "edited", delay = 2, fileName = "secret"})
        equal(env.lastMessage("SlicerSetupEditReply").values[2].ok, true)
        equal(hacker.SlicerPendingConsole, selected)
        env.now = 70; equal(env.slicerListedConsole(hacker, 1), nil)
    end)
    for _, field in ipairs({"deadline", "clock"}) do
        test("status refuses nonfinite and nonnumeric " .. field .. " without changing the session", function()
            for _, value in ipairs({math.huge, -math.huge, 0 / 0, "14", false}) do
                local env, _, hacker, _, _, sessions = fixture()
                if field == "deadline" then sessions[hacker].completeAt = value else env.now = value end
                local line = status(env, hacker, 1)[1]
                contains(line, "status is unavailable"); contains(line, "!quitConsole")
            end
            local env, _, hacker, _, _, sessions = fixture()
            if field == "deadline" then sessions[hacker].completeAt = nil else env.now = nil end
            contains(status(env, hacker, 1)[1], "status is unavailable")
        end)
    end
    test("status refuses overflowing subtraction and bounds large finite waits", function()
        local env, _, hacker, _, _, sessions = fixture()
        sessions[hacker].completeAt, env.now = 1e308, -1e308
        contains(status(env, hacker, 1)[1], "status is unavailable")
        env.now = 0
        contains(status(env, hacker)[2], "seconds remaining")
    end)
    for _, name in ipairs({"  Literal%[]'\\Name  ", string.rep("A", 128), string.rep("界", 42) .. "é"}) do
        test("status preserves a bounded literal name of " .. #name .. " bytes", function()
            local env, _, hacker, console = fixture()
            console.SlicerInformation.name = name
            equal(status(env, hacker)[1], "Your hacking session: console '" .. name .. "'.")
        end)
    end
    test("status cleans controls only in its displayed name and handles invalid names", function()
        local env, _, hacker, console = fixture()
        console.SlicerInformation.name = " A\0\1\31\127\194\128\194\159\226\128\168\226\128\169Z "
        equal(status(env, hacker)[1], "Your hacking session: console ' A????????Z '.")
        for _, value in ipairs({"", "   ", string.rep("A", 129), false, {}, 3}) do
            console.SlicerInformation.name = value
            equal(status(env, hacker)[1], "You have a current hacking session.")
        end
        console.SlicerInformation = nil
        equal(status(env, hacker)[1], "You have a current hacking session.")
    end)
    for _, action in ipairs({"quit", "remove", "death", "disconnect", "complete"}) do
        test("status reports no session after normal " .. action, function()
            local env, _, hacker, console = fixture()
            if action == "quit" then equal(env.fire("PlayerSay", hacker, "!quitConsole"), "")
            elseif action == "remove" then console:Remove()
            elseif action == "death" then env.fire("PlayerDeath", hacker)
            elseif action == "disconnect" then env.fire("PlayerDisconnected", hacker)
            else env.now = 14; env.receive("destroyOnServer", hacker, console) end
            equal(status(env, hacker, 1)[1], "You are not in a hacking session.")
        end)
    end
    test("status describes an invalid retained console without cleaning its reservation", function()
        local env, _, hacker, console, information, sessions = fixture()
        console.valid = false
        contains(status(env, hacker, 1)[1], "status is unavailable")
        equal(sessions[hacker].console, console); equal(information.inUse, true)
    end)
    for _, boundary in ipairs({"Alive", "GetClass", "CurTime"}) do
        test("status stops when " .. boundary .. " replaces the exact session on the same console", function()
            local env, _, hacker, console, _, sessions = fixture()
            local old = sessions[hacker]
            local object = boundary == "Alive" and hacker or (boundary == "GetClass" and console or env)
            local original = object[boundary]
            object[boundary] = function(...)
                object[boundary] = original
                env.receive("playerQuitConsole", hacker)
                env.open(hacker, console)
                return original(...)
            end
            local before = #hacker.chats
            equal(env.fire("PlayerSay", hacker, "!hackStatus"), "")
            equal(#hacker.chats, before, "Retired status must not describe the replacement")
            assert(sessions[hacker] ~= old); equal(sessions[hacker].console, console)
        end)
    end
    for _, action in ipairs({"quit", "remove", "death", "replace", "status"}) do
        test("status stops its remaining lines after feedback reenters " .. action, function()
            local env, _, hacker, console, _, sessions = fixture()
            local original, before = hacker.ChatPrint, #hacker.chats
            function hacker:ChatPrint(line)
                self.ChatPrint = original
                original(self, line)
                if action == "quit" then env.receive("playerQuitConsole", self)
                elseif action == "remove" then console:Remove()
                elseif action == "death" then self.alive = false; env.fire("PlayerDeath", self)
                elseif action == "replace" then env.receive("playerQuitConsole", self); env.open(self, console)
                else equal(env.fire("PlayerSay", self, "!hackStatus"), "") end
            end
            equal(env.fire("PlayerSay", hacker, "!hackStatus"), "")
            equal(#hacker.chats, before + (action == "status" and 4 or 1))
            if action == "replace" or action == "status" then equal(sessions[hacker].console, console) end
        end)
    end
    test("status catches requester accessor and reply errors while remaining private", function()
        for _, boundary in ipairs({"IsPlayer", "Alive", "GetClass", "ChatPrint"}) do
            local env, _, hacker, console, _, sessions = fixture()
            local object = boundary == "GetClass" and console or hacker
            local old = object[boundary]
            object[boundary] = function() error("injected status callback failure") end
            local check = unchanged(env, hacker, sessions)
            equal(env.fire("PlayerSay", hacker, "!hackStatus"), ""); check()
            object[boundary] = old
            status(env, hacker)
        end
    end)
end
