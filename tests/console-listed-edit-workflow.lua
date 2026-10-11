-- Real chat, setup/editor UI, packet handlers and hack completion callbacks.
-- Private listing, ticket, session and door registries are never inspected.
-- The doubles do not claim native Derma, networking or brush-door coverage.
return function(gmod, test, equal)
    local unpackValues = table.unpack or unpack
    local kinds = {
        {folder = "data", extension = "data", timer = "DownloadDataFile", lease = "expiry"},
        {folder = "server", extension = "sys", timer = "DownloadServerFile", lease = "replacement"},
        {folder = "tools", extension = "exe", lease = "invalid relisting"},
    }
    local function deliver(client, packet)
        assert(packet, "Missing server packet")
        client.receive(packet.name, nil, unpackValues(packet.values))
    end
    local function relay(server, actor, packet)
        assert(packet, "Missing client packet")
        server.receive(packet.name, actor, unpackValues(packet.values))
    end
    local function live(panel)
        while panel do
            if not panel.valid or panel:IsMarkedForDeletion() or not panel:IsVisible() then return false end
            panel = panel.parent
        end
        return true
    end
    local function form(client, packet, editing)
        local first, result, entries = #client.panels + 1, {}, {}
        deliver(client, packet)
        for index = first, #client.panels do
            local panel = client.panels[index]
            if panel.class == "DFrame" then result.frame = panel
            elseif panel.class == "DTextEntry" then entries[#entries + 1] = panel
            elseif panel.class == "DComboBox" then result.folder = panel
            elseif panel.class == "DButton" and panel.text == (editing and "Save changes" or "Done") then
                result.submit = panel
            end
        end
        assert(result.frame and result.submit, "Expected the existing configuration form")
        equal(#entries, 3, "Name, delay and filename remain the only text fields")
        result.name, result.delay, result.file = entries[1], entries[2], entries[3]
        if editing then
            assert(not result.folder or result.folder.enabled == false, "Saved folder cannot be edited")
        end
        return result
    end
    local function setup(server, client, owner, folder, name)
        local console = server.console(owner)
        local fields = form(client, server.lastMessage("PlayerSpawnedConsole"))
        fields.name:SetText(name); fields.delay:SetText("2"); fields.file:SetText("Secret")
        fields.folder.selected = folder
        fields.submit:DoClick()
        local request = assert(client.lastMessage("AdminFinishedCreation"))
        equal(live(fields.frame), true)
        relay(server, owner, request)
        local reply = assert(server.lastMessage("SlicerInitialSetupReply"))
        equal(reply.player, owner); equal(reply.values[1], request.values[1][6])
        equal(reply.values[2].ok, true)
        deliver(client, reply); equal(live(fields.frame), false)
        return console
    end
    local function list(server, owner, command)
        local before, packets = #owner.chats, #server.messages
        equal(server.fire("PlayerSay", owner, command or "!listConsoles"), "")
        equal(#server.messages, packets, "Listing remains private chat only")
        local rows = {}
        for index = before + 1, #owner.chats do
            if owner.chats[index]:match("^[1-5]%. Console") then rows[#rows + 1] = owner.chats[index] end
        end
        return rows
    end
    local function rowFor(rows, console)
        for _, row in ipairs(rows) do
            if row:match("^[1-5]%. Console.- %(current ID #" .. console:GetCreationID() .. "%)") then return row end
        end
        error("Missing listed console #" .. console:GetCreationID())
    end
    local function contains(text, expected)
        assert(text:find(expected, 1, true), "Expected '" .. expected .. "' in: " .. text)
    end
    local function opening(server, owner, console, command)
        local before = #server.messages
        local result = server.fire("PlayerSay", owner, command)
        local packet = server.lastMessage("SlicerSetupEditOpen")
        -- This is deliberately the first row-operation assertion, so the
        -- unchanged baseline fails at the missing public editor-open packet.
        assert(packet and #server.messages > before,
            command .. " must send a fresh SlicerSetupEditOpen for the listed second console")
        equal(result, ""); equal(#server.messages, before + 1)
        equal(packet.player, owner); equal(#packet.values, 4, "Existing editor-open packet shape")
        equal(packet.values[1], console); equal(packet.values[2], owner)
        assert(type(packet.values[3]) == "string" and packet.values[3] ~= "", "Expected a server edit token")
        equal(packet.values[4].displayIdentity.creationID, console:GetCreationID())
        equal(packet.values[4].displayIdentity.entityIndex, console:EntIndex())
        return packet
    end
    local function activeEntry(client)
        for index = #client.panels, 1, -1 do
            local panel = client.panels[index]
            if live(panel) and panel.OnEnter then return panel end
        end
        error("Missing active hacking command input")
    end
    local function beginHack(server, client, hacker, console, kind, name, file, delay, oldName)
        local before, started = #server.messages, server.now
        server.open(hacker, console)
        equal(#server.messages, before + 1, "A later ordinary Use must still reserve this exact console")
        local packet = assert(server.lastMessage("ServerSendsEntityInformation"))
        equal(packet.player, hacker); equal(packet.values[1], console)
        equal(packet.values[3].name, name); equal(packet.values[3].fileName, file)
        equal(packet.values[3].delay, delay); equal(packet.values[3].fileType, kind.folder)
        equal(packet.values[3].inUse, false)
        deliver(client, packet)
        if oldName then
            client.command("/a[" .. oldName .. "]")
            equal(client.timers.AccessDelay, nil, "The old saved name no longer starts login")
        end
        client.command("/a[" .. name .. "]")
        equal(assert(client.timers.AccessDelay).delay, delay)
        return started
    end
    local function finishHack(server, client, hacker, console, kind, name, file, delay, started, door)
        client.fireTimer("AccessDelay")
        server.now = math.max(server.now, started + delay)
        client.command("/a[" .. name .. "]/{_" .. kind.folder .. "}")
        local rows = {}
        for _, panel in ipairs(activeEntry(client).parent.children) do
            if panel.class == "DTextEntry" and not panel.OnEnter then rows[#rows + 1] = panel end
        end
        equal(#rows, 3)
        equal(rows[1]:GetValue(), string.upper(file) .. "." .. kind.extension,
            "The real terminal listing uses the expected filename and fixed folder")
        if door then
            equal(#door.inputs, 1); equal(door.inputs[1], "Lock")
            equal(server.fire("PlayerUse", hacker, door), false)
        end
        client.command((kind.timer and "/d" or "/r") .. "{_" .. kind.folder .. "}/" .. file .. "." .. kind.extension)
        if kind.timer then
            equal(assert(client.timers[kind.timer]).delay, delay)
            client.fireTimer(kind.timer)
            server.now = math.max(server.now, started + delay * 2)
        end
        local request = assert(client.lastMessage(kind.timer and "destroyOnServer" or "PlayerActivatedDoor"))
        equal(request.values[1], console)
        local before = #server.messages
        relay(server, hacker, request)
        equal(console.removed, true, "The original public session must still complete successfully")
        equal(#server.messages, before + 1)
        local accepted = assert(server.lastMessage("SlicerCompleted"))
        equal(accepted.player, hacker); equal(accepted.values[1], name)
        equal(accepted.values[2], file); equal(accepted.values[3], kind.folder)
        deliver(client, accepted); client.assertClosed()
        if door then
            equal(#door.inputs, 2); equal(door.inputs[2], "Unlock")
        end
    end

    for _, kind in ipairs(kinds) do
        test("listed " .. kind.folder .. " editor preserves drafts and saves after " .. kind.lease .. " through public workflows", function()
            local server, client, hackClient = gmod.new(), gmod.client(), gmod.client()
            local owner, hacker, otherHacker = server.player(), server.player(), server.player()
            local sibling = setup(server, client, owner, "data", "Shared name")
            local selected = setup(server, client, owner, kind.folder, "Shared name")
            local identity, door = selected:GetName()
            if kind.folder == "tools" then
                door = server.entity("func_door_rotating")
                owner.target = door
                equal(server.fire("PlayerSay", owner, "!setEntity"), "")
                equal(selected.SlicerDoor, door); equal(door.inputs[1], "Lock")
            end
            local rows = list(server, owner)
            equal(#rows, 2)
            contains(rowFor({rows[1]}, sibling), "shared name")
            contains(rowFor({rows[2]}, selected), "shared name")

            -- These later creations do not replace the already printed page.
            local active = setup(server, client, owner, "data", "Active terminal")
            local pending = setup(server, client, owner, "tools", "Pending terminal")
            local activeStart = beginHack(server, hackClient, otherHacker, active, kinds[1], "active terminal", "secret", 2)
            local activeTimer = hackClient.timers.AccessDelay
            local trace, weapon = owner.GetEyeTrace, owner.weapon
            owner.target, owner.weapon = sibling, nil
            owner.GetEyeTrace = function() error("Listed editor must never read the eye trace") end
            local packet = opening(server, owner, selected, "!editConsole 2")
            equal(packet.values[4].fileType, kind.folder)
            local editing = form(client, packet, true)
            equal(editing.name:GetValue(), "shared name"); equal(tonumber(editing.delay:GetValue()), 2)
            equal(editing.file:GetValue(), "secret")
            editing.name:SetText("  Renamed Console  ")
            editing.delay:SetText("3.75"); editing.file:SetText("  ConsoleLogs  ")
            local panels, popup, token = #client.panels, editing.frame.popupCalls, packet.values[3]
            local function sameDraft(reopened)
                equal(reopened.values[3], token, "Both entry points reuse the current server ticket")
                deliver(client, reopened)
                equal(#client.panels, panels, "Repeated opens retain the one existing form")
                popup = popup + 1; equal(editing.frame.popupCalls, popup)
                equal(live(editing.frame), true)
                equal(editing.name:GetValue(), "  Renamed Console  ")
                equal(editing.delay:GetValue(), "3.75"); equal(editing.file:GetValue(), "  ConsoleLogs  ")
            end
            sameDraft(opening(server, owner, selected, "!editConsole 2"))
            owner.GetEyeTrace, owner.target = trace, selected
            sameDraft(opening(server, owner, selected, "!editConsole"))
            owner.GetEyeTrace = function() error("Listed editor must never read the eye trace") end
            owner.target = sibling
            sameDraft(opening(server, owner, selected, "!editConsole 2"))

            if kind.lease == "expiry" then
                server.now = 60 -- No Think callback: expiry must be checked on request.
            elseif kind.lease == "replacement" then
                rows = list(server, owner, "!findConsoles 1 pending terminal")
                equal(#rows, 1); rowFor(rows, pending)
            else
                equal(#list(server, owner, "!listConsoles 0"), 0)
            end
            local messages, chats = #server.messages, #owner.chats
            equal(server.fire("PlayerSay", owner, "!editConsole 2"), "")
            equal(#server.messages, messages, "Unavailable row cannot open a replacement form")
            equal(#owner.chats, chats + 1, "Unavailable row gives one private relist instruction")
            contains(owner.chats[#owner.chats], "!listConsoles")
            equal(live(editing.frame), true, "Losing the listing does not retire the open edit")
            editing.submit:DoClick()
            equal(live(editing.frame), true, "Save waits for its acknowledgement")
            local save = assert(client.lastMessage("SlicerSetupEditSave"))
            equal(#save.values, 3); equal(save.values[1], selected); equal(save.values[2], token)
            local fields, allowed = 0, {name = true, delay = true, fileName = true}
            for key in pairs(save.values[3]) do
                assert(allowed[key], "Save must contain only existing editable fields")
                fields = fields + 1
            end
            equal(fields, 3)
            local before = #server.messages
            relay(server, owner, save)
            equal(#server.messages, before + 1)
            local accepted = assert(server.lastMessage("SlicerSetupEditReply"))
            equal(#accepted.values, 2); equal(accepted.player, owner)
            equal(accepted.values[1], token); equal(accepted.values[2].ok, true)
            equal(live(editing.frame), true, "Only delivery of the matching reply closes the client")
            deliver(client, accepted); equal(live(editing.frame), false)
            equal(selected:GetName(), identity); equal(selected.SlicerCreator, owner)
            equal(selected.SlicerDoor, door, "The saved editor keeps its existing door assignment")
            rows = list(server, owner)
            contains(rowFor(rows, selected), "renamed console")
            contains(rowFor(rows, selected), kind.folder == "tools" and "registered link to func_door_rotating"
                or "configured for " .. kind.folder)
            contains(rowFor(rows, sibling), "shared name")
            equal(hackClient.timers.AccessDelay, activeTimer)

            -- Complete the already-running hack without reopening it, and
            -- accept the original pending selection by linking only a door.
            finishHack(server, hackClient, otherHacker, active, kinds[1], "active terminal", "secret", 2, activeStart)
            owner.GetEyeTrace, owner.weapon = trace, weapon
            local pendingDoor = server.entity("func_door")
            owner.target = pendingDoor
            equal(server.fire("PlayerSay", owner, "!setEntity"), "")
            equal(pending.SlicerDoor, pendingDoor, "The original tools selection remains authoritative")
            equal(#pendingDoor.inputs, 1); equal(pendingDoor.inputs[1], "Lock")
            equal(selected.SlicerDoor, door)
            equal(server.fire("PlayerUse", hacker, pendingDoor), false)

            local started = beginHack(server, client, hacker, selected, kind, "renamed console", "consolelogs", 3.75, "shared name")
            finishHack(server, client, hacker, selected, kind, "renamed console", "consolelogs", 3.75, started, door)
            local siblingStart = beginHack(server, client, hacker, sibling, kinds[1], "shared name", "secret", 2)
            finishHack(server, client, hacker, sibling, kinds[1], "shared name", "secret", 2, siblingStart)
            equal(pending.removed, nil); equal(pending.SlicerDoor, pendingDoor)
            equal(#pendingDoor.inputs, 1, "Completing the edited console and sibling cannot unlock the pending console's door")
        end)
    end
end
