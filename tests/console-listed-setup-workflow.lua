-- Public server chat to existing Derma receiver, submission and receipt paths.
-- Recorded Entity/String calls and local panels do not certify native GMod.
return function(gmod, test, equal)
    local unpackValues = table.unpack or unpack
    local function deliver(client, packet)
        assert(packet, "Missing real server packet")
        client.receive(packet.name, nil, unpackValues(packet.values))
    end
    local function relay(server, owner, packet)
        assert(packet, "Missing real client packet")
        server.receive(packet.name, owner, unpackValues(packet.values))
    end
    local function count(env, name)
        local result = 0
        for _, packet in ipairs(env.messages) do if packet.name == name then result = result + 1 end end
        return result
    end
    local function form(client, packet)
        local first, result, entries = #client.panels + 1, {}, {}
        deliver(client, packet)
        for i = first, #client.panels do
            local panel = client.panels[i]
            if panel.class == "DFrame" then result.frame = panel
            elseif panel.class == "DTextEntry" then entries[#entries + 1] = panel
            elseif panel.class == "DComboBox" then result.folder = panel
            elseif panel.class == "DLabel" then result.status = panel
            elseif panel.text == "Done" then result.done = panel
            elseif panel.text == "Set up later" then result.close = panel end
        end
        assert(result.frame and result.done and result.close, "The existing initial form must open")
        equal(#entries, 3); result.name, result.delay, result.file = entries[1], entries[2], entries[3]
        return result
    end
    local function fill(fields, folder, name)
        fields.name:SetText(name or "  Listed console  ")
        fields.delay:SetText("2.5"); fields.file:SetText("  NewFile  ")
        fields.folder.selected = folder or "data"
    end
    local function list(server, owner, command) equal(server.fire("PlayerSay", owner, command or "!listConsoles"), "") end
    local function opening(server, owner, console, row)
        local before = #server.messages
        local handled = server.fire("PlayerSay", owner, "!setupConsole " .. (row or "2"))
        -- Missing-command RED control uses a fresh public packet, never the
        -- original automatic spawn packet still present in the fixture.
        equal(#server.messages, before + 1, "Listed command must open the existing initial form")
        equal(handled, "")
        local packet = server.messages[#server.messages]
        equal(packet.name, "PlayerSpawnedConsole"); equal(packet.player, owner)
        equal(#packet.values, 2); equal(packet.values[1], owner); equal(packet.values[2], console:GetName())
        return packet
    end
    local function fixture()
        local server, client = gmod.new(), gmod.client()
        local owner = server.player()
        local sibling, console = server.console(owner), server.console(owner)
        function owner:GetEyeTrace() error("Listed opening must not use the trace") end
        function owner:GetActiveWeapon() error("Listed opening must not use the weapon") end
        list(server, owner)
        return server, client, owner, console, sibling
    end
    local function submit(client, fields)
        local n = count(client, "AdminFinishedCreation")
        fields.done:DoClick()
        equal(count(client, "AdminFinishedCreation"), n + 1)
        local packet = client.lastMessage("AdminFinishedCreation")
        equal(#packet.values, 1); equal(#packet.values[1], 6, "Original correlated scalar fields plus token")
        assert(type(packet.values[1][6]) == "string" and packet.values[1][6] ~= "")
        return packet
    end
    local function locked(fields)
        equal(fields.frame.valid, true); equal(fields.name.editable, false)
        equal(fields.delay.editable, false); equal(fields.file.editable, false); equal(fields.folder.enabled, false)
        equal(fields.close.text, "Close"); equal(fields.done.text, "Check setup result")
    end
    local function check(server, client, owner, fields)
        fields.done:DoClick()
        local request = assert(client.lastMessage("SlicerInitialSetupStatusRequest"))
        relay(server, owner, request)
        return server.lastMessage("SlicerInitialSetupStatusReply")
    end

    for _, folder in ipairs({"data", "server", "tools"}) do
        test("listed " .. folder .. " setup uses real form and correlated save after page expiry", function()
            local server, client, owner, console, sibling = fixture()
            local fields = form(client, opening(server, owner, console)); fill(fields, folder)
            equal(console.SlicerInformation, nil); equal(#server.returnSpawnedEntities(), 0)
            server.now = 60 -- An open form is not authorized by its later page lease.
            local request = submit(client, fields); locked(fields)
            equal(request.values[1][5], console:GetName())
            relay(server, owner, request)
            local reply = server.lastMessage("SlicerInitialSetupReply")
            equal(reply.player, owner); equal(reply.values[1], request.values[1][6]); equal(reply.values[2].ok, true)
            equal(console.SlicerInformation.name, "listed console"); equal(console.SlicerInformation.delay, 2.5)
            equal(console.SlicerInformation.fileName, "newfile"); equal(console.SlicerInformation.fileType, folder)
            equal(sibling.SlicerInformation, nil); equal(#server.returnSpawnedEntities(), 1)
            equal(owner.SlicerPendingConsole, folder == "tools" and console or nil)
            deliver(client, reply); equal(fields.frame.valid, false)
            equal(count(client, "AdminFinishedCreation"), 1)
        end)
    end
    test("listed and physical repeated openings retain the same focused draft", function()
        local server, client, owner, console = fixture()
        local fields = form(client, opening(server, owner, console)); fill(fields, "server", "Draft")
        fields.file:RequestFocus(); fields.file:SetCaretPos(4)
        local panels = #client.panels
        deliver(client, opening(server, owner, console))
        equal(#client.panels, panels); equal(client.focusedPanel, fields.frame)
        equal(fields.file.caret, 4, "Raising the existing form retains its focused draft and caret")
        equal(fields.name:GetValue(), "Draft"); equal(fields.file:GetValue(), "  NewFile  ")
        server.open(owner, console); deliver(client, server.lastMessage("PlayerSpawnedConsole"))
        equal(#client.panels, panels); equal(client.focusedPanel, fields.frame); equal(fields.delay:GetValue(), "2.5")
        equal(count(client, "AdminFinishedCreation"), 0)
    end)
    test("independent listed targets keep independent forms and dismissed reopening starts blank", function()
        local server, client, owner, console, sibling = fixture()
        local selected = form(client, opening(server, owner, console)); fill(selected, "data", "Selected draft")
        local first = form(client, opening(server, owner, sibling, 1)); fill(first, "tools", "Sibling draft")
        selected.close:DoClick(); equal(selected.frame.valid, false); equal(first.frame.valid, true)
        local fresh = form(client, opening(server, owner, console))
        equal(fresh.name:GetValue(), ""); equal(fresh.delay:GetValue(), ""); equal(fresh.file:GetValue(), "")
        equal(fresh.folder.selected, nil); equal(first.name:GetValue(), "Sibling draft")
    end)
    test("pending listed and physical reopenings preserve frozen request without setup replay", function()
        local server, client, owner, console = fixture()
        local fields = form(client, opening(server, owner, console)); fill(fields)
        local request = submit(client, fields); locked(fields)
        local original, token, panels = request.values[1], request.values[1][6], #client.panels
        deliver(client, opening(server, owner, console)); server.open(owner, console)
        deliver(client, server.lastMessage("PlayerSpawnedConsole")); locked(fields)
        equal(#client.panels, panels); equal(count(client, "AdminFinishedCreation"), 1)
        equal(client.lastMessage("AdminFinishedCreation").values[1][6], token)
        fields.name:SetText("Attempted local change")
        local status = check(server, client, owner, fields)
        equal(status.values[2].confirmed, false); deliver(client, status); locked(fields)
        equal(client.lastMessage("SlicerInitialSetupStatusRequest").values[1][1], original[1])
        equal(count(client, "AdminFinishedCreation"), 1)
        relay(server, owner, request); deliver(client, server.lastMessage("SlicerInitialSetupReply"))
        equal(fields.frame.valid, false); equal(console.SlicerInformation.name, "listed console")
    end)
    for _, change in ipairs({"owner", "remove", "intervening setup"}) do
        test("existing save admission rejects listed draft after " .. change, function()
            local server, client, owner, console = fixture()
            local fields = form(client, opening(server, owner, console)); fill(fields)
            local request = submit(client, fields)
            if change == "owner" then console.SlicerCreator = server.player()
            elseif change == "remove" then console:Remove()
            else server.configure(owner, console, "server") end
            relay(server, owner, request)
            local reply = server.lastMessage("SlicerInitialSetupReply"); equal(reply.values[2].ok, false)
            deliver(client, reply); equal(fields.frame.valid, true); equal(fields.name.editable, true)
            equal(fields.name:GetValue(), "  Listed console  "); equal(fields.file:GetValue(), "  NewFile  ")
            equal(fields.done.text, "Done")
        end)
    end
    test("legacy five-field save remains admitted after a listed opening", function()
        local server, client, owner, console = fixture()
        local fields = form(client, opening(server, owner, console)); fill(fields, "tools")
        local request = submit(client, fields); request.values[1][6] = nil
        relay(server, owner, request)
        equal(console.SlicerInformation.fileType, "tools"); equal(owner.SlicerPendingConsole, console)
        equal(count(server, "SlicerInitialSetupReply"), 0, "Tokenless legacy setup remains tokenless")
        locked(fields)
        local result = check(server, client, owner, fields)
        equal(result.values[2].confirmed, false); deliver(client, result); locked(fields)
        equal(count(client, "AdminFinishedCreation"), 1)
    end)
    for _, folder in ipairs({"data", "server", "tools"}) do
        test("accepted pending " .. folder .. " setup refuses reopening and recovers its original receipt", function()
            local server, client, owner, console = fixture()
            local fields = form(client, opening(server, owner, console)); fill(fields, folder)
            local request = submit(client, fields); relay(server, owner, request)
            local accepted = server.lastMessage("SlicerInitialSetupReply"); equal(accepted.values[2].ok, true)
            -- Lose the genuine acceptance reply. No delivered synthetic acceptance.
            local before, panels = #server.messages, #client.panels
            equal(server.fire("PlayerSay", owner, "!setupConsole 2"), "")
            equal(#server.messages, before); equal(#client.panels, panels); locked(fields)
            local info, pending = console.SlicerInformation, owner.SlicerPendingConsole
            local status = check(server, client, owner, fields); equal(status.values[2].confirmed, true)
            equal(status.values[1], request.values[1][6]); deliver(client, status)
            equal(fields.frame.valid, false); equal(console.SlicerInformation, info); equal(owner.SlicerPendingConsole, pending)
            equal(count(client, "AdminFinishedCreation"), 1)
            deliver(client, accepted); equal(fields.frame.valid, false)
        end)
    end
    test("reordered replies close only the matching listed initial form", function()
        local server, client, owner, console, sibling = fixture()
        local second = form(client, opening(server, owner, console)); fill(second, "data", "Second")
        local first = form(client, opening(server, owner, sibling, 1)); fill(first, "server", "First")
        local secondRequest, firstRequest = submit(client, second), submit(client, first)
        relay(server, owner, secondRequest); local secondReply = server.lastMessage("SlicerInitialSetupReply")
        relay(server, owner, firstRequest); local firstReply = server.lastMessage("SlicerInitialSetupReply")
        deliver(client, firstReply); equal(first.frame.valid, false); locked(second)
        deliver(client, firstReply); locked(second)
        deliver(client, secondReply); equal(second.frame.valid, false)
        equal(count(client, "AdminFinishedCreation"), 2)
    end)
    test("opening preserves pending door choice editor receipt marker and unrelated hack deadline", function()
        local support = dofile("tests/console-locator-support.lua")(gmod)
        local server, client = support.server(), support.client()
        local owner, other = server.player(), server.player()
        local configured = server.console(owner); server.configure(owner, configured, "data", 2)
        local pending = server.console(owner); server.configure(owner, pending, "tools")
        local selected = server.console(owner)
        -- Obtain a real receipt and editor for a distinct accepted console.
        local receiptConsole = server.console(owner)
        local receiptForm = form(client, server.lastMessage("PlayerSpawnedConsole")); fill(receiptForm)
        local request = submit(client, receiptForm); relay(server, owner, request)
        owner.target = receiptConsole; equal(server.fire("PlayerSay", owner, "!editConsole"), "")
        local editor = server.lastMessage("SlicerSetupEditOpen")
        owner.target = pending; equal(server.fire("PlayerSay", owner, "!setEntity"), "")
        server.open(owner, configured)
        local hacked = server.lastMessage("ServerSendsEntityInformation"); deliver(client, hacked)
        client.command("/a[terminal]"); local timer = client.timers.AccessDelay
        list(server, owner); equal(server.fire("PlayerSay", owner, "!locateConsole 3"), "")
        support.deliver(client, server.lastMessage("SlicerConsoleLocation")); local marker = client.paint()
        local registry, pendingChoice, serial = server.returnSpawnedEntities(), owner.SlicerPendingConsole, server.slicerSetupEditSerial
        local chats, panelCount = #other.chats, #client.panels
        local weapon = owner.GetActiveWeapon
        function owner:GetEyeTrace() error("No trace during opening") end
        function owner:GetActiveWeapon() error("No weapon during opening") end
        local opened = opening(server, owner, selected, 3)
        equal(selected.SlicerInformation, nil); equal(server.returnSpawnedEntities(), registry)
        equal(owner.SlicerPendingConsole, pendingChoice); equal(pendingChoice, pending)
        equal(server.slicerSetupEditSerial, serial); equal(client.timers.AccessDelay, timer)
        equal(client.paint(), marker); equal(#client.panels, panelCount); equal(#other.chats, chats)
        equal(#configured.inputs, 0); equal(#pending.inputs, 0); equal(#selected.inputs, 0)
        equal(check(server, client, owner, receiptForm).values[2].confirmed, true)
        server.receive("SlicerSetupEditSave", owner, receiptConsole, editor.values[3], {name = "Updated", delay = 3, fileName = "New"})
        equal(server.lastMessage("SlicerSetupEditReply").values[2].ok, true)
        local door = server.entity("func_door"); owner.target = door
        function owner:GetEyeTrace() return {Entity = self.target} end
        equal(server.fire("PlayerSay", owner, "!setEntity"), ""); equal(pending.SlicerDoor, door)
        equal(server.fire("PlayerUse", other, door), false); equal(door.inputs[1], "Lock")
        owner.GetActiveWeapon = weapon
        client.fireTimer("AccessDelay"); client.command("/a[terminal]/{_data}")
        client.command("/d{_data}/secret.data"); client.fireTimer("DownloadDataFile")
        server.now = 4; relay(server, owner, client.lastMessage("destroyOnServer")); equal(configured.removed, true)
        equal(selected.SlicerInformation, nil); equal(#door.inputs, 1)
        deliver(client, opened); equal(count(client, "AdminFinishedCreation"), 1)
    end)
end
