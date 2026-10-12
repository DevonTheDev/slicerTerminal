-- Real form submissions, server reservations, locator and completion callbacks.
-- Native chat delivery, input focus and multiplayer rendering are not modeled.
return function(gmod, test, equal)
    local support = dofile("tests/console-locator-support.lua")(gmod)
    local unpackValues = table.unpack or unpack
    local function deliver(client, packet) client.receive(packet.name, nil, unpackValues(packet.values)) end
    local function relay(server, actor, packet) server.receive(packet.name, actor, unpackValues(packet.values)) end
    local function form(client, packet, editing)
        local first, result, entries = #client.panels + 1, {}, {}
        deliver(client, packet)
        for index = first, #client.panels do
            local panel = client.panels[index]
            if panel.class == "DFrame" then result.frame = panel
            elseif panel.class == "DTextEntry" then entries[#entries + 1] = panel
            elseif panel.class == "DComboBox" then result.folder = panel
            elseif panel.class == "DButton" and panel.text == (editing and "Save changes" or "Done") then result.submit = panel end
        end
        equal(#entries, 3); result.name, result.delay, result.file = entries[1], entries[2], entries[3]
        result.name:SetText(editing and "Edited name" or "New setup")
        result.delay:SetText("2"); result.file:SetText("secret")
        if not editing then result.folder.selected = "data" end
        result.submit:DoClick()
        equal(result.name.editable, false); equal(result.frame.valid, true)
        return result
    end
    for _, early in ipairs({true, false}) do
    test("command directory preserves pending forms, links and locator " .. (early and "before" or "at") .. " both hacking deadlines", function()
        local server, client, hackClient = support.server(), support.client(), gmod.client()
        local owner, other = server.player(), server.player()
        local editable, selected, linked = server.console(owner), server.console(owner), server.console(owner)
        assert(server.configure(owner, editable, "server", 2))
        assert(server.configure(owner, selected, "tools", 2)); assert(server.configure(owner, linked, "tools", 2))
        local door = server.entity("func_door_rotating")
        owner.target = door; equal(server.fire("PlayerSay", owner, "!setEntity"), "")
        owner.target = selected; equal(server.fire("PlayerSay", owner, "!setEntity"), "")
        owner.target = editable; equal(server.fire("PlayerSay", owner, "!editConsole"), "")
        local editing = form(client, server.lastMessage("SlicerSetupEditOpen"), true)
        local editSave = client.lastMessage("SlicerSetupEditSave")
        local deferred = server.console(owner)
        local initial = form(client, server.lastMessage("PlayerSpawnedConsole"))
        local setupSave = client.lastMessage("AdminFinishedCreation")
        local active, otherActive = server.console(other), server.console(owner)
        assert(server.configure(other, active, "data", 2)); assert(server.configure(owner, otherActive, "server", 2))
        server.now = 10; server.open(owner, active)
        deliver(hackClient, server.lastMessage("ServerSendsEntityInformation"))
        hackClient.command("/a[terminal]"); local timer = hackClient.timers.AccessDelay
        server.open(other, otherActive)
        equal(server.fire("PlayerSay", owner, "!listConsoles"), "")
        equal(server.fire("PlayerSay", owner, "!locateConsole 1"), "")
        support.deliver(client, server.lastMessage("SlicerConsoleLocation"))
        local marker, location = client.paint(), server.lastMessage("SlicerConsoleLocation")
        local registry, information, serial = server.returnSpawnedEntities(), editable.SlicerInformation, server.slicerSetupEditSerial
        local packets, clientPackets, otherChats, focus = #server.messages, #client.messages, #other.chats, client.focusedPanel
        server.now = 11 -- Help must not move the original completion time from 14 to 15.
        for _, command in ipairs({"!slicerHelp", "!slicerHelp browse", "!slicerHelp setup", "!slicerHelp links", "!slicerHelp hacking", "!slicerHelp invalid"}) do
            equal(server.fire("PlayerSay", owner, command), "")
        end
        equal(#server.messages, packets); equal(#client.messages, clientPackets); equal(#other.chats, otherChats)
        equal(server.returnSpawnedEntities(), registry); equal(editable.SlicerInformation, information)
        equal(server.slicerSetupEditSerial, serial); equal(owner.SlicerPendingConsole, selected)
        equal(linked.SlicerDoor, door); equal(#door.inputs, 1); equal(door.inputs[1], "Lock")
        equal(server.lastMessage("SlicerConsoleLocation"), location); equal(client.paint(), marker)
        equal(client.focusedPanel, focus); equal(editing.frame.valid, true); equal(initial.frame.valid, true)
        equal(editing.name:GetValue(), "Edited name"); equal(initial.name:GetValue(), "New setup")
        equal(editing.name.editable, false); equal(initial.name.editable, false)
        equal(client.lastMessage("SlicerSetupEditSave"), editSave); equal(client.lastMessage("AdminFinishedCreation"), setupSave)
        equal(hackClient.timers.AccessDelay, timer); equal(active.SlicerInformation.inUse, true); equal(otherActive.SlicerInformation.inUse, true)
        equal(server.slicerListedConsole(owner, 1), editable)
        relay(server, owner, editSave)
        local editReply = server.lastMessage("SlicerSetupEditReply"); equal(editReply.values[2].ok, true)
        deliver(client, editReply); equal(editing.frame.valid, false)
        relay(server, owner, setupSave)
        local setupReply = server.lastMessage("SlicerInitialSetupReply"); equal(setupReply.values[2].ok, true)
        deliver(client, setupReply); equal(initial.frame.valid, false)
        equal(editable.SlicerInformation.name, "edited name"); equal(deferred.SlicerInformation.name, "new setup")
        hackClient.fireTimer("AccessDelay"); hackClient.command("/a[terminal]/{_data}")
        hackClient.command("/d{_data}/secret.data"); hackClient.fireTimer("DownloadDataFile")
        local completion = hackClient.lastMessage("destroyOnServer")
        server.now = early and 13.99 or 14
        relay(server, owner, completion); server.receive("destroyOnServer", other, otherActive)
        local removed
        if not early then removed = true end
        equal(active.removed, removed); equal(otherActive.removed, removed)
        equal(active.SlicerInformation.inUse, false); equal(otherActive.SlicerInformation.inUse, false)
        equal(owner.SlicerPendingConsole, selected); equal(linked.SlicerDoor, door); equal(#door.inputs, 1)
    end)
    end
end
