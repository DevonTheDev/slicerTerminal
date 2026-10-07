-- Execute actual server setup, chat, Use, network and entity lifecycle callbacks.
-- The host substitutes entity/transport APIs; native GMod behavior is untested.
return function(gmod, test, equal)
    local function fixture(folder)
        local server = gmod.new()
        local owner, stranger = server.player(), server.player()
        local console = server.console(owner)
        local information = assert(server.configure(owner, console, folder or "data"))
        return server, owner, stranger, console, information
    end
    local function edit(server, owner, console)
        owner.target = console
        local count = #server.messages
        equal(server.fire("PlayerSay", owner, "!editConsole"), "", "The edit command is handled")
        equal(#server.messages, count + 1, "Opening sends exactly one packet")
        local packet = server.messages[#server.messages]
        equal(packet.name, "SlicerSetupEditOpen"); equal(packet.player, owner)
        equal(#packet.values, 4); equal(packet.values[1], console); equal(packet.values[2], owner)
        local token = packet.values[3]
        assert(type(token) == "string" and token:match("^%d+$") and #token <= 16, "Use a bounded decimal token")
        equal(type(packet.values[4]), "table")
        return token, packet.values[4]
    end
    local function save(server, owner, console, token, fields)
        local count = #server.messages
        server.receive("SlicerSetupEditSave", owner, console, token,
            fields or {name = " Updated Terminal ", delay = 3.5, fileName = " New File "})
        equal(#server.messages, count + 1, "A save gets one reply")
        local packet = server.messages[#server.messages]
        equal(packet.name, "SlicerSetupEditReply"); equal(packet.player, owner)
        equal(#packet.values, 2, "Replies must not serialize an invalid entity")
        equal(packet.values[1], token); equal(type(packet.values[2].ok), "boolean")
        assert(type(packet.values[2].message) == "string" and #packet.values[2].message > 0)
        return packet.values[2]
    end
    local function obsolete(reply)
        equal(reply.ok, false)
        assert(reply.message:find("!editConsole", 1, true), "Obsolete replies must explain how to reopen")
    end
    local function record(server, console)
        local found, count
        count = 0
        for _, entry in ipairs(server.returnSpawnedEntities()) do
            if entry.entity == console then found, count = entry, count + 1 end
        end
        equal(count, 1, "Keep one existing registry entry per configured console")
        equal(found.entityName, console:GetName()); equal(found.information, console.SlicerInformation)
        return found
    end
    local function cancel(server, owner, console, token)
        server.receive("SlicerSetupEditCancel", owner, console, token)
    end
    local function duplicate(server, original, actor)
        local data = {SlicerInformation = original.SlicerInformation,
            SlicerCreator = original.SlicerCreator, SlicerDoor = original.SlicerDoor}
        original:OnEntityCopyTableFinish(data)
        local copy = setmetatable(server.entity("consoleent"), {__index = server.ENT})
        copy:Initialize()
        copy.SlicerInformation = data.SlicerInformation
        copy.SlicerCreator, copy.SlicerDoor = data.SlicerCreator, data.SlicerDoor
        copy:OnDuplicated(data)
        copy:PostEntityPaste(actor, copy, {})
        return copy
    end

    for _, folder in ipairs({"data", "server", "tools"}) do
        test("creator edits existing " .. folder .. " with a normalized isolated prefill and stable record", function()
            local server, owner, _, console, original = fixture(folder)
            local oldRecord, entityName = record(server, console), console:GetName()
            local pending = server.console(owner); server.configure(owner, pending, "tools")
            local door = server.entity("func_door")
            if folder == "tools" then
                owner.target = console; server.fire("PlayerSay", owner, "!setEntity")
                owner.target = door; server.fire("PlayerSay", owner, "!setEntity")
                owner.SlicerPendingConsole = pending
            end
            owner.weapon = nil
            local token, prefill = edit(server, owner, console)
            equal(prefill.name, "terminal"); equal(prefill.fileName, "secret")
            equal(prefill.fileType, folder); equal(prefill.delay, 2); equal(prefill.inUse, false)
            assert(prefill ~= original)
            prefill.name = "client tamper"
            equal(original.name, "terminal")
            local reply = save(server, owner, console, token, {name = " Updated Terminal ", delay = 3.5,
                fileName = " New File ", fileType = "server", inUse = true, SlicerDoor = nil})
            equal(reply.ok, true)
            local updated = console.SlicerInformation
            equal(updated.name, "updated terminal"); equal(updated.fileName, "new file")
            equal(updated.delay, 3.5); equal(updated.fileType, folder); equal(updated.inUse, false)
            equal(console:GetName(), entityName); equal(console.SlicerCreator, owner); equal(console.valid, true)
            equal(owner.SlicerPendingConsole, pending); equal(record(server, console), oldRecord)
            if folder == "tools" then
                equal(console.SlicerDoor, door); equal(#door.inputs, 1); equal(door.inputs[1], "Lock")
                equal(server.fire("PlayerUse", owner, door), false, "Door registry remains linked")
            end
            obsolete(save(server, owner, console, token))
            equal(console.SlicerInformation, updated, "Accepted ticket cannot replay")
        end)
    end

    test("reopening a current edit reuses its token without changing state", function()
        local server, owner, _, console, information = fixture()
        local first = edit(server, owner, console)
        local second, prefill = edit(server, owner, console)
        equal(second, first); equal(prefill.name, "terminal")
        equal(console.SlicerInformation, information); equal(information.inUse, false)
        equal(record(server, console).information, information)
    end)

    test("only the exact chat command opens an edit", function()
        local server, owner, _, console = fixture()
        owner.target = console
        local count = #server.messages
        for _, text in ipairs({"!editconsole", "!EditConsole", "!editConsole ", " !editConsole", "!editConsole extra"}) do
            equal(server.fire("PlayerSay", owner, text), nil)
        end
        equal(#server.messages, count)
        edit(server, owner, console)
    end)

    for _, invalid in ipairs({"stranger", "dead", "removed actor", "prop actor", "missing actor", "unconfigured", "removed console", "prop target", "missing target", "busy"}) do
        test("edit opening rejects " .. invalid .. " context", function()
            local server, owner, stranger, console, information = fixture()
            local actor, target = owner, console
            if invalid == "stranger" then actor = stranger
            elseif invalid == "dead" then owner.alive = false
            elseif invalid == "removed actor" then owner.valid = false
            elseif invalid == "prop actor" then actor = server.entity("prop_physics")
            elseif invalid == "missing actor" then actor = nil
            elseif invalid == "unconfigured" then target = server.console(owner)
            elseif invalid == "removed console" then console:Remove()
            elseif invalid == "prop target" then target = server.entity("prop_physics")
            elseif invalid == "missing target" then target = nil
            else server.open(stranger, console) end
            if actor then actor.target = target end
            local count = #server.messages
            server.fire("PlayerSay", actor, "!editConsole")
            equal(#server.messages, count, "Invalid context cannot open a form")
            equal(console.SlicerInformation, information)
        end)
    end

    local invalidFields = {
        {label = "blank name", key = "name", value = "  "},
        {label = "oversized raw name", key = "name", value = " " .. string.rep("a", 128)},
        {label = "nonstring name", key = "name", value = {}},
        {label = "missing name", key = "name"},
        {label = "blank filename", key = "fileName", value = "\t"},
        {label = "oversized filename", key = "fileName", value = string.rep("b", 129)},
        {label = "numeric string delay", key = "delay", value = "2"},
        {label = "zero delay", key = "delay", value = 0},
        {label = "negative delay", key = "delay", value = -1},
        {label = "NaN delay", key = "delay", value = 0/0},
        {label = "infinite delay", key = "delay", value = math.huge},
        {label = "negative infinity", key = "delay", value = -math.huge},
    }
    for _, bad in ipairs(invalidFields) do
        test("invalid edit " .. bad.label .. " preserves the ticket for correction", function()
            local server, owner, _, console, information = fixture()
            local token = edit(server, owner, console)
            local fields = {name = "New", delay = 1, fileName = "Next"}; fields[bad.key] = bad.value
            equal(save(server, owner, console, token, fields).ok, false)
            equal(console.SlicerInformation, information)
            equal(edit(server, owner, console), token)
            equal(save(server, owner, console, token).ok, true)
        end)
    end

    test("edit accepts the same 128-character and positive fractional boundaries as setup", function()
        local server, owner, _, console = fixture("server")
        local token = edit(server, owner, console)
        equal(save(server, owner, console, token, {name = string.rep("N", 128), delay = 0.5,
            fileName = string.rep("F", 128)}).ok, true)
        equal(console.SlicerInformation.name, string.rep("n", 128))
        equal(console.SlicerInformation.fileName, string.rep("f", 128)); equal(console.SlicerInformation.delay, 0.5)
    end)

    test("the normalized string limit is measured in bytes and validation explains it", function()
        local server, owner, _, console = fixture()
        local token = edit(server, owner, console)
        local reply = save(server, owner, console, token, {name = string.rep("é", 65), delay = 1, fileName = "file"})
        equal(reply.ok, false)
        assert(reply.message:find("128 bytes", 1, true), "The error must describe the actual byte limit")
        equal(save(server, owner, console, token, {name = string.rep("é", 64), delay = 1, fileName = "file"}).ok, true)
        equal(console.SlicerInformation.name, string.rep("é", 64))
    end)

    test("unauthorized sender cannot save or cancel a creator's live ticket", function()
        local server, owner, stranger, console, information = fixture()
        local token = edit(server, owner, console)
        obsolete(save(server, stranger, console, token))
        cancel(server, stranger, console, token)
        equal(console.SlicerInformation, information)
        equal(edit(server, owner, console), token)
        equal(save(server, owner, console, token).ok, true)
    end)

    test("a legitimate changed creator opens a fresh edit instead of inheriting the former owner's ticket", function()
        local server, owner, successor, console = fixture()
        local original = edit(server, owner, console)
        console.SlicerCreator = successor
        local replacement = edit(server, successor, console)
        assert(replacement ~= original, "Changed creator cannot inherit the old edit token")
        obsolete(save(server, owner, console, original))
        equal(save(server, successor, console, replacement).ok, true)
    end)

    test("observing stale context from another actor retires it permanently", function()
        local server, owner, other, console, information = fixture()
        local token = edit(server, owner, console)
        information.delay = 9
        other.target = console; server.fire("PlayerSay", other, "!editConsole")
        information.delay = 2
        obsolete(save(server, owner, console, token))
        equal(save(server, owner, console, edit(server, owner, console)).ok, true)
    end)

    test("an unauthorized open attempt does not retire an unchanged owner edit", function()
        local server, owner, stranger, console = fixture()
        local token = edit(server, owner, console)
        stranger.target = console; server.fire("PlayerSay", stranger, "!editConsole")
        equal(edit(server, owner, console), token)
        equal(save(server, owner, console, token).ok, true)
    end)

    test("cancel retires only its exact console and token", function()
        local server, owner, _, first, information = fixture()
        local second = server.console(owner); server.configure(owner, second, "server")
        local firstToken, secondToken = edit(server, owner, first), edit(server, owner, second)
        assert(firstToken ~= secondToken)
        cancel(server, owner, second, firstToken)
        cancel(server, owner, first, firstToken)
        equal(first.SlicerInformation, information)
        obsolete(save(server, owner, first, firstToken))
        local replacement = edit(server, owner, first)
        assert(replacement ~= firstToken)
        cancel(server, owner, first, firstToken)
        equal(save(server, owner, first, replacement).ok, true)
        equal(save(server, owner, second, secondToken).ok, true)
    end)

    test("an actual session vetoes edits even if updateInUse clears the public flag", function()
        local server, owner, hacker, console, information = fixture()
        local token = edit(server, owner, console)
        server.open(hacker, console)
        server.updateInUse(console:GetName(), false)
        equal(information.inUse, false)
        local count = #server.messages
        owner.target = console; server.fire("PlayerSay", owner, "!editConsole")
        equal(#server.messages, count, "The real session still blocks a new edit")
        obsolete(save(server, owner, console, token))
        server.now = 4; server.receive("destroyOnServer", hacker, console)
        equal(console.removed, true, "The edit attempt must preserve the original hacking session")
    end)

    test("a stale repeated opening replaces the ticket without reviving its old snapshot", function()
        local server, owner, _, console, information = fixture()
        local token = edit(server, owner, console)
        information.name = "external change"
        local replacement, prefill = edit(server, owner, console)
        assert(replacement ~= token); equal(prefill.name, "external change")
        obsolete(save(server, owner, console, token))
        equal(save(server, owner, console, replacement).ok, true)
    end)

    test("non-table save fields are rejected without retiring a current edit", function()
        local server, owner, _, console, information = fixture()
        local token = edit(server, owner, console)
        equal(save(server, owner, console, token, "invalid").ok, false)
        equal(console.SlicerInformation, information)
        equal(save(server, owner, console, token).ok, true)
    end)

    for _, stop in ipairs({"quit", "death", "disconnect", "early completion"}) do
        test("beginning a hack permanently retires a prior edit across " .. stop, function()
            local server, owner, hacker, console, information = fixture()
            local token = edit(server, owner, console)
            server.open(hacker, console)
            equal(information.inUse, true)
            -- Do not save while busy: that rejection could mask missing
            -- reservation-time retirement by revoking the ticket itself.
            if stop == "quit" then server.receive("playerQuitConsole", hacker)
            elseif stop == "death" then hacker.alive = false; server.fire("PlayerDeath", hacker)
            elseif stop == "disconnect" then server.fire("PlayerDisconnected", hacker)
            else server.receive("destroyOnServer", hacker, console) end
            equal(information.inUse, false)
            obsolete(save(server, owner, console, token))
            local replacement = edit(server, owner, console)
            assert(replacement ~= token); equal(save(server, owner, console, replacement).ok, true)
        end)
    end

    for _, event in ipairs({"PlayerDeath", "PlayerDisconnected"}) do
        test(event .. " retires all actor edits while preserving another actor's edit", function()
            local server, owner, other, first = fixture()
            local second = server.console(owner); server.configure(owner, second)
            local third = server.console(other); server.configure(other, third)
            local one, two, three = edit(server, owner, first), edit(server, owner, second), edit(server, other, third)
            server.fire(event, owner)
            owner.alive = true
            obsolete(save(server, owner, first, one)); obsolete(save(server, owner, second, two))
            equal(save(server, other, third, three).ok, true)
        end)
    end

    test("removed consoles return token-only errors without restoring a registry record", function()
        local server, owner, _, console, information = fixture()
        local token = edit(server, owner, console)
        console:Remove()
        obsolete(save(server, owner, console, token))
        equal(console.SlicerInformation, information); equal(#server.returnSpawnedEntities(), 0)
        cancel(server, owner, console, token)
    end)

    for _, change in ipairs({"name", "fileName", "delay", "fileType", "information identity", "entity name", "creator", "registry identity", "missing registry", "duplicate registry"}) do
        test("stale " .. change .. " fails closed and cannot revive a rejected ticket", function()
            local server, owner, other, console, information = fixture()
            local token = edit(server, owner, console)
            local entry, savedName = record(server, console), console:GetName()
            local restore
            if change == "information identity" then
                console.SlicerInformation = server.table.Copy(information)
                entry.information = console.SlicerInformation
                restore = function() console.SlicerInformation = information; entry.information = information end
            elseif change == "entity name" then console:SetName("Changed"); restore = function() console:SetName(savedName) end
            elseif change == "creator" then console.SlicerCreator = other; restore = function() console.SlicerCreator = owner end
            elseif change == "registry identity" then
                server.spawnedEntities[1] = {entity = console, entityName = savedName, information = information}
                restore = function() server.spawnedEntities[1] = entry end
            elseif change == "missing registry" then
                server.spawnedEntities[1] = nil; restore = function() server.spawnedEntities[1] = entry end
            elseif change == "duplicate registry" then
                server.spawnedEntities[2] = {entity = console, entityName = savedName, information = information}
                restore = function() server.spawnedEntities[2] = nil end
            else
                local previous = information[change]
                information[change] = change == "delay" and 9 or "changed"
                restore = function() information[change] = previous end
            end
            obsolete(save(server, owner, console, token))
            restore()
            obsolete(save(server, owner, console, token))
            local replacement = edit(server, owner, console)
            assert(replacement ~= token); equal(save(server, owner, console, replacement).ok, true)
        end)
    end

    test("unchanged source copy preserves its edit and gives the pasted console independent authority", function()
        local server, owner, other, source, information = fixture("tools")
        local sourceToken = edit(server, owner, source)
        local copy = duplicate(server, source, other)
        equal(source.SlicerInformation, information); equal(source.SlicerCreator, owner)
        equal(edit(server, owner, source), sourceToken)
        obsolete(save(server, other, copy, sourceToken))
        local copyToken = edit(server, other, copy)
        assert(sourceToken ~= copyToken)
        equal(save(server, other, copy, copyToken).ok, true)
        equal(source.SlicerInformation, information); equal(information.name, "terminal")
        equal(save(server, owner, source, sourceToken).ok, true)
        equal(record(server, source).information, source.SlicerInformation)
        equal(record(server, copy).information, copy.SlicerInformation)
    end)

    for _, hook in ipairs({"OnDuplicated", "PostEntityPaste"}) do
        test(hook .. " reset retires only the reset console's edit", function()
            local server, owner, _, console = fixture()
            local second = server.console(owner); server.configure(owner, second)
            local token, otherToken = edit(server, owner, console), edit(server, owner, second)
            if hook == "OnDuplicated" then console:OnDuplicated({})
            else console:PostEntityPaste(owner, console, {}) end
            obsolete(save(server, owner, console, token))
            equal(save(server, owner, second, otherToken).ok, true)
        end)
    end

    test("configuration reinclude never reuses retired token identities", function()
        local server, owner, _, console = fixture()
        local previous = edit(server, owner, console)
        server.include("autorun/server/sv_config.lua")
        obsolete(save(server, owner, console, previous))
        local nextToken = edit(server, owner, console)
        assert(tonumber(nextToken) > tonumber(previous), "The serial must remain monotonic across reinclude")
        cancel(server, owner, console, previous)
        equal(save(server, owner, console, nextToken).ok, true)
    end)

    test("the last exact serial is bounded and exhaustion never wraps or revives earlier tickets", function()
        local server, owner, _, console = fixture()
        server.slicerSetupEditSerial = 9007199254740990
        local token = edit(server, owner, console)
        equal(token, "9007199254740991")
        cancel(server, owner, console, token)
        local count = #server.messages
        owner.target = console; server.fire("PlayerSay", owner, "!editConsole")
        equal(#server.messages, count, "Exhaustion cannot issue a reused token")
        equal(server.slicerSetupEditSerial, 9007199254740991)
        obsolete(save(server, owner, console, token))
    end)

    test("first-write setup cannot overwrite a configured console before or after an edit", function()
        local server, owner, _, console, information = fixture()
        local token = edit(server, owner, console)
        server.receive("AdminFinishedCreation", owner, {"Hijack", 4, "tools", "Other", console:GetName()})
        equal(console.SlicerInformation, information); equal(owner.SlicerPendingConsole, nil)
        equal(save(server, owner, console, token).ok, true)
        information = console.SlicerInformation
        server.receive("AdminFinishedCreation", owner, {"Hijack", 4, "tools", "Other", console:GetName()})
        equal(console.SlicerInformation, information); equal(record(server, console).information, information)
        equal(owner.SlicerPendingConsole, nil)
    end)
end
