-- These tests execute the addon hooks, not the native GMod duplicator.
-- Contract: generic copy can alias a nested table; generic paste spawns first,
-- restores fields/name, calls OnDuplicated, applies modifiers, then calls
-- PostEntityPaste. Source contracts and their native-runtime limits:
-- https://wiki.facepunch.com/gmod/ENTITY:OnEntityCopyTableFinish
-- https://wiki.facepunch.com/gmod/ENTITY:OnDuplicated
-- https://wiki.facepunch.com/gmod/ENTITY:PostEntityPaste
-- https://github.com/Facepunch/garrysmod/blob/master/garrysmod/lua/includes/modules/duplicator.lua
-- Unlike real entity userdata, this harness uses tables. The adapter explicitly
-- preserves entity references (or drops them in a sensitivity model); it never
-- deep-copies fake entities. It does not model native geometry, save codecs,
-- engine hook dispatch, undo/protection permissions, or Derma rendering.
return function(gmod, test, equal)
    local unpackValues = table.unpack or unpack
    local kinds = {
        {folder = "data", extension = "data", timer = "DownloadDataFile", message = "destroyOnServer"},
        {folder = "server", extension = "sys", timer = "DownloadServerFile", message = "destroyOnServer"},
        {folder = "tools", extension = "exe", message = "PlayerActivatedDoor"},
    }
    local function clone(value, dropRefs, seen)
        if type(value) ~= "table" then return value end
        if value.GetCreationID then return not dropRefs and value or nil end
        seen = seen or {}
        if seen[value] then return seen[value] end
        local result = {}; seen[value] = result
        for key, item in pairs(value) do result[key] = clone(item, dropRefs, seen) end
        return result
    end
    local function copy(console, dropRefs)
        local data = {SlicerInformation = console.SlicerInformation,
            SlicerCreator = console.SlicerCreator, SlicerDoor = console.SlicerDoor,
            Name = console:GetName()}
        if console.OnEntityCopyTableFinish then console:OnEntityCopyTableFinish(data) end
        return dropRefs and clone(data, true) or data
    end
    local function paste(env, data, actor, modifier, created)
        local console = setmetatable(env.entity("consoleent"), {__index = env.ENT})
        console:Initialize()
        local restored = clone(data)
        console.SlicerInformation = restored.SlicerInformation
        console.SlicerCreator, console.SlicerDoor = restored.SlicerCreator, restored.SlicerDoor
        if restored.Name then console:SetName(restored.Name) end
        if console.OnDuplicated then console:OnDuplicated(restored) end
        if modifier then modifier(console) end
        -- Published Lua dispatch has no validity gate after modifiers. A
        -- removed host double retains its method, so exercise the addon's
        -- invalid-self guard here without assuming native userdata behavior.
        if console.PostEntityPaste then
            console:PostEntityPaste(actor, console, created or {})
        end
        return console
    end
    local function registry(env)
        for index = 1, 30 do
            local name, value = debug.getupvalue(env.ENT.OnRemove, index)
            if not name then break end
            if name == "linkedDoors" then return value end
        end
        error("Missing actual OnRemove door registry")
    end
    local function entries(env, console)
        local count, found = 0
        for _, entry in ipairs(env.returnSpawnedEntities()) do
            if entry.entity == console then count, found = count + 1, entry end
        end
        return count, found
    end
    local function select(env, actor, target)
        actor.target = target
        return env.fire("PlayerSay", actor, "!setEntity")
    end
    local function link(env, actor, console, door)
        door = door or env.entity("func_door")
        select(env, actor, console); select(env, actor, door)
        equal(console.SlicerDoor, door, "Explicit link must succeed")
        equal(registry(env)[door], console)
        return door
    end
    local function fixture(kind)
        local env = gmod.new()
        local owner, actor, hacker = env.player(), env.player(), env.player()
        local console = env.console(owner)
        if kind then assert(env.configure(owner, console, kind, 2)) end
        local door = kind == "tools" and link(env, owner, console) or nil
        return env, owner, actor, hacker, console, door
    end
    local function assertInfo(info, folder)
        assert(type(info) == "table", "Missing normalized configuration")
        equal(info.name, "terminal"); equal(info.fileName, "secret")
        equal(info.delay, 2); equal(info.fileType, folder); equal(info.inUse, false)
        local allowed = {name = true, delay = true, fileType = true, fileName = true, inUse = true}
        for key in pairs(info) do assert(allowed[key], "Unexpected configuration field: " .. tostring(key)) end
        equal(getmetatable(info), nil, "Configuration must be a fresh plain table")
    end
    local function assertRegistered(env, console)
        local count, entry = entries(env, console)
        equal(count, 1, "Each configured duplicate needs exactly one record")
        equal(entry.entityName, console:GetName()); equal(entry.information, console.SlicerInformation)
    end
    local function assertOriginal(env, original, door, busy)
        equal(original.removed, nil); equal(original.SlicerInformation.inUse, busy or false)
        assertRegistered(env, original)
        if door then
            equal(original.SlicerDoor, door); equal(registry(env)[door], original)
            equal(door.inputs[#door.inputs], "Lock")
        end
    end

    for _, kind in ipairs(kinds) do
        for _, sameActor in ipairs({false, true}) do
            test("duplicate " .. kind.folder .. " is independent for " .. (sameActor and "same" or "different") .. " creator", function()
                local env, owner, actor, _, original, door = fixture(kind.folder)
                if sameActor then actor = owner end
                local pending = env.console(actor); env.configure(actor, pending, "tools")
                local data = copy(original)
                assert(data.SlicerInformation ~= original.SlicerInformation, "Copy must replace the aliased table")
                equal(data.SlicerDoor, nil); equal(data.SlicerCreator, nil)
                local before = #actor.chats
                local duplicate = paste(env, data, actor)
                assertInfo(duplicate.SlicerInformation, kind.folder)
                equal(duplicate.SlicerCreator, actor); equal(duplicate.SlicerDoor, nil)
                equal(duplicate:GetName(), "DevonsConsoleEntity" .. duplicate:GetCreationID())
                assert(duplicate:GetName() ~= original:GetName(), "Pasted engine name must be fresh")
                assert(duplicate.SlicerInformation ~= data.SlicerInformation)
                assert(duplicate.SlicerInformation ~= original.SlicerInformation)
                assertRegistered(env, duplicate); assertOriginal(env, original, door)
                equal(actor.SlicerPendingConsole, pending, "Pasting must preserve pending selection")
                equal(#actor.chats - before, kind.folder == "tools" and 1 or 0)
                if kind.folder == "tools" then
                    local notice = actor.chats[#actor.chats]
                    assert(notice:find("!setEntity", 1, true) and notice:find("func_door", 1, true))
                    assert(notice:lower():find("unlinked", 1, true))
                end
                duplicate.SlicerInformation.name = "changed"
                equal(original.SlicerInformation.name, "terminal"); equal(data.SlicerInformation.name, "terminal")
                duplicate:Remove()
                equal(entries(env, duplicate), 0); equal(actor.SlicerPendingConsole, pending)
                assertOriginal(env, original, door)
            end)
        end

        for _, stop in ipairs({"quit", "death", "completion"}) do
            for _, beforePaste in ipairs({false, true}) do
                test(kind.folder .. " occupied copy stays independent after " .. stop .. (beforePaste and " before paste" or " after paste"), function()
                    local env, _, actor, hacker, original, originalDoor = fixture(kind.folder)
                    env.open(hacker, original)
                    local sourceInfo = original.SlicerInformation
                    local data = copy(original)
                    equal(sourceInfo.inUse, true, "Copy must never clear the live reservation")
                    assertInfo(data.SlicerInformation, kind.folder)
                    local originalCount = #env.messages
                    local function stopOriginal()
                        if stop == "quit" then env.receive("playerQuitConsole", hacker)
                        elseif stop == "death" then hacker.alive = false; env.fire("PlayerDeath", hacker)
                        else env.now = 4; env.receive(kind.message, hacker, original) end
                        equal(sourceInfo.inUse, false)
                    end
                    if beforePaste then stopOriginal() end
                    local duplicate = paste(env, data, actor)
                    if not beforePaste then
                        equal(#env.messages, originalCount, "Paste must not close or open any original UI")
                        assertOriginal(env, original, originalDoor, true)
                    end
                    assertInfo(duplicate.SlicerInformation, kind.folder)
                    local duplicateDoor = kind.folder == "tools" and link(env, actor, duplicate) or nil
                    env.open(actor, duplicate)
                    equal(duplicate.SlicerInformation.inUse, true)
                    if not beforePaste then stopOriginal() end
                    equal(duplicate.SlicerInformation.inUse, true, "Original cleanup must not release the copy")
                    env.now = 100
                    env.receive(kind.message, hacker, original)
                    equal(duplicate.removed, nil, "Stale original packets cannot complete its copy")
                    equal(duplicate.SlicerInformation.inUse, true)
                    env.receive(kind.message, actor, duplicate)
                    equal(duplicate.removed, true)
                    if duplicateDoor then equal(duplicateDoor.inputs[#duplicateDoor.inputs], "Unlock") end
                    equal(original.removed, stop == "completion" and true or nil)
                    if stop ~= "completion" then assertOriginal(env, original, originalDoor) end
                end)
            end
        end

        test(kind.folder .. " repeated pastes and copy-of-copy get separate names and records", function()
            local env, owner, actor, _, original = fixture(kind.folder)
            local saved = copy(original)
            local first, second = paste(env, saved, actor), paste(env, saved, actor)
            if kind.folder == "tools" then link(env, actor, first) end
            env.open(actor, first)
            local third = paste(env, copy(first), owner)
            assertInfo(third.SlicerInformation, kind.folder)
            equal(third.SlicerCreator, owner); equal(third.SlicerDoor, nil)
            local names, infos = {}, {}
            for _, console in ipairs({original, first, second, third}) do
                assert(not names[console:GetName()]); names[console:GetName()] = true
                assert(not infos[console.SlicerInformation]); infos[console.SlicerInformation] = true
                assertRegistered(env, console)
            end
            -- A repeated completion hook must never append a second record.
            if second.PostEntityPaste then second:PostEntityPaste(actor, second, {}) end
            assertRegistered(env, second)
            equal(first.SlicerInformation.inUse, true)
            env.updateInUse(second:GetName(), true)
            equal(second.SlicerInformation.inUse, true); equal(third.SlicerInformation.inUse, false)
        end)

        test(kind.folder .. " pasted terminal completes through actual client and server callbacks", function()
            local env, _, actor, _, original, originalDoor = fixture(kind.folder)
            local duplicate = paste(env, copy(original), actor)
            local door = kind.folder == "tools" and link(env, actor, duplicate) or nil
            local client = gmod.client()
            env.open(actor, duplicate)
            local packet = assert(env.lastMessage("ServerSendsEntityInformation"))
            equal(packet.values[1], duplicate)
            client.receive(packet.name, nil, unpackValues(packet.values))
            client.command("/a[terminal]"); client.fireTimer("AccessDelay")
            client.command("/a[terminal]/{_" .. kind.folder .. "}")
            client.command((kind.timer and "/d" or "/r") .. "{_" .. kind.folder .. "}/secret." .. kind.extension)
            if kind.timer then client.fireTimer(kind.timer) end
            client.assertClosed()
            packet = assert(client.lastMessage(kind.message))
            env.now = 4
            env.receive(packet.name, actor, unpackValues(packet.values))
            equal(duplicate.removed, true)
            packet = assert(env.lastMessage("SlicerCompleted"))
            client.receive(packet.name, nil, unpackValues(packet.values))
            equal(#client.chatMessages, 1)
            if door then equal(door.inputs[#door.inputs], "Unlock") end
            assertOriginal(env, original, originalDoor)
        end)

        test(kind.folder .. " legacy reference-dropping model still binds the actual paster", function()
            local env, _, actor, _, original, door = fixture(kind.folder)
            -- This is only a reference-loss sensitivity model, not a claim
            -- about the built-in saved-dupe codec or automatic save loading.
            local legacy = clone({SlicerInformation = original.SlicerInformation,
                SlicerCreator = original.SlicerCreator, SlicerDoor = door}, true)
            local duplicate = paste(env, legacy, actor)
            assertInfo(duplicate.SlicerInformation, kind.folder)
            equal(duplicate.SlicerCreator, actor); equal(duplicate.SlicerDoor, nil)
            assertRegistered(env, duplicate); assertOriginal(env, original, door)
        end)

        test(kind.folder .. " original session cannot complete or reserve its pasted copy", function()
            local env, _, actor, hacker, original, door = fixture(kind.folder)
            env.open(hacker, original)
            local duplicate = paste(env, copy(original), actor)
            if kind.folder == "tools" then link(env, actor, duplicate) end
            env.open(hacker, duplicate)
            equal(duplicate.SlicerInformation.inUse, false)
            env.now = 4
            env.receive(kind.message, hacker, duplicate)
            equal(duplicate.removed, nil)
            assertOriginal(env, original, door, true)
            env.receive(kind.message, hacker, original)
            equal(original.removed, true); equal(duplicate.removed, nil)
            env.open(hacker, duplicate)
            equal(duplicate.SlicerInformation.inUse, true)
            -- The fresh session must still meet its own later deadline.
            env.receive(kind.message, hacker, duplicate)
            equal(duplicate.removed, nil); equal(duplicate.SlicerInformation.inUse, false)
        end)
    end

    for _, dropRefs in ipairs({false, true}) do
        test("unconfigured copy recovers creator-only setup with " .. (dropRefs and "dropped" or "retained") .. " references", function()
            local env, owner, actor, _, original = fixture()
            local duplicate = paste(env, copy(original, dropRefs), actor)
            equal(duplicate.SlicerInformation, nil); equal(entries(env, duplicate), 0)
            equal(duplicate.SlicerCreator, actor); equal(duplicate.SlicerDoor, nil)
            equal(#actor.chats, 1); assert(actor.chats[1]:find("Use", 1, true))
            local count = #env.messages
            env.open(owner, duplicate); env.configure(owner, duplicate)
            equal(#env.messages, count); equal(duplicate.SlicerInformation, nil)
            actor.weapon = nil
            env.open(actor, duplicate)
            equal(env.lastMessage("PlayerSpawnedConsole").values[2], duplicate:GetName())
            assert(env.configure(actor, duplicate, "data")); assertRegistered(env, duplicate)
            equal(original.SlicerInformation, nil); equal(original.SlicerCreator, owner)
        end)
    end

    local invalid = {
        {label = "missing"}, {label = "string", value = "bad"}, {label = "number", value = 1},
        {label = "blank name", field = "name", value = " \t "},
        {label = "oversized name", field = "name", value = string.rep("x", 129)},
        {label = "oversized raw name before trim", field = "name", value = " " .. string.rep("x", 128)},
        {label = "nonstring name", field = "name", value = {}},
        {label = "missing file name", field = "fileName"},
        {label = "blank file name", field = "fileName", value = ""},
        {label = "oversized file name", field = "fileName", value = string.rep("x", 129)},
        {label = "unknown type", field = "fileType", value = "admin"},
        {label = "numeric string delay", field = "delay", value = "2"},
        {label = "zero delay", field = "delay", value = 0},
        {label = "negative delay", field = "delay", value = -1},
        {label = "NaN delay", field = "delay", value = 0/0},
        {label = "infinite delay", field = "delay", value = math.huge},
        {label = "negative infinite delay", field = "delay", value = -math.huge},
    }
    for _, bad in ipairs(invalid) do
        test("legacy copied " .. bad.label .. " configuration becomes recoverable setup", function()
            local env, owner, actor, _, original, door = fixture("tools")
            local value = bad.value
            if bad.field then value = clone(original.SlicerInformation); value[bad.field] = bad.value end
            local duplicate = paste(env, {SlicerInformation = value, SlicerCreator = owner, SlicerDoor = door}, actor)
            equal(duplicate.SlicerInformation, nil); equal(entries(env, duplicate), 0)
            equal(duplicate.SlicerCreator, actor); equal(duplicate.SlicerDoor, nil)
            env.open(actor, duplicate)
            equal(env.lastMessage("PlayerSpawnedConsole").values[2], duplicate:GetName())
            assert(env.configure(actor, duplicate)); assertRegistered(env, duplicate)
            assertOriginal(env, original, door)
        end)
    end

    test("legacy config is normalized and runtime authority fields are discarded", function()
        local env, owner, actor, hacker, original, door = fixture("tools")
        env.open(hacker, original)
        local injected = {name = " TERMINAL ", delay = 2, fileType = "tools", fileName = " SECRET ",
            inUse = true, SlicerCreator = owner, SlicerDoor = door, hacker = hacker,
            console = original, completeAt = -1, timers = {AccessDelay = "foreign"}, history = {"foreign"},
            session = {console = original}, version = 9000}
        local duplicate = paste(env, {SlicerInformation = injected, SlicerCreator = owner, SlicerDoor = door}, actor)
        assertInfo(duplicate.SlicerInformation, "tools")
        equal(injected.inUse, true); equal(injected.name, " TERMINAL ")
        equal(duplicate.SlicerCreator, actor); equal(duplicate.SlicerDoor, nil)
        env.now = 100; env.receive("PlayerActivatedDoor", hacker, duplicate)
        env.receive("destroyOnServer", actor, duplicate)
        equal(duplicate.removed, nil); equal(duplicate.SlicerInformation.inUse, false)
        assertOriginal(env, original, door, true)
        select(env, owner, duplicate); equal(owner.SlicerPendingConsole, nil)
        link(env, actor, duplicate)
        env.open(hacker, duplicate)
        equal(duplicate.SlicerInformation.inUse, false, "Original hacker still has one existing session")
        assertOriginal(env, original, door, true)
    end)

    test("copy replaces malformed or extended aliased config without changing the source", function()
        local env, _, _, _, original = fixture("data")
        original.SlicerInformation.extra = {session = original}
        local info = original.SlicerInformation
        assertInfo(copy(original).SlicerInformation, "data")
        equal(original.SlicerInformation, info); equal(info.extra.session, original)
        info.delay = math.huge
        equal(copy(original).SlicerInformation, nil)
        equal(info.delay, math.huge)
    end)

    test("setup and legacy paste retain the same exact accepted boundary values", function()
        local env = gmod.new()
        local actor = env.player()
        local console = env.console(actor)
        local name, file = string.rep("N", 128), " File "
        env.receive("AdminFinishedCreation", actor, {name, 0.5, "server", file, console:GetName()})
        local duplicate = paste(env, {SlicerInformation = {name = name, delay = 0.5,
            fileType = "server", fileName = file}}, actor)
        for key, value in pairs(console.SlicerInformation) do equal(duplicate.SlicerInformation[key], value) end
        assertRegistered(env, duplicate)
    end)

    for _, invalidActor in ipairs({"missing", "prop", "removed player"}) do
        test("invalid paste actor " .. invalidActor .. " removes only the cleaned new entity", function()
            local env, owner, actor, hacker, original, door = fixture("tools")
            env.open(hacker, original)
            local pending = env.console(owner); env.configure(owner, pending, "tools")
            if invalidActor == "missing" then actor = nil
            elseif invalidActor == "prop" then actor = env.entity("prop_physics")
            else actor.valid = false end
            local duplicate = paste(env, {SlicerInformation = original.SlicerInformation,
                SlicerCreator = owner, SlicerDoor = door}, actor)
            equal(duplicate.removed, true); equal(duplicate.SlicerCreator, nil); equal(duplicate.SlicerDoor, nil)
            equal(entries(env, duplicate), 0); equal(owner.SlicerPendingConsole, pending)
            assertOriginal(env, original, door, true)
        end)
    end

    for _, remove in ipairs({false, true}) do
        test("OnDuplicated clears copied authority before a modifier" .. (remove and " removes it" or " runs"), function()
            local env, owner, actor, hacker, original, door = fixture("tools")
            env.open(hacker, original)
            local retiredInformation
            local duplicate = paste(env, {SlicerInformation = original.SlicerInformation,
                SlicerCreator = owner, SlicerDoor = door, Name = original:GetName()}, actor, function(created)
                equal(created.SlicerCreator, nil, "Old authority must be gone before modifiers")
                equal(created.SlicerDoor, nil, "Old door pointer must be gone before modifiers")
                assertInfo(created.SlicerInformation, "tools")
                equal(created:GetName(), "DevonsConsoleEntity" .. created:GetCreationID())
                if remove then
                    created:Remove()
                    retiredInformation = created.SlicerInformation
                end
            end)
            assertOriginal(env, original, door, true)
            if remove then
                equal(duplicate.SlicerInformation, retiredInformation, "Post-paste must leave removed entity state alone")
                equal(entries(env, duplicate), 0); equal(duplicate.SlicerCreator, nil)
                equal(#actor.chats, 0)
            else assertRegistered(env, duplicate) end
        end)
    end

    for _, malformed in ipairs({false, true}) do
        test("post-modifier normalization rechecks " .. (malformed and "invalid" or "valid") .. " fields and authority", function()
            local env, owner, actor, hacker, original, door = fixture("tools")
            env.open(hacker, original)
            local duplicate = paste(env, copy(original), actor, function(created)
                created.SlicerCreator, created.SlicerDoor = owner, door
                created.SlicerInformation = malformed and {fileType = "tools"} or original.SlicerInformation
                created:SetName(original:GetName())
            end, {[door:GetCreationID()] = env.entity("func_door")})
            equal(duplicate.SlicerCreator, actor); equal(duplicate.SlicerDoor, nil)
            equal(duplicate:GetName(), "DevonsConsoleEntity" .. duplicate:GetCreationID())
            if malformed then equal(duplicate.SlicerInformation, nil); equal(entries(env, duplicate), 0)
            else assertInfo(duplicate.SlicerInformation, "tools"); assertRegistered(env, duplicate) end
            assertOriginal(env, original, door, true)
        end)
    end

    test("a modifier reintroducing a foreign door then removing the copy cannot unlock it", function()
        local env, owner, actor, hacker, original, door = fixture("tools")
        env.open(hacker, original)
        local duplicate = paste(env, copy(original), actor, function(created)
            created.SlicerDoor, created.SlicerCreator = door, owner
            created:Remove()
        end)
        equal(duplicate.removed, true); equal(entries(env, duplicate), 0)
        assertOriginal(env, original, door, true)
    end)

    test("unregistered foreign door pointers cannot unlock or clear another console's registry", function()
        local env, _, actor, hacker, original, door = fixture("tools")
        local foreign = env.console(actor); env.configure(actor, foreign)
        foreign.SlicerDoor = door
        env.open(actor, foreign)
        foreign:Remove()
        equal(entries(env, foreign), 0); equal(env.lastMessage("PlayerDied").player, actor)
        equal(env.fire("PlayerUse", hacker, door), false)
        assertOriginal(env, original, door)
    end)

    test("registered duplicate removal unlocks only its own valid door and cleans its session", function()
        local env, _, actor, _, original, door = fixture("tools")
        local duplicate = paste(env, copy(original), actor)
        local ownDoor = link(env, actor, duplicate)
        env.open(actor, duplicate)
        duplicate:Remove()
        equal(ownDoor.inputs[#ownDoor.inputs], "Unlock"); equal(registry(env)[ownDoor], nil)
        equal(env.lastMessage("PlayerDied").player, actor); equal(entries(env, duplicate), 0)
        assertOriginal(env, original, door)
    end)

    test("reload without a local door registration does not infer unlocking authority", function()
        local env, _, _, _, original, door = fixture("tools")
        env.include("entities/consoleent/init.lua")
        equal(registry(env)[door], nil)
        original:Remove()
        equal(door.inputs[#door.inputs], "Lock"); equal(entries(env, original), 0)
    end)

    test("an invalid registered door receives no Unlock while other removal cleanup still runs", function()
        local env, owner, _, hacker, original, door = fixture("tools")
        env.open(hacker, original)
        -- Model a stale pending pointer as well as the normal session record.
        owner.SlicerPendingConsole = original
        door:Remove()
        local count = #door.inputs
        original:Remove()
        equal(#door.inputs, count); equal(entries(env, original), 0)
        equal(owner.SlicerPendingConsole, nil)
        equal(env.lastMessage("PlayerDied").player, hacker)
    end)

    test("copy tools relinking rejects a claimed door and supports an explicit retry", function()
        local env, owner, actor, hacker, original, door = fixture("tools")
        local pending = env.console(actor); env.configure(actor, pending, "tools")
        local duplicateDoor = env.entity("func_door")
        local duplicate = paste(env, copy(original), actor, nil, {[door:GetCreationID()] = duplicateDoor})
        equal(actor.SlicerPendingConsole, pending); equal(duplicate.SlicerDoor, nil)
        env.open(actor, duplicate); equal(duplicate.SlicerInformation.inUse, false)
        select(env, owner, duplicate); equal(owner.SlicerPendingConsole, nil)
        select(env, actor, duplicate); equal(actor.SlicerPendingConsole, duplicate)
        select(env, actor, door)
        equal(actor.SlicerPendingConsole, duplicate); equal(duplicate.SlicerDoor, nil)
        assert(actor.chats[#actor.chats]:find("already linked", 1, true))
        select(env, actor, env.entity("prop_physics"))
        equal(actor.SlicerPendingConsole, duplicate)
        select(env, actor, duplicateDoor)
        equal(actor.SlicerPendingConsole, nil); equal(duplicate.SlicerDoor, duplicateDoor)
        equal(registry(env)[duplicateDoor], duplicate); equal(env.fire("PlayerUse", hacker, duplicateDoor), false)
        duplicate:Remove(); equal(env.fire("PlayerUse", hacker, duplicateDoor), nil)
        assertOriginal(env, original, door)
    end)

    for _, removed in ipairs({"original", "door"}) do
        test("a tools snapshot remains usable after removing its " .. removed, function()
            local env, _, actor, _, original, door = fixture("tools")
            local saved = copy(original)
            if removed == "original" then original:Remove() else door:Remove() end
            local duplicate = paste(env, saved, actor)
            equal(duplicate.SlicerDoor, nil); equal(duplicate.SlicerCreator, actor)
            link(env, actor, duplicate); assertRegistered(env, duplicate)
            env.open(actor, duplicate); equal(duplicate.SlicerInformation.inUse, true)
        end)
    end

    for _, reason in ipairs({"wrong sender", "wrong type", "early", "lost tool"}) do
        test("a pasted terminal retains the existing " .. reason .. " completion check", function()
            local env, _, actor, hacker, original = fixture("data")
            local duplicate = paste(env, copy(original), actor)
            env.open(actor, duplicate)
            env.now = reason == "early" and 0 or 4
            if reason == "lost tool" then actor.weapon = nil end
            env.receive(reason == "wrong type" and "PlayerActivatedDoor" or "destroyOnServer",
                reason == "wrong sender" and hacker or actor, duplicate)
            equal(duplicate.removed, nil); equal(env.lastMessage("SlicerCompleted"), nil)
            equal(duplicate.SlicerInformation.inUse, reason == "wrong sender")
            assertOriginal(env, original)
        end)
    end
end
