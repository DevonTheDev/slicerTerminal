-- Existing client forms, locator and all three terminal completion handlers.
-- API doubles certify handler behavior, not native Derma/chat/brush rendering.
return function(gmod, test, equal)
    local support = dofile("tests/console-locator-support.lua")(gmod)
    local unpackValues = table.unpack or unpack
    local function deliver(client, packet) client.receive(packet.name, nil, unpackValues(packet.values)) end
    local function relay(server, actor, packet) server.receive(packet.name, actor, unpackValues(packet.values)) end
    local function form(client, packet, editing)
        local before, result, entries = #client.panels, {}, {}
        deliver(client, packet)
        for i = before + 1, #client.panels do
            local panel = client.panels[i]
            if panel.class == "DFrame" then result.frame = panel
            elseif panel.class == "DTextEntry" then entries[#entries + 1] = panel
            elseif panel.class == "DComboBox" then result.folder = panel
            elseif panel.class == "DButton" and panel.text == (editing and "Save changes" or "Done") then result.submit = panel end
        end
        assert(result.frame and result.submit); equal(#entries, editing and packet.values[4].fileType ~= "tools" and 4 or 3, "Only data/server edits add an intel input")
        if entries[4] then
            equal(entries[4]:GetValue(), packet.values[4].intelBody or "")
            equal(entries[4].multiline, true)
        end
        result.name, result.delay, result.file = entries[1], entries[2], entries[3]
        return result
    end
    local function inspect(server, owner, row, lines)
        local chats, packets = #owner.chats, #server.messages
        equal(server.fire("PlayerSay", owner, "!inspectConsole " .. row), "", "Inspection must use the real private handler")
        equal(#owner.chats, chats + (lines or 3)); equal(#server.messages, packets)
    end
    local kinds = {
        {folder = "data", extension = "data", timer = "DownloadDataFile"},
        {folder = "server", extension = "sys", timer = "DownloadServerFile"},
        {folder = "tools", extension = "exe"},
    }
    for _, kind in ipairs(kinds) do
        test("saved inspection preserves setup, edit, selection, locator and active " .. kind.folder .. " completion", function()
            local server, client, hackClient, locator = support.server(), gmod.client(), gmod.client(), support.client()
            local owner, hacker, observer = server.player(), server.player(), server.player()
            local console = server.console(owner)
            assert(server.configure(owner, console, kind.folder, 2))
            local door
            if kind.folder == "tools" then
                door = server.entity("func_door_rotating")
                owner.target = door; equal(server.fire("PlayerSay", owner, "!setEntity"), "")
                equal(console.SlicerDoor, door); equal(door.inputs[1], "Lock")
            end
            local pending = server.console(owner)
            assert(server.configure(owner, pending, "tools"))
            equal(owner.SlicerPendingConsole, pending)
            local deferred = server.console(owner)
            local setup = form(client, server.lastMessage("PlayerSpawnedConsole"))
            setup.name:SetText("Deferred draft"); setup.delay:SetText("3"); setup.file:SetText("Draft file")
            setup.folder.selected = "server"
            equal(server.fire("PlayerSay", owner, "!listConsoles"), "")
            equal(server.fire("PlayerSay", owner, "!locateConsole 1"), "")
            local marker = server.lastMessage("SlicerConsoleLocation")
            support.deliver(locator, marker)
            local beforeMarker = locator.paint()
            equal(server.fire("PlayerSay", owner, "!editConsole 1"), "")
            local editPacket = server.lastMessage("SlicerSetupEditOpen")
            local edit = form(client, editPacket, true)
            edit.name:SetText("Edited terminal"); edit.delay:SetText("2.5"); edit.file:SetText("Edited file")
            local serial, panels, clientPackets = server.slicerSetupEditSerial, #client.panels, #client.messages
            owner.weapon, owner.target = nil, nil
            inspect(server, owner, 1); inspect(server, owner, 2); inspect(server, owner, 3, 1)
            equal(server.slicerSetupEditSerial, serial); equal(#client.panels, panels); equal(#client.messages, clientPackets)
            equal(setup.name:GetValue(), "Deferred draft"); equal(edit.name:GetValue(), "Edited terminal")
            equal(owner.SlicerPendingConsole, pending); equal(server.lastMessage("SlicerConsoleLocation"), marker)
            equal(locator.paint(), beforeMarker); equal(#observer.chats, 0)
            if door then equal(console.SlicerDoor, door); equal(#door.inputs, 1); equal(server.fire("PlayerUse", hacker, door), false) end

            edit.submit:DoClick(); relay(server, owner, client.lastMessage("SlicerSetupEditSave"))
            local editReply = server.lastMessage("SlicerSetupEditReply")
            equal(editReply.values[2].ok, true, "Inspection must preserve the existing edit ticket")
            deliver(client, editReply); equal(edit.frame.valid, false)
            equal(console.SlicerInformation.name, "edited terminal"); equal(console.SlicerInformation.fileName, "edited file")
            inspect(server, owner, 1)
            assert(owner.chats[#owner.chats]:find("edited file", 1, true), "Fresh inspection must read the current saved data")
            setup.submit:DoClick(); relay(server, owner, client.lastMessage("AdminFinishedCreation"))
            local setupReply = server.lastMessage("SlicerInitialSetupReply")
            equal(setupReply.values[2].ok, true, "Inspection must preserve the pending initial setup")
            deliver(client, setupReply); equal(setup.frame.valid, false)
            equal(deferred.SlicerInformation.name, "deferred draft"); equal(owner.SlicerPendingConsole, pending)

            server.now = 10; server.open(hacker, console)
            local opened = server.lastMessage("ServerSendsEntityInformation")
            equal(opened.player, hacker); equal(opened.values[1], console)
            deliver(hackClient, opened)
            equal(server.slicerConsoleHasActiveSession(console), true)
            inspect(server, owner, 1) -- Both the ordinary busy flag and actual reservation permit reads.
            console.SlicerInformation.inUse = false
            server.now = 10.5; inspect(server, owner, 1)
            equal(server.slicerConsoleHasActiveSession(console), true)
            equal(console.SlicerInformation.inUse, false, "Inspection must not repair legacy busy flags")
            equal(owner.SlicerPendingConsole, pending); equal(locator.paint(), beforeMarker)
            hackClient.command("/a[edited terminal]")
            equal(hackClient.timers.AccessDelay.delay, 2.5); hackClient.fireTimer("AccessDelay")
            hackClient.command("/a[edited terminal]/{_" .. kind.folder .. "}")
            hackClient.command((kind.timer and "/d" or "/r") .. "{_" .. kind.folder .. "}/edited file." .. kind.extension)
            if kind.timer then equal(hackClient.timers[kind.timer].delay, 2.5); hackClient.fireTimer(kind.timer) end
            server.now = 10 + (kind.timer and 5 or 2.5)
            relay(server, hacker, hackClient.lastMessage(kind.timer and "destroyOnServer" or "PlayerActivatedDoor"))
            equal(console.removed, true, "Inspection must preserve the original server completion deadline")
            local accepted = server.lastMessage("SlicerCompleted")
            equal(accepted.player, hacker); equal(accepted.values[1], "edited terminal")
            equal(accepted.values[2], "edited file"); equal(accepted.values[3], kind.folder)
            deliver(hackClient, accepted); hackClient.assertClosed()
            equal(owner.SlicerPendingConsole, pending)
            if door then equal(#door.inputs, 2); equal(door.inputs[2], "Unlock") end
            owner.target = server.entity("func_door")
            equal(server.fire("PlayerSay", owner, "!setEntity"), "")
            equal(pending.SlicerDoor, owner.target, "The original pending selection must still link normally")
        end)
    end
end
