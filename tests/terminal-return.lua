-- Exercise real client callbacks and server acceptance with the existing API
-- doubles. Native button input, focus, fonts and rendering still need a game.
return function(gmod, test, equal)
    local helper = dofile("tests/player-resize-support.lua")(gmod)
    local unpackValues = table.unpack or unpack
    local kinds = {
        {folder = "data", extension = "data", timer = "DownloadDataFile"},
        {folder = "server", extension = "sys", timer = "DownloadServerFile"},
        {folder = "tools", extension = "exe"},
    }
    local function action(kind)
        return (kind.timer and "/d" or "/r") .. "{_" .. kind.folder .. "}/secret." .. kind.extension
    end
    local function returnCommand(kind) return "//[terminal]/{_" .. kind.folder .. "}" end
    local function openFolder(client, kind)
        local folders = helper.entry(client)
        folders:SetText("/a[terminal]/{_" .. kind.folder .. "}")
        folders:OnEnter()
        local entry = helper.entry(client)
        return entry, helper.button(entry.parent, "Back to folders")
    end
    local function fixture(kind)
        local client, server, hacker, console, info, owner = helper.fixture(640, 480, kind.folder)
        client.sounds = {}
        client.surface.PlaySound = function(sound) client.sounds[#client.sounds + 1] = sound end
        local folders = helper.visit(client, "folders")
        server.now, client.now = 2, 2
        return client, server, hacker, console, info, owner, folders
    end
    local function snapshot(client)
        return {messages = #client.messages, timers = #client.timerEvents, panels = #client.panels,
            history = #client.historyCalls, sounds = #client.sounds, state = #client.stateCalls}
    end
    local function unchanged(client, before)
        local after = snapshot(client)
        for key, value in pairs(before) do equal(after[key], value, "Blocked return changed " .. key) end
    end
    local function completed(client, server, hacker, console, info, owner, kind)
        client.command(action(kind))
        if kind.timer then
            equal(client.timers[kind.timer].delay, 2)
            client.fireTimer(kind.timer)
        end
        client.assertClosed()
        equal(#client.chatMessages, 0, "Only server acceptance announces completion")
        local packet = assert(client.lastMessage(kind.timer and "destroyOnServer" or "PlayerActivatedDoor"))
        server.now = kind.timer and 4 or 2 -- The original reservation deadline.
        server.receive(packet.name, hacker, unpackValues(packet.values))
        equal(console.removed, true); equal(info.inUse, false)
        if kind.folder == "tools" then equal(owner.target.inputs[#owner.target.inputs], "Unlock") end
        helper.deliver(client, assert(server.lastMessage("SlicerCompleted")))
        equal(#client.chatMessages, 1)
    end

    for _, stage in ipairs({"login", "folders"}) do
        test("Back to folders is absent on " .. stage, function()
            local client = helper.fixture(640, 480)
            local entry = helper.visit(client, stage)
            equal(#helper.children(entry.parent, function(p) return p.text == "Back to folders" end), 0)
        end)
    end

    for index, kind in ipairs(kinds) do
        test(kind.folder .. " recovers from the wrong folder and completes at the original deadline", function()
            local client, server, hacker, console, info, owner, folders = fixture(kind)
            local wrong = kinds[index % #kinds + 1]
            local entry, back = openFolder(client, wrong)
            client.command(action(wrong))
            equal(entry.placeholder, "[ERROR] - FILE NOT HERE (/help)")
            local help = helper.help(client, entry)
            local sent = #client.messages
            back:DoClick()
            equal(helper.entry(client), folders, "Return reveals the same folder-selection input")
            equal(folders:GetValue(), ""); equal(folders.placeholder, "Run commands here... (/help | Up/Down history)")
            equal(entry.valid, false); equal(help.valid, false)
            equal(client.timers.dataPageGlitch, nil); equal(client.timers.dataPageReturn, nil)
            equal(client.timers.secondPageGlitch.stopped, false)
            equal(#client.messages, sent, "Navigation sends no packets")
            equal(info.inUse, true, "Navigation keeps the server reservation")
            local correct, correctBack = openFolder(client, kind)
            completed(client, server, hacker, console, info, owner, kind)
            local before = snapshot(client)
            correctBack:DoClick(); correct:OnEnter(); correctBack:Think()
            unchanged(client, before)
        end)

        test(kind.folder .. " button and typed return share cleanup across repeated visits", function()
            local client, _, _, _, _, _, folders = fixture(kind)
            for visit = 1, 3 do
                local entry, back = openFolder(client, kind)
                local help = helper.help(client, entry)
                -- Create the delayed glitch reset too, so both names must retire.
                client.timers.dataPageGlitch.callback()
                assert(client.timers.dataPageReturn)
                entry:SetText(returnCommand(kind))
                if visit == 2 then entry:OnEnter() else back:DoClick() end
                equal(helper.entry(client), folders); equal(folders:GetValue(), "")
                equal(help.valid, false); equal(entry.valid, false)
                equal(client.timers.dataPageGlitch, nil); equal(client.timers.dataPageReturn, nil)
                local before = snapshot(client)
                back:DoClick(); entry:OnEnter(); back:Think()
                unchanged(client, before)
            end
            helper.button(folders.parent, "Quit terminal"):DoClick()
            client.assertClosed()
        end)

        test(kind.folder .. " retained returns cannot affect return, quit, death or replacement", function()
            for _, reason in ipairs({"return", "quit", "death", "replacement"}) do
                local client, server = fixture(kind)
                local entry, back = openFolder(client, kind)
                entry:SetText(returnCommand(kind))
                client.deferPanelRemoval = true
                if reason == "return" then back:DoClick(); openFolder(client, kind)
                elseif reason == "quit" then helper.button(entry.parent, "Quit terminal"):DoClick()
                elseif reason == "death" then client.receive("PlayerDied", nil)
                else helper.deliver(client, assert(server.lastMessage("ServerSendsEntityInformation"))) end
                local current = (reason == "return" or reason == "replacement") and helper.entry(client)
                local help = current and helper.help(client, current)
                local before = snapshot(client)
                back:DoClick(); entry:OnEnter(); back:Think()
                unchanged(client, before)
                if current then equal(helper.entry(client), current); equal(helper.live(help), true) end
            end
        end)

        test(kind.folder .. " return rejects hidden, removed and deletion-marked controls", function()
            for _, target in ipairs({"page", "input", "button"}) do
                for _, state in ipairs({"hidden", "removed", "deletion-marked"}) do
                    local client, _, _, _, _, _, folders = fixture(kind)
                    local entry, back = openFolder(client, kind)
                    entry:SetText(returnCommand(kind))
                    local panel = target == "page" and entry.parent or (target == "input" and entry or back)
                    if state == "hidden" then panel:Hide()
                    elseif state == "removed" then panel:Remove()
                    else client.deferPanelRemoval = true; panel:Remove() end
                    local before = snapshot(client)
                    back:DoClick()
                    -- Hiding/removing only the button does not retire typed navigation.
                    if target ~= "button" then entry:OnEnter() end
                    unchanged(client, before)
                    equal(folders.parent.hidden, true, "Invalid return cannot reveal folders")
                end
            end
        end)
    end

    for _, kind in ipairs({kinds[1], kinds[2]}) do
        test(kind.folder .. " download rejects Back before and after first Think", function()
            local client, server, hacker, console, info, owner, folders = fixture(kind)
            local entry, back = openFolder(client, kind)
            client.command(action(kind))
            local pending = assert(client.timers[kind.timer])
            equal(back.enabled, false, "Disable Back synchronously when a download starts")
            for _, afterThink in ipairs({false, true}) do
                if afterThink then client.fire("Think"); back:Think() end
                entry:SetText(returnCommand(kind))
                local help = helper.help(client, entry)
                local before = snapshot(client)
                back:DoClick(); entry:OnEnter()
                unchanged(client, before)
                equal(back.enabled, false); equal(client.timers[kind.timer], pending)
                equal(helper.entry(client), entry); equal(folders.parent.hidden, true)
                equal(helper.live(help), true, "Blocked navigation keeps Commands readable")
                assert(helper.button(entry.parent, "Quit terminal").enabled ~= false)
            end
            client.fireTimer(kind.timer)
            client.assertClosed()
            local before = snapshot(client)
            back:DoClick(); entry:OnEnter(); back:Think()
            unchanged(client, before)
            local packet = assert(client.lastMessage("destroyOnServer"))
            server.now = 4
            server.receive(packet.name, hacker, unpackValues(packet.values))
            equal(console.removed, true); equal(info.inUse, false)
        end)
    end

    for _, kind in ipairs(kinds) do
        for _, method in ipairs({"button", "typed"}) do
            for _, withHelp in ipairs({false, true}) do
                test(kind.folder .. " " .. method .. " return requests command focus with help " .. tostring(withHelp), function()
                    local client, _, _, _, _, _, folders = fixture(kind)
                    local entry, back = openFolder(client, kind)
                    local help = withHelp and helper.help(client, entry)
                    local session = helper.upvalue(entry.IsCurrentTerminalPage, "session")
                    local history, historyCalls = folders.History, #client.historyCalls
                    local focusCalls, messages, sounds = #client.focusCalls, #client.messages, #client.sounds
                    local requestFocus = folders.RequestFocus
                    function folders:RequestFocus()
                        equal(helper.live(self), true, "Reveal the retained entry before requesting focus")
                        equal(entry:IsMarkedForDeletion(), true, "Retire the previous page before requesting focus")
                        for _, name in ipairs({"data", "server", "tools"}) do
                            local button = assert(session.pages.folders.folderButtons[name], "Missing refreshed folder control")
                            equal(helper.live(button), true,
                                "Refresh folder controls before requesting focus")
                        end
                        requestFocus(self)
                    end
                    if method == "typed" then
                        entry:SetText(returnCommand(kind))
                        entry:OnEnter()
                    else back:DoClick() end
                    equal(#client.focusCalls, focusCalls + 1, "Successful return requests focus exactly once")
                    equal(client.focusCalls[#client.focusCalls], folders, "Focus belongs to the retained command entry")
                    equal(helper.entry(client), folders); equal(folders:GetValue(), "")
                    equal(folders.History, history, "Focus must preserve shared command history")
                    equal(#client.historyCalls, historyCalls + (method == "typed" and 1 or 0))
                    equal(#client.sounds, sounds + (method == "typed" and 1 or 0))
                    equal(#client.messages, messages, "Focus must not submit or send a packet")
                    if help then equal(help.valid, false) end
                end)
            end
        end
    end

    for _, state in ipairs({"hidden frame", "hidden input", "marked input", "disabled input",
        "keyboard disabled", "replaced folder record", "replaced session"}) do
        test("return skips its final focus request for " .. state, function()
            local client, server, _, _, _, _, folders = fixture(kinds[1])
            local entry, back = openFolder(client, kinds[1])
            local session = helper.upvalue(entry.IsCurrentTerminalPage, "session")
            local folderPage = session.pages.folders
            local refresh = folderPage.RefreshFolderButtons
            folderPage.RefreshFolderButtons = function()
                refresh()
                if state == "hidden frame" then folders.parent:Hide()
                elseif state == "hidden input" then folders:Hide()
                elseif state == "marked input" then folders.markedForDeletion = true
                elseif state == "disabled input" then folders:SetEnabled(false)
                elseif state == "keyboard disabled" then folders:SetKeyboardInputEnabled(false)
                elseif state == "replaced folder record" then session.pages.folders = {frame = folders.parent, input = folders}
                else helper.deliver(client, assert(server.lastMessage("ServerSendsEntityInformation"))) end
            end
            local focusCalls = #client.focusCalls
            back:DoClick()
            equal(#client.focusCalls, focusCalls, "Recheck the destination immediately before requesting focus")
        end)
    end

    test("return requires the exact registered file page and a live folder destination", function()
        for _, invalid in ipairs({"file record", "folder frame", "folder input"}) do
            local client, _, _, _, _, _, folders = fixture(kinds[1])
            local entry, back = openFolder(client, kinds[1])
            local session = helper.upvalue(entry.IsCurrentTerminalPage, "session")
            entry:SetText(returnCommand(kinds[1]))
            if invalid == "file record" then session.pages.data = {frame = entry.parent}
            elseif invalid == "folder frame" then folders.parent.markedForDeletion = true
            else folders.markedForDeletion = true end
            local before = snapshot(client)
            back:DoClick(); entry.ReturnToFolders()
            if invalid == "file record" then entry:OnEnter() end
            unchanged(client, before)
            equal(folders.parent.hidden, true)
        end
    end)
end
