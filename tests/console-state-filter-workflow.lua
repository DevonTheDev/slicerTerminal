-- Real server/client handlers with explicit packet relay; no native GMod claim.
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
            elseif panel.class == "DButton" and panel.text == (editing and "Save changes" or "Done") then result.submit = panel
            elseif panel.class == "DButton" and panel.text == "Set up later" then result.later = panel end
        end
        equal(#entries, 3); result.name, result.delay, result.file = entries[1], entries[2], entries[3]
        function result:fill(name, folder)
            self.name:SetText(name); self.delay:SetText("2"); self.file:SetText("secret")
            if not editing then self.folder.selected = folder or "data" end
        end
        return result
    end
    local function filter(server, owner, state)
        local before, packets = #owner.chats, #server.messages
        equal(server.fire("PlayerSay", owner, "!listConsoles 1 " .. state), "")
        equal(#server.messages, packets)
        local rows = {}
        for index = before + 1, #owner.chats do
            if owner.chats[index]:match("^[1-5]%. Console") then rows[#rows + 1] = owner.chats[index] end
        end
        return rows
    end
    local function locate(server, client, owner, ent)
        equal(server.fire("PlayerSay", owner, "!locateConsole 1"), "")
        local packet = assert(server.lastMessage("SlicerConsoleLocation"))
        equal(packet.player, owner); equal(packet.values[3].x, ent.position.x)
        support.deliver(client, packet)
    end

    test("filtered locate supports deferred setup and removed-link recovery while unrelated work retains authority", function()
        local server, client, hackClient = support.server(), support.client(), gmod.client()
        local owner, hacker = server.player(), server.player()
        local active, editable, recovery, selected = server.console(owner), server.console(owner), server.console(owner), server.console(owner)
        assert(server.configure(owner, active, "data", 2)); assert(server.configure(owner, editable, "server", 2))
        assert(server.configure(owner, recovery, "tools", 2)); assert(server.configure(owner, selected, "tools", 2))
        owner.target = recovery; server.fire("PlayerSay", owner, "!setEntity")
        local removedDoor = server.entity("func_door_rotating")
        owner.target = removedDoor; server.fire("PlayerSay", owner, "!setEntity"); removedDoor:Remove()
        owner.target = selected; server.fire("PlayerSay", owner, "!setEntity")
        equal(owner.SlicerPendingConsole, selected)
        server.now = 10; server.open(hacker, active)
        deliver(hackClient, server.lastMessage("ServerSendsEntityInformation"))
        hackClient.command("/a[terminal]"); local login = hackClient.timers.AccessDelay
        owner.target = editable; server.fire("PlayerSay", owner, "!editConsole")
        local editing = form(client, server.lastMessage("SlicerSetupEditOpen"), true)
        editing:fill("Accepted edit"); editing.submit:DoClick()
        local editSave = client.lastMessage("SlicerSetupEditSave")
        local deferred = server.console(owner)
        local draft = form(client, server.lastMessage("PlayerSpawnedConsole")); draft:fill("discarded draft"); draft.later:DoClick()
        equal(draft.frame.valid, false); equal(deferred.SlicerInformation, nil)
        equal(#filter(server, owner, "setup"), 1); locate(server, client, owner, deferred)
        server.open(owner, deferred)
        local setup = form(client, server.lastMessage("PlayerSpawnedConsole")); setup:fill("Accepted setup"); setup.submit:DoClick()
        local setupSave = client.lastMessage("AdminFinishedCreation")
        local registry, info, serial = server.returnSpawnedEntities(), editable.SlicerInformation, server.slicerSetupEditSerial
        local hackerChats, marker = #hacker.chats, client.paint()
        owner.weapon = nil
        function owner:GetEyeTrace() error("Filter or locate traced") end
        function owner:GetActiveWeapon() error("Filter or locate read weapon") end
        equal(#filter(server, owner, "setup"), 1); equal(client.paint(), marker)
        locate(server, client, owner, deferred)
        equal(#filter(server, owner, "unconfirmed"), 1); locate(server, client, owner, recovery)
        equal(#filter(server, owner, "unlinked"), 1); locate(server, client, owner, selected)
        equal(owner.SlicerPendingConsole, selected); equal(editable.SlicerInformation, info)
        equal(server.returnSpawnedEntities(), registry); equal(server.slicerSetupEditSerial, serial)
        equal(editing.frame.valid, true); equal(setup.frame.valid, true)
        equal(editing.name.editable, false); equal(setup.name.editable, false)
        equal(client.lastMessage("SlicerSetupEditSave"), editSave); equal(client.lastMessage("AdminFinishedCreation"), setupSave)
        equal(#hacker.chats, hackerChats); equal(hackClient.timers.AccessDelay, login)
        equal(active.SlicerInformation.inUse, true); equal(recovery.SlicerDoor, removedDoor)
        equal(#removedDoor.inputs, 1); equal(removedDoor.inputs[1], "Lock")
        owner.GetEyeTrace = function(self) return {Entity = self.target} end
        owner.GetActiveWeapon = function(self) return self.weapon end
        relay(server, owner, editSave)
        local editReply = server.lastMessage("SlicerSetupEditReply"); equal(editReply.values[2].ok, true)
        deliver(client, editReply); equal(editing.frame.valid, false)
        relay(server, owner, setupSave)
        local setupReply = server.lastMessage("SlicerInitialSetupReply"); equal(setupReply.values[2].ok, true)
        deliver(client, setupReply); equal(setup.frame.valid, false)
        equal(deferred.SlicerInformation.name, "accepted setup"); equal(#filter(server, owner, "setup"), 0)
        equal(owner.SlicerPendingConsole, selected)
        equal(#filter(server, owner, "unconfirmed"), 1); locate(server, client, owner, recovery)
        owner.target = recovery; equal(server.fire("PlayerSay", owner, "!resetLink"), "")
        equal(recovery.SlicerDoor, nil); equal(owner.SlicerPendingConsole, selected)
        locate(server, client, owner, recovery) -- The exact row survives its status change.
        equal(server.fire("PlayerSay", owner, "!setEntity"), "")
        local replacement = server.entity("func_door")
        owner.target = replacement; equal(server.fire("PlayerSay", owner, "!setEntity"), "")
        equal(recovery.SlicerDoor, replacement); equal(#filter(server, owner, "unconfirmed"), 0)
        equal(selected.SlicerDoor, nil); equal(#replacement.inputs, 1); equal(replacement.inputs[1], "Lock")
        hackClient.fireTimer("AccessDelay"); hackClient.command("/a[terminal]/{_data}")
        hackClient.command("/d{_data}/secret.data"); hackClient.fireTimer("DownloadDataFile")
        local completion = assert(hackClient.lastMessage("destroyOnServer"))
        server.now = 14; relay(server, hacker, completion)
        equal(active.removed, true, "The unrelated original deadline and session must remain usable")
        deliver(hackClient, server.lastMessage("SlicerCompleted")); hackClient.assertClosed()
        equal(recovery.removed, nil); equal(editable.SlicerInformation.name, "accepted edit")
    end)
end
