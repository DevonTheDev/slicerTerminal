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
            local visible, ancestor = true, panel
            while ancestor do
                if not ancestor.valid or ancestor:IsMarkedForDeletion() or not ancestor:IsVisible() then visible = false end
                ancestor = ancestor.parent
            end
            if visible and panel.OnEnter then return panel end
        end
        error("Missing active command entry")
    end
    local function helpWindows(env)
        local found = {}
        for _, panel in ipairs(env.panels) do
            if panel.valid and not panel:IsMarkedForDeletion() and panel:IsVisible() and panel.class == "DFrame" and (panel.title or ""):match("^Commands") then found[#found + 1] = panel end
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

    local function insertionRows(help)
        local _, scroll = helpText(help)
        local rows, label = {}, nil
        contains(helpText(help), "Insert replaces the current draft. Press Enter to run.")
        for _, child in ipairs(scroll.children) do
            if child.class == "DLabel" and child.text:sub(1, 1) == "/" then
                assert(not label, "Every command label needs its own insertion button")
                label = child
            elseif child.class == "DLabel" then
                equal(child.text, "Insert replaces the current draft. Press Enter to run.")
                equal(child.wrap, true)
                equal(child.autoStretchVertical, true)
            elseif child.class == "DButton" then
                assert(label, "Insertion button must follow its command label")
                equal(child.text, "Insert command", "Insertion action needs a short explicit label")
                equal(child.dock, 1, "Insertion buttons must stack beneath their wrapped labels")
                assert(child.height and child.height >= 24, "Insertion buttons need a usable height")
                rows[#rows + 1] = {command = label.text:match("^([^\n]+)"), button = child}
                label = nil
            end
        end
        assert(not label, "Missing Insert command button beneath the last command label")
        assert(#rows > 0, "Missing explicit Insert command actions")
        return rows
    end
    local function findInsertion(help, command)
        for _, row in ipairs(insertionRows(help)) do
            if row.command == command then return row.button end
        end
        error("Missing Insert command action for " .. command)
    end
    local function snapshot(env, entry)
        return {text = entry.text, position = entry.HistoryPos, history = table.concat(entry.History, "\n"),
            sent = #env.messages, timers = #env.timerEvents, historyCalls = #env.historyCalls,
            focusCalls = #env.focusCalls, caretCalls = #env.caretCalls, caret = entry.caret}
    end
    local function unchanged(env, entry, before)
        equal(entry.text, before.text, "Blocked insertion replaced the draft")
        equal(entry.HistoryPos, before.position, "Blocked insertion moved history")
        equal(entry.caret, before.caret, "Blocked insertion moved the caret")
        equal(#env.focusCalls, before.focusCalls, "Blocked insertion requested focus")
        equal(#env.caretCalls, before.caretCalls, "Blocked insertion called SetCaretPos")
        equal(table.concat(entry.History, "\n"), before.history, "Blocked insertion changed history")
        equal(#env.historyCalls, before.historyCalls)
        equal(#env.messages, before.sent, "Blocked insertion sent a packet")
        equal(#env.timerEvents, before.timers, "Blocked insertion changed timers")
    end
    local function insertCommand(env, command, caret)
        local entry = activeEntry(env)
        entry:SetText("unfinished draft")
        entry.HistoryPos = 3
        helpButton(env, entry.parent):DoClick()
        local help = assert(helpWindows(env)[1])
        local button = findInsertion(help, command)
        equal(button.enabled, true, "A live command input should allow explicit insertion")
        local before = snapshot(env, entry)
        button:DoClick()
        equal(entry:GetValue(), command, "Insertion must replace the whole draft with this exact command")
        equal(entry.HistoryPos, 0, "Insertion must exit history navigation")
        equal(entry.caret, caret or #command, "Caret must end at the command's character count")
        equal(#env.caretCalls, before.caretCalls + 1)
        equal(env.caretCalls[#env.caretCalls].panel, entry)
        equal(#env.focusCalls, before.focusCalls + 1)
        equal(env.focusedPanel, entry)
        equal(help:IsMarkedForDeletion(), true, "Insertion must close its help before returning to typing")
        equal(#helpWindows(env), 0)
        equal(activeEntry(env), entry, "Insertion executed a stage transition before Enter")
        equal(entry.parent.valid, true)
        equal(table.concat(entry.History, "\n"), before.history)
        equal(#env.historyCalls, before.historyCalls, "Only Enter may add inserted text to history")
        equal(#env.messages, before.sent, "Insertion must not send a packet")
        equal(#env.timerEvents, before.timers, "Insertion must not change a timer")
        return entry, button
    end

    local function openFileCommandFlow(target, current)
        local server, client = gmod.new(), gmod.client()
        local owner, hacker = server.player(), server.player()
        local console = server.console(owner)
        local info = assert(server.configure(owner, console, target.folder, 2))
        if target.folder == "tools" then
            owner.target = server.entity("func_door")
            server.fire("PlayerSay", owner, "!setEntity")
        end
        server.open(hacker, console)
        local opening = assert(server.lastMessage("ServerSendsEntityInformation"))
        client.receive(opening.name, nil, unpackValues(opening.values))
        login(client)
        server.now = 2
        enterFolder(client, current or target)
        for _, packet in ipairs(client.messages) do
            equal(packet.name, "updateInUse", "Only reservation traffic may precede the action")
            server.receive(packet.name, hacker, unpackValues(packet.values))
        end
        return server, client, hacker, console, info
    end

    local function finishFileCommandFlow(target, server, client, hacker, console, info)
        local sent, entry = #client.messages, activeEntry(client)
        client.command(completeCommand(target))
        if target.timer then
            local pending = assert(client.timers[target.timer], "Matching file must start its download")
            equal(pending.delay, 2); equal(pending.repeats, 1)
            equal(#client.messages, sent, "The download must not send its completion before its timer")
            client.fire("Think")
            equal(entry.editable, false)
            contains(entry.placeholder, "Time to download: 2 seconds")
            equal(console.removed, nil); equal(info.inUse, true)
            equal(server.lastMessage("SlicerCompleted"), nil)
            server.now = 4
            client.fireTimer(target.timer)
        end
        client.assertClosed()
        equal(#client.messages, sent + 1, "Completion must send exactly one packet")
        local packet = assert(client.lastMessage(target.message))
        equal(packet.values[1], console)
        equal(#client.chatMessages, 0, "A client request alone must not announce success")
        server.receive(packet.name, server.player(), unpackValues(packet.values))
        equal(console.removed, nil, "Another sender must not complete this session")
        equal(info.inUse, true); equal(server.lastMessage("SlicerCompleted"), nil)
        server.receive(packet.name, hacker, unpackValues(packet.values))
        equal(console.removed, true); equal(info.inUse, false)
        local accepted = assert(server.lastMessage("SlicerCompleted"), "The server did not accept recovery")
        equal(accepted.player, hacker)
        if target.folder == "tools" then equal(console.SlicerDoor.inputs[#console.SlicerDoor.inputs], "Unlock") end
        client.receive(accepted.name, nil, unpackValues(accepted.values))
        equal(#client.chatMessages, 1)
    end

    -- These source-loaded callback tests would fail if a mismatched file command
    -- stayed silent, fell through to the typo error, or started an action.
    for _, current in ipairs(kinds) do
        for _, target in ipairs(kinds) do
            if current.folder ~= target.folder then
                test("unavailable file command in " .. current.folder .. " explains refusal and recovers to " .. target.folder, function()
                    local server, client, hacker, console, info = openFileCommandFlow(target, current)
                    local entry = activeEntry(client)
                    local color, setColor = nil, entry.SetPlaceholderColor
                    function entry:SetPlaceholderColor(value) color = value; setColor(self, value) end
                    for i = 1, 22 do client.command("invalid-" .. i) end
                    local sent, events, serverSent = #client.messages, #client.timerEvents, #server.messages
                    local function assertRefused(command)
                        entry:OnGetFocus()
                        entry:SetText(command)
                        color = nil
                        local historyCalls = #client.historyCalls
                        entry:OnEnter()
                        equal(entry.placeholder, "[ERROR] - FILE NOT HERE (/help)", "Unavailable file needs explicit recovery feedback")
                        equal(entry:GetValue(), "", "The rejected draft must clear like an ordinary error")
                        assert(color, "Refusal must set its error color")
                        for i, channel in ipairs({255, 0, 0, 255}) do equal(color[i], channel, "Refusal must use the red error color") end
                        equal(entry.editable, true); equal(entry:IsKeyboardInputEnabled(), true)
                        equal(#entry.History, 20, "Refused commands must stay in bounded history")
                        equal(entry.History[20], command)
                        equal(#client.historyCalls, historyCalls + 1, "Each submission must enter history once")
                        client.fire("Think")
                        equal(entry.placeholder, "[ERROR] - FILE NOT HERE (/help)", "Think must not replace refusal with a countdown")
                        equal(entry.editable, true); equal(entry:IsKeyboardInputEnabled(), true)
                        equal(activeEntry(client), entry, "Refusal must keep the same folder and input")
                        equal(client.timers.DownloadDataFile, nil); equal(client.timers.DownloadServerFile, nil)
                        equal(client.hooks.Think.downloadDataFile, nil); equal(client.hooks.Think.downloadServerFile, nil)
                        equal(#client.timerEvents, events, "Refusal must not create, restart, stop or remove timers")
                        equal(#client.messages, sent, "Refusal must not send any packet")
                        equal(#server.messages, serverSent)
                        equal(console.removed, nil); equal(info.inUse, true)
                        equal(server.lastMessage("SlicerCompleted"), nil)
                        if target.folder == "tools" then equal(console.SlicerDoor.inputs[#console.SlicerDoor.inputs], "Lock") end
                    end
                    local command = completeCommand(current)
                    assertRefused(command)
                    equal(entry.History[1], "invalid-4", "The refused command must evict the oldest history item")
                    assertRefused(string.upper(command))
                    assertRefused(string.upper(command))
                    equal(entry.History[1], "invalid-5", "Repeating the same spelling must not evict another item")
                    -- Submit text recalled from the real history array. Native
                    -- arrow-key dispatch is deliberately outside this host test.
                    equal(entry.History[19], command)
                    assertRefused(entry.History[19])
                    local help, text = openHelp(client)
                    for _, kind in ipairs(kinds) do excludes(text, completeCommand(kind)) end
                    local back = "//[terminal]/{_" .. current.folder .. "}"
                    local historyCalls = #client.historyCalls
                    findInsertion(help, back):DoClick()
                    equal(entry:GetValue(), back); equal(activeEntry(client), entry)
                    equal(#client.historyCalls, historyCalls, "Inserting Return must wait for Enter")
                    equal(#client.timerEvents, events); equal(#client.messages, sent)
                    entry:OnEnter()
                    equal(entry.parent.valid, false); equal(activeEntry(client).parent, client.secondPage)
                    enterFolder(client, target)
                    finishFileCommandFlow(target, server, client, hacker, console, info)
                end)
            end
        end
    end

    for _, target in ipairs(kinds) do
        test("available file command in " .. target.folder .. " retains its authorized completion flow", function()
            finishFileCommandFlow(target, openFileCommandFlow(target))
        end)

        test("available file command in " .. target.folder .. " still cannot complete before the server delay", function()
            local server, client, hacker, console, info = openFileCommandFlow(target)
            client.command(completeCommand(target))
            if target.timer then client.fireTimer(target.timer) end
            local packet = assert(client.lastMessage(target.message))
            server.now = target.timer and 3.99 or 1.99
            server.receive(packet.name, hacker, unpackValues(packet.values))
            equal(console.removed, nil); equal(info.inUse, false)
            equal(server.lastMessage("SlicerCompleted"), nil); equal(#client.chatMessages, 0)
            if target.folder == "tools" then equal(console.SlicerDoor.inputs[#console.SlicerDoor.inputs], "Lock") end
            client.assertClosed()
        end)
    end

    test("unavailable file command typo retains the ordinary error", function()
        local server, client, _, console, info = openFileCommandFlow(kinds[2], kinds[1])
        local entry = activeEntry(client)
        local sent, events = #client.messages, #client.timerEvents
        local command = completeCommand(kinds[1]) .. "-typo"
        client.command(command)
        equal(entry.placeholder, "[ERROR] - INCORRECT COMMAND"); equal(entry:GetValue(), "")
        equal(entry.editable, true); equal(entry.History[#entry.History], command)
        client.fire("Think")
        equal(entry.placeholder, "[ERROR] - INCORRECT COMMAND")
        equal(#client.messages, sent); equal(#client.timerEvents, events)
        equal(console.removed, nil); equal(info.inUse, true)
        equal(server.lastMessage("SlicerCompleted"), nil)
        client.receive("PlayerDied", nil); client.assertClosed()
    end)

    for _, stage in ipairs({"login", "folders", "data", "server", "tools"}) do
        local targets = (stage == "login" or stage == "folders") and {kinds[1]} or kinds
        for _, target in ipairs(targets) do
            test(stage .. " insertion offers exactly its contextual commands for a " .. target.folder .. " target", function()
                local env, commands = openClient(target.folder), {}
                if stage ~= "login" then login(env) end
                if stage == "login" then commands = {"/a[terminal]", "/q[terminal]", "/help"}
                elseif stage == "folders" then
                    commands = {"/a[terminal]/{_data}", "/a[terminal]/{_server}", "/a[terminal]/{_tools}", "/q[terminal]", "/help"}
                else
                    enterFolder(env, {folder = stage})
                    commands = {"//[terminal]/{_" .. stage .. "}"}
                    if target.folder == stage then commands[#commands + 1] = completeCommand(target) end
                    commands[#commands + 1] = "/help"
                end
                helpButton(env, activeEntry(env).parent):DoClick()
                local rows = insertionRows(helpWindows(env)[1])
                equal(#rows, #commands, "Unexpected offered insertion action")
                for i, command in ipairs(commands) do
                    equal(rows[i].command, command)
                    insertCommand(env, command)
                end
                env.receive("PlayerDied", nil); env.assertClosed()
            end)
        end
    end

    for _, names in ipairs({
        {label = "long", name = string.rep("n", 128), file = string.rep("f", 128), nameChars = 128, fileChars = 128},
        {label = "multibyte", name = "终端é", file = "档案🔐", nameChars = 3, fileChars = 3},
        {label = "invalid UTF-8", name = "bad" .. string.char(255), file = "file" .. string.char(192, 128)},
    }) do
        test("insertion preserves " .. names.label .. " configured names and caret position", function()
            local env = openClient("server", nil, names.name, names.file)
            local access = "/a[" .. names.name .. "]"
            local entry = insertCommand(env, access, names.nameChars and names.nameChars + 4 or #access)
            entry:OnEnter(); env.fireTimer("AccessDelay")
            local folder = "/a[" .. names.name .. "]/{_server}"
            entry = insertCommand(env, folder, names.nameChars and names.nameChars + 14 or #folder)
            entry:OnEnter()
            local download = "/d{_server}/" .. names.file .. ".sys"
            insertCommand(env, download, names.fileChars and names.fileChars + 16 or #download)
            env.receive("PlayerDied", nil); env.assertClosed()
        end)
    end

    for _, countdown in ipairs({
        {name = "AccessDelay", start = "/a[terminal]", command = "/q[terminal]"},
        {name = "DownloadDataFile", kind = kinds[1], start = completeCommand(kinds[1]), command = "//[terminal]/{_data}"},
        {name = "DownloadServerFile", kind = kinds[2], start = completeCommand(kinds[2]), command = "//[terminal]/{_server}"},
    }) do
        test(countdown.name .. " blocks insertion before and after the first countdown Think", function()
            local env = openClient(countdown.kind and countdown.kind.folder or "data")
            if countdown.kind then login(env); enterFolder(env, countdown.kind) end
            local entry = activeEntry(env)
            env.command(countdown.start)
            equal(entry:IsKeyboardInputEnabled(), false, "Countdown must lock input before its first Think")
            helpButton(env, entry.parent):DoClick()
            local help = assert(helpWindows(env)[1], "Reference must remain readable during the countdown")
            local button = findInsertion(help, countdown.command)
            equal(button.enabled, false, "Pending countdown must visibly disable insertion immediately")
            local pending, before = env.timers[countdown.name], snapshot(env, entry)
            button:DoClick()
            unchanged(env, entry, before)
            equal(help.valid, true, "Blocked insertion must keep reference available")
            env.fire("Think")
            equal(entry:IsKeyboardInputEnabled(), false)
            if button.Think then button:Think() end
            equal(button.enabled, false)
            before = snapshot(env, entry)
            button:DoClick()
            unchanged(env, entry, before)
            equal(env.timers[countdown.name], pending, "Insertion replaced a pending countdown")
            env.fireTimer(countdown.name)
            if not countdown.kind then env.receive("PlayerDied", nil) end
            env.assertClosed()
        end)
    end

    for _, subject in ipairs({"input", "parent", "help"}) do
        for _, blockedBy in ipairs({"hidden", "deletion", "invalid"}) do
            test(blockedBy .. " " .. subject .. " rejects retained insertion callbacks", function()
                local env = openClient()
                local entry = activeEntry(env)
                entry:SetText("keep this draft"); entry.HistoryPos = 2
                helpButton(env, entry.parent):DoClick()
                local help = helpWindows(env)[1]
                local button = findInsertion(help, "/a[terminal]")
                local target = subject == "input" and entry or subject == "parent" and entry.parent or help
                if blockedBy == "hidden" then target:Hide()
                elseif blockedBy == "deletion" then env.deferPanelRemoval = true; target:Remove()
                else target:Remove() end
                local before = snapshot(env, entry)
                if button.Think then button:Think() end
                equal(button.enabled, false, "Unavailable owner/help must visibly disable insertion")
                button:DoClick()
                unchanged(env, entry, before)
            end)
        end
    end

    for _, subject in ipairs({"input", "parent"}) do
        for _, blockedBy in ipairs({"hidden", "deletion"}) do
            test("ShowCommandHelp rejects " .. blockedBy .. " " .. subject, function()
                local env = openClient()
                local entry = activeEntry(env)
                local button = helpButton(env, entry.parent)
                local target = subject == "input" and entry or entry.parent
                if blockedBy == "hidden" then target:Hide()
                else env.deferPanelRemoval = true; target:Remove() end
                assertRetired(env, button)
            end)
        end
    end

    for _, disable in ipairs({"editable", "keyboard"}) do
        test(disable .. " disabled input rejects insertion while keeping reference readable", function()
            local env = openClient()
            local entry = activeEntry(env)
            helpButton(env, entry.parent):DoClick()
            local help = helpWindows(env)[1]
            local button = findInsertion(help, "/a[terminal]")
            if disable == "editable" then entry:SetEditable(false)
            else entry:SetKeyboardInputEnabled(false); equal(entry.editable, true) end
            if button.Think then button:Think() end
            equal(button.enabled, false)
            local before = snapshot(env, entry)
            button:DoClick(); unchanged(env, entry, before)
            equal(help.valid, true)
        end)
    end

    for _, retirement in ipairs({"hidden", "deferred close"}) do
        test(retirement .. " help is replaced instead of being reused by ShowCommandHelp", function()
            local env = openClient()
            local entry = activeEntry(env)
            local opener = helpButton(env, entry.parent)
            opener:DoClick()
            local first = helpWindows(env)[1]
            if retirement == "hidden" then first:Hide()
            else env.deferPanelRemoval = true; first:Close() end
            equal(first.valid, true, "Race needs an existing native panel before removal flushes")
            opener:DoClick()
            local second = assert(helpWindows(env)[1], "Closed or hidden help must reopen as a fresh frame")
            assert(first ~= second, "ShowCommandHelp reused a hidden or retiring frame")
            local button = findInsertion(second, "/a[terminal]")
            button:DoClick()
            equal(entry:GetValue(), "/a[terminal]")
        end)
    end

    test("closed and reopened help cannot be changed by the old insertion callback", function()
        local env = openClient()
        local entry = activeEntry(env)
        helpButton(env, entry.parent):DoClick()
        local first = helpWindows(env)[1]
        local old = findInsertion(first, "/a[terminal]")
        first:Close()
        helpButton(env, entry.parent):DoClick()
        local second = helpWindows(env)[1]
        assert(second ~= first)
        local before = snapshot(env, entry)
        old:DoClick(); unchanged(env, entry, before)
        equal(second.valid, true, "An old callback closed the newer help")
        findInsertion(second, "/q[terminal]"):DoClick()
        equal(entry:GetValue(), "/q[terminal]")
    end)

    test("hidden folder selection cannot reopen help or reuse an old insertion after returning", function()
        local env = openClient()
        login(env)
        local entry = activeEntry(env)
        local helpOpener = helpButton(env, entry.parent)
        helpOpener:DoClick()
        local old = findInsertion(helpWindows(env)[1], "/a[terminal]/{_tools}")
        enterFolder(env, kinds[1])
        equal(entry:IsVisible(), true, "Native self visibility must expose the hidden-parent race")
        equal(entry.parent:IsVisible(), false)
        assertRetired(env, helpOpener)
        old:DoClick()
        env.command("//[terminal]/{_data}")
        equal(activeEntry(env), entry)
        helpOpener:DoClick()
        local current = helpWindows(env)[1]
        entry:SetText("new draft")
        local before = snapshot(env, entry)
        old:DoClick(); unchanged(env, entry, before)
        equal(current.valid, true)
    end)

    for _, ending in ipairs({"new session", "death", "deferred close"}) do
        test(ending .. " retires insertion callbacks without changing a later draft", function()
            local env = openClient()
            local first = activeEntry(env)
            helpButton(env, first.parent):DoClick()
            local help = helpWindows(env)[1]
            local button = findInsertion(help, "/a[terminal]")
            if ending == "new session" then
                env.command("/q[terminal]"); openClient("data", env)
            elseif ending == "death" then env.receive("PlayerDied", nil)
            else env.deferPanelRemoval = true; help:Close() end
            local entry = ending == "new session" and activeEntry(env) or first
            if entry.valid then entry:SetText("new draft") end
            if ending == "new session" then helpButton(env, entry.parent):DoClick() end
            local current = ending == "new session" and helpWindows(env)[1]
            local before = snapshot(env, entry)
            button:DoClick(); unchanged(env, entry, before)
            if current then equal(current.valid, true) end
        end)
    end

    test("Enter alone submits inserted help and quit commands to their original handlers", function()
        for _, stage in ipairs({"login", "folders"}) do
            local env = openClient()
            if stage == "folders" then login(env) end
            local entry = insertCommand(env, "/help")
            local histories = #env.historyCalls
            entry:OnEnter()
            equal(#env.historyCalls, histories + 1)
            equal(env.historyCalls[#env.historyCalls].text, "/help")
            equal(#helpWindows(env), 1)
            entry = insertCommand(env, "/q[terminal]")
            local sent = #env.messages
            entry:OnEnter()
            equal(#env.messages, sent + 1)
            equal(env.lastMessage("playerQuitConsole").values[2].class, "consoleent")
            env.assertClosed()
        end
    end)

    for _, kind in ipairs(kinds) do
        test(kind.folder .. " inserted commands complete through the actual client and server only after Enter", function()
            local server, client = gmod.new(), gmod.client()
            local owner, hacker, intruder = server.player(), server.player(), server.player()
            local console = server.console(owner)
            local info = server.configure(owner, console, kind.folder, 2)
            local door
            if kind.folder == "tools" then
                door = server.entity("func_door")
                owner.target = door
                server.fire("PlayerSay", owner, "!setEntity")
            end
            server.open(hacker, console)
            local opening = assert(server.lastMessage("ServerSendsEntityInformation"))
            client.receive(opening.name, nil, unpackValues(opening.values))
            local entry = insertCommand(client, "/a[terminal]")
            entry:OnEnter()
            equal(client.timers.AccessDelay.delay, 2)
            client.fireTimer("AccessDelay")
            entry = insertCommand(client, "/a[terminal]/{_" .. kind.folder .. "}")
            entry:OnEnter()
            entry = insertCommand(client, "//[terminal]/{_" .. kind.folder .. "}")
            entry:OnEnter()
            equal(activeEntry(client).parent, client.secondPage)
            entry = insertCommand(client, "/a[terminal]/{_" .. kind.folder .. "}")
            entry:OnEnter()
            entry = insertCommand(client, completeCommand(kind))
            equal(console.removed, nil); equal(info.inUse, true)
            equal(server.lastMessage("SlicerCompleted"), nil)
            equal(client.lastMessage(kind.message), nil)
            server.now = 4
            server.receive(kind.message, intruder, console)
            equal(console.removed, nil); equal(info.inUse, true)
            local histories, sent = #client.historyCalls, #client.messages
            entry:OnEnter()
            equal(#client.historyCalls, histories + 1)
            equal(client.historyCalls[#client.historyCalls].text, completeCommand(kind))
            if kind.timer then
                equal(#client.messages, sent, "Download packet preceded its unchanged delay")
                equal(client.timers[kind.timer].delay, 2)
                client.fireTimer(kind.timer)
            end
            equal(#client.messages, sent + 1)
            local packet = assert(client.lastMessage(kind.message))
            equal(#packet.values, 1); equal(packet.values[1], console)
            server.receive(packet.name, hacker, unpackValues(packet.values))
            equal(info.inUse, false); equal(console.removed, true)
            equal(server.lastMessage("SlicerCompleted").player, hacker)
            if door then equal(door.inputs[#door.inputs], "Unlock") end
            client.assertClosed()
        end)
    end
end
