-- Public chat/setup/session callbacks; no private listing or session tables.
-- The GMod doubles do not establish native chat, networking or door behavior.
return function(gmod, test, equal)
    local function say(env, owner, text) return env.fire("PlayerSay", owner, text) end
    local function contains(text, part) assert(text:find(part, 1, true), "Missing " .. part .. " in " .. text) end
    local function setup(env, owner, name, folder)
        local console = env.console(owner)
        env.receive("AdminFinishedCreation", owner, {name, 2, folder or "tools", "Secret", console:GetName()})
        assert(console.SlicerInformation)
        return console
    end
    local function fixture(count)
        local env = gmod.new()
        local owner, other, consoles = env.player(), env.player(), {}
        for row = 1, count or 2 do consoles[row] = setup(env, owner, row == 1 and "Alpha" or "Beta") end
        owner.GetEyeTrace = function() error("Listed selection must never read the eye trace") end
        return env, owner, other, consoles
    end
    local function list(env, owner, command) equal(say(env, owner, command or "!listConsoles"), "") end
    local function select(env, owner, row, console)
        local packets, chats = #env.messages, #owner.chats
        local result = say(env, owner, "!setEntity " .. row)
        equal(owner.SlicerPendingConsole, console, "Listed selection must choose the exact printed console")
        equal(result, ""); equal(#env.messages, packets)
        equal(#owner.chats, chats + 1)
        contains(owner.chats[#owner.chats], console.SlicerInformation.name)
        contains(owner.chats[#owner.chats], "!cancelLink")
        equal(console.SlicerDoor, nil)
    end
    local function reject(env, owner, row, guidance)
        local pending, packets, chats = owner.SlicerPendingConsole, #env.messages, #owner.chats
        equal(say(env, owner, "!setEntity " .. row), "")
        equal(owner.SlicerPendingConsole, pending, "Refusal preserves the previous pending choice")
        equal(#env.messages, packets); equal(#owner.chats, chats + 1)
        contains(owner.chats[#owner.chats], guidance or "!setEntity")
    end
    local function bare(env, owner, target)
        owner.target = target
        owner.GetEyeTrace = function(self) return {Entity = self.target} end
        return say(env, owner, "!setEntity")
    end

    test("listed selection replaces automatic Beta with printed Alpha without an eye trace or door input", function()
        local env, owner, _, consoles = fixture()
        local door = env.entity("func_door")
        owner.target = door
        equal(owner.SlicerPendingConsole, consoles[2])
        list(env, owner)
        select(env, owner, 1, consoles[1])
        equal(#door.inputs, 0)
    end)

    test("listed selection recognizes exactly rows one through five and leaves near matches as chat", function()
        local env, owner, _, consoles = fixture(5)
        owner.weapon = nil
        list(env, owner)
        for row = 1, 5 do select(env, owner, row, consoles[row]) end
        for _, text in ipairs({"!setEntity 0", "!setEntity 6", "!setEntity 01", "!setEntity +1", "!setEntity -1",
            "!setEntity 1.0", "!setEntity 1e0", "!setEntity  1", "!setEntity 1 ", " !setEntity 1",
            "!setentity 1", "!SetEntity 1", "!setEntity\t1", "!setEntity 1\n", "!setEntity 1 extra",
            "!setEntity １２", "!setEntity " .. string.rep("1", 1000)}) do
            local pending, chats, packets = owner.SlicerPendingConsole, #owner.chats, #env.messages
            equal(say(env, owner, text), nil, text)
            equal(owner.SlicerPendingConsole, pending); equal(#owner.chats, chats); equal(#env.messages, packets)
        end
    end)

    test("listed selection requires the original lease and never renews its sixty second deadline", function()
        local env, owner, _, consoles = fixture()
        reject(env, owner, 1, "!listConsoles")
        list(env, owner); reject(env, owner, 5, "!listConsoles")
        env.now = 59.99; select(env, owner, 1, consoles[1])
        env.now = 60; reject(env, owner, 2, "!listConsoles")
        local door = env.entity("func_door")
        equal(bare(env, owner, door), "")
        equal(consoles[1].SlicerDoor, door, "Accepted selection survives lease expiry")
    end)

    test("listing pages and searches replace exact rows without changing accepted pending selection", function()
        local env, owner, _, consoles = fixture(6)
        list(env, owner); select(env, owner, 2, consoles[2])
        list(env, owner, "!listConsoles 2"); equal(owner.SlicerPendingConsole, consoles[2])
        select(env, owner, 1, consoles[6]); reject(env, owner, 2, "!listConsoles")
        list(env, owner, "!findConsoles 1 alpha"); select(env, owner, 1, consoles[1])
        for _, command in ipairs({"!listConsoles 0", "!listConsoles 99", "!findConsoles 1 missing",
            "!listConsoles 1 linked", "!findConsoles 0 alpha"}) do
            list(env, owner, command); reject(env, owner, 1, "!listConsoles")
            equal(owner.SlicerPendingConsole, consoles[1])
        end
        local door = env.entity("func_door_rotating")
        equal(bare(env, owner, door), ""); equal(consoles[1].SlicerDoor, door)
    end)

    test("duplicate names and creation IDs preserve row entity identity after ordinal shifts and renaming", function()
        local env, owner, _, consoles = fixture(3)
        for _, console in ipairs(consoles) do console.id = 42; console.SlicerInformation.name = "same" end
        list(env, owner, "!listConsoles 1 unlinked same")
        consoles[1]:Remove()
        local replacement = setup(env, owner, "Same"); replacement.id = 42
        reject(env, owner, 1, "!listConsoles")
        equal(owner.SlicerPendingConsole, replacement)
        consoles[2].SlicerInformation.name = "renamed"
        select(env, owner, 2, consoles[2])
        list(env, owner); select(env, owner, 1, consoles[2])
        equal(replacement.SlicerDoor, nil)
    end)

    local invalidations = {
        {"changed owner", function(env, console) console.SlicerCreator = env.player() end},
        {"changed class", function(_, console) console.class = "prop_physics" end},
        {"removed console", function(_, console) console:Remove() end},
        {"missing config", function(_, console) console.SlicerInformation = nil end},
        {"nontable config", function(_, console) console.SlicerInformation = true end},
        {"invalid name", function(_, console) console.SlicerInformation.name = " " end},
        {"invalid filename", function(_, console) console.SlicerInformation.fileName = false end},
        {"invalid delay", function(_, console) console.SlicerInformation.delay = 0 end},
        {"infinite delay", function(_, console) console.SlicerInformation.delay = math.huge end},
        {"nan delay", function(_, console) console.SlicerInformation.delay = 0/0 end},
        {"data folder", function(_, console) console.SlicerInformation.fileType = "data" end},
        {"server folder", function(_, console) console.SlicerInformation.fileType = "server" end},
        {"busy flag", function(_, console) console.SlicerInformation.inUse = true end},
        {"truthy legacy busy flag", function(_, console) console.SlicerInformation.inUse = "false" end},
        {"live door", function(env, console) console.SlicerDoor = env.entity("func_door") end},
        {"removed door", function(env, console)
            console.SlicerDoor = env.entity("func_door_rotating"); console.SlicerDoor:Remove()
        end},
        {"false nonnil door", function(_, console) console.SlicerDoor = false end},
    }
    for _, case in ipairs(invalidations) do
        test("listed refusal preserves the old selection after " .. case[1], function()
            local env, owner, _, consoles = fixture()
            list(env, owner); case[2](env, consoles[1])
            local info, door, records = consoles[1].SlicerInformation, consoles[1].SlicerDoor, #env.returnSpawnedEntities()
            reject(env, owner, 1)
            equal(owner.SlicerPendingConsole, consoles[2]); equal(consoles[1].SlicerInformation, info)
            equal(consoles[1].SlicerDoor, door); equal(#env.returnSpawnedEntities(), records)
            for _, entity in ipairs(env.entities) do equal(#entity.inputs, 0) end
        end)
    end

    test("listed selection validates a copy without requiring canonical fields or an editor registry record", function()
        local env, owner, _, consoles = fixture()
        local info = consoles[1].SlicerInformation
        info.name, info.fileName, info.extra = "  Mixed NAME  ", "  Secret  ", "retained"
        table.remove(env.returnSpawnedEntities(), 1)
        list(env, owner); select(env, owner, 1, consoles[1])
        equal(consoles[1].SlicerInformation, info)
        equal(info.name, "  Mixed NAME  "); equal(info.fileName, "  Secret  "); equal(info.extra, "retained")
        equal(info.inUse, false); equal(#env.returnSpawnedEntities(), 1)
        info.inUse = nil -- Existing idle semantics: reject truthy raw flags, not missing flags.
        select(env, owner, 1, consoles[1]); equal(info.inUse, nil)
    end)

    test("listed selection checks an actual reservation even after legacy busy and door flags are cleared", function()
        local env, owner, hacker, consoles = fixture()
        local door = env.entity("func_door")
        bare(env, owner, consoles[1]); bare(env, owner, door)
        env.open(hacker, consoles[1]); equal(env.slicerConsoleHasActiveSession(consoles[1]), true)
        equal(consoles[1].SlicerInformation.inUse, true)
        -- Establish the real reservation first; these are deliberate legacy mutations.
        consoles[1].SlicerInformation.inUse, consoles[1].SlicerDoor = false, nil
        bare(env, owner, consoles[2]); list(env, owner)
        reject(env, owner, 1)
        equal(owner.SlicerPendingConsole, consoles[2]); equal(env.slicerConsoleHasActiveSession(consoles[1]), true)
        equal(#door.inputs, 1)
        env.receive("playerQuitConsole", hacker)
        select(env, owner, 1, consoles[1])
    end)

    test("living actor and lifecycle checks refuse without replacing pending selection", function()
        local env, owner, other, consoles = fixture()
        list(env, owner); owner.alive = false
        local chats = #owner.chats
        equal(say(env, owner, "!setEntity 1"), ""); equal(#owner.chats, chats)
        equal(owner.SlicerPendingConsole, consoles[2])
        equal(say(env, nil, "!setEntity 1"), "")
        equal(say(env, env.entity("prop_physics"), "!setEntity 1"), "")
        owner.alive = true
        for _, event in ipairs({"PlayerDeath", "PlayerDisconnected"}) do
            list(env, owner); env.fire(event, owner)
            reject(env, owner, 1, "!listConsoles")
        end
        reject(env, other, 1, "!listConsoles")
    end)

    test("listed selection resolves the current function and refreshed listing closure at command time", function()
        local env, owner, _, consoles = fixture()
        list(env, owner)
        local resolve = env.slicerListedConsole
        env.slicerListedConsole = nil; reject(env, owner, 1, "!listConsoles")
        local called = 0
        env.slicerListedConsole = function(actor, row)
            called = called + 1; equal(actor, owner); equal(row, 1); return resolve(actor, row)
        end
        select(env, owner, 1, consoles[1]); equal(called, 1)
        env.include("entities/consoleent/init.lua")
        reject(env, owner, 2, "!listConsoles")
        list(env, owner); select(env, owner, 2, consoles[2]); equal(called, 1)
    end)

    for _, action in ipairs({"new selection", "cancel", "remove", "throw"}) do
        for _, entry in ipairs({"listed", "bare"}) do
            test(entry .. " selection commits before chat callback can " .. action, function()
                local env, owner, _, consoles = fixture()
                list(env, owner)
                local chat, reentered = owner.ChatPrint, false
                owner.ChatPrint = function(self, text)
                    chat(self, text)
                    if reentered then return end
                    reentered = true
                    equal(self.SlicerPendingConsole, consoles[1], "Commit precedes the callback")
                    if action == "new selection" then say(env, owner, "!setEntity 2")
                    elseif action == "cancel" then say(env, owner, "!cancelLink")
                    elseif action == "remove" then consoles[1]:Remove()
                    else error("synthetic ChatPrint failure") end
                end
                local ok, err = pcall(function()
                    if entry == "listed" then say(env, owner, "!setEntity 1") else bare(env, owner, consoles[1]) end
                end)
                equal(reentered, true)
                if action == "throw" then equal(ok, false); contains(tostring(err), "synthetic ChatPrint failure")
                else equal(ok, true) end
                local expected = action == "new selection" and consoles[2] or action == "throw" and consoles[1] or nil
                equal(owner.SlicerPendingConsole, expected, "Outer selection never overwrites a later effect")
            end)
        end
    end

    test("removed door remains ineligible until ordinary reset then listed selection", function()
        local env, owner, _, consoles = fixture()
        local door = env.entity("func_door")
        bare(env, owner, consoles[1]); bare(env, owner, door); door:Remove()
        bare(env, owner, consoles[2]); list(env, owner); reject(env, owner, 1)
        owner.target = consoles[1]; equal(say(env, owner, "!resetLink"), "")
        equal(owner.SlicerPendingConsole, consoles[2]); select(env, owner, 1, consoles[1])
        equal(#door.inputs, 1)
    end)

    test("accepted listed selection retains the existing bare final-link eligibility checks", function()
        for _, mutation in ipairs({"owner", "class", "folder", "busy", "door", "removed"}) do
            local env, owner, _, consoles = fixture()
            list(env, owner); select(env, owner, 1, consoles[1])
            if mutation == "owner" then consoles[1].SlicerCreator = env.player()
            elseif mutation == "class" then consoles[1].class = "prop_physics"
            elseif mutation == "folder" then consoles[1].SlicerInformation.fileType = "data"
            elseif mutation == "busy" then consoles[1].SlicerInformation.inUse = true
            elseif mutation == "door" then consoles[1].SlicerDoor = env.entity("func_door")
            else consoles[1]:Remove() end
            local pending, door = owner.SlicerPendingConsole, env.entity("func_door")
            bare(env, owner, door)
            equal(owner.SlicerPendingConsole, pending); equal(#door.inputs, 0)
        end
    end)

    test("bare selection retains its pre-existing actor and legacy reservation boundaries", function()
        local env, owner, hacker, consoles = fixture()
        owner.alive = false
        equal(bare(env, owner, consoles[1]), ""); equal(owner.SlicerPendingConsole, consoles[1])
        owner.alive = true
        local door = env.entity("func_door")
        bare(env, owner, door); env.open(hacker, consoles[1])
        equal(env.slicerConsoleHasActiveSession(consoles[1]), true)
        consoles[1].SlicerInformation.inUse, consoles[1].SlicerDoor = false, nil
        bare(env, owner, consoles[2]); equal(bare(env, owner, consoles[1]), "")
        equal(owner.SlicerPendingConsole, consoles[1])
    end)
    test("filtered rows retain exact identity when setup state changes before selection", function()
        local env = gmod.new()
        local owner = env.player()
        local alpha = env.console(owner)
        local beta = setup(env, owner, "Beta")
        list(env, owner, "!listConsoles 1 setup")
        env.receive("AdminFinishedCreation", owner, {"Alpha", 2, "tools", "Secret", alpha:GetName()})
        bare(env, owner, beta)
        select(env, owner, 1, alpha)
    end)

    test("listed selection preserves the current locator marker and original shared lease", function()
        local support = dofile("tests/console-locator-support.lua")(gmod)
        local env = support.server()
        local owner = env.player()
        local alpha, beta = setup(env, owner, "Alpha"), setup(env, owner, "Beta")
        list(env, owner)
        equal(say(env, owner, "!locateConsole 2"), "")
        local marker, packets = env.lastMessage("SlicerConsoleLocation"), #env.messages
        select(env, owner, 1, alpha)
        equal(env.lastMessage("SlicerConsoleLocation"), marker); equal(#env.messages, packets)
        equal(say(env, owner, "!locateConsole clear"), "")
        env.now = 59.99; select(env, owner, 2, beta)
        env.now = 60; reject(env, owner, 1, "!listConsoles")
        equal(env.lastMessage("SlicerConsoleLocation").values[1], false)
    end)

end
