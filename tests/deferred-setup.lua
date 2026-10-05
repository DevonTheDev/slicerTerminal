-- Exercise actual setup, Use, command and submission callbacks. The host
-- doubles only model the documented panel lifecycle and transport boundary.
return function(gmod, test, equal)
    local unpackValues = table.unpack or unpack
    local function deliver(client, packet)
        client.receive(packet.name, nil, unpackValues(packet.values))
    end
    local function formSince(client, first)
        local form, entries = {}, {}
        for i = first, #client.panels do
            local panel = client.panels[i]
            if panel.class == "DFrame" then form.frame = panel
            elseif panel.class == "DTextEntry" then entries[#entries + 1] = panel
            elseif panel.class == "DComboBox" then form.folder = panel
            elseif panel.class == "DButton" and panel.text == "Done" then form.done = panel
            elseif panel.class == "DButton" and panel.text == "Set up later" then form.later = panel end
        end
        assert(form.frame, "Expected a new setup form")
        form.name, form.delay, form.file = entries[1], entries[2], entries[3]
        function form:fill(folder, name)
            self.name:SetText(name or "Terminal")
            self.delay:SetText("2")
            self.folder.selected = folder or "data"
            self.file:SetText("Secret")
        end
        function form:defer()
            assert(self.later, "Setup needs an explicit Set up later button"):DoClick()
        end
        function form:assertBlank()
            equal(self.name:GetValue(), "", "Fresh name")
            equal(self.delay:GetValue(), "", "Fresh delay")
            equal(self.file:GetValue(), "", "Fresh file")
            equal(self.folder:GetSelected(), nil, "Fresh folder")
        end
        return form
    end
    local function openPacket(client, packet)
        local first = #client.panels + 1
        deliver(client, packet)
        return formSince(client, first)
    end
    local function fixture()
        local server, client = gmod.new(), gmod.client()
        local owner = server.player()
        local console = server.console(owner)
        local spawn = assert(server.lastMessage("PlayerSpawnedConsole"))
        return server, client, owner, console, openPacket(client, spawn), spawn
    end
    local function reopen(server, client, owner, console)
        local count = #server.messages
        server.open(owner, console)
        equal(#server.messages, count + 1, "Creator Use must send one setup message")
        local packet = server.messages[#server.messages]
        equal(packet.name, "PlayerSpawnedConsole", "Reuse the existing setup protocol")
        equal(packet.player, owner, "Only send setup to its creator")
        equal(#packet.values, 2, "Keep the original packet shape")
        equal(packet.values[1], owner); equal(packet.values[2], console:GetName())
        return openPacket(client, packet)
    end
    local function relaySetup(server, client, owner)
        local packet = assert(client.lastMessage("AdminFinishedCreation"), "No setup submission")
        server.receive(packet.name, owner, unpackValues(packet.values))
        return packet
    end

    test("Set up later discards only its unsaved form without a server packet", function()
        local server, client, owner, console, form = fixture()
        form:fill("tools")
        local serverCount, clientCount = #server.messages, #client.messages
        form:defer()
        equal(form.frame.valid, false, "Deferral closes this form")
        equal(#client.messages, clientCount, "Deferral must not submit or quit")
        equal(#server.messages, serverCount)
        equal(console.SlicerInformation, nil, "Console remains unconfigured")
        equal(console.valid, true); equal(console.SlicerCreator, owner)
        equal(owner.SlicerPendingConsole, nil)
        client.assertClosed()
        local fresh = reopen(server, client, owner, console)
        fresh:assertBlank()
        fresh.done:DoClick()
        equal(#client.messages, clientCount, "Blank reopen cannot reuse the discarded draft")
        equal(fresh.frame.valid, true, "Blank form stays editable")
        fresh:defer()
        client.assertClosed()
    end)

    for _, weapon in ipairs({"tool", "none", "other"}) do
        test("creator Use recovers unconfigured setup with " .. weapon .. " equipped", function()
            local server, client, owner, console, form = fixture()
            form.frame:Close()
            if weapon == "none" then owner.weapon = nil
            elseif weapon == "other" then owner.weapon = server.entity("weapon_crowbar") end
            local fresh = reopen(server, client, owner, console)
            fresh:assertBlank()
            equal(console.SlicerInformation, nil, "Opening must not configure or reserve")
            equal(client.lastMessage("playerQuitConsole"), nil)
        end)
    end

    test("duplicate setup packets focus the same form and preserve partial typing", function()
        local server, client, owner, console, form, packet = fixture()
        form.name:SetText("Partially typed")
        form.delay:SetText("2.")
        form.file:SetText("Draft")
        form.folder.selected = "server"
        local count, popups = #client.panels, form.frame.popupCalls
        deliver(client, packet)
        equal(#client.panels, count, "Repeated packets must not stack forms")
        equal(form.frame.popupCalls, popups + 1, "Request focus again")
        equal(form.frame.frontCalls, 1, "Raise the current form")
        equal(client.focusedPanel, form.frame)
        equal(form.name:GetValue(), "Partially typed"); equal(form.delay:GetValue(), "2.")
        equal(form.file:GetValue(), "Draft"); equal(form.folder:GetSelected(), "server")
        server.open(owner, console)
        deliver(client, server.lastMessage("PlayerSpawnedConsole"))
        equal(#client.panels, count, "Repeated Use also retains the current form")
        form.done:DoClick()
        relaySetup(server, client, owner)
        equal(console.SlicerInformation.name, "partially typed")
    end)

    -- Calls saved before native deletion may arrive after a new form exists.
    -- All variants keep panels valid until the simulated end-of-frame removal.
    for _, retirement in ipairs({"defer", "submit", "close", "remove", "hide"}) do
        test("retired setup callbacks cannot affect a replacement after " .. retirement, function()
            local server, client, owner, console, old, packet = fixture()
            old:fill("data", "Old")
            local done, later = old.done.DoClick, old.later and old.later.DoClick
            client.deferPanelRemoval = true
            if retirement == "defer" then old:defer()
            elseif retirement == "submit" then old.done:DoClick()
            elseif retirement == "close" then old.frame:Close()
            elseif retirement == "remove" then old.frame:Remove()
            else old.frame:Hide() end
            local count = #client.messages
            local fresh = openPacket(client, packet)
            fresh:assertBlank(); fresh:fill("server", "Replacement")
            done()
            if later then later() end
            -- Both native cleanup paths may be delivered after replacement.
            if old.frame.OnClose then old.frame:OnClose() end
            if old.frame.OnRemove then old.frame:OnRemove() end
            equal(#client.messages, count, "Retired callbacks must not submit")
            equal(fresh.frame:IsMarkedForDeletion(), false, "Replacement must stay open")
            equal(fresh.frame:IsVisible(), true)
            equal(fresh.name:GetValue(), "Replacement")
            local panels = #client.panels
            deliver(client, packet)
            equal(#client.panels, panels, "Late cleanup must not erase replacement ownership")
            fresh.done:DoClick()
            equal(#client.messages, count + 1, "Replacement still submits exactly once")
            relaySetup(server, client, owner)
            equal(console.SlicerInformation.name, "replacement")
        end)
    end

    test("OnClose retires a setup even when a hidden native frame is shown again", function()
        local _, client, _, _, old, packet = fixture()
        old:fill()
        old.frame:SetDeleteOnClose(false)
        old.frame:Close()
        old.frame:Show()
        old.done:DoClick()
        equal(#client.messages, 0, "OnClose retirement survives visibility changes")
        local fresh = openPacket(client, packet)
        fresh:assertBlank()
        fresh:defer()
    end)

    test("runtime OnRemove retires ownership before any delayed callbacks", function()
        local _, client, _, _, old, packet = fixture()
        old:fill()
        assert(old.frame.OnRemove, "Setup must retire ownership on runtime removal")(old.frame)
        old.done:DoClick()
        equal(#client.messages, 0)
        openPacket(client, packet):assertBlank()
    end)

    test("deferring one terminal keeps a different terminal's form and values", function()
        local server, client, owner, alpha, first, alphaPacket = fixture()
        local beta = server.console(owner)
        local second = openPacket(client, server.lastMessage("PlayerSpawnedConsole"))
        first:fill("data", "Alpha"); second:fill("server", "Beta")
        local count = #client.panels
        deliver(client, alphaPacket)
        equal(#client.panels, count, "Focus lookup is per console even with another form on top")
        equal(client.focusedPanel, first.frame)
        equal(first.name:GetValue(), "Alpha"); equal(second.name:GetValue(), "Beta")
        first:defer()
        equal(second.frame.valid, true); equal(second.name:GetValue(), "Beta")
        local replacement = openPacket(client, alphaPacket)
        replacement:assertBlank()
        first.done:DoClick(); first.later:DoClick()
        equal(#client.messages, 0)
        equal(second.frame.valid, true); equal(replacement.frame.valid, true)
        second.done:DoClick(); relaySetup(server, client, owner)
        equal(beta.SlicerInformation.name, "beta"); equal(alpha.SlicerInformation, nil)
        replacement:fill("data", "Alpha again")
        replacement.done:DoClick(); relaySetup(server, client, owner)
        equal(alpha.SlicerInformation.name, "alpha again")
    end)

    for _, invalid in ipairs({"outsider", "dead", "invalid player", "nonplayer", "nil", "removed console", "wrong input"}) do
        test("unconfigured Use rejects " .. invalid .. " without setup or state changes", function()
            local server, _, owner, console = fixture()
            local activator, input = owner, "Use"
            if invalid == "outsider" then activator = server.player()
            elseif invalid == "dead" then owner.alive = false
            elseif invalid == "invalid player" then owner.valid = false
            elseif invalid == "nonplayer" then activator = server.entity("prop_physics")
            elseif invalid == "nil" then activator = nil
            elseif invalid == "removed console" then console:Remove()
            else input = "Enable" end
            local count = #server.messages
            console:AcceptInput(input, activator, activator)
            equal(#server.messages, count, "No setup or hacking message")
            equal(console.SlicerInformation, nil); equal(console.SlicerCreator, owner)
            equal(#server.returnSpawnedEntities(), 0)
        end)
    end

    for _, invalid in ipairs({"dead", "invalid", "nonplayer"}) do
        test("setup opening and saved Done callbacks reject a " .. invalid .. " player", function()
            local _, client, owner, _, old, packet = fixture()
            old:fill()
            if invalid == "dead" then owner.alive = false
            elseif invalid == "invalid" then owner.valid = false
            else owner.class = "prop_physics" end
            old.done:DoClick()
            equal(#client.messages, 0, "Invalid submitter cannot send configuration")
            old.frame:Close()
            local count = #client.panels
            deliver(client, packet)
            equal(#client.panels, count, "Invalid opening player cannot create a form")
        end)
    end

    test("deferral preserves another active hack, timers, help and pending door selection", function()
        local server, client, owner, deferred, setup = fixture()
        local pending = server.console(owner)
        server.configure(owner, pending, "tools")
        local active = server.console(owner)
        local info = server.configure(owner, active, "data")
        server.open(owner, active)
        deliver(client, server.lastMessage("ServerSendsEntityInformation"))
        client.command("/a[terminal]")
        local timer = assert(client.timers.AccessDelay)
        local helpButton
        for _, panel in ipairs(client.panels) do
            if panel.class == "DButton" and panel.text == "Commands (/help)" then helpButton = panel end
        end
        assert(helpButton):DoClick() -- Help remains clickable while command input is disabled.
        local help = client.panels[#client.panels].parent.parent
        local messages = #client.messages
        setup:defer()
        equal(#client.messages, messages, "Never send the hacking quit packet")
        equal(info.inUse, true, "Keep the unrelated server reservation")
        equal(client.timers.AccessDelay, timer, "Keep the active login countdown")
        equal(help.valid, true, "Keep active command help")
        equal(owner.SlicerPendingConsole, pending, "Keep the selected door terminal")
        equal(deferred.SlicerInformation, nil)
        local fresh = reopen(server, client, owner, deferred)
        fresh:defer()
        equal(info.inUse, true); equal(owner.SlicerPendingConsole, pending)
        client.fireTimer("AccessDelay")
        client.command("/a[terminal]/{_data}")
        client.command("/d{_data}/secret.data")
        client.fireTimer("DownloadDataFile")
        server.now = 4
        local packet = assert(client.lastMessage("destroyOnServer"))
        server.receive(packet.name, owner, unpackValues(packet.values))
        equal(active.removed, true, "The unrelated hack can still finish")
        equal(deferred.valid, true); equal(pending.valid, true)
        equal(owner.SlicerPendingConsole, pending)
    end)

    for _, kind in ipairs({
        {folder = "data", extension = "data", timer = "DownloadDataFile", message = "destroyOnServer"},
        {folder = "server", extension = "sys", timer = "DownloadServerFile", message = "destroyOnServer"},
        {folder = "tools", extension = "exe", message = "PlayerActivatedDoor"},
    }) do
        test("spawn, defer, creator Use, configure and ordinary " .. kind.folder .. " completion", function()
            local server, client, owner, console, initial = fixture()
            initial:fill(kind.folder, "Discarded")
            initial:defer()
            owner.weapon = nil
            local fresh = reopen(server, client, owner, console)
            fresh:assertBlank(); fresh:fill(kind.folder)
            fresh.done:DoClick()
            local setupPacket = relaySetup(server, client, owner)
            local info = assert(console.SlicerInformation)
            equal(info.name, "terminal"); equal(info.inUse, false)
            equal(fresh.frame.valid, false)
            -- Existing ownership and first-write validation still decide setup.
            server.receive("AdminFinishedCreation", server.player(), setupPacket.values[1])
            server.receive("AdminFinishedCreation", owner, {"Edited", 8, "data", "Changed", console:GetName()})
            equal(console.SlicerInformation, info); equal(info.name, "terminal")
            local count = #server.messages
            server.open(owner, console)
            equal(#server.messages, count, "Configured Use still requires the hacking tool")
            local door
            if kind.folder == "tools" then
                equal(owner.SlicerPendingConsole, console)
                owner.weapon = server.entity("weapon_hacking")
                server.open(owner, console)
                equal(#server.messages, count, "Unlinked tools terminal must not open setup or hacking")
                door = server.entity("func_door")
                owner.target = door
                server.fire("PlayerSay", owner, "!setEntity")
                equal(door.inputs[1], "Lock"); equal(console.SlicerDoor, door)
            end
            local hacker = server.player()
            server.open(hacker, console)
            deliver(client, server.lastMessage("ServerSendsEntityInformation"))
            equal(info.inUse, true)
            client.command("/a[terminal]"); client.fireTimer("AccessDelay")
            client.command("/a[terminal]/{_" .. kind.folder .. "}")
            client.command((kind.timer and "/d" or "/r") .. "{_" .. kind.folder .. "}/secret." .. kind.extension)
            if kind.timer then client.fireTimer(kind.timer) end
            local completion = assert(client.lastMessage(kind.message))
            server.now = kind.timer and 4 or 2
            server.receive(completion.name, hacker, unpackValues(completion.values))
            equal(console.removed, true, "Ordinary completion consumes the configured terminal")
            if door then equal(door.inputs[#door.inputs], "Unlock") end
            deliver(client, assert(server.lastMessage("SlicerCompleted")))
            equal(#client.chatMessages, 1, "Success remains server-authoritative")
            client.assertClosed()
        end)
    end

    test("a removed deferred terminal cannot later be configured by a saved packet", function()
        local server, client, owner, console, form = fixture()
        form:fill(); form.done:DoClick()
        console:Remove()
        relaySetup(server, client, owner)
        equal(console.SlicerInformation, nil)
        equal(#server.returnSpawnedEntities(), 0)
    end)
end
