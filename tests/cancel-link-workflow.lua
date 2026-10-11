-- Real setup forms, acknowledgements, chat hooks and hacking callbacks with
-- explicit packet relay. Native GMod transport/rendering is not exercised.
return function(gmod, test, equal)
    local support = dofile("tests/console-locator-support.lua")(gmod)
    local unpackValues = table.unpack or unpack
    local function deliver(client, packet) client.receive(packet.name, nil, unpackValues(packet.values)) end
    local function relay(server, owner, packet) server.receive(packet.name, owner, unpackValues(packet.values)) end
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
        function result:fill(name, folder)
            self.name:SetText(name); self.delay:SetText("2"); self.file:SetText("secret")
            if not editing then self.folder.selected = folder or "tools" end
        end
        return result
    end
    local function say(server, owner, target, text)
        owner.target = target
        return server.fire("PlayerSay", owner, text or "!setEntity")
    end

    for _, class in ipairs({"func_door", "func_door_rotating"}) do
        test("cancel accepted setup before its reply then freshly reselect and hack " .. class, function()
            local server, client, hackerClient = gmod.new(), gmod.client(), gmod.client()
            local owner, hacker = server.player(), server.player()
            local console = server.console(owner)
            local setup = form(client, server.lastMessage("PlayerSpawnedConsole"))
            setup:fill("Terminal"); setup.submit:DoClick()
            local request = assert(client.lastMessage("AdminFinishedCreation"))
            equal(setup.frame.valid, true); equal(setup.submit.enabled, true); equal(setup.submit.text, "Check setup result")
            relay(server, owner, request)
            local reply = assert(server.lastMessage("SlicerInitialSetupReply"))
            equal(reply.values[2].ok, true); equal(owner.SlicerPendingConsole, console)
            local before = #server.messages
            equal(server.fire("PlayerSay", owner, "!cancelLink"), "")
            equal(owner.SlicerPendingConsole, nil); equal(#server.messages, before)
            equal(setup.frame.valid, true); equal(setup.submit.enabled, true); equal(setup.submit.text, "Check setup result")
            deliver(client, reply); equal(setup.frame.valid, false)
            equal(owner.SlicerPendingConsole, nil, "Delayed accepted reply cannot reselect the canceled console")
            local guidance = owner.chats[#owner.chats]
            assert(guidance:find("!cancelLink", 1, true), "Accepted tools setup should explain cancellation")
            local door = server.entity(class)
            say(server, owner, door)
            equal(console.SlicerDoor, nil); equal(#door.inputs, 0)
            equal(say(server, owner, console), "")
            assert(owner.chats[#owner.chats]:find("!cancelLink", 1, true), "Explicit selection should explain cancellation")
            say(server, owner, server.entity("prop_physics"))
            equal(owner.SlicerPendingConsole, console)
            equal(server.fire("PlayerSay", owner, "!cancelLink"), "")
            say(server, owner, door); equal(console.SlicerDoor, nil); equal(#door.inputs, 0)
            equal(say(server, owner, console), ""); equal(say(server, owner, door), "")
            equal(console.SlicerDoor, door); equal(door.inputs[1], "Lock")
            server.open(hacker, console); deliver(hackerClient, server.lastMessage("ServerSendsEntityInformation"))
            hackerClient.command("/a[terminal]"); hackerClient.fireTimer("AccessDelay")
            hackerClient.command("/a[terminal]/{_tools}"); hackerClient.command("/r{_tools}/secret.exe")
            server.now = 2; relay(server, hacker, assert(hackerClient.lastMessage("PlayerActivatedDoor")))
            equal(console.removed, true); equal(#door.inputs, 2); equal(door.inputs[2], "Unlock")
            deliver(hackerClient, server.lastMessage("SlicerCompleted")); hackerClient.assertClosed()
        end)
    end

    test("cancel preserves drafts, pending saves, locator lease and active client countdown", function()
        local server, client, hackClient = support.server(), support.client(), gmod.client()
        local owner = server.player()
        local active, editable, selected = server.console(owner), server.console(owner), server.console(owner)
        assert(server.configure(owner, active, "data", 2)); assert(server.configure(owner, editable, "server", 2))
        assert(server.configure(owner, selected, "tools", 2))
        server.now = 10; server.open(owner, active)
        deliver(hackClient, server.lastMessage("ServerSendsEntityInformation"))
        hackClient.command("/a[terminal]"); local login = assert(hackClient.timers.AccessDelay)
        equal(say(server, owner, editable, "!editConsole"), "")
        local editing = form(client, server.lastMessage("SlicerSetupEditOpen"), true)
        editing:fill("Saved edit"); editing.submit:DoClick()
        local editSave = assert(client.lastMessage("SlicerSetupEditSave"))
        local pending = server.console(owner)
        local setup = form(client, server.lastMessage("PlayerSpawnedConsole"))
        setup:fill("Saved setup", "data"); setup.submit:DoClick()
        local setupSave = assert(client.lastMessage("AdminFinishedCreation"))
        local unsaved = server.console(owner)
        local draft = form(client, server.lastMessage("PlayerSpawnedConsole")); draft:fill("Keep draft", "tools")
        equal(server.fire("PlayerSay", owner, "!listConsoles 1 unlinked"), "")
        equal(server.fire("PlayerSay", owner, "!locateConsole 1"), "")
        local location = assert(server.lastMessage("SlicerConsoleLocation"))
        support.deliver(client, location)
        local marker, packets, clientPackets, timers = client.paint(), #server.messages, #client.messages, #hackClient.timerEvents
        local savedInfo, records, serial = editable.SlicerInformation, server.returnSpawnedEntities(), server.slicerSetupEditSerial
        equal(owner.SlicerPendingConsole, selected)
        server.now = 13
        equal(server.fire("PlayerSay", owner, "!cancelLink"), "")
        equal(owner.SlicerPendingConsole, nil); equal(#server.messages, packets); equal(#client.messages, clientPackets)
        equal(client.paint(), marker); equal(hackClient.timers.AccessDelay, login); equal(#hackClient.timerEvents, timers)
        equal(editing.frame.valid, true); equal(setup.frame.valid, true); equal(draft.frame.valid, true)
        equal(editing.name.editable, false); equal(setup.name.editable, false); equal(draft.name:GetValue(), "Keep draft")
        equal(editable.SlicerInformation, savedInfo); equal(server.returnSpawnedEntities(), records)
        equal(server.slicerSetupEditSerial, serial); equal(active.SlicerInformation.inUse, true)
        equal(server.lastMessage("SlicerConsoleLocation"), location)
        relay(server, owner, editSave)
        local editReply = server.lastMessage("SlicerSetupEditReply"); equal(editReply.values[2].ok, true)
        deliver(client, editReply); equal(editing.frame.valid, false)
        relay(server, owner, setupSave)
        local setupReply = server.lastMessage("SlicerInitialSetupReply"); equal(setupReply.values[2].ok, true)
        deliver(client, setupReply); equal(setup.frame.valid, false)
        equal(editable.SlicerInformation.name, "saved edit"); equal(pending.SlicerInformation.name, "saved setup")
        equal(unsaved.SlicerInformation, nil); equal(draft.frame.valid, true); equal(draft.name:GetValue(), "Keep draft")
        hackClient.fireTimer("AccessDelay"); hackClient.command("/a[terminal]/{_data}")
        hackClient.command("/d{_data}/secret.data"); hackClient.fireTimer("DownloadDataFile")
        server.now = 14; relay(server, owner, assert(hackClient.lastMessage("destroyOnServer")))
        equal(active.removed, true, "Cancellation preserves the original completion deadline")
        deliver(hackClient, server.lastMessage("SlicerCompleted")); hackClient.assertClosed()
        server.now = 69.999
        equal(server.fire("PlayerSay", owner, "!locateConsole 1"), "")
        equal(server.lastMessage("SlicerConsoleLocation").values[1], true)
        equal(server.lastMessage("SlicerConsoleLocation").values[3].x, selected.position.x)
        server.now = 70
        local packetsBeforeExpiry = #server.messages
        equal(server.fire("PlayerSay", owner, "!locateConsole 1"), "")
        equal(#server.messages, packetsBeforeExpiry, "Cancellation cannot extend the listing lease")
        assert(owner.chats[#owner.chats]:find("expired", 1, true), "Original listing lease must expire")
        equal(owner.SlicerPendingConsole, nil); equal(selected.SlicerDoor, nil)
    end)
end
