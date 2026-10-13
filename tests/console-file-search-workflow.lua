-- Public setup/edit/chat/client callbacks, with explicit packet relay. Native
-- chat length, multiplayer delivery and marker rendering still need GMod.
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
        function result:fill(name, file, folder)
            self.name:SetText(name); self.delay:SetText("2"); self.file:SetText(file)
            if not editing then self.folder.selected = folder or "data" end
        end
        return result
    end
    local function search(server, owner, query)
        local before, count = #owner.chats, #server.messages
        equal(server.fire("PlayerSay", owner, "!findConsoleFiles 1 " .. query), "")
        equal(#server.messages, count, "Search sent a packet")
        local rows = {}
        for index = before + 1, #owner.chats do
            if owner.chats[index]:match("^[1-5]%. Console") then rows[#rows + 1] = owner.chats[index] end
        end
        return rows
    end
    local function locate(server, client, owner, ent)
        equal(server.fire("PlayerSay", owner, "!locateConsole 1"), "")
        local packet = server.lastMessage("SlicerConsoleLocation")
        equal(packet.player, owner); equal(packet.values[3].x, ent.position.x)
        support.deliver(client, packet)
    end

    test("file search preserves accepted setup edit paste tickets selection and an unrelated original deadline", function()
        local server, client, hackClient = support.server(), support.client(), gmod.client()
        local owner, hacker = server.player(), server.player()
        local active, editable, selected = server.console(owner), server.console(owner), server.console(owner)
        server.configure(owner, active, "data", 2); server.configure(owner, editable, "server", 2)
        server.configure(owner, selected, "tools", 2)
        editable.SlicerInformation.fileName = "old saved file"
        server.now = 10; server.open(hacker, active); deliver(hackClient, server.lastMessage("ServerSendsEntityInformation"))
        hackClient.command("/a[terminal]"); local login = hackClient.timers.AccessDelay
        owner.target = editable; server.fire("PlayerSay", owner, "!editConsole")
        local editOpen = server.lastMessage("SlicerSetupEditOpen")
        local editing = form(client, editOpen, true); editing:fill("Accepted edit", "edited file"); editing.submit:DoClick()
        local editSave = client.lastMessage("SlicerSetupEditSave")
        local deferred = server.console(owner)
        local setup = form(client, server.lastMessage("PlayerSpawnedConsole")); setup:fill("Accepted setup", "setup file"); setup.submit:DoClick()
        local setupSave = client.lastMessage("AdminFinishedCreation")
        local info, registry, serial = editable.SlicerInformation, server.returnSpawnedEntities(), server.slicerSetupEditSerial
        local chats = #hacker.chats
        owner.weapon = nil
        function owner:GetEyeTrace() error("Search/locate must not trace") end
        function owner:GetActiveWeapon() error("Search/locate must not read a weapon") end
        equal(#search(server, owner, "old saved file"), 1); locate(server, client, owner, editable)
        local marker = client.paint(); assert(marker ~= "")
        equal(#search(server, owner, "edited file"), 0); equal(client.paint(), marker, "Search cleared an existing marker")
        equal(#search(server, owner, "secret"), 2)
        equal(owner.SlicerPendingConsole, selected); equal(editable.SlicerInformation, info)
        equal(server.returnSpawnedEntities(), registry); equal(server.slicerSetupEditSerial, serial)
        equal(editing.name.editable, false); equal(setup.name.editable, false)
        equal(editing.frame.valid, true); equal(setup.frame.valid, true)
        equal(client.lastMessage("SlicerSetupEditSave"), editSave); equal(client.lastMessage("AdminFinishedCreation"), setupSave)
        equal(#hacker.chats, chats); equal(hackClient.timers.AccessDelay, login); equal(active.SlicerInformation.inUse, true)
        owner.GetEyeTrace = function(self) return {Entity = self.target} end
        owner.GetActiveWeapon = function(self) return self.weapon end
        relay(server, owner, editSave)
        local editReply = server.lastMessage("SlicerSetupEditReply"); equal(editReply.values[2].ok, true)
        equal(#search(server, owner, "edited file"), 1); locate(server, client, owner, editable)
        equal(editing.frame.valid, true, "Search cannot acknowledge the edit on the client's behalf")
        deliver(client, editReply); equal(editing.frame.valid, false)
        relay(server, owner, setupSave)
        local setupReply = server.lastMessage("SlicerInitialSetupReply"); equal(setupReply.values[2].ok, true)
        equal(#search(server, owner, "setup file"), 1); locate(server, client, owner, deferred)
        deliver(client, setupReply); equal(setup.frame.valid, false)
        equal(owner.SlicerPendingConsole, selected)
        -- Native duplication captures fields before the copy hook, then
        -- restores them on the new entity before OnDuplicated runs.
        local data = {SlicerInformation = editable.SlicerInformation}
        editable:OnEntityCopyTableFinish(data)
        assert(type(data.SlicerInformation) == "table", "Copy fixture lost saved configuration")
        assert(data.SlicerInformation ~= editable.SlicerInformation, "Copy hook retained original configuration")
        local copier = server.player()
        local copy = setmetatable(server.entity("consoleent"), {__index = server.ENT})
        copy:Initialize(); copy.SlicerInformation = data.SlicerInformation
        copy:OnDuplicated(data); copy:PostEntityPaste(copier, copy, {})
        copy.position = support.vector(9000, 0, 0)
        function copy:WorldSpaceCenter() return self.position end
        equal(copy.SlicerCreator, copier); assert(copy.SlicerInformation ~= editable.SlicerInformation)
        assert(type(copy.SlicerInformation) == "table", "Paste fixture lost saved configuration")
        equal(copy.SlicerInformation.fileName, "edited file", "Pasted saved filename")
        equal(#search(server, copier, "edited file"), 1, "Pasted console filename search"); locate(server, client, copier, copy)
        equal(#search(server, owner, "edited file"), 1); locate(server, client, owner, editable)
        equal(owner.SlicerPendingConsole, selected)
        local door = server.entity("func_door_rotating"); owner.target = door
        equal(server.fire("PlayerSay", owner, "!setEntity"), ""); equal(selected.SlicerDoor, door)
        hackClient.fireTimer("AccessDelay"); hackClient.command("/a[terminal]/{_data}")
        hackClient.command("/d{_data}/secret.data"); hackClient.fireTimer("DownloadDataFile")
        local completion = assert(hackClient.lastMessage("destroyOnServer"))
        server.now = 14; relay(server, hacker, completion); equal(active.removed, true, "Original deadline must still permit completion")
        deliver(hackClient, server.lastMessage("SlicerCompleted")); hackClient.assertClosed()
        equal(#door.inputs, 1); equal(door.inputs[1], "Lock"); equal(selected.removed, nil)
    end)

end
