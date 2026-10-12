-- Exercise real production PlayerSay hooks and existing row actions. Vector and
-- transport doubles check numerical decisions, not native GMod movement/chat.
return function(gmod, test, equal)
    local support = dofile("tests/console-locator-support.lua")(gmod)
    local function contains(text, part)
        assert(text:find(part, 1, true), "Missing " .. part .. " in " .. text)
    end
    local function say(env, actor, command) return env.fire("PlayerSay", actor, command) end
    local function position(entity, x, y, z, calls)
        entity.position = support.vector(x, y or 0, z or 0)
        function entity:GetPos()
            if calls then calls[self] = (calls[self] or 0) + 1 end
            return self.position
        end
    end
    local function fixture(count, folder)
        local env = support.server()
        local owner, other = env.player(), env.player()
        local consoles, calls = {}, {}
        position(owner, 0, 0, 0, calls)
        position(other, 0, 0, 0, calls)
        for i = 1, count or 1 do
            local console = env.console(owner)
            env.receive("AdminFinishedCreation", owner, {"console" .. i, 2, folder or "data", "secret", console:GetName()})
            consoles[i] = console
            position(console, i * 10, 0, 0, calls)
        end
        return env, owner, other, consoles, calls
    end
    local function listing(env, owner, command)
        local first = #owner.chats + 1
        equal(say(env, owner, command or "!nearConsoles"), "", "Recognized nearest request must be consumed")
        local messages, rows = {}, {}
        for i = first, #owner.chats do
            local message = owner.chats[i]
            assert(#message <= 255, "Private chat exceeds 255 bytes")
            assert(not message:find("[%z\1-\31\127]"), "Private chat has an ASCII control")
            messages[#messages + 1] = message
            if message:match("^[1-5]%. Console.*%(current ID #") then rows[#rows + 1] = message end
        end
        assert(#messages > 0, "Nearest request needs private feedback")
        assert(#rows <= 5, "Nearest page has more than five rows")
        return messages, rows
    end
    local function order(env, owner, rows, expected)
        equal(#rows, #expected)
        for i, console in ipairs(expected) do
            owner.target = console
            local eyeTrace = owner.GetEyeTrace
            owner.GetEyeTrace = function() return {Entity = console} end
            equal(say(env, owner, "!inspectLink"), "")
            owner.GetEyeTrace = eyeTrace
            equal(rows[i], i .. ". " .. owner.chats[#owner.chats], "Nearest rows must reuse exact inspection strings")
            equal(env.slicerListedConsole(owner, i), console, "Nearest lease binds exact entities")
        end
    end
    local function snapshot(env, owner)
        local records, seen = {}, {}
        local function visit(value)
            if type(value) ~= "table" or seen[value] then return end
            seen[value] = true
            local fields = {}; records[#records + 1] = {value, fields}
            for key, child in pairs(value) do
                if value ~= owner or key ~= "chats" then fields[key] = child; visit(child) end
            end
        end
        visit(env.entities); visit(env.messages); visit(env.returnSpawnedEntities())
        local now, serial, outgoing = env.now, env.slicerSetupEditSerial, env.outgoing
        return function()
            equal(env.now, now); equal(env.slicerSetupEditSerial, serial); equal(env.outgoing, outgoing)
            for _, entry in ipairs(records) do
                local value, fields = entry[1], entry[2]
                for key, child in pairs(fields) do equal(value[key], child, "Nearest listing mutated " .. tostring(key)) end
                for key, child in pairs(value) do
                    if value ~= owner or key ~= "chats" then equal(child, fields[key], "Nearest listing added " .. tostring(key)) end
                end
            end
        end
    end

    test("nearest catalogue orders a one-sample 3D request snapshot before private feedback", function()
        local env, owner, other, consoles, calls = fixture(5)
        position(consoles[1], 0, 0, 12, calls)
        position(consoles[2], 3, 4, 0, calls)
        position(consoles[3], -2, 0, 0, calls)
        position(consoles[4], 0, 6, 0, calls)
        position(consoles[5], 0, 0, 0, calls)
        local sort = env.table.sort
        env.table.sort = function(values, comparator)
            equal(calls[owner], 1, "Player position must be sampled before sorting")
            for _, console in ipairs(consoles) do equal(calls[console], 1, "Console positions must precede sorting") end
            local guarded = function(a, b)
                local result = comparator(a, b)
                equal(calls[owner], 1)
                for _, console in ipairs(consoles) do equal(calls[console], 1, "Comparator sampled a console position") end
                return result
            end
            return sort(values, guarded)
        end
        local chat = owner.ChatPrint
        function owner:ChatPrint(message)
            equal(calls[self], 1)
            for _, console in ipairs(consoles) do equal(calls[console], 1, "Feedback sampled a console position") end
            chat(self, message)
        end
        local unchanged = snapshot(env, owner)
        local messages, rows = listing(env, owner)
        unchanged()
        contains(messages[1], "nearest-first request snapshot")
        order(env, owner, rows, {consoles[5], consoles[3], consoles[2], consoles[4], consoles[1]})
        equal(#other.chats, 0); equal(calls[other], nil)
    end)

    test("nearest equal distances tie by creation ID then entity index without sorting enumeration", function()
        local env, owner, _, consoles, calls = fixture(4)
        local ids = {8, 2, 2, 1}
        for i, console in ipairs(consoles) do console.id = ids[i]; position(console, i % 2 == 0 and -5 or 5, 0, 0, calls) end
        local original = {consoles[3], consoles[1], consoles[4], consoles[2]}
        env.ents.FindByClass = function() return original end
        local _, rows = listing(env, owner)
        order(env, owner, rows, {consoles[4], consoles[2], consoles[3], consoles[1]})
        equal(original[1], consoles[3]); equal(original[2], consoles[1]); equal(original[3], consoles[4]); equal(original[4], consoles[2])
    end)

    test("nearest copies the sampled origin before subsequent mutable vector changes", function()
        local env, owner, _, consoles = fixture(2)
        local first, original = consoles[1], consoles[1].GetPos
        function first:GetPos() owner.position.x = 1000; return original(self) end
        local _, rows = listing(env, owner)
        order(env, owner, rows, {consoles[1], consoles[2]})
    end)

    test("nearest copies each console coordinate sample before sampling the next console", function()
        local env, owner, _, consoles = fixture(2)
        local shared = support.vector(1, 0, 0)
        local first, second = consoles[1], consoles[2]
        function first:GetPos() return shared end
        function second:GetPos() shared.x = 100; return shared end
        local _, rows = listing(env, owner)
        order(env, owner, rows, {consoles[1], consoles[2]})
    end)

    local unavailable = {
        {name = "missing method", apply = function(entity) entity.GetPos = nil end},
        {name = "throwing method", apply = function(entity) function entity:GetPos() error("No position") end end},
        {name = "nil vector", apply = function(entity) function entity:GetPos() return nil end end},
        {name = "missing coordinate", apply = function(entity) entity.position.z = nil end},
        {name = "string coordinate", apply = function(entity) entity.position.x = "1" end},
        {name = "NaN coordinate", apply = function(entity) entity.position.y = 0 / 0 end},
        {name = "positive infinity", apply = function(entity) entity.position.z = math.huge end},
        {name = "negative infinity", apply = function(entity) entity.position.x = -math.huge end},
        {name = "throwing coordinate", apply = function(entity) entity.position = setmetatable({}, {__index = function() error("No coordinate") end}) end},
    }
    for _, case in ipairs(unavailable) do
        test("nearest privately refuses an unavailable player origin: " .. case.name, function()
            local env, owner, other, consoles = fixture()
            equal(say(env, owner, "!listConsoles"), "")
            equal(env.slicerListedConsole(owner, 1), consoles[1])
            case.apply(owner)
            function env.ents.FindByClass() error("Invalid origin must not enumerate consoles") end
            local messages, rows = listing(env, owner)
            equal(#messages, 1); equal(#rows, 0)
            contains(messages[1], "position"); contains(messages[1], "!nearConsoles"); contains(messages[1], "again")
            equal(env.slicerListedConsole(owner, 1), nil); equal(#other.chats, 0)
        end)
        test("nearest retains an unmeasured owned console: " .. case.name, function()
            local env, owner, _, consoles = fixture(2)
            case.apply(consoles[1]); consoles[1].id = 0
            local _, rows = listing(env, owner)
            order(env, owner, rows, {consoles[2], consoles[1]})
        end)
    end

    test("nearest retains squared-overflow and subtraction-overflow consoles after finite distances", function()
        local env, owner, _, consoles, calls = fixture(5)
        position(consoles[1], 1e200, 0, 0, calls)
        position(consoles[2], 1e308, 0, 0, calls)
        position(consoles[3], -1e308, 0, 0, calls)
        position(owner, -1e308, 0, 0, calls)
        position(consoles[4], -1e308, 0, 0, calls)
        consoles[1].id, consoles[2].id, consoles[5].id = 2, 1, 2
        local _, rows = listing(env, owner)
        order(env, owner, rows, {consoles[3], consoles[4], consoles[2], consoles[1], consoles[5]})
    end)

    test("nearest retains all unknown-distance consoles with the old tie order", function()
        local env, owner, _, consoles = fixture(3)
        for _, console in ipairs(consoles) do console.GetPos = nil end
        consoles[1].id, consoles[2].id, consoles[3].id = 2, 1, 1
        local _, rows = listing(env, owner)
        order(env, owner, rows, {consoles[2], consoles[3], consoles[1]})
    end)

    test("nearest includes setup data server tools and reserved consoles privately without mutation", function()
        local env, owner, other, consoles, calls = fixture(4)
        consoles[2].SlicerInformation.fileType = "server"
        consoles[3].SlicerInformation.fileType = "tools"
        env.open(other, consoles[4])
        local setup = env.console(owner); position(setup, 1, 0, 0, calls)
        owner.SlicerPendingConsole = consoles[3]
        owner.target = consoles[1]; equal(say(env, owner, "!editConsole"), "")
        local ticket = env.lastMessage("SlicerSetupEditOpen").values[3]
        owner.weapon = nil
        function owner:GetEyeTrace() error("Nearest listing must not trace") end
        function owner:GetActiveWeapon() error("Nearest listing must not inspect a weapon") end
        local unchanged = snapshot(env, owner)
        local _, rows = listing(env, owner)
        unchanged(); order(env, owner, rows, {setup, consoles[1], consoles[2], consoles[3], consoles[4]})
        equal(owner.SlicerPendingConsole, consoles[3]); equal(consoles[4].SlicerInformation.inUse, true)
        env.receive("SlicerSetupEditSave", owner, consoles[1], ticket, {name = "renamed", delay = 3, fileName = "new"})
        equal(env.lastMessage("SlicerSetupEditReply").values[2].ok, true, "Listing must preserve the edit ticket")
        env.now = 4; env.receive("destroyOnServer", other, consoles[4])
        equal(consoles[4].removed, true, "Listing must preserve an unrelated hack's original deadline")
    end)

    test("nearest filters live exact ownership before position access without admin override", function()
        local env, owner, other, consoles = fixture(1)
        function owner:IsAdmin() return true end
        local foreign = env.console(other)
        local removed = env.console(owner); removed:Remove()
        local ownerless = env.entity("consoleent")
        local prop = env.entity("prop_physics"); prop.SlicerCreator = owner
        for _, entity in ipairs({foreign, removed, ownerless, prop}) do function entity:GetPos() error("Filtered entity was sampled") end end
        env.ents.FindByClass = function() return {false, foreign, removed, ownerless, prop, consoles[1]} end
        local _, rows = listing(env, owner); order(env, owner, rows, {consoles[1]})
        equal(#other.chats, 0)
    end)

    for _, count in ipairs({0, 5, 6, 12}) do
        test("nearest paginates " .. count .. " owned consoles with command-preserving hints", function()
            local env, owner, _, consoles, calls = fixture(count)
            for page = 1, math.max(1, math.ceil(count / 5)) do
                local messages, rows = listing(env, owner, "!nearConsoles" .. (page == 1 and "" or " " .. page))
                equal(#rows, math.min(5, math.max(0, count - (page - 1) * 5)))
                if count == 0 then equal(messages[1], "You have no consoles."); equal(env.slicerListedConsole(owner, 1), nil)
                else
                    contains(messages[1], "page " .. page .. " of " .. math.ceil(count / 5))
                    contains(messages[1], "(" .. count .. " total)")
                    if page < math.ceil(count / 5) then equal(messages[#messages], "Next page: !nearConsoles " .. (page + 1) .. ".")
                    elseif page > 1 then equal(messages[#messages], "First page: !nearConsoles.") end
                    for row = 1, #rows do equal(env.slicerListedConsole(owner, row), consoles[(page - 1) * 5 + row]) end
                end
                equal(calls[owner], page)
                for _, console in ipairs(consoles) do equal(calls[console], page) end
            end
        end)
    end

    test("nearest resamples movement on each page request while previous rows keep their entities", function()
        local env, owner, _, consoles, calls = fixture(6)
        listing(env, owner)
        position(owner, 100, 0, 0, calls)
        position(consoles[1], 1000, 0, 0, calls)
        equal(env.slicerListedConsole(owner, 1), consoles[1], "Movement must not rerun a printed row")
        equal(say(env, owner, "!locateConsole 1"), "")
        equal(env.lastMessage("SlicerConsoleLocation").values[3].x, 1000)
        local messages, rows = listing(env, owner, "!nearConsoles 2")
        contains(messages[1], "page 2 of 2"); order(env, owner, rows, {consoles[1]})
        local _, first = listing(env, owner, "!nearConsoles 1")
        order(env, owner, first, {consoles[6], consoles[5], consoles[4], consoles[3], consoles[2]})
        equal(calls[owner], 3)
    end)

    test("nearest rejects malformed recognized arguments before enumeration conversion or position access", function()
        local env, owner, other = fixture()
        function env.ents.FindByClass() error("Malformed nearest request enumerated") end
        function owner:GetPos() error("Malformed nearest request sampled") end
        function env.tonumber() error("Malformed nearest request converted") end
        for _, suffix in ipairs({" ", " 0", " 01", " -1", " +1", " 1.0", " 1e1", " 1 ", " 1 2", "  1", " 10000000", " ١", "\t1", "\n1", "\r1", "\v1", "\f1", " 1 setup extra", " 1 reactor", " " .. string.rep("9", 200000)}) do
            local messages, rows = listing(env, owner, "!nearConsoles" .. suffix)
            equal(#messages, 1); equal(#rows, 0); contains(messages[1], "Usage:"); contains(messages[1], "1-7"); contains(messages[1], "no leading zero")
            equal(env.slicerListedConsole(owner, 1), nil)
        end
        equal(#other.chats, 0)
    end)

    test("nearest command near matches remain ordinary chat and keep the previous lease", function()
        local env, owner, _, consoles, calls = fixture()
        listing(env, owner)
        local chats, samples = #owner.chats, calls[owner]
        for _, command in ipairs({"!nearConsolesNow", "!nearConsoles1", "!nearConsoles/2", "!nearconsoles", "!NEARCONSOLES 1", " !nearConsoles", "hello"}) do
            equal(say(env, owner, command), nil); equal(#owner.chats, chats); equal(calls[owner], samples)
            equal(env.slicerListedConsole(owner, 1), consoles[1])
        end
    end)

    for _, actorKind in ipairs({"missing", "invalid", "non-player", "dead"}) do
        test("nearest consumes requests and clears prior authority for a " .. actorKind .. " caller", function()
            local env, owner = fixture()
            listing(env, owner)
            local actor = owner
            if actorKind == "missing" then actor = nil
            elseif actorKind == "invalid" then actor.valid = false
            elseif actorKind == "non-player" then actor.class = "prop_physics"
            else actor.alive = false end
            function owner:ChatPrint() error("Ineligible requester got output") end
            function owner:GetPos() error("Ineligible requester sampled") end
            function env.ents.FindByClass() error("Ineligible requester enumerated") end
            for _, command in ipairs({"!nearConsoles", "!nearConsoles 2", "!nearConsoles 0", "!nearConsoles\t1"}) do equal(say(env, actor, command), "") end
            if actor then owner.valid, owner.class, owner.alive = true, "player", true; equal(env.slicerListedConsole(owner, 1), nil) end
        end)
    end

    for _, command in ipairs({"!nearConsoles 01", "!nearConsoles 2", "!nearConsoles 9999999"}) do
        test("nearest recognized invalid request replaces another catalogue lease: " .. command, function()
            local env, owner, other, consoles = fixture()
            equal(say(env, owner, "!findConsoles 1 console"), "")
            equal(env.slicerListedConsole(owner, 1), consoles[1])
            local messages, rows = listing(env, owner, command)
            equal(#rows, 0); equal(#messages, 1)
            if command ~= "!nearConsoles 01" then contains(messages[1], "between 1 and 1"); contains(messages[1], "!nearConsoles <page>") end
            equal(env.slicerListedConsole(owner, 1), nil); equal(#other.chats, 0)
        end)
    end

    test("nearest empty inventory clears a previously printed row", function()
        local env, owner, _, consoles = fixture()
        listing(env, owner); consoles[1]:Remove()
        local messages = listing(env, owner)
        equal(messages[1], "You have no consoles."); equal(env.slicerListedConsole(owner, 1), nil)
    end)

    test("nearest installs all exact rows before callbacks and retains a newer reentrant request", function()
        local env, owner, _, consoles, calls = fixture(2)
        local chat, entered = owner.ChatPrint, false
        function owner:ChatPrint(message)
            chat(self, message)
            if not entered then
                entered = true
                equal(env.slicerListedConsole(owner, 1), consoles[1]); equal(env.slicerListedConsole(owner, 2), consoles[2])
                consoles[1]:Remove(); consoles[2].SlicerInformation.name = "renamed"
                local first = consoles[1]
                function first:GetCreationID() error("Old entity reread during chat") end
                equal(say(env, owner, "!findConsoles 1 renamed"), "")
            end
        end
        local messages = listing(env, owner)
        local rendered = table.concat(messages, "\n")
        contains(rendered, "'console1'"); contains(rendered, "'console2'"); contains(rendered, "'renamed'")
        equal(env.slicerListedConsole(owner, 1), consoles[2]); equal(env.slicerListedConsole(owner, 2), nil)
        equal(calls[owner], 1); equal(calls[consoles[1]], 1); equal(calls[consoles[2]], 1)
    end)

    test("nearest reentrant invalidation cannot be overwritten by the older request", function()
        local env, owner = fixture()
        local chat, entered = owner.ChatPrint, false
        function owner:ChatPrint(message)
            chat(self, message)
            if not entered then entered = true; equal(say(env, owner, "!nearConsoles 0"), "") end
        end
        listing(env, owner); equal(env.slicerListedConsole(owner, 1), nil)
    end)

    test("nearest exact row actions share a lease and retain creator eligibility", function()
        local env, owner, other, consoles, calls = fixture(2, "tools")
        position(consoles[2], 1, 0, 0, calls)
        local foreign = env.console(other); env.configure(other, foreign, "tools"); position(foreign, 1, 0, 0, calls)
        listing(env, owner); listing(env, other)
        function owner:GetEyeTrace() error("Nearest row action must not trace") end
        equal(say(env, owner, "!setEntity 1"), ""); equal(owner.SlicerPendingConsole, consoles[2])
        equal(say(env, owner, "!editConsole 1"), ""); equal(env.lastMessage("SlicerSetupEditOpen").values[1], consoles[2])
        equal(say(env, owner, "!locateConsole 1"), ""); equal(env.lastMessage("SlicerConsoleLocation").values[3].x, 1)
        consoles[2].SlicerCreator = other
        equal(env.slicerListedConsole(owner, 1), nil); equal(env.slicerListedConsole(other, 1), foreign)
        local before = #env.messages
        equal(say(env, owner, "!editConsole 1"), ""); equal(#env.messages, before)
        equal(say(env, owner, "!setEntity 1"), ""); equal(owner.SlicerPendingConsole, consoles[2])
    end)

    test("nearest row locating editing and selection never extend the exact sixty-second lease", function()
        local env, owner, _, consoles = fixture(1, "tools")
        env.now = 10; listing(env, owner)
        env.now = 69.99
        equal(say(env, owner, "!locateConsole clear"), "")
        equal(say(env, owner, "!locateConsole 1"), "")
        equal(say(env, owner, "!editConsole 1"), "")
        equal(say(env, owner, "!setEntity 1"), "")
        equal(env.slicerListedConsole(owner, 1), consoles[1])
        env.now = 70; equal(env.slicerListedConsole(owner, 1), nil)
        local before = #env.messages
        equal(say(env, owner, "!editConsole 1"), ""); equal(#env.messages, before)
    end)

    for _, invalidation in ipairs({"removed", "reclassified", "death", "disconnect"}) do
        test("nearest leased rows recheck " .. invalidation .. " before access", function()
            local env, owner, _, consoles = fixture()
            listing(env, owner)
            if invalidation == "removed" then consoles[1]:Remove()
            elseif invalidation == "reclassified" then consoles[1].class = "prop_physics"
            elseif invalidation == "death" then owner.alive = false; env.fire("PlayerDeath", owner); owner.alive = true
            else env.fire("PlayerDisconnected", owner) end
            equal(env.slicerListedConsole(owner, 1), nil)
        end)
    end

    test("nearest leaves an existing locator packet and pending setup acknowledgement untouched", function()
        local env, owner, _, consoles, calls = fixture()
        equal(say(env, owner, "!listConsoles"), "")
        equal(say(env, owner, "!locateConsole 1"), "")
        local marker = env.lastMessage("SlicerConsoleLocation")
        local setup = env.console(owner); position(setup, 1, 0, 0, calls)
        env.receive("AdminFinishedCreation", owner, {"new", 2, "server", "file", setup:GetName(), "123"})
        local result = env.lastMessage("SlicerInitialSetupReply")
        local unchanged = snapshot(env, owner)
        listing(env, owner); unchanged()
        equal(env.lastMessage("SlicerConsoleLocation"), marker)
        equal(env.lastMessage("SlicerInitialSetupReply"), result)
        assert(result, "Fixture must have a pending setup acknowledgement")
    end)

    for _, name in ipairs({string.rep("n", 128), string.rep("界", 42) .. "é", "a\0b\1c\9d\10e\13f\31g\127h\194\133i\226\128\168j"}) do
        test("nearest preserves inspection byte budgets and saved bytes for name " .. #name, function()
            local env, owner, _, consoles = fixture(1, "tools")
            local console = consoles[1]; console.SlicerInformation.name = name
            console.id = 10000000
            local door = env.entity("func_door_rotating"); door.id = 10000000
            owner.target = console; equal(say(env, owner, "!setEntity"), "")
            owner.target = door; equal(say(env, owner, "!setEntity"), "")
            local _, rows = listing(env, owner); order(env, owner, rows, {console})
            equal(console.SlicerInformation.name, name)
        end)
    end

    test("default catalogue list and search retain exact bytes and add zero position calls", function()
        local env, owner, _, consoles = fixture(6)
        local setup = env.console(owner)
        function owner:GetPos() error("Default catalogue sampled requester") end
        for _, console in ipairs(consoles) do function console:GetPos() error("Default catalogue sampled console") end end
        function setup:GetPos() error("Default catalogue sampled setup console") end
        local function row(index, console)
            return index .. ". Console '" .. console.SlicerInformation.name .. "' (current ID #" .. console:GetCreationID() .. "): configured for data; door linking is for tools consoles."
        end
        local function expected(command, messages)
            local actual = listing(env, owner, command)
            equal(#actual, #messages)
            for i, message in ipairs(messages) do equal(actual[i], message, "Default catalogue byte parity") end
        end
        expected("!listConsoles", {"Your consoles: page 1 of 2 (7 total). Locate: !locateConsole <row>.", row(1, consoles[1]), row(2, consoles[2]), row(3, consoles[3]), row(4, consoles[4]), row(5, consoles[5]), "Next page: !listConsoles 2."})
        expected("!listConsoles 2", {"Your consoles: page 2 of 2 (7 total). Locate: !locateConsole <row>.", row(1, consoles[6]), "2. Console (current ID #" .. setup:GetCreationID() .. "): needs setup. Use it to configure it.", "First page: !listConsoles."})
        expected("!findConsoles 1 console", {"Your matching consoles: page 1 of 2 (6 matches). Locate: !locateConsole <row>.", row(1, consoles[1]), row(2, consoles[2]), row(3, consoles[3]), row(4, consoles[4]), row(5, consoles[5]), "Next page: !findConsoles 2 console"})
        expected("!findConsoles 2 console", {"Your matching consoles: page 2 of 2 (6 matches). Locate: !locateConsole <row>.", row(1, consoles[6]), "First page: !findConsoles 1 console"})
        expected("!listConsoles 1 setup", {"Your consoles (setup): page 1 of 1 (1 total). Locate: !locateConsole <row>.", "1. Console (current ID #" .. setup:GetCreationID() .. "): needs setup. Use it to configure it."})
        expected("!findConsoles 1 absent", {"No matching console names. Use !listConsoles for all your consoles, including those needing setup."})
    end)
end
