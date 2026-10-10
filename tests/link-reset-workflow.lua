-- Relay real setup forms, chat hooks, Use, client commands and completion.
-- Native targeting, multiplayer transport and brush-door I/O require GMod.
return function(gmod, test, equal)
    local unpackValues = table.unpack or unpack
    local function deliver(client, packet)
        assert(packet, "Missing server packet")
        client.receive(packet.name, nil, unpackValues(packet.values))
    end
    local function relay(server, actor, packet)
        assert(packet, "Missing client packet")
        server.receive(packet.name, actor, unpackValues(packet.values))
    end
    local function say(server, actor, target, command)
        actor.target = target
        return server.fire("PlayerSay", actor, command)
    end
    local function formSince(client, first, editing)
        local form, entries = {}, {}
        for index = first, #client.panels do
            local panel = client.panels[index]
            if panel.class == "DFrame" then form.frame = panel
            elseif panel.class == "DTextEntry" then entries[#entries + 1] = panel
            elseif panel.class == "DComboBox" then form.folder = panel
            elseif panel.class == "DButton" and panel.text == (editing and "Save changes" or "Done") then form.submit = panel end
        end
        equal(#entries, 3)
        form.name, form.delay, form.file = entries[1], entries[2], entries[3]
        assert(form.frame and form.submit)
        return form
    end
    local function setup(server, client, owner, name, folder)
        local console, first = server.console(owner), #client.panels + 1
        deliver(client, server.lastMessage("PlayerSpawnedConsole"))
        local form = formSince(client, first)
        form.name:SetText(name); form.delay:SetText("3.5"); form.file:SetText("Secret")
        form.folder.selected = folder or "tools"
        form.submit:DoClick()
        equal(form.frame.valid, true)
        relay(server, owner, client.lastMessage("AdminFinishedCreation"))
        local accepted = server.lastMessage("SlicerInitialSetupReply")
        equal(accepted.player, owner); equal(accepted.values[2].ok, true)
        deliver(client, accepted); equal(form.frame.valid, false)
        equal(console.SlicerInformation.name, string.lower(name))
        return console
    end
    local function link(server, owner, console, class)
        local door = server.entity(class)
        equal(say(server, owner, console, "!setEntity"), "")
        equal(say(server, owner, door, "!setEntity"), "")
        equal(console.SlicerDoor, door); equal(#door.inputs, 1); equal(door.inputs[1], "Lock")
        return door
    end
    local function open(server, client, hacker, console)
        local before = #server.messages
        server.open(hacker, console)
        equal(#server.messages, before + 1)
        local packet = server.lastMessage("ServerSendsEntityInformation")
        equal(packet.player, hacker); equal(packet.values[1], console)
        deliver(client, packet)
    end
    local function complete(client, console)
        local information = console.SlicerInformation
        client.command("/a[" .. information.name .. "]"); client.fireTimer("AccessDelay")
        client.command("/a[" .. information.name .. "]/{_tools}")
        client.command("/r{_tools}/" .. information.fileName .. ".exe")
        client.assertClosed()
        return assert(client.lastMessage("PlayerActivatedDoor"))
    end
    local function reset(server, owner, console)
        equal(say(server, owner, console, "!resetLink"), "")
        equal(console.SlicerDoor, nil)
    end

    for _, oldClass in ipairs({"func_door", "func_door_rotating"}) do
        for _, newClass in ipairs({"func_door", "func_door_rotating"}) do
            test("actual recovery workflow replaces removed " .. oldClass .. " with " .. newClass, function()
                local server, client = gmod.new(), gmod.client()
                local owner, hacker = server.player(), server.player()
                local console = setup(server, client, owner, "Recovered")
                local oldDoor = link(server, owner, console, oldClass)
                local other = setup(server, client, owner, "Other")
                local otherDoor = link(server, owner, other, newClass)
                local pending = setup(server, client, owner, "Pending")
                oldDoor:Remove()
                say(server, owner, console, "!setEntity")
                equal(owner.SlicerPendingConsole, pending)
                server.open(hacker, console)
                equal(server.slicerConsoleHasActiveSession(console), false)
                reset(server, owner, console)
                equal(owner.SlicerPendingConsole, pending)
                equal(say(server, owner, console, "!inspectLink"), "")
                assert(owner.chats[#owner.chats]:find("has no door link", 1, true))
                local firstReply = #owner.chats + 1
                say(server, owner, console, "!listConsoles")
                local rows = {}
                for index = firstReply, #owner.chats do rows[#rows + 1] = owner.chats[index] end
                assert(table.concat(rows, "\n"):find("Console 'recovered' (current ID #" .. console:GetCreationID()
                    .. "): has no door link", 1, true), "Listing must reflect the recovered console's unlinked state")
                local replacement = link(server, owner, console, newClass)
                say(server, owner, replacement, "!inspectLink")
                assert(owner.chats[#owner.chats]:find("registered link to " .. newClass, 1, true))
                equal(server.fire("PlayerUse", hacker, replacement), false)
                equal(server.fire("PlayerUse", hacker, oldDoor), nil)
                open(server, client, hacker, console)
                local early = complete(client, console)
                server.now = 3.49; relay(server, hacker, early)
                equal(console.valid, true); equal(#replacement.inputs, 1)
                equal(server.lastMessage("SlicerCompleted"), nil)
                deliver(client, server.lastMessage("PlayerDied"))
                server.now = 4; open(server, client, hacker, console)
                local packet = complete(client, console)
                hacker.target = otherDoor
                server.now = 7.5; relay(server, hacker, packet)
                equal(console.removed, true)
                equal(#replacement.inputs, 2); equal(replacement.inputs[2], "Unlock")
                equal(#oldDoor.inputs, 1); equal(#otherDoor.inputs, 1)
                equal(other.valid, true); equal(pending.valid, true)
                local accepted = server.lastMessage("SlicerCompleted")
                equal(accepted.player, hacker)
                deliver(client, accepted); equal(#client.chatMessages, 1); client.assertClosed()
                local count = #server.messages
                relay(server, hacker, packet)
                equal(#server.messages, count); equal(#replacement.inputs, 2)
            end)
        end
    end

    test("reset retains its current editor and unrelated setup forms before normal relinking", function()
        local server, client = gmod.new(), gmod.client()
        local owner = server.player()
        local console = setup(server, client, owner, "Editable")
        local oldDoor = link(server, owner, console, "func_door")
        say(server, owner, console, "!editConsole")
        local first = #client.panels + 1
        local editOpen = server.lastMessage("SlicerSetupEditOpen")
        deliver(client, editOpen)
        local editor = formSince(client, first, true)
        editor.name:SetText("Updated"); editor.delay:SetText("5"); editor.file:SetText("Replacement")
        local deferred = server.console(owner)
        first = #client.panels + 1
        deliver(client, server.lastMessage("PlayerSpawnedConsole"))
        local setupForm = formSince(client, first)
        setupForm.name:SetText("Deferred"); setupForm.delay:SetText("2"); setupForm.file:SetText("Separate")
        setupForm.folder.selected = "data"
        oldDoor:Remove(); reset(server, owner, console)
        equal(editor.frame.valid, true); equal(setupForm.frame.valid, true)
        editor.submit:DoClick()
        relay(server, owner, client.lastMessage("SlicerSetupEditSave"))
        local reply = server.lastMessage("SlicerSetupEditReply")
        equal(reply.values[1], editOpen.values[3]); equal(reply.values[2].ok, true)
        deliver(client, reply); equal(editor.frame.valid, false)
        equal(console.SlicerInformation.name, "updated"); equal(console.SlicerInformation.delay, 5)
        equal(console.SlicerInformation.fileName, "replacement"); equal(console.SlicerDoor, nil)
        equal(setupForm.frame.valid, true)
        setupForm.submit:DoClick()
        relay(server, owner, client.lastMessage("AdminFinishedCreation"))
        local accepted = server.lastMessage("SlicerInitialSetupReply")
        equal(accepted.values[2].ok, true); deliver(client, accepted)
        equal(deferred.SlicerInformation.name, "deferred")
        local replacement = link(server, owner, console, "func_door_rotating")
        console:Remove()
        equal(#replacement.inputs, 2); equal(replacement.inputs[2], "Unlock")
        equal(#oldDoor.inputs, 1); equal(deferred.valid, true)
    end)

    test("late old-owner completion cannot acquire a recovered console's newer session", function()
        local server, oldClient, newClient = gmod.new(), gmod.client(), gmod.client()
        local owner, oldHacker, newHacker = server.player(), server.player(), server.player()
        local console = setup(server, oldClient, owner, "Recovered")
        local oldDoor = link(server, owner, console, "func_door_rotating")
        open(server, oldClient, oldHacker, console)
        local late = complete(oldClient, console)
        oldDoor:Remove()
        server.receive("playerQuitConsole", oldHacker)
        reset(server, owner, console)
        local replacement = link(server, owner, console, "func_door")
        server.now = 10; open(server, newClient, newHacker, console)
        local current = complete(newClient, console)
        local messages = #server.messages
        server.now = 12; relay(server, oldHacker, late)
        equal(#server.messages, messages)
        equal(server.slicerConsoleHasActiveSession(console), true)
        equal(console.SlicerInformation.inUse, true); equal(#replacement.inputs, 1)
        server.now = 13.5; relay(server, newHacker, current)
        equal(console.removed, true); equal(#replacement.inputs, 2)
        deliver(newClient, server.lastMessage("SlicerCompleted"))
        equal(#newClient.chatMessages, 1); equal(#oldClient.chatMessages, 0)
        equal(#oldDoor.inputs, 1)
    end)

    test("a recovered original and its duplicated console keep independent links and cleanup", function()
        local server, client = gmod.new(), gmod.client()
        local owner, copier = server.player(), server.player()
        local original = setup(server, client, owner, "Same name")
        local oldDoor = link(server, owner, original, "func_door")
        local data = {SlicerInformation = original.SlicerInformation,
            SlicerCreator = owner, SlicerDoor = oldDoor}
        original:OnEntityCopyTableFinish(data)
        local copy = setmetatable(server.entity("consoleent"), {__index = server.ENT})
        copy:Initialize()
        copy.SlicerInformation, copy.SlicerCreator, copy.SlicerDoor = data.SlicerInformation, data.SlicerCreator, data.SlicerDoor
        copy:OnDuplicated(data); copy:PostEntityPaste(copier, copy, {})
        local copyDoor = link(server, copier, copy, "func_door_rotating")
        oldDoor:Remove(); reset(server, owner, original)
        local newDoor = link(server, owner, original, "func_door")
        assert(copy.SlicerInformation ~= original.SlicerInformation)
        original:Remove()
        equal(copy.valid, true); equal(#copyDoor.inputs, 1)
        equal(#newDoor.inputs, 2); equal(newDoor.inputs[2], "Unlock")
        copy:Remove()
        equal(#copyDoor.inputs, 2); equal(copyDoor.inputs[2], "Unlock")
        equal(#oldDoor.inputs, 1)
    end)
end
