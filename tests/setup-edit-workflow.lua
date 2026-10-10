-- Actual setup/chat/network/UI callbacks, with explicit packet relay between
-- isolated server/client doubles. No private editor/session fields are read.
-- Native Derma rendering/focus, packet ordering, player timing, duplication
-- dispatch and door-engine behavior still require a Garry's Mod game test.
return function(gmod, test, equal)
    local unpackValues = table.unpack or unpack
    local kinds = {
        {folder = "data", extension = "data", timer = "DownloadDataFile", complete = "destroyOnServer"},
        {folder = "server", extension = "sys", timer = "DownloadServerFile", complete = "destroyOnServer"},
        {folder = "tools", extension = "exe", complete = "PlayerActivatedDoor"},
    }
    local function deliver(client, packet)
        assert(packet, "Missing server packet")
        client.receive(packet.name, nil, unpackValues(packet.values))
    end
    local function relay(server, owner, packet)
        assert(packet, "Missing client packet")
        server.receive(packet.name, owner, unpackValues(packet.values))
    end
    local function live(panel)
        while panel do
            if not panel.valid or panel:IsMarkedForDeletion() or not panel:IsVisible() then return false end
            panel = panel.parent
        end
        return true
    end
    local function formSince(client, first, editing)
        local form, entries = {}, {}
        for index = first, #client.panels do
            local panel = client.panels[index]
            if panel.class == "DFrame" then form.frame = panel
            elseif panel.class == "DTextEntry" then entries[#entries + 1] = panel
            elseif panel.class == "DComboBox" then form.folder = panel
            elseif panel.class == "DButton" and panel.text == "Done" then form.done = panel
            elseif panel.class == "DButton" and panel.text == "Save changes" then form.save = panel
            elseif panel.class == "DButton" and panel.text == "Cancel" then form.cancel = panel end
        end
        assert(form.frame, "Expected a new " .. (editing and "edit" or "setup") .. " form")
        equal(#entries, 3, "The form exposes name, delay and filename")
        form.name, form.delay, form.file = entries[1], entries[2], entries[3]
        if editing then
            assert(form.save, "Editor needs a Save action")
            assert(form.cancel, "Editor needs a Cancel action")
            assert(not form.folder or form.folder.enabled == false, "Saved folder must not be editable")
        end
        function form:fill(name, delay, file)
            self.name:SetText(name or "  Renamed Console  ")
            self.delay:SetText(delay or "3.75")
            self.file:SetText(file or "  ConsoleLogs  ")
        end
        return form
    end
    local function fixture(folder, initialDelay)
        local server, client = gmod.new(), gmod.client()
        local owner, hacker = server.player(), server.player()
        local console = server.console(owner)
        local first = #client.panels + 1
        deliver(client, server.lastMessage("PlayerSpawnedConsole"))
        local setup = formSince(client, first)
        setup:fill("  Terminal  ", initialDelay or "2", "  Secret  ")
        setup.folder.selected = folder or "data"
        setup.done:DoClick()
        equal(setup.frame.valid, true, "Initial setup remains pending until its reply")
        local submitted = assert(client.lastMessage("AdminFinishedCreation"))
        local before = #server.messages
        relay(server, owner, submitted)
        equal(#server.messages, before + 1)
        local reply = assert(server.lastMessage("SlicerInitialSetupReply"))
        equal(reply.player, owner); equal(reply.values[1], submitted.values[1][6])
        equal(reply.values[2].ok, true)
        deliver(client, reply)
        equal(setup.frame.valid, false, "Initial setup closes only on matching acceptance")
        equal(console.SlicerInformation.name, "terminal")
        equal(console.SlicerInformation.fileName, "secret")
        equal(console.SlicerInformation.delay, tonumber(initialDelay or "2"))
        local door
        if folder == "tools" then
            door = server.entity("func_door_rotating")
            owner.target = door
            server.fire("PlayerSay", owner, "!setEntity")
            equal(console.SlicerDoor, door)
            equal(door.inputs[#door.inputs], "Lock")
        end
        return {server = server, client = client, owner = owner, hacker = hacker,
            console = console, door = door, folder = folder or "data"}
    end
    local function openPacket(session, console, owner)
        local server = session.server
        console, owner = console or session.console, owner or session.owner
        owner.target = console
        local before = #server.messages
        server.fire("PlayerSay", owner, "!editConsole")
        local packet = server.lastMessage("SlicerSetupEditOpen")
        assert(packet and #server.messages > before, "!editConsole must open the creator's saved configuration")
        equal(packet.player, owner, "Only the requesting creator receives the editor")
        equal(#packet.values, 4, "Edit-open transport shape")
        equal(packet.values[1], console); equal(packet.values[2], owner)
        assert(type(packet.values[3]) == "string" and packet.values[3] ~= "", "Editor needs a server ticket")
        equal(type(packet.values[4]), "table")
        return packet
    end
    local function edit(session, console, owner)
        local packet = openPacket(session, console, owner)
        local first = #session.client.panels + 1
        deliver(session.client, packet)
        local form = formSince(session.client, first, true)
        form.packet, form.token = packet, packet.values[3]
        return form
    end
    local function registered(server, console)
        local count, found = 0
        for _, entry in ipairs(server.returnSpawnedEntities()) do
            if entry.entity == console then count, found = count + 1, entry end
        end
        equal(count, 1, "Each configured console has exactly one registry record")
        equal(found.entityName, console:GetName())
        equal(found.information, console.SlicerInformation, "Registry must refer to the current configuration")
        return found
    end
    local function assertInfo(console, name, delay, file, folder, busy)
        local info = assert(console.SlicerInformation)
        equal(info.name, name); equal(info.delay, delay); equal(info.fileName, file)
        equal(info.fileType, folder); equal(info.inUse, busy or false)
        local allowed = {name = true, delay = true, fileType = true, fileName = true, inUse = true}
        for key in pairs(info) do assert(allowed[key], "Unexpected configuration field: " .. tostring(key)) end
    end
    local function reply(session, token, accepted, previousCount)
        local packet = assert(session.server.lastMessage("SlicerSetupEditReply"), "Server must acknowledge every editor save")
        if previousCount then assert(#session.server.messages > previousCount, "Expected a fresh edit reply") end
        equal(packet.player, session.owner); equal(#packet.values, 2)
        equal(packet.values[1], token); equal(packet.values[2].ok, accepted)
        if not accepted then
            assert(type(packet.values[2].message) == "string" and packet.values[2].message ~= "", "Rejected saves need an explanation")
        end
        return packet
    end
    local function submit(session, form)
        local before = #session.client.messages
        form.save:DoClick()
        equal(#session.client.messages, before + 1, "One Save sends one edit request")
        equal(live(form.frame), true, "Save stays open until its server reply")
        local packet = assert(session.client.lastMessage("SlicerSetupEditSave"))
        equal(#packet.values, 3); equal(packet.values[1], form.packet.values[1])
        equal(packet.values[2], form.token)
        local fields, allowed = 0, {name = true, delay = true, fileName = true}
        for key in pairs(packet.values[3]) do assert(allowed[key], "Save must only submit editable fields"); fields = fields + 1 end
        equal(fields, 3)
        return packet
    end
    local function save(session, form)
        local packet, count = submit(session, form), #session.server.messages
        relay(session.server, session.owner, packet)
        local accepted = reply(session, form.token, true, count)
        equal(live(form.frame), true, "Server acceptance cannot close a client without delivery")
        deliver(session.client, accepted)
        equal(live(form.frame), false, "Matching successful reply closes the editor")
        return accepted
    end
    local function activeEntry(client)
        for index = #client.panels, 1, -1 do
            local panel = client.panels[index]
            if live(panel) and panel.OnEnter then return panel end
        end
        error("Missing active hacking input")
    end
    local function help(client)
        activeEntry(client).ShowCommandHelp()
        local commands = {}
        for _, panel in ipairs(client.panels) do
            if live(panel) and panel.class == "DScrollPanel" then
                local command
                for _, child in ipairs(panel.children) do
                    if child.class == "DLabel" then command = child:GetValue():match("^([^\n]+)\n") end
                    if child.class == "DButton" and child.text == "Insert command" then commands[assert(command)] = child end
                end
            end
        end
        return commands
    end
    local function hack(session, kind, name, file, delay)
        local server, client = session.server, session.client
        local started = server.now
        server.open(session.hacker, session.console)
        local packet = assert(server.lastMessage("ServerSendsEntityInformation"))
        equal(packet.values[1], session.console)
        equal(packet.values[3].name, name); equal(packet.values[3].fileName, file)
        equal(packet.values[3].delay, delay); equal(packet.values[3].inUse, false)
        deliver(client, packet)
        client.command("/a[terminal]")
        equal(client.timers.AccessDelay, nil, "Old console name no longer logs in")
        local access = "/a[" .. name .. "]"
        local input = activeEntry(client)
        assert(help(client)[access], "Login help uses the edited name"):DoClick()
        equal(input:GetValue(), access)
        input:OnEnter()
        equal(client.timers.AccessDelay.delay, delay)
        client.fireTimer("AccessDelay")
        server.now = started + delay
        local enter = access .. "/{_" .. kind.folder .. "}"
        assert(help(client)[enter], "Folder help uses the edited name")
        client.command(enter)
        local rows = {}
        for _, child in ipairs(activeEntry(client).parent.children) do
            if child.class == "DTextEntry" and not child.OnEnter then rows[#rows + 1] = child end
        end
        equal(#rows, 3)
        equal(rows[1]:GetValue(), string.upper(file) .. "." .. kind.extension)
        local seen = {}
        for _, row in ipairs(rows) do
            local base = string.lower(assert(row:GetValue():match("^(.+)%.")))
            assert(not seen[base], "Edited filename must not duplicate a listing decoy")
            seen[base] = true
            equal(row.editable, false)
        end
        local back = "//[" .. name .. "]/{_" .. kind.folder .. "}"
        assert(help(client)[back], "Return help uses the edited name")
        client.command(back); client.command(enter)
        local action = (kind.timer and "/d" or "/r") .. "{_" .. kind.folder .. "}/" .. file .. "." .. kind.extension
        input = activeEntry(client)
        assert(help(client)[action], "Action help uses the edited filename"):DoClick()
        equal(input:GetValue(), action)
        if session.door then
            equal(session.door.inputs[#session.door.inputs], "Lock")
            equal(server.fire("PlayerUse", session.hacker, session.door), false)
        end
        input:OnEnter()
        if kind.timer then
            equal(client.timers[kind.timer].delay, delay)
            client.fireTimer(kind.timer)
            server.now = started + delay * 2
        end
        local complete = assert(client.lastMessage(kind.complete))
        relay(server, session.hacker, complete)
        equal(session.console.removed, true, "Edited console must legitimately complete")
        local accepted = assert(server.lastMessage("SlicerCompleted"))
        equal(accepted.player, session.hacker)
        equal(accepted.values[1], name); equal(accepted.values[2], file); equal(accepted.values[3], kind.folder)
        if session.door then equal(session.door.inputs[#session.door.inputs], "Unlock") end
        deliver(client, accepted)
        equal(#client.chatMessages, 1)
        client.assertClosed()
    end

    for _, kind in ipairs(kinds) do
        test(kind.folder .. " complete creator setup, acknowledged edit and fresh hacking workflow", function()
            local session = fixture(kind.folder)
            local server, client, owner, console = session.server, session.client, session.owner, session.console
            local identity = console:GetName()
            local pending = server.console(owner); server.configure(owner, pending, "tools")
            local outsider = server.player()
            local other = server.console(outsider); server.configure(outsider, other, "server")
            server.open(outsider, other)
            local otherInfo, count = other.SlicerInformation, #server.returnSpawnedEntities()
            owner.weapon = nil -- Explicit creator editing does not require the hacking tool.
            local form = edit(session)
            equal(form.name:GetValue(), "terminal"); equal(tonumber(form.delay:GetValue()), 2)
            equal(form.file:GetValue(), "secret")
            equal(form.packet.values[4].fileType, kind.folder)
            equal(console.SlicerInformation.inUse, false)
            form:fill()
            save(session, form)
            assertInfo(console, "renamed console", 3.75, "consolelogs", kind.folder)
            equal(console:GetName(), identity); equal(console.SlicerCreator, owner)
            equal(console.SlicerDoor, session.door); equal(owner.SlicerPendingConsole, pending)
            equal(#server.returnSpawnedEntities(), count); registered(server, console)
            equal(other.SlicerInformation, otherInfo); equal(otherInfo.inUse, true)
            local current = console.SlicerInformation
            server.receive("AdminFinishedCreation", owner, {"Forged", 8, "data", "Changed", identity})
            server.receive("AdminFinishedCreation", outsider, {"Forged", 8, "data", "Changed", identity})
            equal(console.SlicerInformation, current, "Initial setup remains first-write-only")
            local cancelled = edit(session); cancelled:fill("Cancelled", "99", "Unwanted")
            cancelled.cancel:DoClick()
            relay(server, owner, client.lastMessage("SlicerSetupEditCancel"))
            equal(live(cancelled.frame), false); equal(console.SlicerInformation, current)
            equal(console.SlicerDoor, session.door); equal(owner.SlicerPendingConsole, pending)
            equal(other.SlicerInformation, otherInfo); equal(otherInfo.inUse, true)
            if session.door then equal(#session.door.inputs, 1) end
            hack(session, kind, "renamed console", "consolelogs", 3.75)
            equal(owner.SlicerPendingConsole, pending)
            equal(otherInfo.inUse, true, "Edited console completion must not release another actor")
            equal(other.removed, nil); registered(server, other)
        end)
    end

    test("repeating the current edit request keeps the same ticket, draft and frame", function()
        local session = fixture()
        local form = edit(session)
        form:fill("Draft Name", "2.", "Draft File")
        local panels, popup = #session.client.panels, form.frame.popupCalls
        local packet = openPacket(session)
        equal(packet.values[3], form.token, "Unchanged server state reuses its active ticket")
        deliver(session.client, packet)
        equal(#session.client.panels, panels); equal(form.frame.popupCalls, popup + 1)
        equal(form.name:GetValue(), "Draft Name"); equal(form.delay:GetValue(), "2.")
        equal(form.file:GetValue(), "Draft File")
        save(session, form)
        assertInfo(session.console, "draft name", 2, "draft file", "data")
    end)

    test("name-only edit preserves the exact nontrivial fractional saved delay", function()
        local session = fixture("data", "0.12345678901234567")
        local original = session.console.SlicerInformation.delay
        local form = edit(session)
        form.name:SetText("Name Only")
        save(session, form)
        local current = session.console.SlicerInformation
        equal(current.name, "name only"); equal(current.fileName, "secret")
        assert(current.delay == original,
            string.format("Name-only Save changed the exact delay from %.17g to %.17g", original, current.delay))
        equal(tonumber(form.packet.values[4].delay), original)
        registered(session.server, session.console)
    end)

    for _, invalid in ipairs({
        {label = "blank name", name = "   "}, {label = "blank filename", fileName = "\t"},
        {label = "129-byte name", name = string.rep("N", 129)},
        {label = "overlong multibyte filename", fileName = string.rep("é", 65)},
        {label = "zero delay", delay = 0}, {label = "negative delay", delay = -1},
        {label = "NaN delay", delay = 0 / 0}, {label = "positive infinite delay", delay = math.huge},
        {label = "negative infinite delay", delay = -math.huge},
        {label = "string delay", delay = "3"}, {label = "table name", name = {}},
        {label = "boolean filename", fileName = false},
    }) do
        test("server rejects " .. invalid.label .. " and retry preserves the editor draft", function()
            local session = fixture()
            local form = edit(session); form:fill("Retained Draft", "6.25", "Retained File")
            local packet = submit(session, form)
            for key, value in pairs(invalid) do if key ~= "label" then packet.values[3][key] = value end end
            local before, current = #session.server.messages, session.console.SlicerInformation
            relay(session.server, session.owner, packet)
            local rejection = reply(session, form.token, false, before)
            equal(session.console.SlicerInformation, current)
            local chats = #session.owner.chats
            deliver(session.client, rejection)
            equal(live(form.frame), true)
            equal(form.name:GetValue(), "Retained Draft"); equal(form.delay:GetValue(), "6.25")
            equal(form.file:GetValue(), "Retained File")
            local explained = #session.owner.chats > chats
            for _, panel in ipairs(session.client.panels) do
                if live(panel) and panel.text == rejection.values[2].message then explained = true end
            end
            assert(explained, "Server rejection explanation must be visible to the creator")
            save(session, form)
            assertInfo(session.console, "retained draft", 6.25, "retained file", "data")
            registered(session.server, session.console)
        end)
    end

    for _, invalid in ipairs({"", "0", "-2", "not a number", "1e999"}) do
        test("client keeps an invalid delay draft: " .. invalid, function()
            local session = fixture()
            local form = edit(session); form:fill("Draft", invalid, "File")
            local messages, chats = #session.client.messages, #session.owner.chats
            form.save:DoClick()
            equal(#session.client.messages, messages, "Locally invalid fields never submit")
            equal(live(form.frame), true); equal(form.delay:GetValue(), invalid)
            local explained = #session.owner.chats > chats
            for _, panel in ipairs(session.client.panels) do
                if live(panel) and panel.class == "DLabel" and panel.text:lower():find("invalid", 1, true) then explained = true end
            end
            assert(explained, "Invalid field needs an explanation")
            form.delay:SetText("0.0001"); save(session, form)
            assertInfo(session.console, "draft", 0.0001, "file", "data")
        end)
    end

    for _, values in ipairs({
        {name = string.rep("A", 128), file = string.rep("B", 128), delay = "1000000000"},
        {name = "  CAFÉ 東京  ", file = "  Étude MiXeD  ", delay = "0.125"},
        {name = string.rep("é", 64), file = string.rep("中", 42) .. "AB", delay = "2.5"},
    }) do
        test("edit preserves existing normalization for " .. #values.name .. " byte names and " .. #values.file .. " byte filenames", function()
            local session = fixture()
            local form = edit(session); form:fill(values.name, values.delay, values.file)
            save(session, form)
            assertInfo(session.console, string.lower(session.server.string.Trim(values.name)), tonumber(values.delay),
                string.lower(session.server.string.Trim(values.file)), "data")
            registered(session.server, session.console)
        end)
    end

    test("an edit ticket authenticates both sender and exact console", function()
        local session = fixture()
        local form = edit(session); form:fill()
        local outsider = session.server.player()
        local other = session.server.console(session.owner); session.server.configure(session.owner, other, "server")
        local packet = submit(session, form)
        local original, otherInfo = session.console.SlicerInformation, other.SlicerInformation
        relay(session.server, outsider, packet)
        equal(session.console.SlicerInformation, original)
        local stolen = {name = packet.name, values = {other, form.token, packet.values[3]}}
        relay(session.server, session.owner, stolen)
        equal(other.SlicerInformation, otherInfo); equal(session.console.SlicerInformation, original)
        session.server.receive("SlicerSetupEditCancel", outsider, session.console, form.token)
        session.server.receive("SlicerSetupEditCancel", session.owner, other, form.token)
        relay(session.server, session.owner, packet)
        deliver(session.client, reply(session, form.token, true))
        assertInfo(session.console, "renamed console", 3.75, "consolelogs", "data")
        equal(other.SlicerInformation, otherInfo); registered(session.server, other)
    end)

    test("a ticket cannot overwrite configuration changed since the form opened", function()
        local session = fixture()
        local form = edit(session); form:fill("Outdated Draft", "8", "Outdated File")
        local packet = submit(session, form)
        -- Existing addons can change this public record in place. This keeps
        -- its identity and registry link, exercising the saved-value binding.
        session.console.SlicerInformation.fileName = "newer saved file"
        relay(session.server, session.owner, packet)
        deliver(session.client, reply(session, form.token, false))
        assertInfo(session.console, "terminal", 2, "newer saved file", "data")
        equal(live(form.frame), true); equal(form.file:GetValue(), "Outdated File")
        registered(session.server, session.console)
        local fresh = edit(session)
        assert(fresh.token ~= form.token)
        equal(fresh.file:GetValue(), "newer saved file")
        fresh:fill("Current Draft", "9", "Current File")
        save(session, fresh)
        relay(session.server, session.owner, packet)
        reply(session, form.token, false)
        assertInfo(session.console, "current draft", 9, "current file", "data")
    end)

    for _, event in ipairs({"intervening hack", "hack ended before the first edit save", "completed hack", "death", "disconnect", "removal", "duplication reset"}) do
        test("saved edit cannot survive " .. event, function()
            local session = fixture()
            local form = edit(session); form:fill()
            local packet = submit(session, form)
            local server, console, owner = session.server, session.console, session.owner
            if event == "intervening hack" or event == "completed hack" or event == "hack ended before the first edit save" then
                server.open(session.hacker, console)
                if event == "completed hack" then server.now = 4; server.receive("destroyOnServer", session.hacker, console) end
                if event == "hack ended before the first edit save" then server.receive("playerQuitConsole", session.hacker) end
            elseif event == "death" then owner.alive = false; server.fire("PlayerDeath", owner); owner.alive = true
            elseif event == "disconnect" then server.fire("PlayerDisconnected", owner)
            elseif event == "removal" then console:Remove()
            else console:OnDuplicated(); console:PostEntityPaste(owner, console, {}) end
            local current, before = console.SlicerInformation, #server.messages
            relay(server, owner, packet)
            deliver(session.client, reply(session, form.token, false, before))
            equal(console.SlicerInformation, current)
            equal(current.name, "terminal"); equal(current.delay, 2)
            equal(form.name:GetValue(), "  Renamed Console  ")
            equal(live(form.frame), true, "Rejected stale save retains the draft for review")
            if event == "intervening hack" then
                equal(current.inUse, true)
                server.receive("playerQuitConsole", session.hacker)
                before = #server.messages
                relay(server, owner, packet)
                reply(session, form.token, false, before)
                equal(current.inUse, false, "Ending the hack cannot restore an old editor ticket")
            end
        end)
    end

    for _, retirement in ipairs({"cancel", "close", "remove", "hide", "success"}) do
        test("deferred " .. retirement .. " and stale replies cannot affect a replacement editor", function()
            local session = fixture()
            local server, client = session.server, session.client
            local old = edit(session); old:fill("Old Draft", "3", "Old File")
            local oldSave, oldCancel = old.save.DoClick, old.cancel.DoClick
            client.deferPanelRemoval = true
            local oldReply
            if retirement == "success" then oldReply = save(session, old)
            elseif retirement == "cancel" then old.cancel:DoClick()
            elseif retirement == "close" then old.frame:Close()
            elseif retirement == "remove" then old.frame:Remove()
            else old.frame:Hide() end
            -- Cancel using the public ticket even if native OnRemove is deferred.
            server.receive("SlicerSetupEditCancel", session.owner, session.console, old.token)
            local fresh = edit(session)
            assert(fresh.token ~= old.token, "Retired tickets must not be reused")
            fresh:fill("New Draft", "4.5", "New File")
            local count = #client.messages
            oldSave(); oldCancel()
            if old.frame.OnClose then old.frame:OnClose() end
            if old.frame.OnRemove then old.frame:OnRemove() end
            equal(#client.messages, count, "Retired callbacks cannot send against a replacement")
            server.receive("SlicerSetupEditCancel", session.owner, session.console, old.token)
            deliver(client, oldReply or {name = "SlicerSetupEditReply", values = {old.token, {ok = true, message = "Saved"}}})
            deliver(client, {name = "SlicerSetupEditReply", values = {old.token, {ok = false, message = "Old rejection"}}})
            equal(live(fresh.frame), true); equal(fresh.name:GetValue(), "New Draft")
            local panels = #client.panels
            deliver(client, fresh.packet)
            equal(#client.panels, panels, "Late cleanup must not remove the replacement's ownership")
            save(session, fresh)
            assertInfo(session.console, "new draft", 4.5, "new file", "data")
        end)
    end

    test("a successful reply for an unsent editor cannot close its draft", function()
        local session = fixture()
        local form = edit(session); form:fill("Unsaved", "5", "Draft")
        deliver(session.client, {name = "SlicerSetupEditReply", values = {form.token, {ok = true, message = "Unexpected"}}})
        equal(live(form.frame), true, "Acknowledgement must match an outstanding Save")
        equal(form.name:GetValue(), "Unsaved")
        save(session, form)
    end)

    for _, order in ipairs({"Cancel before Save", "Save before Cancel"}) do
        test("closing pending editor with " .. order .. " preserves actual server commit order", function()
            local session = fixture()
            local server, client = session.server, session.client
            local old = edit(session); old:fill("First Saved", "3", "First File")
            local request = submit(session, old)
            client.deferPanelRemoval = true
            old.cancel:DoClick()
            local cancel = assert(client.lastMessage("SlicerSetupEditCancel"))
            equal(cancel.values[1], session.console); equal(cancel.values[2], old.token)
            equal(live(old.frame), false)
            local accepted = order == "Save before Cancel"
            if accepted then
                relay(server, session.owner, request)
                relay(server, session.owner, cancel)
            else
                relay(server, session.owner, cancel)
                relay(server, session.owner, request)
            end
            local oldReply = reply(session, old.token, accepted)
            assertInfo(session.console, accepted and "first saved" or "terminal", accepted and 3 or 2,
                accepted and "first file" or "secret", "data")
            -- A new pending editor must survive either late result. Closing
            -- the earlier window never rolls back an already accepted write.
            local fresh = edit(session)
            equal(fresh.name:GetValue(), accepted and "first saved" or "terminal")
            fresh:fill("Second Saved", "5", "Second File")
            local nextRequest = submit(session, fresh)
            deliver(client, oldReply)
            equal(live(old.frame), false); equal(live(fresh.frame), true)
            equal(fresh.name:GetValue(), "Second Saved")
            relay(server, session.owner, cancel)
            relay(server, session.owner, nextRequest)
            deliver(client, reply(session, fresh.token, true))
            equal(live(fresh.frame), false)
            assertInfo(session.console, "second saved", 5, "second file", "data")
            registered(server, session.console)
        end)
    end

    test("a cleared inUse flag cannot hide an existing hack from editor authorization", function()
        local session = fixture()
        local form = edit(session); form:fill()
        local packet = submit(session, form)
        local server, console = session.server, session.console
        server.open(session.hacker, console)
        server.updateInUse(console:GetName(), false)
        equal(console.SlicerInformation.inUse, false, "Exercise the legacy flag change")
        local before = #server.messages
        session.owner.target = console
        server.fire("PlayerSay", session.owner, "!editConsole")
        equal(#server.messages, before, "A real reservation blocks opening even with a cleared flag")
        relay(server, session.owner, packet)
        deliver(session.client, reply(session, form.token, false))
        assertInfo(console, "terminal", 2, "secret", "data")
        equal(live(form.frame), true)
        server.now = 4
        server.receive("destroyOnServer", session.hacker, console)
        equal(console.removed, true, "Rejected editor traffic must preserve the authenticated hack")
        equal(server.lastMessage("SlicerCompleted").player, session.hacker)
    end)

    for _, kind in ipairs(kinds) do
    test("editing a pasted " .. kind.folder .. " console preserves its source, sibling and registry count", function()
        local session = fixture(kind.folder)
        local server, owner, original = session.server, session.owner, session.console
        local data = {SlicerInformation = original.SlicerInformation, SlicerCreator = owner,
            SlicerDoor = original.SlicerDoor, Name = original:GetName()}
        original:OnEntityCopyTableFinish(data)
        local function paste()
            local console = setmetatable(server.entity("consoleent"), {__index = server.ENT})
            console:Initialize()
            console.SlicerInformation = data.SlicerInformation
            console.SlicerCreator, console.SlicerDoor = data.SlicerCreator, data.SlicerDoor
            console:SetName(data.Name)
            console:OnDuplicated(data); console:PostEntityPaste(owner, console, {})
            return console
        end
        local first, second = paste(), paste()
        local source, sibling, count = original.SlicerInformation, second.SlicerInformation, #server.returnSpawnedEntities()
        local form = edit(session, first); form:fill("Copied Edit", "8.25", "Copy File")
        save(session, form)
        assertInfo(first, "copied edit", 8.25, "copy file", kind.folder)
        equal(original.SlicerInformation, source); assertInfo(original, "terminal", 2, "secret", kind.folder)
        equal(second.SlicerInformation, sibling); assertInfo(second, "terminal", 2, "secret", kind.folder)
        equal(#server.returnSpawnedEntities(), count)
        for _, console in ipairs({original, first, second}) do registered(server, console) end
        assert(first:GetName() ~= original:GetName() and first:GetName() ~= second:GetName())
        local originalDoor = session.door
        session.console, session.door = first, nil
        if originalDoor then
            equal(original.SlicerDoor, originalDoor); equal(originalDoor.inputs[#originalDoor.inputs], "Lock")
            equal(first.SlicerDoor, nil, "Edit must not relink a copied tools console")
            equal(second.SlicerDoor, nil)
            session.door = server.entity("func_door")
            owner.target = first; server.fire("PlayerSay", owner, "!setEntity")
            owner.target = session.door; server.fire("PlayerSay", owner, "!setEntity")
        end
        hack(session, kind, "copied edit", "copy file", 8.25)
        equal(original.SlicerInformation, source); equal(original.removed, nil)
        equal(second.SlicerInformation, sibling); equal(second.removed, nil)
        if originalDoor then equal(originalDoor.inputs[#originalDoor.inputs], "Lock") end
    end)
    end

    test("edit Save and Cancel preserve the creator's separate live hacking UI, help and pending door choice", function()
        local session = fixture()
        local server, client, owner = session.server, session.client, session.owner
        local pending = server.console(owner); server.configure(owner, pending, "tools")
        local active = server.console(owner); server.configure(owner, active, "data")
        server.open(owner, active)
        deliver(client, server.lastMessage("ServerSendsEntityInformation"))
        client.command("/a[terminal]")
        local timer = assert(client.timers.AccessDelay)
        activeEntry(client).ShowCommandHelp()
        local helpFrame
        for _, panel in ipairs(client.panels) do
            if live(panel) and panel.class == "DFrame" and panel.title and panel.title:find("Commands", 1, true) then helpFrame = panel end
        end
        assert(helpFrame)
        local form = edit(session); form:fill(); save(session, form)
        equal(client.timers.AccessDelay, timer); equal(live(helpFrame), true)
        equal(active.SlicerInformation.inUse, true); equal(owner.SlicerPendingConsole, pending)
        local second = edit(session); second:fill("Cancelled", "90", "Wrong"); second.cancel:DoClick()
        relay(server, owner, client.lastMessage("SlicerSetupEditCancel"))
        equal(client.timers.AccessDelay, timer); equal(live(helpFrame), true)
        equal(client.lastMessage("playerQuitConsole"), nil, "Editor dismissal must not quit a hack")
        equal(active.SlicerInformation.inUse, true); equal(owner.SlicerPendingConsole, pending)
        client.fireTimer("AccessDelay")
        client.command("/a[terminal]/{_data}")
        client.command("/d{_data}/secret.data")
        client.fireTimer("DownloadDataFile")
        server.now = 4
        relay(server, owner, client.lastMessage("destroyOnServer"))
        equal(active.removed, true)
        deliver(client, server.lastMessage("SlicerCompleted"))
        assertInfo(session.console, "renamed console", 3.75, "consolelogs", "data")
        equal(session.console.removed, nil); equal(owner.SlicerPendingConsole, pending)
        client.assertClosed()
    end)

    test("forged additional edit fields cannot change fixed console or door state", function()
        local session = fixture("tools")
        local server, console, owner = session.server, session.console, session.owner
        local pending = server.console(owner); server.configure(owner, pending, "tools")
        local unrelatedDoor = server.entity("func_door")
        local identity, creator = console:GetName(), console.SlicerCreator
        local form = edit(session); form:fill()
        local packet = submit(session, form)
        local payload = packet.values[3]
        payload.fileType, payload.inUse = "server", true
        payload.entityName, payload.SlicerCreator, payload.SlicerDoor = "forged", session.hacker, unrelatedDoor
        relay(server, owner, packet)
        deliver(session.client, reply(session, form.token, true))
        assertInfo(console, "renamed console", 3.75, "consolelogs", "tools")
        equal(console:GetName(), identity); equal(console.SlicerCreator, creator)
        equal(console.SlicerDoor, session.door); equal(owner.SlicerPendingConsole, pending)
        equal(#session.door.inputs, 1); equal(session.door.inputs[1], "Lock")
        equal(#unrelatedDoor.inputs, 0)
        registered(server, console)
    end)

    for _, kind in ipairs(kinds) do
        test(kind.folder .. " server completion deadline uses the edited delay", function()
            local session = fixture(kind.folder)
            local form = edit(session); form:fill("New", "10", "File"); save(session, form)
            local server = session.server
            server.open(session.hacker, session.console)
            server.now = kind.timer and 4 or 2 -- The original setup deadline.
            server.receive(kind.complete, session.hacker, session.console)
            equal(session.console.removed, nil, "The old delay must not authorize completion")
            equal(server.lastMessage("SlicerCompleted"), nil)
            if session.door then equal(session.door.inputs[#session.door.inputs], "Lock") end
            server.open(session.hacker, session.console)
            server.now = server.now + (kind.timer and 20 or 10)
            server.receive(kind.complete, session.hacker, session.console)
            equal(session.console.removed, true)
            if session.door then equal(session.door.inputs[#session.door.inputs], "Unlock") end
        end)
    end

    test("identified colliding copies keep exact targets through rejection pending close and late reply", function()
        local session = fixture("tools")
        local server, client, owner, first = session.server, session.client, session.owner, session.console
        local data = {SlicerInformation = first.SlicerInformation, SlicerCreator = owner, SlicerDoor = session.door}
        first:OnEntityCopyTableFinish(data)
        local second = setmetatable(server.entity("consoleent"), {__index = server.ENT})
        second:Initialize(); second.SlicerInformation = data.SlicerInformation
        second:OnDuplicated(data); second:PostEntityPaste(owner, second, {})
        second.id = first.id
        local secondDoor = server.entity("func_door")
        owner.target = second; server.fire("PlayerSay", owner, "!setEntity")
        owner.target = secondDoor; server.fire("PlayerSay", owner, "!setEntity")
        local firstForm, secondForm = edit(session), edit(session, second)
        local firstTitle = string.format("Edit console #%.0f (entity %.0f)", first:GetCreationID(), first:EntIndex())
        local secondTitle = string.format("Edit console #%.0f (entity %.0f)", second:GetCreationID(), second:EntIndex())
        equal(firstForm.frame.title, firstTitle); equal(secondForm.frame.title, secondTitle)
        assert(firstTitle ~= secondTitle)
        firstForm:fill("first draft", "4", "first file"); secondForm:fill("second draft", "5", "second file")
        local invalid = submit(session, firstForm); invalid.values[3].delay = 0
        relay(server, owner, invalid); deliver(client, reply(session, firstForm.token, false))
        equal(firstForm.frame.title, firstTitle); equal(firstForm.name:GetValue(), "first draft")
        local panels = #client.panels
        deliver(client, openPacket(session)); equal(#client.panels, panels)
        equal(firstForm.frame.title, firstTitle); equal(firstForm.name:GetValue(), "first draft")
        local pending = submit(session, firstForm)
        local busy = server.console(owner); server.configure(owner, busy, "data")
        server.open(session.hacker, busy)
        local busyInfo, selection = busy.SlicerInformation, owner.SlicerPendingConsole
        relay(server, owner, pending)
        local accepted = reply(session, firstForm.token, true)
        equal(firstForm.frame.title, firstTitle); equal(firstForm.cancel.text, "Close")
        client.deferPanelRemoval = true
        firstForm.cancel:DoClick(); relay(server, owner, client.lastMessage("SlicerSetupEditCancel"))
        first.id = first.id + 100
        local fresh = edit(session)
        local freshTitle = string.format("Edit console #%.0f (entity %.0f)", first:GetCreationID(), first:EntIndex())
        equal(fresh.frame.title, freshTitle); fresh:fill("replacement draft", "6", "replacement file")
        local messages = #client.messages
        deliver(client, accepted); firstForm.save:DoClick(); firstForm.cancel:DoClick()
        firstForm.frame:OnClose(); firstForm.frame:OnRemove()
        equal(#client.messages, messages); equal(live(fresh.frame), true); equal(live(secondForm.frame), true)
        equal(fresh.frame.title, freshTitle); equal(fresh.name:GetValue(), "replacement draft")
        equal(secondForm.frame.title, secondTitle); equal(secondForm.name:GetValue(), "second draft")
        assertInfo(first, "first draft", 4, "first file", "tools")
        assertInfo(second, "terminal", 2, "secret", "tools")
        equal(first.SlicerDoor, session.door); equal(second.SlicerDoor, secondDoor)
        equal(#session.door.inputs, 1); equal(#secondDoor.inputs, 1)
        equal(busy.SlicerInformation, busyInfo); equal(busyInfo.inUse, true)
        equal(owner.SlicerPendingConsole, selection)
        save(session, secondForm)
        assertInfo(second, "second draft", 5, "second file", "tools")
        equal(live(fresh.frame), true); equal(fresh.frame.title, freshTitle)
        server.now = 4; server.receive("destroyOnServer", session.hacker, busy)
        equal(busy.removed, true, "Other active session retains its original completion deadline")
    end)
end
