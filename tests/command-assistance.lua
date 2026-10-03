-- Exercise the real client's stage callbacks through the host API boundary.
-- The doubles verify command/history configuration and lifetime, not native
-- keyboard handling, focus behavior, clipping or the rendered help layout.
return function(gmod, test, equal)
    local kinds = {
        {folder = "data", extension = "data", timer = "DownloadDataFile", message = "destroyOnServer"},
        {folder = "server", extension = "sys", timer = "DownloadServerFile", message = "destroyOnServer"},
        {folder = "tools", extension = "exe", message = "PlayerActivatedDoor"},
    }
    local unpackValues = table.unpack or unpack
    local function openClient(fileType, env, name, file)
        env = env or gmod.client()
        env.receive("ServerSendsEntityInformation", nil, env.entity("consoleent"), env.entity("player"),
            {name = name or "terminal", delay = 2, fileType = fileType or "data", fileName = file or "secret", inUse = false}, "console1")
        return env
    end
    local function activeEntry(env)
        for i = #env.panels, 1, -1 do
            local panel = env.panels[i]
            if panel:IsVisible() and panel.OnEnter then return panel end
        end
        error("Missing active command entry")
    end
    local function helpWindows(env)
        local found = {}
        for _, panel in ipairs(env.panels) do
            if panel.valid and panel.class == "DFrame" and (panel.title or ""):match("^Commands") then found[#found + 1] = panel end
        end
        return found
    end
    local function helpButton(env, stage)
        for _, panel in ipairs(env.panels) do
            if panel.valid and panel.parent == stage and panel.class == "DButton" and panel.text == "Commands (/help)" then return panel end
        end
        error("Missing Commands (/help) button on active stage")
    end
    local function helpText(help)
        local text, scroll = {}, nil
        local function visit(panel)
            if panel.class == "DScrollPanel" then scroll = panel end
            if panel.class == "DLabel" then text[#text + 1] = panel.text end
            for _, child in ipairs(panel.children) do visit(child) end
        end
        visit(help)
        assert(scroll, "Help commands need a scroll container")
        equal(scroll.dock, 5, "The scroll container fills the help frame")
        return table.concat(text, "\n"), scroll
    end
    local function contains(text, expected)
        assert(text:find(expected, 1, true), "Missing contextual command: " .. expected .. " in " .. text)
    end
    local function excludes(text, unexpected)
        assert(not text:find(unexpected, 1, true), "Unexpected contextual command: " .. unexpected)
    end
    local function openHelp(env, command)
        local stage = activeEntry(env).parent
        local sent, events = #env.messages, #env.timerEvents
        env.command(command or "/help")
        local windows = helpWindows(env)
        equal(#windows, 1, "Submitting /help must show exactly one Commands window")
        equal(windows[1].parent, stage, "Help belongs to its current terminal stage")
        equal(#env.messages, sent, "Help must not send an action packet")
        equal(#env.timerEvents, events, "Help must not create, restart, stop or remove timers")
        equal(stage.valid, true, "Help must leave the current stage open")
        return windows[1], helpText(windows[1])
    end
    local function login(env)
        env.command("/a[terminal]")
        equal(env.timers.AccessDelay.delay, 2, "Access delay must be preserved")
        env.fireTimer("AccessDelay")
    end
    local function enterFolder(env, kind)
        env.command("/a[terminal]/{_" .. kind.folder .. "}")
    end
    local function completeCommand(kind)
        return (kind.timer and "/d" or "/r") .. "{_" .. kind.folder .. "}/secret." .. kind.extension
    end
    local function assertHint(entry)
        contains(string.lower(entry.placeholder or ""), "/help")
        contains(string.lower(entry.placeholder or ""), "up/down")
    end
    local function assertRetired(env, button)
        local count = #env.panels
        button.DoClick(button)
        equal(#env.panels, count, "A retained callback reopened retired help")
        equal(#helpWindows(env), 0, "Retired help window leaked")
    end

    test("login /help opens contextual commands without submitting an action", function()
        local env = openClient()
        local _, text = openHelp(env)
        contains(text, "/a[terminal]")
        contains(text, "/q[terminal]")
        contains(text, "/help")
        excludes(text, "/a[terminal]/{_")
        excludes(text, "/d{_")
        excludes(text, "/r{_")
        equal(env.timers.AccessDelay, nil)
    end)

    test("case-insensitive /help and its button reuse one dismissible login help window", function()
        local env = openClient()
        local entry = activeEntry(env)
        local button = helpButton(env, entry.parent)
        local sent, events = #env.messages, #env.timerEvents
        local first = openHelp(env, "/HeLp")
        button:DoClick()
        equal(helpWindows(env)[1], first, "Repeated help should reuse the live window")
        equal(openHelp(env, "/HELP"), first)
        equal(#helpWindows(env), 1)
        first:Close()
        equal(entry.parent.valid, true, "Closing help closed the terminal")
        equal(#helpWindows(env), 0)
        button:DoClick()
        local reopened = helpWindows(env)[1]
        assert(reopened and reopened ~= first, "Closed help must be reopenable on a live stage")
        equal(#env.messages, sent)
        equal(#env.timerEvents, events)
        env.receive("PlayerDied", nil)
        env.assertClosed()
    end)

    test("folder-selection help lists all folders and quit without running commands", function()
        local env = openClient()
        login(env)
        local entry = activeEntry(env)
        helpButton(env, entry.parent):DoClick()
        local help, text = openHelp(env, "/HeLp")
        for _, kind in ipairs(kinds) do contains(text, "/a[terminal]/{_" .. kind.folder .. "}") end
        contains(text, "/q[terminal]"); contains(text, "/help")
        excludes(text, "/d{_"); excludes(text, "/r{_")
        equal(env.insideData, nil); equal(env.insideServer, nil); equal(env.insideTools, nil)
        help:Close()
        equal(entry.parent.valid, true)
        env.command("/q[terminal]")
        env.assertClosed()
    end)

    for _, kind in ipairs(kinds) do
        for _, target in ipairs(kinds) do
            test(kind.folder .. " help exposes an action only for the " .. target.folder .. " target", function()
                local env = openClient(target.folder)
                login(env); enterFolder(env, kind)
                local entry = activeEntry(env)
                helpButton(env, entry.parent):DoClick()
                local _, text, scroll = openHelp(env, "/HELP")
                contains(text, "//[terminal]/{_" .. kind.folder .. "}")
                contains(text, "/help")
                excludes(text, "/a[terminal]"); excludes(text, "/q[terminal]")
                for _, candidate in ipairs(kinds) do
                    if candidate.folder == kind.folder and kind.folder == target.folder then
                        contains(text, completeCommand(candidate))
                    else excludes(text, completeCommand(candidate)) end
                end
                for _, label in ipairs(scroll.children) do
                    if label.class == "DLabel" then
                        equal(label.dock, env.TOP)
                        equal(label.wrap, true, "Long configured names must wrap")
                        equal(label.autoStretchVertical, true, "Wrapped commands need vertical space")
                    end
                end
                equal(env.timers.DownloadDataFile, nil); equal(env.timers.DownloadServerFile, nil)
                env.receive("PlayerDied", nil); env.assertClosed()
            end)
        end
    end

    test("help uses configured console and file names rather than sample commands", function()
        local name, file = string.rep("n", 128), string.rep("f", 128)
        local env = openClient("server", nil, name, file)
        local _, text = openHelp(env)
        contains(text, "/a[" .. name .. "]")
        env.command("/a[" .. name .. "]"); env.fireTimer("AccessDelay")
        env.command("/a[" .. name .. "]/{_server}")
        _, text = openHelp(env)
        contains(text, "//[" .. name .. "]/{_server}")
        contains(text, "/d{_server}/" .. file .. ".sys")
        excludes(text, "/secret."); excludes(text, "[terminal]")
    end)

    test("typing a command or using its help button never submits or autocompletes it", function()
        local env = openClient()
        local entry = activeEntry(env)
        local sent, events = #env.messages, #env.timerEvents
        equal(rawget(entry, "GetAutoComplete"), nil, "The addon must not install autocomplete")
        equal(rawget(entry, "OnKeyCodeTyped"), nil, "History keeps native key dispatch")
        entry:SetText("/a[ter")
        if entry.OnTextChanged then entry:OnTextChanged() end
        equal(entry:GetValue(), "/a[ter", "Typing was expanded into a command")
        equal(#env.messages, sent); equal(#env.timerEvents, events)
        helpButton(env, entry.parent):DoClick()
        equal(entry:GetValue(), "/a[ter", "Opening reference should preserve an unfinished command")
        equal(env.timers.AccessDelay, nil)
        equal(#env.messages, sent); equal(#env.timerEvents, events)
        equal(#env.historyCalls, 0, "Unsubmitted text must not enter history")
    end)

    test("all command stages enable native history and keep the same session array", function()
        local env = openClient()
        local entry = activeEntry(env)
        local history = entry.History
        equal(entry.historyEnabled, true); assertHint(entry)
        env.command("/HeLp")
        equal(env.historyCalls[#env.historyCalls].text, "/HeLp", "History records the submitted spelling")
        login(env)
        entry = activeEntry(env)
        equal(entry.historyEnabled, true); equal(entry.History, history); assertHint(entry)
        for _, kind in ipairs(kinds) do
            enterFolder(env, kind)
            entry = activeEntry(env)
            equal(entry.historyEnabled, true); equal(entry.History, history); assertHint(entry)
            if entry.OnLoseFocus then entry:OnLoseFocus(); assertHint(entry) end
            env.command("//[terminal]/{_" .. kind.folder .. "}")
            equal(activeEntry(env).History, history); assertHint(activeEntry(env))
        end
        equal(#history, 8, "Navigation and help submissions share the terminal history")
        equal(#env.historyCalls, 8, "Each submitted command must use the native AddHistory API once")
    end)

    test("history uses native duplicate removal and keeps the most recent 20 commands", function()
        local env = openClient()
        local entry = activeEntry(env)
        for i = 1, 25 do env.command("invalid-" .. i) end
        equal(#entry.History, 20)
        equal(entry.History[1], "invalid-6"); equal(entry.History[20], "invalid-25")
        env.command("invalid-10")
        equal(#entry.History, 20)
        equal(entry.History[5], "invalid-11", "Duplicate must be removed from its old location")
        equal(entry.History[20], "invalid-10", "Resubmitted command becomes newest")
        env.command("invalid-10")
        equal(#entry.History, 20)
        equal(#env.historyCalls, 27)
        equal(entry.placeholder, "[ERROR] - INCORRECT COMMAND", "History must preserve the existing invalid-command handler")
    end)

    test("blank and oversized submissions bypass history but retain original command errors", function()
        local env = openClient()
        local entry = activeEntry(env)
        for _, invalid in ipairs({"", " \t ", string.rep("x", 513)}) do
            env.command(invalid)
            equal(#entry.History, 0)
            equal(#env.historyCalls, 0, "Filtered history entries reached native AddHistory")
            equal(entry.placeholder, "[ERROR] - INCORRECT COMMAND")
        end
        local boundary = string.rep("x", 512)
        env.command(boundary)
        equal(entry.History[1], boundary)
        equal(#env.historyCalls, 1)
    end)

    for _, ending in ipairs({"quit", "death", "stage removal"}) do
        test(ending .. " removes help and prevents retained callbacks reopening it", function()
            local env = openClient()
            local entry = activeEntry(env)
            local button = helpButton(env, entry.parent)
            local help = openHelp(env)
            if ending == "quit" then env.command("/q[terminal]")
            elseif ending == "death" then env.receive("PlayerDied", nil)
            else entry.parent:Remove() end
            equal(help.valid, false)
            assertRetired(env, button)
            if ending ~= "stage removal" then env.assertClosed() end
        end)
    end

    test("login stage transition retires help and its retained button callback", function()
        local env = openClient()
        local button = helpButton(env, activeEntry(env).parent)
        local help = openHelp(env)
        env.command("/a[terminal]")
        equal(help.valid, false, "Ordinary commands close the reference window")
        env.fireTimer("AccessDelay")
        assertRetired(env, button)
        equal(activeEntry(env).parent, env.secondPage)
    end)

    for _, kind in ipairs(kinds) do
        test("leaving " .. kind.folder .. " retires help while preserving history", function()
            local env = openClient(kind.folder)
            login(env); enterFolder(env, kind)
            local entry = activeEntry(env)
            local history, button = entry.History, helpButton(env, entry.parent)
            local help = openHelp(env)
            env.command("//[terminal]/{_" .. kind.folder .. "}")
            equal(help.valid, false); assertRetired(env, button)
            equal(activeEntry(env).History, history)
            enterFolder(env, kind)
            equal(activeEntry(env).History, history)
            equal(activeEntry(env).historyEnabled, true)
            env.receive("PlayerDied", nil); env.assertClosed()
        end)

        test(kind.folder .. " manual completion retains timing and packet after consulting help", function()
            local env = openClient(kind.folder)
            login(env); enterFolder(env, kind)
            local button = helpButton(env, activeEntry(env).parent)
            local help = openHelp(env)
            local sent = #env.messages
            env.command(completeCommand(kind))
            equal(help.valid, false)
            if kind.timer then
                equal(env.timers[kind.timer].delay, 2)
                equal(env.timers[kind.timer].repeats, 1)
                equal(#env.messages, sent, "Completion cannot precede the original timer")
                local events = #env.timerEvents
                button:DoClick()
                local countdownHelp = assert(helpWindows(env)[1], "Help remains usable during the download")
                equal(#env.timerEvents, events, "Opening help cannot change the pending download")
                env.fireTimer(kind.timer)
                equal(countdownHelp.valid, false, "Timer completion must remove open help")
            end
            env.assertClosed(); assertRetired(env, button)
            equal(#env.messages, sent + 1, "Completion emits exactly one original packet")
            local packet = assert(env.lastMessage(kind.message))
            equal(#packet.values, 1); equal(packet.values[1].class, "consoleent")
        end)
    end

    test("a new terminal starts fresh history and old help cannot affect it", function()
        local env = openClient()
        local first = activeEntry(env)
        local button = helpButton(env, first.parent)
        openHelp(env)
        env.command("invalid-command")
        env.command("/q[terminal]")
        openClient("data", env)
        local second = activeEntry(env)
        assert(second.History ~= first.History, "A new terminal inherited the old history array")
        equal(#second.History, 0)
        assertRetired(env, button)
        equal(second.parent.valid, true)
        env.receive("PlayerDied", nil); env.assertClosed()
    end)

    for _, kind in ipairs(kinds) do
        test(kind.folder .. " help preserves the server reservation and completion authorization", function()
            local server, client = gmod.new(), gmod.client()
            local owner, hacker, intruder = server.player(), server.player(), server.player()
            local console = server.console(owner)
            local info = server.configure(owner, console, kind.folder, 2)
            if kind.folder == "tools" then
                owner.target = server.entity("func_door")
                server.fire("PlayerSay", owner, "!setEntity")
            end
            server.open(hacker, console)
            local opening = assert(server.lastMessage("ServerSendsEntityInformation"))
            client.receive(opening.name, nil, unpackValues(opening.values))
            local sent = #client.messages
            openHelp(client); login(client); openHelp(client); enterFolder(client, kind); openHelp(client)
            -- Route real client packets to the unchanged server; the original
            -- login reservation packet is the only permitted pre-action packet.
            for i = sent + 1, #client.messages do
                local packet = client.messages[i]
                equal(packet.name, "updateInUse")
                server.receive(packet.name, hacker, unpackValues(packet.values))
            end
            equal(info.inUse, true); equal(console.removed, nil)
            equal(server.lastMessage("SlicerCompleted"), nil)
            server.now = 4
            server.receive(kind.message, intruder, console)
            equal(info.inUse, true); equal(console.removed, nil)
            equal(server.lastMessage("SlicerCompleted"), nil)
            client.command(completeCommand(kind))
            if kind.timer then client.fireTimer(kind.timer) end
            local packet = assert(client.lastMessage(kind.message))
            server.receive(packet.name, hacker, unpackValues(packet.values))
            equal(info.inUse, false); equal(console.removed, true)
            equal(server.lastMessage("SlicerCompleted").player, hacker)
            client.assertClosed()
        end)
    end
end
