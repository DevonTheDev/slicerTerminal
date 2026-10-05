-- Execute the production client callbacks and server receivers. These tests
-- cover ownership and network effects, not native Derma layout or mouse input.
return function(gmod, test, equal)
    local kinds = {
        {folder = "data", extension = "data", timer = "DownloadDataFile", message = "destroyOnServer"},
        {folder = "server", extension = "sys", timer = "DownloadServerFile", message = "destroyOnServer"},
        {folder = "tools", extension = "exe", message = "PlayerActivatedDoor"},
    }
    local unpackValues = table.unpack or unpack
    local function packetCount(env, name)
        local count = 0
        for _, packet in ipairs(env.messages) do if packet.name == name then count = count + 1 end end
        return count
    end
    local function activeEntry(env)
        for i = #env.panels, 1, -1 do
            local panel, live = env.panels[i], true
            local ancestor = panel
            while ancestor do
                if not ancestor.valid or ancestor:IsMarkedForDeletion() or not ancestor:IsVisible() then live = false end
                ancestor = ancestor.parent
            end
            if live and panel.OnEnter then return panel end
        end
        error("Missing live terminal input")
    end
    local function button(page, text)
        for _, child in ipairs(page.children) do
            if child.class == "DButton" and child.text == text then return child end
        end
        error("Missing " .. text .. " button on terminal page")
    end
    local function acceptOpening(server, client)
        local packet = assert(server.lastMessage("ServerSendsEntityInformation"))
        client.receive(packet.name, nil, unpackValues(packet.values))
    end
    local function fixture(kind)
        local server, client = gmod.new(), gmod.client()
        local owner, hacker = server.player(), server.player()
        local console = server.console(owner)
        local info = assert(server.configure(owner, console, kind.folder, 2))
        local door
        if kind.folder == "tools" then
            door = server.entity("func_door")
            owner.target = door
            server.fire("PlayerSay", owner, "!setEntity")
        end
        server.open(hacker, console)
        acceptOpening(server, client)
        return server, client, owner, hacker, console, info, door
    end
    local function visit(client, stage)
        if stage ~= "login" then
            client.command("/a[terminal]")
            equal(client.timers.AccessDelay.delay, 2)
            client.fireTimer("AccessDelay")
            if stage ~= "folders" then client.command("/a[terminal]/{_" .. stage .. "}") end
        end
        return activeEntry(client)
    end
    local function action(kind)
        return (kind.timer and "/d" or "/r") .. "{_" .. kind.folder .. "}/secret." .. kind.extension
    end
    local function noCompletion(server, client, console, door)
        equal(console.removed, nil, "Quit must preserve the terminal")
        equal(client.lastMessage("destroyOnServer"), nil, "Quit must not request a download")
        equal(client.lastMessage("PlayerActivatedDoor"), nil, "Quit must not run a door tool")
        equal(server.lastMessage("SlicerCompleted"), nil, "Quit must not report success")
        equal(#client.chatMessages, 0)
        if door then equal(door.inputs[#door.inputs], "Lock", "Quit must leave the linked door locked") end
    end
    local function releaseAndReenter(server, client, hacker, console, info, door)
        equal(packetCount(client, "playerQuitConsole"), 1, "Quit must send exactly one request")
        local packet = assert(client.lastMessage("playerQuitConsole"))
        equal(#packet.values, 2, "Keep the existing quit packet shape")
        equal(packet.values[1], hacker); equal(packet.values[2], console)
        equal(info.inUse, true, "Local cancellation must await the actual server receiver")
        server.receive(packet.name, hacker, unpackValues(packet.values))
        equal(info.inUse, false, "Server must release the reservation")
        server.now = 100
        server.receive("destroyOnServer", hacker, console)
        server.receive("PlayerActivatedDoor", hacker, console)
        noCompletion(server, client, console, door)
        local nextPlayer = server.player()
        server.open(nextPlayer, console)
        equal(server.lastMessage("ServerSendsEntityInformation").player, nextPlayer)
        equal(info.inUse, true, "Another player must be admitted after quit")
    end

    for _, kind in ipairs(kinds) do
        for _, stage in ipairs({"login", "folders", "data", "server", "tools"}) do
            test("Quit terminal releases " .. kind.folder .. " from " .. stage .. " with help open", function()
                local server, client, _, hacker, console, info, door = fixture(kind)
                local entry = visit(client, stage)
                local quit = button(entry.parent, "Quit terminal")
                button(entry.parent, "Commands (/help)"):DoClick()
                quit:DoClick()
                client.assertClosed()
                quit:DoClick() -- A retained callback cannot send a second quit.
                client.fire("Think")
                client.assertClosed()
                releaseAndReenter(server, client, hacker, console, info, door)
            end)
        end
    end

    for _, countdown in ipairs({
        {stage = "login", kind = kinds[1], timer = "AccessDelay", command = "/a[terminal]"},
        {stage = "data", kind = kinds[1], timer = "DownloadDataFile", command = action(kinds[1])},
        {stage = "server", kind = kinds[2], timer = "DownloadServerFile", command = action(kinds[2])},
    }) do
        for _, afterThink in ipairs({false, true}) do
            test("Quit terminal cancels " .. countdown.timer .. (afterThink and " after" or " before") .. " first Think", function()
                local server, client, _, hacker, console, info, door = fixture(countdown.kind)
                local entry = visit(client, countdown.stage)
                client.command(countdown.command)
                equal(client.timers[countdown.timer].delay, 2)
                if afterThink then client.fire("Think"); equal(entry.editable, false) end
                button(entry.parent, "Commands (/help)"):DoClick()
                local quit = button(entry.parent, "Quit terminal")
                assert(quit.enabled ~= false, "Quit must remain enabled during a countdown")
                quit:DoClick()
                client.assertClosed(); client.fire("Think")
                releaseAndReenter(server, client, hacker, console, info, door)
            end)
        end
    end

    for _, stage in ipairs({"login", "folders"}) do
        test("typed quit shares one cancellation action on " .. stage, function()
            local server, client, _, hacker, console, info, door = fixture(kinds[1])
            local entry = visit(client, stage)
            local quit = button(entry.parent, "Quit terminal")
            client.command("/Q[terminal]")
            entry:OnEnter(); quit:DoClick()
            client.assertClosed()
            releaseAndReenter(server, client, hacker, console, info, door)
        end)
    end

    for _, state in ipairs({"hidden", "removed", "deletion-marked"}) do
        for _, stage in ipairs({"login", "folders", "data", "server", "tools"}) do
            test(state .. " " .. stage .. " owner cannot quit a live reservation", function()
                local server, client, _, hacker, console, info, door = fixture(kinds[3])
                local entry = visit(client, stage)
                local page, quit = entry.parent, button(entry.parent, "Quit terminal")
                entry:SetText("/q[terminal]")
                if state == "hidden" then page:Hide()
                elseif state == "removed" then page:Remove()
                else client.deferPanelRemoval = true; page:Remove() end
                local sent, events = #client.messages, #client.timerEvents
                quit:DoClick()
                if stage == "login" or stage == "folders" then entry:OnEnter() end
                equal(#client.messages, sent, "A retired page must not send quit")
                equal(#client.timerEvents, events, "A retired page must not clean up current work")
                equal(info.inUse, true); noCompletion(server, client, console, door)
                if state == "hidden" then
                    page:Show(); quit:DoClick()
                    releaseAndReenter(server, client, hacker, console, info, door)
                end
            end)
        end
    end

    test("folder selection quits again when returned to after its hidden callbacks were ignored", function()
        local server, client, _, hacker, console, info, door = fixture(kinds[3])
        local folders = visit(client, "folders")
        local quit = button(folders.parent, "Quit terminal")
        client.command("/a[terminal]/{_tools}")
        local tools = activeEntry(client)
        folders:SetText("/q[terminal]")
        folders:OnEnter(); quit:DoClick()
        equal(packetCount(client, "playerQuitConsole"), 0)
        equal(activeEntry(client), tools)
        client.command("//[terminal]/{_tools}")
        equal(activeEntry(client), folders)
        quit:DoClick(); client.assertClosed()
        releaseAndReenter(server, client, hacker, console, info, door)
    end)

    for _, sameConsole in ipairs({false, true}) do
        for _, oldStage in ipairs({"login", "folders", "data", "server", "tools"}) do
            test("old " .. oldStage .. " quit cannot release a new " .. (sameConsole and "same-console" or "different-console") .. " session", function()
                local server, client, owner, hacker, console, info = fixture(kinds[1])
                local oldEntry = visit(client, oldStage)
                local oldQuit = button(oldEntry.parent, "Quit terminal")
                oldEntry:SetText("/q[terminal]")
                -- Native panel deletion is deferred. Keep the old callback alive
                -- through close and reopen, including its original input value.
                client.deferPanelRemoval = true
                oldQuit:DoClick()
                local packet = assert(client.lastMessage("playerQuitConsole"))
                server.receive(packet.name, hacker, unpackValues(packet.values))
                if not sameConsole then
                    console = server.console(owner)
                    info = assert(server.configure(owner, console))
                end
                server.open(hacker, console); acceptOpening(server, client)
                local current = activeEntry(client)
                local sent, events = #client.messages, #client.timerEvents
                oldQuit:DoClick()
                if oldStage == "login" or oldStage == "folders" then oldEntry:OnEnter() end
                equal(#client.messages, sent); equal(#client.timerEvents, events)
                equal(activeEntry(client), current); equal(info.inUse, true)
                client.command("/a[terminal]")
                assert(client.timers.AccessDelay, "The new session must still work")
                button(current.parent, "Quit terminal"):DoClick()
                equal(packetCount(client, "playerQuitConsole"), 2)
                packet = assert(client.lastMessage("playerQuitConsole"))
                server.receive(packet.name, hacker, unpackValues(packet.values))
                equal(info.inUse, false)
            end)
        end
    end

    for _, closeReason in ipairs({"quit", "death", "completion"}) do
        test(closeReason .. " retires callback ownership before panel removal can reenter", function()
            local server, client, _, hacker, console, info, door = fixture(kinds[3])
            local entry = visit(client, closeReason == "completion" and "tools" or "folders")
            local page, quit = entry.parent, button(entry.parent, "Quit terminal")
            local originalRemove, removing = page.Remove, false
            function page:Remove()
                assert(not removing, "Closing recursively entered the same active quit action")
                removing = true
                -- Removal hooks run before this page becomes invalid or hidden.
                quit:DoClick()
                if closeReason ~= "completion" then entry:SetText("/q[terminal]"); entry:OnEnter() end
                originalRemove(self)
                removing = false
            end
            if closeReason == "quit" then quit:DoClick()
            elseif closeReason == "death" then
                server.fire("PlayerDeath", hacker)
                client.receive("PlayerDied", nil)
            else
                server.now = 2
                client.command(action(kinds[3]))
                local packet = assert(client.lastMessage("PlayerActivatedDoor"))
                server.receive(packet.name, hacker, unpackValues(packet.values))
                equal(console.removed, true); equal(door.inputs[#door.inputs], "Unlock")
            end
            client.assertClosed(); quit:DoClick()
            equal(packetCount(client, "playerQuitConsole"), closeReason == "quit" and 1 or 0)
            if closeReason ~= "quit" then equal(info.inUse, false) end
        end)
    end

    for _, kind in ipairs(kinds) do
        test(kind.folder .. " completion keeps its timing and ignores retained Quit terminal", function()
            local server, client, _, hacker, console, info, door = fixture(kind)
            local entry = visit(client, kind.folder)
            local quit = button(entry.parent, "Quit terminal")
            client.command(action(kind))
            if kind.timer then
                equal(client.timers[kind.timer].delay, 2)
                client.fireTimer(kind.timer)
            end
            client.assertClosed(); quit:DoClick()
            equal(packetCount(client, "playerQuitConsole"), 0)
            local packet = assert(client.lastMessage(kind.message))
            equal(#client.chatMessages, 0)
            server.now = kind.timer and 4 or 2
            server.receive(packet.name, hacker, unpackValues(packet.values))
            equal(console.removed, true); equal(info.inUse, false)
            if door then equal(door.inputs[#door.inputs], "Unlock") end
            local completed = assert(server.lastMessage("SlicerCompleted"))
            client.receive(completed.name, nil, unpackValues(completed.values))
            equal(#client.chatMessages, 1)
        end)
    end
end
