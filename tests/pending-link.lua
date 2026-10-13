-- Real server callbacks with ordinary native-accessor doubles and explicit
-- synchronous reentry points. This does not model arbitrary hostile metatables
-- or native multiplayer chat delivery.
return function(gmod, test, equal)
    local function contains(text, part) assert(text:find(part, 1, true), "Missing " .. part .. " in " .. text) end
    local function lacks(text, part) assert(not text:find(part, 1, true), "Unexpected " .. part .. " in " .. text) end
    local function configured(env, owner, name)
        local console = env.console(owner)
        assert(env.configure(owner, console, "tools", 2))
        console.SlicerInformation.name = name or "alpha"
        return console
    end
    local function fixture()
        local env = gmod.new()
        local owner, other = env.player(), env.player()
        local console = configured(env, owner)
        return env, owner, console, other
    end
    local function upvalue(callback, wanted)
        for index = 1, 100 do
            local name, value = debug.getupvalue(callback, index)
            if not name then break end
            if name == wanted then return value end
        end
        error("Missing existing state: " .. wanted)
    end
    local function snapshot(env, owner)
        local saved, seen = {}, {}
        local function visit(value)
            if type(value) ~= "table" or seen[value] or value == owner.chats then return end
            seen[value] = true
            local fields = {}; saved[#saved + 1] = {value, fields}
            for key, item in pairs(value) do fields[key] = item; visit(item) end
        end
        visit(env.entities); visit(env.messages); visit(env.returnSpawnedEntities())
        visit(upvalue(env.hooks.PlayerUse.isUsingOurObject, "linkedDoors"))
        visit(upvalue(env.slicerConsoleHasActiveSession, "sessions"))
        visit(upvalue(env.retireSlicerSetupEdit, "editTickets"))
        visit(upvalue(env.hooks.PlayerSay.slicerListConsoles, "consoleListings"))
        local outgoing, serial = env.outgoing, env.slicerSetupEditSerial
        return function()
            equal(env.outgoing, outgoing); equal(env.slicerSetupEditSerial, serial)
            for _, record in ipairs(saved) do
                for key, value in pairs(record[2]) do equal(record[1][key], value, "Changed " .. tostring(key)) end
                for key, value in pairs(record[1]) do equal(value, record[2][key], "Added " .. tostring(key)) end
            end
        end
    end
    local function inspect(env, owner)
        local before, unchanged = #owner.chats, snapshot(env, owner)
        equal(env.fire("PlayerSay", owner, "!pendingLink"), "", "Exact pending command must be consumed")
        equal(#owner.chats, before + 1, "One requester-private line")
        local message = owner.chats[#owner.chats]
        assert(#message > 0 and #message <= 240, "Pending reply exceeded byte budget")
        assert(not message:find("[%z\1-\31\127]") and not message:find("\194[\128-\159]")
            and not message:find("\226\128[\168\169]"), "Pending reply contains display controls")
        unchanged()
        return message
    end
    local function identity(message, console, name)
        contains(message, "'" .. (name or console.SlicerInformation.name) .. "'")
        contains(message, "current ID #" .. string.format("%.0f", console.id))
        contains(message, "linking rechecks eligibility")
    end
    local function forbidden() error("Pending inspection used unrelated authority") end

    test("pending empty selection has one constant private result", function()
        local env, owner, _, other = fixture(); owner.SlicerPendingConsole = nil
        contains(inspect(env, owner), "no pending door-link selection")
        equal(#other.chats, 0)
    end)

    for _, selection in ipairs({"automatic", "bare", "listed"}) do
        test("pending reports exact " .. selection .. " selection without targeting or resolving", function()
            local env, owner, console, other = fixture()
            if selection ~= "automatic" then
                configured(env, owner, "beta")
                if selection == "bare" then owner.target = console; equal(env.fire("PlayerSay", owner, "!setEntity"), "")
                else equal(env.fire("PlayerSay", owner, "!listConsoles"), ""); equal(env.fire("PlayerSay", owner, "!setEntity 1"), "") end
            end
            owner.weapon, owner.target = nil, nil
            owner.GetEyeTrace, owner.GetActiveWeapon, owner.IsAdmin = forbidden, forbidden, forbidden
            env.ents.FindByClass, env.ents.FindByName, env.Entity = forbidden, forbidden, forbidden
            env.slicerListedConsole, env.normalizeSlicerInformation = forbidden, forbidden
            console.GetName, console.EntIndex = forbidden, forbidden
            identity(inspect(env, owner), console); equal(#other.chats, 0)
        end)
    end

    local changes = {
        {"unconfigured", function(c) c.SlicerInformation = nil end},
        {"malformed", function(c) c.SlicerInformation = false end},
        {"data", function(c) c.SlicerInformation.fileType = "data" end},
        {"server", function(c) c.SlicerInformation.fileType = "server" end},
        {"busy", function(c) c.SlicerInformation.inUse = true end},
        {"saved door", function(c, env) c.SlicerDoor = env.entity("func_door") end},
        {"removed door", function(c, env) c.SlicerDoor = env.entity("func_door_rotating"); c.SlicerDoor:Remove() end},
    }
    for _, change in ipairs(changes) do
        test("pending owned choice remains visible with " .. change[1], function()
            local env, owner, console = fixture(); change[2](console, env)
            local message = inspect(env, owner)
            contains(message, "current ID #" .. console.id); contains(message, "linking rechecks eligibility")
            lacks(message, "unavailable"); lacks(message, "ready"); lacks(message, "can link")
        end)
    end

    for _, state in ipairs({"removed", "foreign", "admin foreign", "wrong class", "false", "opaque", "same-ID replacement"}) do
        test("pending hides unavailable " .. state .. " reference without clearing it", function()
            local env, owner, console, other = fixture()
            if state == "removed" then console:Remove(); owner.SlicerPendingConsole = console
            elseif state == "foreign" or state == "admin foreign" then console.SlicerCreator = other; owner.IsAdmin = function() return true end
            elseif state == "wrong class" then console.class = "prop_physics"
            elseif state == "false" then owner.SlicerPendingConsole = false
            elseif state == "opaque" then owner.SlicerPendingConsole = {}
            elseif state == "same-ID replacement" then
                console:Remove(); local replacement = configured(env, owner, "alpha"); replacement.id = console.id
                owner.SlicerPendingConsole = console
            end
            local message = inspect(env, owner)
            contains(message, "unavailable"); contains(message, "!cancelLink"); contains(message, "!setEntity")
            lacks(message, "alpha"); lacks(message, "current ID")
        end)
    end

    for _, kind in ipairs({"nil", "false", "invalid", "nonplayer", "dead"}) do
        test("pending consumes exact command from " .. kind .. " requester without a reply", function()
            local env, owner, console = fixture(); local actor = owner
            if kind == "nil" then actor = nil elseif kind == "false" then actor = false
            elseif kind == "invalid" then owner.valid = false elseif kind == "nonplayer" then owner.class = "prop_physics"
            else owner.alive = false end
            local before = #owner.chats
            equal(env.fire("PlayerSay", actor, "!pendingLink"), "")
            equal(#owner.chats, before); equal(owner.SlicerPendingConsole, console)
        end)
    end

    test("pending recognizes exact grammar only under both hook orders", function()
        local env, owner = fixture()
        local names = {}; for name in pairs(env.hooks.PlayerSay) do names[#names + 1] = name end; table.sort(names)
        local function ordered(text, reverse)
            for step = 1, #names do
                local result = env.hooks.PlayerSay[names[reverse and (#names - step + 1) or step]](owner, text)
                if result ~= nil then return result end
            end
        end
        for _, reverse in ipairs({false, true}) do
            for _, text in ipairs({"hello", "!pendinglink", "!PendingLink", "!PENDINGLINK", " !pendingLink", "!pendingLink ",
                "!pendingLink 1", "!pendingLink extra", "!pendingLink\t", "!pendingLink\n", "!pendingLink\0", "!pendingLink!"}) do
                local before = #owner.chats; equal(ordered(text, reverse), nil); equal(#owner.chats, before)
            end
            local before = #owner.chats; equal(ordered("!pendingLink", reverse), ""); equal(#owner.chats, before + 1)
        end
    end)

    for _, source in ipairs({"IsValid", "IsPlayer", "Alive", "GetClass", "GetCreationID", "name", "ChatPrint"}) do
        test("pending contains " .. source .. " read or reply error and consumes chat", function()
            local env, owner, console = fixture(); local before, packets = #owner.chats, #env.messages
            if source == "IsValid" then env.IsValid = forbidden
            elseif source == "name" then console.SlicerInformation = setmetatable({}, {__index = forbidden})
            elseif source == "GetClass" or source == "GetCreationID" then console[source] = forbidden
            else owner[source] = forbidden end
            local unchanged = snapshot(env, owner)
            local ok, result = pcall(env.fire, "PlayerSay", owner, "!pendingLink")
            equal(ok, true); equal(result, ""); equal(#owner.chats, before); equal(#env.messages, packets); unchanged()
        end)
    end

    for index, name in ipairs({string.rep("n", 128), string.rep("é", 64), string.rep("界", 42) .. "é", string.rep("🔐", 32), "A\0B\nC\127D\194\133E\226\128\168F\226\128\169G"}) do
        test("pending keeps bounded literal name bytes case " .. index, function()
            local env, owner, console = fixture(); console.SlicerInformation.name = name; console.id = 10000000
            local safe = name:gsub("[%z\1-\31\127]", "?"):gsub("\194[\128-\159]", "?"):gsub("\226\128[\168\169]", "?")
            identity(inspect(env, owner), console, safe); equal(console.SlicerInformation.name, name)
        end)
    end
    test("pending omits missing malformed and overlong names without runtime-name fallback", function()
        local env, owner, console = fixture(); console.GetName = forbidden
        for _, info in ipairs({{}, {name = false}, {name = {}}, {name = 42}, {name = ""}, {name = " \t "}, {name = string.rep("x", 129)}}) do
            console.SlicerInformation = info
            local message = inspect(env, owner); lacks(message, "'"); contains(message, "current ID #" .. console.id)
        end
    end)
    test("pending accepts only current bounded integral numeric IDs", function()
        local env, owner, console = fixture()
        for _, id in ipairs({0, 1, 10000000}) do console.id = id; identity(inspect(env, owner), console) end
        for _, id in ipairs({false, "42", {}, 0 / 0, math.huge, -math.huge, -1, 1.5, 10000001}) do
            -- Exercise the accessor result without putting NaN (unequal to
            -- itself) into the ordinary-field preservation snapshot.
            console.GetCreationID = function() return id end
            local message = inspect(env, owner); contains(message, "'alpha'"); lacks(message, "current ID")
        end
        console.GetCreationID = function() return nil end; lacks(inspect(env, owner), "current ID")
    end)
    test("pending uses current renamed label and exact same-name same-ID reference", function()
        local env, owner, first = fixture(); local second = configured(env, owner, "alpha"); second.id = first.id
        owner.SlicerPendingConsole = first; first.SlicerInformation.name = "Renamed Literal"
        identity(inspect(env, owner), first); owner.SlicerPendingConsole = second
        identity(inspect(env, owner), second)
    end)

    local actions = {"replace", "cancel", "remove", "reown", "class", "die", "invalidate"}
    local function change(action, env, owner, console, replacement, other)
        if action == "replace" then owner.SlicerPendingConsole = replacement
        elseif action == "cancel" then owner.SlicerPendingConsole = nil
        elseif action == "remove" then console:Remove()
        elseif action == "reown" then console.SlicerCreator = other
        elseif action == "class" then console.class = "prop_physics"
        elseif action == "die" then owner.alive = false
        elseif action == "invalidate" then owner.valid = false end
    end
    for _, source in ipairs({"GetClass", "GetCreationID", "name", "feedback lookup"}) do
        for _, action in ipairs(actions) do
            test("pending suppresses obsolete display after " .. source .. " can " .. action, function()
                local env, owner, console, other = fixture()
                local replacement = configured(env, owner, "alpha"); replacement.id = console.id; owner.SlicerPendingConsole = console
                local before, calls = #owner.chats, 0
                local function reenter() calls = calls + 1; change(action, env, owner, console, replacement, other) end
                if source == "GetClass" then
                    local original = console.GetClass
                    console.GetClass = function(self) local class = original(self); self.GetClass = original; reenter(); return class end
                elseif source == "GetCreationID" then console.GetCreationID = function(self) reenter(); return self.id end
                elseif source == "name" then console.SlicerInformation = setmetatable({}, {__index = function(_, key) if key == "name" then reenter(); return "alpha" end end})
                else
                    local feedback = owner.ChatPrint; owner.ChatPrint = nil
                    setmetatable(owner, {__index = function(_, key) if key == "ChatPrint" then reenter(); return feedback end end})
                end
                equal(env.fire("PlayerSay", owner, "!pendingLink"), ""); equal(calls, 1)
                equal(#owner.chats, before, "Obsolete pending identity must not reach feedback")
                local expected = action == "replace" and replacement or console
                if action == "cancel" or action == "remove" then expected = nil end
                equal(owner.SlicerPendingConsole, expected)
            end)
        end
    end
    for _, action in ipairs({"replace", "cancel", "remove", "reown", "throw"}) do
        test("pending feedback reentry preserves " .. action .. " result without rollback", function()
            local env, owner, console, other = fixture(); local replacement = configured(env, owner, "beta"); owner.SlicerPendingConsole = console
            local feedback, calls = owner.ChatPrint, 0
            owner.ChatPrint = function(self, message)
                calls = calls + 1
                if action == "throw" then error("Private reply failed") end
                if action == "replace" then
                    self.ChatPrint = feedback; self.target = replacement; equal(env.fire("PlayerSay", self, "!setEntity"), "")
                else change(action, env, owner, console, replacement, other) end
                feedback(self, message)
            end
            equal(env.fire("PlayerSay", owner, "!pendingLink"), ""); equal(calls, 1)
            local expected = action == "replace" and replacement or console
                if action == "cancel" or action == "remove" then expected = nil end
                equal(owner.SlicerPendingConsole, expected)
        end)
    end
    test("pending suppresses an obsolete empty reply if feedback lookup selects a console", function()
        local env, owner, console = fixture(); owner.SlicerPendingConsole = nil
        local feedback, before = owner.ChatPrint, #owner.chats; owner.ChatPrint = nil
        setmetatable(owner, {__index = function(_, key)
            if key == "ChatPrint" then owner.SlicerPendingConsole = console; return feedback end
        end})
        equal(env.fire("PlayerSay", owner, "!pendingLink"), "")
        equal(#owner.chats, before); equal(owner.SlicerPendingConsole, console)
    end)
    test("pending lifecycle keeps death retention and existing disconnect and removal cleanup", function()
        local env, owner, console = fixture(); inspect(env, owner)
        owner.alive = false; env.fire("PlayerDeath", owner); equal(owner.SlicerPendingConsole, console)
        owner.alive = true; identity(inspect(env, owner), console)
        env.fire("PlayerDisconnected", owner); equal(owner.SlicerPendingConsole, nil)
        local nextConsole = configured(env, owner); identity(inspect(env, owner), nextConsole)
        nextConsole:Remove(); equal(owner.SlicerPendingConsole, nil)
    end)
    test("pending command is discoverable in existing links help", function()
        local env, owner = fixture(); local before = #owner.chats
        equal(env.fire("PlayerSay", owner, "!slicerHelp links"), "")
        local lines = {}; for index = before + 1, #owner.chats do lines[#lines + 1] = owner.chats[index]; assert(#owner.chats[index] <= 240) end
        local message = table.concat(lines, "\n"); contains(message, "!pendingLink"); contains(message, "!cancelLink"); contains(message, "!inspectLink")
    end)
end
