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
        test("pending survives catalogue replacement expiry and respawn before actual " .. class .. " linking", function()
            local server, client, hackClient = gmod.new(), gmod.client(), gmod.client()
            local owner, hacker = server.player(), server.player()
            local console = server.console(owner)
            local setup = form(client, server.lastMessage("PlayerSpawnedConsole"))
            setup:fill("Alpha"); setup.submit:DoClick()
            relay(server, owner, assert(client.lastMessage("AdminFinishedCreation")))
            local reply = assert(server.lastMessage("SlicerInitialSetupReply"))
            equal(owner.SlicerPendingConsole, console)
            local packets = #server.messages
            equal(server.fire("PlayerSay", owner, "!pendingLink"), "")
            assert(owner.chats[#owner.chats]:find("'alpha'", 1, true)); equal(#server.messages, packets)
            deliver(client, reply); equal(setup.frame.valid, false); equal(owner.SlicerPendingConsole, console)
            local second = server.console(owner); assert(server.configure(owner, second, "tools", 2))
            equal(owner.SlicerPendingConsole, second, "Existing accepted setup still replaces selection")
            equal(server.fire("PlayerSay", owner, "!listConsoles"), "")
            equal(server.fire("PlayerSay", owner, "!setEntity 1"), ""); equal(owner.SlicerPendingConsole, console)
            equal(server.fire("PlayerSay", owner, "!findConsoles 1 terminal"), "")
            equal(server.slicerListedConsole(owner, 1), second)
            equal(server.fire("PlayerSay", owner, "!pendingLink"), ""); equal(owner.SlicerPendingConsole, console)
            server.now = 60; equal(server.slicerListedConsole(owner, 1), nil)
            equal(server.fire("PlayerSay", owner, "!pendingLink"), ""); equal(owner.SlicerPendingConsole, console)
            owner.alive = false; server.fire("PlayerDeath", owner); equal(owner.SlicerPendingConsole, console)
            local before = #owner.chats
            equal(server.fire("PlayerSay", owner, "!pendingLink"), ""); equal(#owner.chats, before)
            owner.alive = true; server.now = 3600
            equal(server.fire("PlayerSay", owner, "!pendingLink"), ""); equal(owner.SlicerPendingConsole, console)
            assert(owner.chats[#owner.chats]:find("'alpha'", 1, true), "Pending choice has no invented timeout")
            say(server, owner, server.entity("prop_physics")); equal(owner.SlicerPendingConsole, console)
            equal(server.fire("PlayerSay", owner, "!pendingLink"), "")
            local door = server.entity(class); equal(say(server, owner, door), "")
            equal(console.SlicerDoor, door); equal(door.inputs[1], "Lock"); equal(owner.SlicerPendingConsole, nil)
            equal(server.fire("PlayerSay", owner, "!pendingLink"), "")
            assert(owner.chats[#owner.chats]:find("no pending", 1, true))
            server.open(hacker, console); deliver(hackClient, server.lastMessage("ServerSendsEntityInformation"))
            hackClient.command("/a[alpha]"); hackClient.fireTimer("AccessDelay")
            hackClient.command("/a[alpha]/{_tools}"); hackClient.command("/r{_tools}/secret.exe")
            server.now = 3602; relay(server, hacker, assert(hackClient.lastMessage("PlayerActivatedDoor")))
            equal(console.removed, true); equal(door.inputs[2], "Unlock"); equal(second.removed, nil)
            deliver(hackClient, server.lastMessage("SlicerCompleted")); hackClient.assertClosed()
        end)
    end

    test("pending preserves drafts, pending saves, locator lease, other selection and active client countdown", function()
        local server, client, hackClient = support.server(), support.client(), gmod.client()
        local owner, other = server.player(), server.player()
        local otherSelected = server.console(other); assert(server.configure(other, otherSelected, "tools", 2))
        local otherChats = #other.chats
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
        equal(server.fire("PlayerSay", owner, "!pendingLink"), "")
        equal(owner.SlicerPendingConsole, selected); equal(other.SlicerPendingConsole, otherSelected); equal(#other.chats, otherChats)
        equal(#server.messages, packets); equal(#client.messages, clientPackets)
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
        equal(active.removed, true, "Pending inspection preserves the original completion deadline")
        deliver(hackClient, server.lastMessage("SlicerCompleted")); hackClient.assertClosed()
        server.now = 69.999
        equal(server.fire("PlayerSay", owner, "!locateConsole 1"), "")
        equal(server.lastMessage("SlicerConsoleLocation").values[1], true)
        equal(server.lastMessage("SlicerConsoleLocation").values[3].x, selected.position.x)
        server.now = 70
        local packetsBeforeExpiry = #server.messages
        equal(server.fire("PlayerSay", owner, "!locateConsole 1"), "")
        equal(#server.messages, packetsBeforeExpiry, "Pending inspection cannot extend the listing lease")
        assert(owner.chats[#owner.chats]:find("expired", 1, true), "Original listing lease must expire")
        equal(owner.SlicerPendingConsole, selected); equal(selected.SlicerDoor, nil)
    end)
end
