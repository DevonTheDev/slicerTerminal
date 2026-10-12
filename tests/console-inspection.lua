-- Real PlayerSay callbacks and exact listed entities; no private registries.
return function(gmod, test, equal)
    local function contains(text, part)
        assert(text:find(part, 1, true), "Missing '" .. part .. "' in: " .. text)
    end
    local function configure(env, owner, name, folder)
        local console = env.console(owner)
        env.receive("AdminFinishedCreation", owner, {name or "terminal", 2, folder or "data", "secret", console:GetName()})
        assert(console.SlicerInformation)
        function console:GetPos() return {x = self.id, y = 0, z = 0} end
        return console
    end
    local function fixture(folder)
        local env = gmod.new()
        local owner, other = env.player(), env.player()
        function owner:GetPos() return {x = 0, y = 0, z = 0} end
        local console = configure(env, owner, nil, folder)
        equal(env.fire("PlayerSay", owner, "!listConsoles"), "")
        return env, owner, console, other
    end
    local function unchanged(env, owner)
        local records, seen = {}, {}
        local function same(actual, expected, message)
            if type(actual) == "number" and actual ~= actual and type(expected) == "number" and expected ~= expected then return end
            equal(actual, expected, message)
        end
        local function visit(value)
            if type(value) ~= "table" or seen[value] then return end
            seen[value] = true
            local fields = {}; records[#records + 1] = {value, fields}
            for key, child in pairs(value) do
                if value ~= owner or key ~= "chats" then fields[key] = child; visit(child) end
            end
        end
        visit(env.entities); visit(env.messages); visit(env.returnSpawnedEntities())
        local serial, outgoing = env.slicerSetupEditSerial, env.outgoing
        return function()
            equal(env.slicerSetupEditSerial, serial); equal(env.outgoing, outgoing)
            for _, record in ipairs(records) do
                for key, value in pairs(record[2]) do same(record[1][key], value, "Inspection changed " .. tostring(key)) end
                for key, value in pairs(record[1]) do
                    if record[1] ~= owner or key ~= "chats" then same(value, record[2][key], "Inspection added " .. tostring(key)) end
                end
            end
        end
    end
    local function inspect(env, owner, row, count)
        local before, check = #owner.chats, unchanged(env, owner)
        equal(env.fire("PlayerSay", owner, "!inspectConsole " .. (row or 1)), "", "Exact inspection must be consumed")
        equal(#owner.chats, before + (count or 3), "Inspection must give bounded private feedback")
        local lines = {}
        for i = before + 1, #owner.chats do
            local text = owner.chats[i]
            assert(#text <= 255, "Inspection exceeds 255 bytes")
            assert(not text:find("[%z\1-\31\127]") and not text:find("\194[\128-\159]")
                and not text:find("\226\128[\168\169]"), "Inspection contains display controls")
            lines[#lines + 1] = text
        end
        check()
        return lines
    end
    local function saved(lines, console, name, filename)
        contains(lines[1], "'" .. (name or console.SlicerInformation.name) .. "'")
        contains(lines[1], "current ID #" .. console:GetCreationID())
        contains(lines[1], "saved configuration")
        contains(lines[2], "Folder: " .. console.SlicerInformation.fileType)
        contains(lines[2], "base delay: ")
        equal(tonumber(lines[2]:match("base delay: (.-) seconds")), console.SlicerInformation.delay)
        equal(lines[3], "Saved filename (no extension): '" .. (filename or console.SlicerInformation.fileName) .. "'.")
    end
    for _, folder in ipairs({"data", "server", "tools"}) do
        test("saved inspection privately shows all " .. folder .. " fields without tool, target or distance", function()
            local env, owner, console, other = fixture(folder)
            owner.weapon, owner.target = nil, nil
            local function forbidden() error("Inspection requested action eligibility") end
            owner.GetActiveWeapon, owner.GetEyeTrace, owner.GetPos = forbidden, forbidden, forbidden
            console.GetPos, env.slicerConsoleHasActiveSession = forbidden, forbidden
            saved(inspect(env, owner), console)
            equal(#other.chats, 0)
        end)
    end
    test("inspection accepts only the exact 17-byte row grammar", function()
        local env, owner, console = fixture()
        for _, command in ipairs({"!inspectConsole", "!inspectConsole ", "!inspectConsole 0", "!inspectConsole 6",
            "!inspectConsole 01", "!inspectConsole 1 ", " !inspectConsole 1", "!inspectconsole 1",
            "!InspectConsole 1", "!inspectConsole\t1", "!inspectConsole  1", "!inspectConsole 1\n",
            "!inspectConsole 1 extra", "!inspectConsole1", "!inspectConsole １", "!inspectConsole " .. string.rep("1", 256)}) do
            local before, check = #owner.chats, unchanged(env, owner)
            equal(env.fire("PlayerSay", owner, command), nil, "Malformed inspection must remain ordinary chat")
            equal(#owner.chats, before); check()
        end
        for row = 1, 5 do
            if row == 1 then saved(inspect(env, owner, row), console)
            else contains(inspect(env, owner, row, 1)[1], "!listConsoles") end
        end
    end)
    test("inspection follows exact latest list, find and nearest rows independently per player", function()
        local env, owner, first, other = fixture()
        local second = configure(env, owner, "second")
        local foreign = configure(env, other, "foreign")
        equal(env.fire("PlayerSay", other, "!listConsoles"), "")
        saved(inspect(env, owner), first); saved(inspect(env, other), foreign)
        equal(env.fire("PlayerSay", owner, "!findConsoles 1 second"), "")
        saved(inspect(env, owner), second); saved(inspect(env, other), foreign)
        function second:GetPos() return {x = 0, y = 0, z = 0} end
        equal(env.fire("PlayerSay", owner, "!nearConsoles"), "")
        saved(inspect(env, owner), second); saved(inspect(env, owner, 2), first)
        equal(env.fire("PlayerSay", owner, "!listConsoles"), "")
        saved(inspect(env, owner), first); saved(inspect(env, owner, 2), second)
    end)
    test("inspection row identity survives duplicate names and IDs but never substitutes a replacement", function()
        local env, owner, first = fixture()
        local second = configure(env, owner)
        second.id = first.id
        first.SlicerInformation.fileName, second.SlicerInformation.fileName = "first", "second"
        equal(env.fire("PlayerSay", owner, "!listConsoles"), "")
        saved(inspect(env, owner), first); saved(inspect(env, owner, 2), second)
        first:Remove()
        local replacement = configure(env, owner)
        replacement.id, replacement.name = first.id, first.name
        contains(inspect(env, owner, 1, 1)[1], "unavailable or expired")
        saved(inspect(env, owner, 2), second)
    end)
    for _, change in ipairs({"removed", "reowned", "reclassified"}) do
        test("inspection refuses a listed entity that was " .. change, function()
            local env, owner, console, other = fixture()
            if change == "removed" then console:Remove()
            elseif change == "reowned" then console.SlicerCreator = other
            else console.class = "prop_physics" end
            local text = inspect(env, owner, 1, 1)[1]
            contains(text, "unavailable or expired"); contains(text, "!nearConsoles")
            assert(not text:find("secret", 1, true))
        end)
    end
    test("inspection consumes exact commands silently for invalid, dead and nonplayer requesters", function()
        local env, owner, console = fixture()
        local nonplayer = env.entity("prop_physics")
        nonplayer.ChatPrint = function() error("Nonplayer received inspection") end
        owner.alive = false
        local before = #owner.chats
        equal(env.fire("PlayerSay", owner, "!inspectConsole 1"), ""); equal(#owner.chats, before)
        owner.alive, owner.valid = true, false
        equal(env.fire("PlayerSay", owner, "!inspectConsole 1"), ""); equal(#owner.chats, before)
        equal(env.fire("PlayerSay", nonplayer, "!inspectConsole 1"), "")
        equal(env.fire("PlayerSay", nil, "!inspectConsole 1"), "")
        owner.valid = true
        saved(inspect(env, owner), console)
    end)
    test("inspection expires exactly at 60 seconds and does not renew repeated rows", function()
        local env, owner, console = fixture()
        for _, now in ipairs({1, 30, 59.999}) do env.now = now; saved(inspect(env, owner), console) end
        env.now = 60
        contains(inspect(env, owner, 1, 1)[1], "unavailable or expired")
        equal(env.fire("PlayerSay", owner, "!listConsoles"), "")
        saved(inspect(env, owner), console)
    end)
    for _, command in ipairs({"!findConsoles 1 absent", "!listConsoles 0", "!nearConsoles 0"}) do
        test("inspection cannot reuse rows cleared by " .. command, function()
            local env, owner = fixture()
            equal(env.fire("PlayerSay", owner, command), "")
            contains(inspect(env, owner, 1, 1)[1], "unavailable or expired")
        end)
    end
    test("inspection distinguishes unconfigured consoles from malformed saved data", function()
        local env, owner, console = fixture()
        console.SlicerInformation = nil
        contains(inspect(env, owner, 1, 1)[1], "needs setup")
        for _, info in ipairs({false, true, 0, "bad", {}, {name = "valid", delay = 2, fileType = "data"}}) do
            console.SlicerInformation = info
            contains(inspect(env, owner, 1, 1)[1], "invalid configuration")
        end
        local cases = {{"name", ""}, {"name", "  "}, {"name", string.rep("x", 129)}, {"fileName", false},
            {"fileName", string.rep("界", 43)}, {"fileType", "Data"}, {"delay", 0}, {"delay", -1},
            {"delay", math.huge}, {"delay", -math.huge}, {"delay", 0 / 0}, {"delay", "2"}}
        for _, case in ipairs(cases) do
            console.SlicerInformation = {name = "terminal", delay = 2, fileType = "data", fileName = "secret"}
            console.SlicerInformation[case[1]] = case[2]
            contains(inspect(env, owner, 1, 1)[1], "invalid configuration")
        end
    end)
    test("inspection keeps legacy case and edge spaces while cleaning display controls only", function()
        local env, owner, console = fixture()
        local raw = "  Legacy\0\1\31\127\194\128\194\159\226\128\168\226\128\169Case  "
        local clean = "  Legacy????????Case  "
        console.SlicerInformation.name, console.SlicerInformation.fileName = raw, raw
        saved(inspect(env, owner), console, clean, clean)
        equal(console.SlicerInformation.name, raw); equal(console.SlicerInformation.fileName, raw)
    end)
    for _, text in ipairs({string.rep("A", 128), string.rep("界", 42) .. "é"}) do
        test("inspection preserves a complete " .. (#text == 128 and text:sub(1, 1) == "A" and "ASCII" or "multibyte") .. " 128-byte saved name and filename", function()
            local env, owner, console = fixture()
            console.id = 4294967295
            console.SlicerInformation.name, console.SlicerInformation.fileName = text, text
            saved(inspect(env, owner), console)
        end)
    end
    test("inspection round-trips fractional, tiny and large configured base delays", function()
        local env, owner, console = fixture()
        for _, delay in ipairs({0.1, 1 / 3, 1.2345678901234567, 1e-300, 1e300}) do
            console.SlicerInformation.delay = delay
            saved(inspect(env, owner), console)
        end
    end)
    test("inspection applies the editor precision fallback when tostring loses saved delay bits", function()
        local env, owner, console = fixture()
        local delay = 1.2345678901234567
        console.SlicerInformation.delay = delay
        env.tostring = function(value) if value == delay then return "1.2345678901235" end; return tostring(value) end
        saved(inspect(env, owner), console)
    end)
    test("inspection accepts busy flags without requiring editor registry eligibility", function()
        local env, owner, console = fixture()
        console.SlicerInformation.inUse = true
        env.returnSpawnedEntities()[1] = nil
        saved(inspect(env, owner), console)
    end)
    for _, change in ipairs({"remove", "edit"}) do
        test("inspection captures every reply before ChatPrint can " .. change .. " the console", function()
            local env, owner, console = fixture()
            local original, replies, before = owner.ChatPrint, 0, #owner.chats
            function owner:ChatPrint(text)
                replies = replies + 1; original(self, text)
                if replies == 1 then
                    if change == "remove" then console:Remove()
                    else
                        console.SlicerInformation.name, console.SlicerInformation.delay = "new name", 99
                        console.SlicerInformation.fileName, console.SlicerInformation.fileType = "new file", "tools"
                    end
                end
            end
            equal(env.fire("PlayerSay", owner, "!inspectConsole 1"), "")
            equal(replies, 3)
            contains(owner.chats[before + 1], "'terminal'")
            equal(owner.chats[before + 2], "Folder: data; configured base delay: 2 seconds.")
            equal(owner.chats[before + 3], "Saved filename (no extension): 'secret'.")
        end)
    end
    test("browse help includes the saved configuration inspection command", function()
        local env, owner = fixture()
        local before = #owner.chats
        equal(env.fire("PlayerSay", owner, "!slicerHelp browse"), "")
        local messages = {}; for i = before + 1, #owner.chats do messages[#messages + 1] = owner.chats[i] end
        contains(table.concat(messages, "\n"), "!inspectConsole <row>")
    end)
end
