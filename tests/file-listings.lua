-- Run real setup, file-page and completion callbacks. Panel flags/data are
-- observable here; native Derma editing, focus and rendering need a game test.
return function(gmod, test, equal)
    local unpackValues = table.unpack or unpack
    local kinds = {
        {folder = "data", extension = "data", timer = "DownloadDataFile", message = "destroyOnServer"},
        {folder = "server", extension = "sys", timer = "DownloadServerFile", message = "destroyOnServer"},
        {folder = "tools", extension = "exe", message = "PlayerActivatedDoor"},
    }
    local function deliver(client, packet)
        assert(packet, "Missing server packet")
        client.receive(packet.name, nil, unpackValues(packet.values))
    end
    local function activeEntry(client)
        for i = #client.panels, 1, -1 do
            local panel, visible = client.panels[i], true
            local ancestor = panel
            while ancestor do
                if not ancestor.valid or ancestor:IsMarkedForDeletion() or not ancestor:IsVisible() then visible = false end
                ancestor = ancestor.parent
            end
            if visible and panel.OnEnter then return panel end
        end
        error("Missing active command input")
    end
    local function login(session)
        local server, client = session.server, session.client
        server.open(session.hacker, session.console)
        deliver(client, server.lastMessage("ServerSendsEntityInformation"))
        client.command("/a[terminal]")
        equal(client.timers.AccessDelay.delay, 2)
        client.fireTimer("AccessDelay")
        server.now = server.now + 2
    end
    local function fixture(kind, file)
        local server, client = gmod.new(), gmod.client()
        local create = client.vgui.Create
        client.vgui.Create = function(class, parent)
            local panel = create(class, parent)
            local setText = panel.SetText
            function panel:SetText(value)
                self.textWrites = (self.textWrites or 0) + 1
                return setText(self, value)
            end
            return panel
        end
        local owner, hacker = server.player(), server.player()
        local console = server.console(owner)
        server.receive("AdminFinishedCreation", owner, {"Terminal", 2, kind.folder, file, console:GetName()})
        local info = assert(console.SlicerInformation, "Normal server setup rejected the fixture")
        equal(info.fileName, string.lower(server.string.Trim(file)), "Setup normalization must reach the client")
        local door
        if kind.folder == "tools" then
            door = server.entity("func_door")
            owner.target = door
            server.fire("PlayerSay", owner, "!setEntity")
            equal(door.inputs[#door.inputs], "Lock")
        end
        local session = {server = server, client = client, hacker = hacker, console = console, info = info, door = door, kind = kind}
        login(session)
        return session
    end
    local function enter(session, folder)
        session.client.command("/a[terminal]/{_" .. (folder or session.kind.folder) .. "}")
        return activeEntry(session.client)
    end
    local function rows(entry)
        local found = {}
        for _, panel in ipairs(entry.parent.children) do
            if panel.class == "DTextEntry" and not panel.OnEnter then found[#found + 1] = panel end
        end
        equal(#found, 3, "A file page must retain its three display rows")
        return found
    end
    local function snapshot(entry)
        local values = {}
        for _, row in ipairs(rows(entry)) do values[#values + 1] = row:GetValue() end
        return table.concat(values, "\n")
    end
    local function action(kind, file)
        return (kind.timer and "/d" or "/r") .. "{_" .. kind.folder .. "}/" .. file .. "." .. kind.extension
    end
    local function helpCommands(client)
        activeEntry(client).ShowCommandHelp()
        local commands = {}
        for _, panel in ipairs(client.panels) do
            if panel.valid and not panel:IsMarkedForDeletion() and panel.class == "DScrollPanel" and panel.parent.valid then
                local command
                for _, child in ipairs(panel.children) do
                    if child.class == "DLabel" then command = child:GetValue():match("^([^\n]+)\n") end
                    if child.class == "DButton" and child.text == "Insert command" then commands[assert(command)] = child end
                end
            end
        end
        return commands
    end
    local function finish(session)
        local server, client, kind = session.server, session.client, session.kind
        local entry = activeEntry(client)
        local command = action(kind, session.info.fileName)
        local insert = assert(helpCommands(client)[command], "Target folder must retain its action help")
        local sent, timers, history = #client.messages, #client.timerEvents, #client.historyCalls
        insert:DoClick()
        equal(entry:GetValue(), command)
        equal(entry.editable, true, "The real command input must remain editable")
        equal(#client.messages, sent, "Insertion must only draft the command")
        equal(#client.timerEvents, timers)
        equal(#client.historyCalls, history)
        equal(session.info.inUse, true); equal(session.console.removed, nil)
        entry:OnEnter()
        equal(#client.historyCalls, history + 1)
        equal(client.historyCalls[#client.historyCalls].text, command)
        if kind.timer then
            equal(client.timers[kind.timer].delay, 2)
            equal(#client.messages, sent, "Downloads must retain their second delay")
            client.fireTimer(kind.timer)
            server.now = server.now + 2
        end
        local packet = assert(client.lastMessage(kind.message))
        equal(#client.messages, sent + 1)
        equal(#packet.values, 1); equal(packet.values[1], session.console)
        equal(server.lastMessage("SlicerCompleted"), nil, "The client cannot accept its own completion")
        server.receive(packet.name, session.hacker, unpackValues(packet.values))
        local accepted = assert(server.lastMessage("SlicerCompleted"), "The real server rejected the configured target")
        equal(accepted.player, session.hacker)
        equal(session.console.removed, true); equal(session.info.inUse, false)
        if session.door then equal(session.door.inputs[#session.door.inputs], "Unlock") end
        deliver(client, accepted)
        equal(#client.chatMessages, 1)
        client.assertClosed()
    end

    for _, kind in ipairs(kinds) do
        for _, file in ipairs({"Secret", "hitlist", "HiTlIsT", "consolelogs", "ConsoleLogs", "important", "ImPoRtAnT"}) do
            test(kind.folder .. " listing keeps distinct basenames after normal setup of " .. file, function()
                local session = fixture(kind, file)
                local listing = rows(enter(session))
                local seen, pool = {}, {hitlist = true, consoleLogs = true, important = true}
                for index, row in ipairs(listing) do
                    local name, extension = row:GetValue():match("^(.+)%.([^%.]+)$")
                    assert(name, "File row " .. index .. " is empty or has no suffix")
                    local normalized = string.lower(name)
                    assert(not seen[normalized], "Repeated case-insensitive basename: " .. normalized)
                    seen[normalized] = true
                    local suffix = kind.folder == "tools" and index == 3 and "sys" or kind.extension
                    equal(extension, suffix, "Preserve each existing row suffix")
                    if index == 1 then
                        equal(name, string.upper(session.info.fileName), "Preserve the uppercase target marker")
                    else
                        assert(pool[name], "Decoys must use the existing filename vocabulary")
                        assert(normalized ~= session.info.fileName, "A decoy duplicates the configured target")
                    end
                end
                equal(seen[session.info.fileName], true)
                session.client.receive("PlayerDied", nil); session.client.assertClosed()
            end)
        end

        test(kind.folder .. " file rows are read-only while its command input stays editable", function()
            local session = fixture(kind, "Secret")
            local entry = enter(session)
            for _, row in ipairs(rows(entry)) do
                equal(row.editable, false, "Display-only filenames must not accept edits")
                equal(row:IsKeyboardInputEnabled(), false)
                equal(row.textWrites, 1, "Populate each existing display row once")
            end
            equal(entry.editable, true); equal(entry:IsKeyboardInputEnabled(), true)
            entry:SetText("unfinished command")
            equal(entry:GetValue(), "unfinished command")
            equal(session.info.fileName, "secret")
            session.client.receive("PlayerDied", nil); session.client.assertClosed()
        end)

        test(kind.folder .. " listings survive reentry and independent sessions unchanged", function()
            local first, second = fixture(kind, "ConsoleLogs"), fixture(kind, "HiTlIsT")
            local expectedFirst, expectedSecond = snapshot(enter(first)), snapshot(enter(second))
            for _ = 1, 3 do
                for _, session in ipairs({first, second}) do
                    session.client.command("//[terminal]/{_" .. kind.folder .. "}")
                    equal(snapshot(enter(session)), session == first and expectedFirst or expectedSecond)
                    equal(session.info.fileName, session == first and "consolelogs" or "hitlist")
                    equal(session.info.inUse, true); equal(session.console.removed, nil)
                end
            end
            activeEntry(first.client).QuitTerminal()
            local quit = assert(first.client.lastMessage("playerQuitConsole"))
            first.server.receive(quit.name, first.hacker, unpackValues(quit.values))
            equal(first.info.inUse, false)
            first.client.assertClosed()
            login(first)
            equal(snapshot(enter(first)), expectedFirst, "A fresh session must not inherit a consumed pool")
            equal(snapshot(activeEntry(second.client)), expectedSecond, "Another client's listing changed")
            finish(first); finish(second)
        end)
    end

    local wrongRows = {
        data = "consoleLogs.data\nrecentlyDeleted.data\ncleaningLog.data",
        server = "updateCheck.sys\nconnections.sys\nidCheck.sys",
        tools = "mainControl.exe\nwashingMachine.exe\nbreathing.exe",
    }
    for _, case in ipairs({
        {target = kinds[2], wrong = kinds[1], file = "ConsoleLogs"},
        {target = kinds[3], wrong = kinds[2], file = "UpdateCheck"},
        {target = kinds[1], wrong = kinds[3], file = "MainControl"},
    }) do
        test(case.wrong.folder .. " preserves same-basename distractors and refuses the wrong-folder action", function()
            local session = fixture(case.target, case.file)
            local client = session.client
            local entry = enter(session, case.wrong.folder)
            equal(snapshot(entry), wrongRows[case.wrong.folder], "Wrong-folder distractors must remain unchanged")
            for _, row in ipairs(rows(entry)) do equal(row.editable, false) end
            local commands = helpCommands(client)
            equal(commands[action(case.target, session.info.fileName)], nil)
            equal(commands[action(case.wrong, session.info.fileName)], nil)
            assert(commands["//[terminal]/{_" .. case.wrong.folder .. "}"], "Wrong-folder help must retain Return")
            local sent, timers = #client.messages, #client.timerEvents
            client.command(action(case.wrong, session.info.fileName))
            equal(entry.placeholder, "[ERROR] - FILE NOT HERE (/help)")
            equal(entry:GetValue(), ""); equal(entry.editable, true)
            equal(#client.messages, sent); equal(#client.timerEvents, timers)
            equal(session.console.removed, nil); equal(session.info.inUse, true)
            equal(session.server.lastMessage("SlicerCompleted"), nil)
            client.command("//[terminal]/{_" .. case.wrong.folder .. "}")
            enter(session)
            finish(session)
        end)
    end
end
