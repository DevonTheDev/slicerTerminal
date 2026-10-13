-- Fixed pending-target cases, executed against the actual server hook. Native
-- encoding, multiplayer transport and rendering remain real-engine smoke scope.
return function(gmod, test, equal)
    local support = dofile("tests/console-locator-support.lua")(gmod)
    local function contains(text, part) assert(text:find(part, 1, true), "Missing " .. part .. " in " .. text) end
    local function forbidden() error("Pending locator used unrelated authority") end
    local function configured(env, owner, name)
        local console = env.console(owner)
        assert(env.configure(owner, console, "tools", 2))
        console.SlicerInformation.name = name or "alpha"
        return console
    end
    local function fixture()
        local env = support.server(); env.Vector = support.vector
        local owner, other = env.player(), env.player()
        local console = configured(env, owner)
        return env, owner, console, other
    end
    local function say(env, owner, text) return env.fire("PlayerSay", owner, text or "!locateConsole pending") end
    local function upvalue(callback, wanted)
        for index = 1, 100 do
            local name, value = debug.getupvalue(callback, index)
            if not name then break end
            if name == wanted then return value end
        end
        error("Missing existing state: " .. wanted)
    end
    local function snapshot(env, owner)
        local saved, seen = {}, {[owner.chats] = true}
        local function visit(value)
            if type(value) ~= "table" or seen[value] then return end
            seen[value] = true
            local fields = {}; saved[#saved + 1] = {value, fields}
            for key, item in pairs(value) do fields[key] = item; visit(item) end
        end
        visit(env.entities); visit(env.returnSpawnedEntities())
        visit(upvalue(env.hooks.PlayerUse.isUsingOurObject, "linkedDoors"))
        visit(upvalue(env.slicerConsoleHasActiveSession, "sessions"))
        visit(upvalue(env.retireSlicerSetupEdit, "editTickets"))
        visit(upvalue(env.hooks.PlayerSay.slicerListConsoles, "consoleListings"))
        local serial = env.slicerSetupEditSerial
        local function same(actual, expected, message)
            if type(actual) == "number" and type(expected) == "number" and actual ~= actual and expected ~= expected then return end
            equal(actual, expected, message)
        end
        return function()
            equal(env.slicerSetupEditSerial, serial); equal(env.outgoing, nil)
            for _, record in ipairs(saved) do
                for key, value in pairs(record[2]) do same(record[1][key], value, "Changed " .. tostring(key)) end
                for key, value in pairs(record[1]) do same(value, record[2][key], "Added " .. tostring(key)) end
            end
        end
    end
    local function safe(text)
        assert(type(text) == "string" and #text > 0 and #text <= 240, "Display byte budget")
        assert(not text:find("[%z\1-\31\127]") and not text:find("\194[\128-\159]")
            and not text:find("\226\128[\168\169]"), "Display controls")
    end
    local function locate(env, owner, console)
        local before, chats, unchanged = #env.messages, #owner.chats, snapshot(env, owner)
        equal(say(env, owner), "", "Exact pending locator is consumed")
        equal(#env.messages, before + 1, "Pending locator must send exactly one private packet")
        local packet = env.messages[#env.messages]
        equal(packet.name, "SlicerConsoleLocation"); equal(packet.player, owner)
        equal(#packet.values, 3); equal(packet.values[1], true); safe(packet.values[2])
        equal(packet.values[3].x, console.position.x); equal(packet.values[3].y, console.position.y)
        equal(packet.values[3].z, console.position.z); equal(#owner.chats, chats); unchanged()
        return packet
    end
    local function reject(env, owner, fragment)
        local before, chats, prior, unchanged = #env.messages, #owner.chats, env.lastMessage("SlicerConsoleLocation"), snapshot(env, owner)
        equal(say(env, owner), ""); equal(#env.messages, before); equal(env.lastMessage("SlicerConsoleLocation"), prior)
        equal(#owner.chats, chats + 1); safe(owner.chats[#owner.chats])
        if fragment then contains(owner.chats[#owner.chats], fragment) end
        unchanged()
    end
    local function noAuthority(env, owner, console)
        owner.weapon, owner.target = nil, nil
        owner.GetEyeTrace, owner.GetActiveWeapon, owner.IsAdmin = forbidden, forbidden, forbidden
        env.ents.FindByClass, env.ents.FindByName, env.Entity = forbidden, forbidden, forbidden
        env.slicerListedConsole, env.normalizeSlicerInformation = forbidden, forbidden
        console.GetName, console.EntIndex = forbidden, forbidden
    end

    test("pending locator 01 retains exact A after page replacement with B", function()
        local env, owner, first, other = fixture(); local second = configured(env, owner, "beta")
        equal(say(env, owner, "!listConsoles"), "")
        equal(say(env, owner, "!setEntity 1"), ""); equal(owner.SlicerPendingConsole, first)
        equal(say(env, owner, "!findConsoles 1 beta"), ""); equal(env.slicerListedConsole(owner, 1), second)
        local chats, packets = #other.chats, #env.messages
        locate(env, owner, first)
        equal(#env.messages, packets + 1); equal(#other.chats, chats); equal(owner.SlicerPendingConsole, first)
        equal(env.slicerListedConsole(owner, 1), second)
        equal(say(env, owner, "!locateConsole 1"), "")
        equal(env.lastMessage("SlicerConsoleLocation").values[3].x, second.position.x)
    end)

    test("pending locator 02 accepts automatic bare and listed exact selection", function()
        for _, selection in ipairs({"automatic", "bare", "listed"}) do
            local env, owner, console = fixture()
            if selection ~= "automatic" then
                configured(env, owner, "beta")
                if selection == "bare" then owner.target = console; equal(say(env, owner, "!setEntity"), "")
                else equal(say(env, owner, "!listConsoles"), ""); equal(say(env, owner, "!setEntity 1"), "") end
            end
            equal(owner.SlicerPendingConsole, console); noAuthority(env, owner, console)
            locate(env, owner, console)
        end
    end)

    test("pending locator 03 survives exact row expiry and ordinary respawn", function()
        local env, owner, console = fixture(); equal(say(env, owner, "!listConsoles"), "")
        env.now = 60; locate(env, owner, console); equal(env.slicerListedConsole(owner, 1), nil)
        owner.alive = false; env.fire("PlayerDeath", owner); equal(owner.SlicerPendingConsole, console)
        owner.alive = true; env.now = 3600; noAuthority(env, owner, console); locate(env, owner, console)
        equal(owner.SlicerPendingConsole, console)
    end)

    test("pending locator 04 never substitutes duplicate names IDs or removed references", function()
        local env, owner, first = fixture(); local second = configured(env, owner, "alpha")
        second.id = first.id; owner.SlicerPendingConsole = first; noAuthority(env, owner, first)
        locate(env, owner, first); equal(owner.SlicerPendingConsole, first)
        first.valid = false; reject(env, owner, "unavailable"); equal(owner.SlicerPendingConsole, first)
        equal(second.removed, nil); equal(second.SlicerDoor, nil)
        -- Replacement identity is deliberately identical, but never authority.
        second.name = first.name; second.position = support.vector(999, 998, 997)
        reject(env, owner, "unavailable")
    end)

    test("pending locator 05 rejects invalid callers without target reads or row changes", function()
        for _, kind in ipairs({"nil", "invalid", "non-player", "dead"}) do
            local env, owner, console = fixture(); equal(say(env, owner, "!listConsoles"), "")
            console.GetClass, console.GetCreationID, console.WorldSpaceCenter = forbidden, forbidden, forbidden
            local actor = owner
            if kind == "nil" then actor = nil elseif kind == "invalid" then owner.valid = false
            elseif kind == "non-player" then owner.class = "prop_physics" else owner.alive = false end
            owner.ChatPrint = forbidden
            local before, unchanged = #env.messages, snapshot(env, owner)
            equal(say(env, actor), ""); equal(#env.messages, before); unchanged()
        end
    end)

    test("pending locator 06 preserves prior marker and nil removed foreign wrong-class opaque choices", function()
        for _, kind in ipairs({"nil", "removed", "foreign", "wrong-class", "opaque"}) do
            local env, owner, console, other = fixture(); locate(env, owner, console)
            if kind == "nil" then owner.SlicerPendingConsole = nil
            elseif kind == "removed" then console.valid = false
            elseif kind == "foreign" then console.SlicerCreator = other
            elseif kind == "wrong-class" then console.class = "prop_physics"
            else owner.SlicerPendingConsole = "opaque choice" end
            reject(env, owner, kind == "nil" and "no pending" or "unavailable")
            if kind ~= "nil" then contains(owner.chats[#owner.chats], "!cancelLink"); contains(owner.chats[#owner.chats], "!setEntity") end
        end
    end)

    test("pending locator 07 ignores configuration busy reservation and door eligibility", function()
        for _, state in ipairs({"unconfigured", "malformed", "data", "server", "busy", "reserved", "live-door", "removed-door"}) do
            local env, owner, console, other = fixture()
            if state == "unconfigured" then console.SlicerInformation = nil
            elseif state == "malformed" then console.SlicerInformation = false
            elseif state == "data" or state == "server" then console.SlicerInformation.fileType = state
            elseif state == "busy" then console.SlicerInformation.inUse = true
            elseif state == "reserved" then
                console.SlicerDoor = env.entity("func_door"); env.open(other, console)
                equal(env.slicerConsoleHasActiveSession(console), true)
            else console.SlicerDoor = env.entity("func_door"); if state == "removed-door" then console.SlicerDoor:Remove() end end
            locate(env, owner, console)
        end
    end)

    test("pending locator 08 bounds and cleans display names without changing saved bytes", function()
        for _, name in ipairs({string.rep("n", 128), string.rep("é", 64), string.rep("界", 42) .. "é", string.rep("🔐", 32),
            "A\0B\nC\127D\194\133E\226\128\168F\226\128\169G"}) do
            local env, owner, console = fixture(); console.SlicerInformation.name = name; console.id = 10000000
            local packet = locate(env, owner, console)
            local clean = name:gsub("[%z\1-\31\127]", "?"):gsub("\194[\128-\159]", "?"):gsub("\226\128[\168\169]", "?")
            contains(packet.values[2], "'" .. clean .. "'"); equal(console.SlicerInformation.name, name)
        end
        for _, info in ipairs({{}, {name = false}, {name = 42}, {name = ""}, {name = " \t "}, {name = string.rep("x", 129)}}) do
            local env, owner, console = fixture(); console.SlicerInformation = info; console.GetName = forbidden
            assert(not locate(env, owner, console).values[2]:find("'", 1, true))
        end
    end)

    test("pending locator 09 treats numeric creation IDs only as bounded optional labels", function()
        local env, owner, console = fixture()
        for _, id in ipairs({0, 1, 10000000}) do
            console.GetCreationID = function() return id end
            contains(locate(env, owner, console).values[2], "current ID #" .. string.format("%.0f", id))
        end
        for _, id in ipairs({false, "42", {}, -1, 1.5, 0 / 0, math.huge, -math.huge, 10000001}) do
            -- Do not place NaN in a strict-equality ordinary-state fixture.
            console.GetCreationID = function() return id end
            assert(not locate(env, owner, console).values[2]:find("current ID", 1, true))
        end
        console.GetCreationID = false; assert(not locate(env, owner, console).values[2]:find("current ID", 1, true))
        console.GetCreationID = function() return nil end; assert(not locate(env, owner, console).values[2]:find("current ID", 1, true))
        console.GetCreationID = forbidden
        local before, unchanged = #env.messages, snapshot(env, owner)
        equal(say(env, owner), ""); equal(#env.messages, before); unchanged()
    end)

    test("pending locator 10 copies one finite position sample and contains unusable positions", function()
        local env, owner, console = fixture(); local calls, copied = 0, nil
        local position = support.vector(111, 222, 333); console.position = position
        console.WorldSpaceCenter = function() calls = calls + 1; return position end
        env.net.WriteVector = function(value) copied = value; env.net.WriteString(support.vector(value.x, value.y, value.z)) end
        local packet = locate(env, owner, console); equal(calls, 1); assert(copied ~= position)
        position.x = 999; equal(packet.values[3].x, 111)
        for _, kind in ipairs({"missing-method", "throw", "nil", "missing-x", "nonnumeric", "nan", "positive-infinity", "negative-infinity"}) do
            local broken, player, target = fixture(); locate(broken, player, target)
            if kind == "missing-method" then target.WorldSpaceCenter = false
            elseif kind == "throw" then target.WorldSpaceCenter = forbidden
            else target.WorldSpaceCenter = function()
                if kind == "nil" then return nil end
                if kind == "missing-x" then return {y = 2, z = 3} end
                return {x = kind == "nonnumeric" and "1" or kind == "nan" and 0 / 0
                    or kind == "positive-infinity" and math.huge or -math.huge, y = 2, z = 3}
            end end
            local before, previous, unchanged = #broken.messages, broken.lastMessage("SlicerConsoleLocation"), snapshot(broken, player)
            equal(say(broken, player), ""); equal(#broken.messages, before)
            equal(broken.lastMessage("SlicerConsoleLocation"), previous); unchanged()
        end
    end)

    test("pending locator 11 suppresses fixed accessor reentry without restoring a pointer", function()
        for _, pair in ipairs({{"GetClass", "reselect"}, {"GetCreationID", "cancel"}, {"WorldSpaceCenter", "remove"},
            {"WorldSpaceCenter", "owner"}, {"WorldSpaceCenter", "class"}, {"WorldSpaceCenter", "death"}}) do
            local env, owner, console, other = fixture(); local replacement = configured(env, owner, "beta")
            owner.SlicerPendingConsole = console
            local accessor, action, calls = console[pair[1]], pair[2], 0
            console[pair[1]] = function(self)
                local value = accessor(self); self[pair[1]] = accessor; calls = calls + 1
                if action == "reselect" then owner.target = replacement; equal(say(env, owner, "!setEntity"), "")
                elseif action == "cancel" then equal(say(env, owner, "!cancelLink"), "")
                elseif action == "remove" then self:Remove()
                elseif action == "owner" then self.SlicerCreator = other
                elseif action == "class" then self.class = "prop_physics"
                else owner.alive = false end
                return value
            end
            local before = #env.messages
            equal(say(env, owner), ""); equal(calls, 1); equal(#env.messages, before)
            local expected = action == "reselect" and replacement or console
            if action == "cancel" or action == "remove" then expected = nil end
            equal(owner.SlicerPendingConsole, expected)
        end
    end)

    test("pending locator 12 preserves refusal reply reselection and contains throwing paths", function()
        local env, owner, console = fixture(); owner.SlicerPendingConsole = nil
        local feedback, calls = owner.ChatPrint, 0
        owner.ChatPrint = function(self, message)
            calls = calls + 1; self.ChatPrint = feedback; self.target = console
            equal(say(env, self, "!setEntity"), ""); feedback(self, message)
        end
        local before = #env.messages; equal(say(env, owner), ""); equal(calls, 1)
        equal(owner.SlicerPendingConsole, console); equal(#env.messages, before)
        for _, source in ipairs({"IsPlayer", "Alive", "GetClass", "GetCreationID", "WorldSpaceCenter", "ChatPrint"}) do
            local broken, player, target = fixture()
            if source == "ChatPrint" then player.SlicerPendingConsole = nil; player.ChatPrint = forbidden
            elseif source == "IsPlayer" or source == "Alive" then player[source] = forbidden
            else target[source] = forbidden end
            local packets, unchanged = #broken.messages, snapshot(broken, player)
            local ok, result = pcall(say, broken, player)
            equal(ok, true); equal(result, ""); equal(#broken.messages, packets); unchanged()
        end
    end)

    test("pending locator 16 keeps exact grammar and bounded help discoverability", function()
        local env, owner, console = fixture()
        for _, text in ipairs({"!locateConsole", "!locateConsole Pending", "!locateConsole pending ", "!locateConsole  pending",
            "!locateConsole\tpending", "!locateConsole pending extra", "!locateConsole pending\n", "!locateConsole pending\0"}) do
            local before, chats = #env.messages, #owner.chats
            equal(say(env, owner, text), ""); equal(#env.messages, before); equal(#owner.chats, chats + 1)
            safe(owner.chats[#owner.chats]); contains(owner.chats[#owner.chats], "Usage:")
            contains(owner.chats[#owner.chats], "pending")
        end
        for _, text in ipairs({"!locateconsole pending", "!LocateConsole pending", " !locateConsole pending", "!locateConsolepending", "hello"}) do
            local before, chats = #env.messages, #owner.chats
            equal(say(env, owner, text), nil); equal(#env.messages, before); equal(#owner.chats, chats)
        end
        locate(env, owner, console)
        for _, topic in ipairs({"browse", "links"}) do
            local before = #owner.chats; equal(say(env, owner, "!slicerHelp " .. topic), "")
            local lines = {}; assert(#owner.chats - before <= 10)
            for index = before + 1, #owner.chats do safe(owner.chats[index]); lines[#lines + 1] = owner.chats[index] end
            contains(table.concat(lines, "\n"), "!locateConsole pending")
        end
    end)
end
