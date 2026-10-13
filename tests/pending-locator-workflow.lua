-- Three fixed workflow cases using the real chat, network, form and hacking
-- handlers. Wire vectors, projection, focus and door inputs are API doubles;
-- this is not native GMod transport, rendering or multiplayer evidence.
return function(gmod, test, equal)
    local support = dofile("tests/console-locator-support.lua")(gmod)
    local unpackValues = table.unpack or unpack
    local function serverFixture()
        local server = support.server()
        server.Vector = support.vector
        return server
    end
    local function contains(text, fragment)
        assert(text:find(fragment, 1, true), "Missing '" .. fragment .. "' in " .. text)
    end
    local function deliver(client, packet)
        assert(packet, "Missing server packet")
        if packet.name == "SlicerConsoleLocation" then
            -- Supply only the test projection method for the wire vector. The
            -- existing Bool/String/Vector payload and real receiver are retained.
            return support.deliver(client, packet)
        end
        client.receive(packet.name, nil, unpackValues(packet.values))
    end
    local function relay(server, owner, packet)
        assert(packet, "Missing client packet")
        server.receive(packet.name, owner, unpackValues(packet.values))
    end
    local function say(server, owner, text, target)
        if target then owner.target = target end
        return server.fire("PlayerSay", owner, text)
    end
    local function configured(server, owner, name, folder)
        local console = server.console(owner)
        server.receive("AdminFinishedCreation", owner,
            {name, 2, folder or "tools", "Secret", console:GetName()})
        assert(console.SlicerInformation, "Real setup handler did not accept configuration")
        return console
    end
    local function locate(server, client, owner, argument, console)
        local count = #server.messages
        equal(say(server, owner, "!locateConsole " .. argument), "")
        equal(#server.messages, count + 1, "Location must produce exactly one fresh private packet")
        local packet = server.messages[#server.messages]
        equal(packet.name, "SlicerConsoleLocation"); equal(packet.player, owner)
        equal(packet.values[1], argument ~= "clear")
        equal(#packet.values, argument == "clear" and 1 or 3, "Existing location packet layout")
        if console then
            equal(type(packet.values[2]), "string"); assert(#packet.values[2] <= 240)
            equal(packet.values[3].x, console.position.x)
            equal(packet.values[3].y, console.position.y)
            equal(packet.values[3].z, console.position.z)
        end
        if client then deliver(client, packet) end
        return packet
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
        equal(#entries, 3); assert(result.frame and result.submit)
        result.name, result.delay, result.file = entries[1], entries[2], entries[3]
        function result:fill(name, folder)
            self.name:SetText(name); self.delay:SetText("2"); self.file:SetText("secret")
            if not editing then self.folder.selected = folder or "tools" end
        end
        return result
    end
    local function upvalue(callback, wanted)
        for index = 1, 32 do
            local name, value = debug.getupvalue(callback, index)
            if not name then break end
            if name == wanted then return value end
        end
        error("Missing server state: " .. wanted)
    end

    test("pending locator 13 relays the existing snapshot packet through replacement expiry clear and death", function()
        local server, client = serverFixture(), support.client()
        local owner, other = server.player(), server.player()
        local alpha = configured(server, owner, "Alpha")
        alpha.position = support.vector(300, 0, 400)
        client.net.ReadEntity = function() error("A location snapshot must not resolve a client entity") end
        client.vgui.Create = function() error("A location snapshot must not create a panel") end
        local focus, focusCalls, otherChats = client.focusedPanel, #client.focusCalls, #other.chats
        local first = locate(server, client, owner, "pending", alpha)
        local firstText = client.paint()
        contains(firstText, "Location snapshot (15s)"); contains(firstText, "alpha")
        contains(firstText, "500 units"); contains(firstText, "400 above")
        equal(say(server, owner, "!cancelLink"), ""); equal(owner.SlicerPendingConsole, nil)
        alpha.position = support.vector(900, 0, 0)
        equal(client.paint(), firstText, "Cancellation and movement cannot track or retract a snapshot")
        equal(first.values[3].x, 300); equal(first.values[3].z, 400)

        local beta = configured(server, owner, "Beta")
        beta.position = support.vector(600, 0, 800)
        server.now, client.now = 10, 10
        locate(server, client, owner, "pending", beta)
        local replacement = client.paint()
        contains(replacement, "beta"); contains(replacement, "1000 units")
        assert(not replacement:find("alpha", 1, true), "Replacement retained the old marker")
        client.now = 15; contains(client.paint(), "beta")
        client.now = 24.999; contains(client.paint(), "beta")
        client.now = 25; client.fire("Think")
        equal(client.paint(), ""); equal(next(client.hooks.Think or {}), nil)

        locate(server, client, owner, "pending", beta)
        locate(server, client, owner, "clear")
        equal(client.paint(), ""); equal(next(client.hooks.Think or {}), nil)
        equal(owner.SlicerPendingConsole, beta, "Clearing the marker must retain the selection")
        locate(server, client, owner, "pending", beta)
        owner.alive, client.localPlayer.alive = false, false
        server.fire("PlayerDeath", owner); client.fire("Think")
        equal(client.paint(), ""); equal(next(client.hooks.Think or {}), nil)
        owner.alive, client.localPlayer.alive = true, true
        equal(client.paint(), "", "Respawn cannot restore a retired marker")
        equal(owner.SlicerPendingConsole, beta)
        equal(#client.panels, 0); equal(client.focusedPanel, focus); equal(#client.focusCalls, focusCalls)
        equal(#client.messages, 0); equal(#other.chats, otherChats)
    end)

    test("pending locator 14 preserves exact selection through both brush-door link and timed hack workflows", function()
        for _, class in ipairs({"func_door", "func_door_rotating"}) do
            local server, client, hackClient = serverFixture(), support.client(), gmod.client()
            local owner, hacker = server.player(), server.player()
            local alpha = server.console(owner)
            local setup = form(client, server.lastMessage("PlayerSpawnedConsole"))
            setup:fill("Alpha"); setup.submit:DoClick()
            relay(server, owner, client.lastMessage("AdminFinishedCreation"))
            local setupReply = assert(server.lastMessage("SlicerInitialSetupReply"))
            equal(setupReply.values[2].ok, true); deliver(client, setupReply)
            equal(setup.frame.valid, false); equal(owner.SlicerPendingConsole, alpha)

            local beta = configured(server, owner, "Beta")
            local betaDoor, alphaDoor, unrelatedDoor = server.entity(class), server.entity(class), server.entity(class)
            equal(say(server, owner, "!setEntity", betaDoor), "")
            equal(beta.SlicerDoor, betaDoor); equal(#betaDoor.inputs, 1); equal(betaDoor.inputs[1], "Lock")
            equal(say(server, owner, "!listConsoles"), "")
            equal(say(server, owner, "!setEntity 1"), ""); equal(owner.SlicerPendingConsole, alpha)
            equal(say(server, owner, "!findConsoles 1 beta"), "")
            equal(server.slicerListedConsole(owner, 1), beta)
            server.now = 60; equal(server.slicerListedConsole(owner, 1), nil)
            local packet = locate(server, client, owner, "pending", alpha)
            contains(packet.values[2], "alpha"); contains(client.paint(), "Location snapshot")
            equal(server.slicerListedConsole(owner, 1), nil, "Locating pending cannot recreate an expired page")
            equal(owner.SlicerPendingConsole, alpha); equal(alpha.SlicerDoor, nil)
            equal(#alphaDoor.inputs, 0); equal(#betaDoor.inputs, 1); equal(#unrelatedDoor.inputs, 0)

            equal(say(server, owner, "!setEntity", alphaDoor), "")
            equal(alpha.SlicerDoor, alphaDoor); equal(owner.SlicerPendingConsole, nil)
            equal(#alphaDoor.inputs, 1); equal(alphaDoor.inputs[1], "Lock")
            server.open(hacker, alpha)
            local opening = assert(server.lastMessage("ServerSendsEntityInformation"))
            equal(opening.player, hacker); equal(opening.values[1], alpha); deliver(hackClient, opening)
            hackClient.command("/a[alpha]"); assert(hackClient.timers.AccessDelay)
            server.now = 61.999
            equal(say(server, hacker, "!hackStatus"), "")
            equal(hacker.chats[#hacker.chats - 1], "Server minimum wait: 1 seconds remaining.")
            equal(#alphaDoor.inputs, 1); equal(#betaDoor.inputs, 1)
            hackClient.fireTimer("AccessDelay")
            hackClient.command("/a[alpha]/{_tools}"); hackClient.command("/r{_tools}/secret.exe")
            local completion = assert(hackClient.lastMessage("PlayerActivatedDoor"))
            server.now = 62; relay(server, hacker, completion)
            equal(alpha.removed, true); equal(beta.removed, nil)
            equal(#alphaDoor.inputs, 2); equal(alphaDoor.inputs[2], "Unlock")
            equal(beta.SlicerDoor, betaDoor); equal(#betaDoor.inputs, 1); equal(betaDoor.inputs[1], "Lock")
            equal(#unrelatedDoor.inputs, 0)
            deliver(hackClient, server.lastMessage("SlicerCompleted")); hackClient.assertClosed()
            local packets = #server.messages
            relay(server, hacker, completion)
            equal(#server.messages, packets); equal(#alphaDoor.inputs, 2); equal(#betaDoor.inputs, 1)
        end
    end)

    test("pending locator 15 preserves acknowledgements draft choices row lease and unrelated hack deadline", function()
        local server, client, hackClient = serverFixture(), support.client(), gmod.client()
        local owner, other = server.player(), server.player()
        local otherSelected = configured(server, other, "Other")
        local otherChats = #other.chats
        local active = configured(server, owner, "Terminal", "data")
        local editable = configured(server, owner, "Editable", "server")
        local selected = configured(server, owner, "Selected")
        server.now = 10; server.open(owner, active)
        deliver(hackClient, server.lastMessage("ServerSendsEntityInformation"))
        hackClient.command("/a[terminal]")
        local login, hackTimerEvents = assert(hackClient.timers.AccessDelay), #hackClient.timerEvents
        local sessions = upvalue(server.ENT.AcceptInput, "sessions")
        local session = assert(sessions[owner]); equal(session.completeAt, 14)
        equal(say(server, owner, "!editConsole", editable), "")
        local editOpen = assert(server.lastMessage("SlicerSetupEditOpen"))
        local editing = form(client, editOpen, true)
        editing:fill("Saved edit"); editing.submit:DoClick()
        local editSave = assert(client.lastMessage("SlicerSetupEditSave"))
        local pending = server.console(owner)
        local setup = form(client, server.lastMessage("PlayerSpawnedConsole"))
        setup:fill("Saved setup", "data"); setup.submit:DoClick()
        local setupSave = assert(client.lastMessage("AdminFinishedCreation"))
        local unsaved = server.console(owner)
        local draft = form(client, server.lastMessage("PlayerSpawnedConsole"))
        draft:fill("Keep draft"); draft.file:RequestFocus(); draft.file:SetCaretPos(3)
        equal(say(server, owner, "!listConsoles 1 unlinked"), "")
        equal(server.slicerListedConsole(owner, 1), selected)
        local panels, focus, focusCalls = #client.panels, client.focusedPanel, #client.focusCalls
        local clientPackets, timerEvents = #client.messages, #client.timerEvents
        local savedInfo, records, serial = editable.SlicerInformation, server.returnSpawnedEntities(), server.slicerSetupEditSerial
        local function retained()
            equal(owner.SlicerPendingConsole, selected); equal(other.SlicerPendingConsole, otherSelected)
            equal(#other.chats, otherChats); equal(#client.messages, clientPackets)
            equal(#client.panels, panels); equal(client.focusedPanel, focus); equal(#client.focusCalls, focusCalls)
            equal(#client.timerEvents, timerEvents); equal(hackClient.timers.AccessDelay, login)
            equal(#hackClient.timerEvents, hackTimerEvents); equal(sessions[owner], session)
            equal(session.console, active); equal(session.completeAt, 14); equal(active.SlicerInformation.inUse, true)
            equal(editing.frame.valid, true); equal(setup.frame.valid, true); equal(draft.frame.valid, true)
            equal(editing.name.editable, false); equal(setup.name.editable, false)
            equal(draft.name:GetValue(), "Keep draft"); equal(draft.file:GetValue(), "secret"); equal(draft.file.caret, 3)
            equal(unsaved.SlicerInformation, nil); equal(selected.SlicerDoor, nil)
            equal(server.slicerSetupEditSerial, serial); equal(server.returnSpawnedEntities(), records)
        end
        local function refused()
            local location, marker = server.lastMessage("SlicerConsoleLocation"), client.paint()
            local packets, chats = #server.messages, #owner.chats
            local position = selected.WorldSpaceCenter
            selected.WorldSpaceCenter = function() return nil end
            equal(say(server, owner, "!locateConsole pending"), "")
            selected.WorldSpaceCenter = position
            equal(#server.messages, packets); equal(server.lastMessage("SlicerConsoleLocation"), location)
            equal(#owner.chats, chats + 1); assert(#owner.chats[#owner.chats] <= 240)
            equal(client.paint(), marker, "Refusal must preserve the earlier marker")
            retained()
        end

        server.now = 12; locate(server, client, owner, "pending", selected); retained()
        equal(editable.SlicerInformation, savedInfo); equal(pending.SlicerInformation, nil)
        server.now = 13; refused()
        relay(server, owner, editSave)
        local editReply = assert(server.lastMessage("SlicerSetupEditReply"))
        equal(editReply.player, owner); equal(editReply.values[1], editOpen.values[3]); equal(editReply.values[2].ok, true)
        relay(server, owner, setupSave)
        local setupReply = assert(server.lastMessage("SlicerInitialSetupReply"))
        equal(setupReply.player, owner); equal(setupReply.values[2].ok, true)
        -- Both accepted replies are deliberately held while the pending forms
        -- remain locked, exercising the in-flight acknowledgements themselves.
        server.now = 13.25; locate(server, client, owner, "pending", selected); retained()
        server.now = 13.5; refused()
        deliver(client, editReply); deliver(client, setupReply)
        equal(editing.frame.valid, false); equal(setup.frame.valid, false)
        equal(editable.SlicerInformation.name, "saved edit"); equal(pending.SlicerInformation.name, "saved setup")
        equal(draft.frame.valid, true); equal(draft.name:GetValue(), "Keep draft")
        equal(unsaved.SlicerInformation, nil); equal(owner.SlicerPendingConsole, selected)
        equal(other.SlicerPendingConsole, otherSelected); equal(sessions[owner], session); equal(session.completeAt, 14)

        server.now = 13.999; equal(say(server, owner, "!hackStatus"), "")
        equal(owner.chats[#owner.chats - 1], "Server minimum wait: 1 seconds remaining.")
        hackClient.fireTimer("AccessDelay"); hackClient.command("/a[terminal]/{_data}")
        hackClient.command("/d{_data}/secret.data"); hackClient.fireTimer("DownloadDataFile")
        server.now = 14; relay(server, owner, hackClient.lastMessage("destroyOnServer"))
        equal(active.removed, true, "The original hacking deadline must still accept completion")
        deliver(hackClient, server.lastMessage("SlicerCompleted")); hackClient.assertClosed()
        server.now = 69.999; locate(server, nil, owner, "1", selected)
        server.now = 70
        local packets = #server.messages
        equal(say(server, owner, "!locateConsole 1"), "")
        equal(#server.messages, packets, "Pending location cannot renew the original row lease")
        contains(owner.chats[#owner.chats], "expired")
        equal(owner.SlicerPendingConsole, selected); equal(other.SlicerPendingConsole, otherSelected)
        equal(selected.SlicerDoor, nil); equal(draft.frame.valid, true); equal(draft.name:GetValue(), "Keep draft")
    end)
end
