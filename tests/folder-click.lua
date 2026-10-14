-- Real client callbacks with local API doubles only. This does not establish
-- native mouse hit testing, focus, hover rendering, fonts or multiplayer input.
return function(gmod, test, equal)
    local helper = dofile("tests/player-resize-support.lua")(gmod)
    local kinds = {"data", "server", "tools"}
    local extensions = {data = "data", server = "sys", tools = "exe"}
    local wrongRows = {
        data = "consoleLogs.data|recentlyDeleted.data|cleaningLog.data",
        server = "updateCheck.sys|connections.sys|idCheck.sys",
        tools = "mainControl.exe|washingMachine.exe|breathing.exe",
    }
    local function command(folder) return "/a[terminal]/{_" .. folder .. "}" end
    local function fixture(target)
        local client, server = helper.fixture(640, 480, target)
        client.sounds = {}
        client.surface.PlaySound = function(sound) client.sounds[#client.sounds + 1] = sound end
        local folders = helper.visit(client, "folders")
        return client, folders, server
    end
    local function buttons(entry)
        local found = {}
        for _, panel in ipairs(helper.children(entry.parent, function(p)
            return p.class == "DButton" and p.tooltip and p.tooltip:match("^Open .+ folder$")
        end)) do
            found[panel.tooltip:match("^Open (.+) folder$")] = panel
        end
        return found
    end
    local function click(entry, folder)
        local button = assert(buttons(entry)[folder], "Missing " .. folder .. " folder button")
        button:DoClick()
        return button
    end
    local function rows(entry)
        local found = {}
        for _, row in ipairs(helper.children(entry.parent, function(p)
            return p.class == "DTextEntry" and not p.OnEnter
        end)) do
            equal(row.editable, false, "File names remain read-only")
            equal(row.DoClick, nil, "No file action shortcut")
            found[#found + 1] = row:GetValue()
        end
        equal(#found, 3)
        return table.concat(found, "|")
    end
    local function snapshot(client)
        return {messages = #client.messages, timers = #client.timerEvents, panels = #client.panels,
            history = #client.historyCalls, sounds = #client.sounds, state = #client.stateCalls,
            geometry = #client.geometryCalls, focus = #client.focusCalls, caret = #client.caretCalls}
    end
    local function unchanged(client, before)
        local after = snapshot(client)
        for key, value in pairs(before) do equal(after[key], value, "Rejected click changed " .. key) end
    end
    local function insertFor(client, entry, text)
        local help = helper.help(client, entry)
        local scroll = assert(helper.children(help, function(p) return p.class == "DScrollPanel" end)[1])
        local preceding
        for _, child in ipairs(scroll.children) do
            if child.class == "DLabel" then preceding = child.text:match("^([^\n]+)\n") end
            if child.text == "Insert command" and preceding == text then return child, help end
        end
        error("Missing command insertion: " .. text)
    end

    for _, folder in ipairs(kinds) do
        test("folder click opens exact " .. folder .. " listing for every target type", function()
            for _, target in ipairs(kinds) do
                local client, folders = fixture(target)
                local help = helper.help(client, folders)
                folders:SetText("draft to replace")
                local before = snapshot(client)
                local stale = click(folders, folder)
                local entry = helper.entry(client)
                assert(entry ~= folders)
                equal(folders.parent.hidden, true)
                equal(help.valid, false, "Navigation closes Commands")
                equal(#client.historyCalls, before.history + 1)
                equal(client.historyCalls[#client.historyCalls].text, command(folder))
                equal(entry.History, folders.History)
                equal(#client.sounds, before.sounds + 1)
                equal(client.sounds[#client.sounds], "code_enter.wav")
                equal(#client.messages, before.messages, "Opening a folder sends no packet")
                equal(client.timers.AccessDelay, nil)
                equal(client.timers.DownloadDataFile, nil)
                equal(client.timers.DownloadServerFile, nil)
                equal(client.timers.secondPageGlitch.stopped, true)
                assert(client.timers.dataPageGlitch)
                local suffix = extensions[folder]
                local expected = folder == target and ("SECRET." .. suffix .. "|hitlist." .. suffix
                    .. "|consoleLogs." .. (folder == "tools" and "sys" or suffix)) or wrongRows[folder]
                equal(rows(entry), expected, "Preserve metadata/decoy names and original suffixes")
                local typed, typedFolders = fixture(target)
                typedFolders:SetText(command(folder)); typedFolders:OnEnter()
                equal(rows(helper.entry(typed)), rows(entry), "Click and typed navigation agree")
                before = snapshot(client)
                stale:DoClick()
                unchanged(client, before)
            end
        end)

        test("folder click returns with fresh " .. folder .. " controls and bounded layout registrations", function()
            local client, folders = fixture(folder)
            local session = helper.upvalue(folders.IsCurrentTerminalPage, "session")
            local geometryCount = #session.pages.folders.geometry
            for visit = 1, 3 do
                local previous = buttons(folders)
                local old = click(folders, folder)
                local entry = helper.entry(client)
                local help = helper.help(client, entry)
                client.timers.dataPageGlitch.callback()
                if visit == 2 then
                    entry:SetText("//[terminal]/{_" .. folder .. "}"); entry:OnEnter()
                else helper.button(entry.parent, "Back to folders"):DoClick() end
                equal(helper.entry(client), folders)
                equal(folders:GetValue(), "")
                equal(help.valid, false)
                equal(client.timers.dataPageGlitch, nil)
                equal(client.timers.dataPageReturn, nil)
                equal(client.timers.secondPageGlitch.stopped, false)
                equal(#session.pages.folders.geometry, geometryCount, "Do not accumulate geometry closures")
                local current = buttons(folders)
                for _, name in ipairs(kinds) do
                    assert(current[name] and current[name] ~= previous[name], "Back needs a fresh " .. name .. " button")
                    assert(previous[name]:IsMarkedForDeletion())
                end
                local before = snapshot(client)
                old:DoClick()
                unchanged(client, before)
            end
            helper.button(folders.parent, "Quit terminal"):DoClick()
            client.assertClosed()
        end)

        test("folder picker still only inserts the " .. folder .. " command", function()
            local client, folders = fixture(folder)
            local stale = assert(buttons(folders)[folder])
            local insert, help = insertFor(client, folders, command(folder))
            local before = snapshot(client)
            insert:DoClick()
            equal(folders:GetValue(), command(folder))
            equal(helper.entry(client), folders)
            equal(help.valid, false)
            equal(#client.historyCalls, before.history)
            equal(#client.messages, before.messages)
            equal(#client.timerEvents, before.timers)
            equal(#client.sounds, before.sounds)
            folders:OnEnter()
            assert(helper.entry(client) ~= folders)
            equal(client.historyCalls[#client.historyCalls].text, command(folder))
            before = snapshot(client); stale:DoClick(); unchanged(client, before)
        end)

        test("retained " .. folder .. " clicks cannot navigate after return quit death or replacement", function()
            for _, reason in ipairs({"navigation", "return", "quit", "death", "replacement"}) do
                local client, folders, server = fixture(folder)
                local retained = buttons(folders)
                client.deferPanelRemoval = true
                if reason == "navigation" or reason == "return" then
                    folders:SetText(command(folder)); folders:OnEnter()
                    if reason == "return" then
                        helper.button(helper.entry(client).parent, "Back to folders"):DoClick()
                    end
                elseif reason == "quit" then helper.button(folders.parent, "Quit terminal"):DoClick()
                elseif reason == "death" then client.receive("PlayerDied", nil)
                else helper.deliver(client, assert(server.lastMessage("ServerSendsEntityInformation"))) end
                local current = (reason == "navigation" or reason == "return" or reason == "replacement")
                    and helper.entry(client)
                local help = current and helper.help(client, current)
                local before = snapshot(client)
                for _, button in pairs(retained) do button:DoClick() end
                unchanged(client, before)
                if current then equal(helper.entry(client), current); assert(helper.live(help)) end
            end
        end)

        test("folder click guards reject invalid " .. folder .. " controls before draft or history changes", function()
            for _, target in ipairs({"button", "input", "page"}) do
                for _, state in ipairs({"hidden", "removed", "deletion-marked"}) do
                    local client, folders = fixture(folder)
                    local button = assert(buttons(folders)[folder])
                    local panel = target == "button" and button or (target == "input" and folders or folders.parent)
                    if state == "hidden" then panel:Hide()
                    elseif state == "removed" then panel:Remove()
                    else client.deferPanelRemoval = true; panel:Remove() end
                    local before = snapshot(client); button:DoClick(); unchanged(client, before)
                end
            end
            for _, lock in ipairs({"keyboard", "button", "AccessDelay", "DownloadDataFile", "DownloadServerFile"}) do
                local client, folders = fixture(folder)
                local button = assert(buttons(folders)[folder])
                folders:SetText("keep this draft")
                if lock == "keyboard" then folders:SetKeyboardInputEnabled(false)
                elseif lock == "button" then button:SetEnabled(false)
                else client.timer.Create(lock, 2, 1, function() error("Do not fire this sentinel timer") end) end
                local before = snapshot(client); button:DoClick(); unchanged(client, before)
                equal(folders:GetValue(), "keep this draft")
            end
        end)
    end

    test("folder click requires the exact registered folder page", function()
        local client, folders = fixture("data")
        local retained = buttons(folders)
        local session = helper.upvalue(folders.IsCurrentTerminalPage, "session")
        session.pages.folders = {frame = folders.parent, input = folders}
        local before = snapshot(client)
        for _, button in pairs(retained) do button:DoClick() end
        unchanged(client, before)
    end)

    test("folder buttons retire ownership before a removal callback can click a sibling", function()
        local client, folders = fixture("data")
        local retained = buttons(folders)
        for _, button in pairs(retained) do
            button.OnRemove = function()
                local before = snapshot(client)
                for _, sibling in pairs(retained) do sibling:DoClick() end
                unchanged(client, before)
            end
        end
        local before = snapshot(client)
        click(folders, "data")
        equal(#client.historyCalls, before.history + 1)
        equal(#client.messages, before.messages)
        equal(rows(helper.entry(client)), "SECRET.data|hitlist.data|consoleLogs.data")
    end)

    test("folder hit targets follow existing artwork after resize and expose hover affordances", function()
        local client, folders = fixture("data")
        local paintCalls = {}
        client.draw = {RoundedBox = function(...) paintCalls[#paintCalls + 1] = {...} end}
        local function check()
            local images = {}
            for _, panel in ipairs(folders.parent.children) do
                if panel.class == "DImage" and panel.image then images[panel.image] = panel end
            end
            for index, folder in ipairs(kinds) do
                local button = assert(buttons(folders)[folder])
                local image = assert(images["vgui/folder" .. index .. ".png"])
                equal(button.x, image.x); equal(button.y, image.y)
                equal(button.width, image.width); equal(button.height, image.height)
                equal(button.cursor, "hand"); equal(button.text, "")
                assert(button.y + button.height < folders.y)
                local count = #paintCalls
                button.hovered = false; button:Paint(button.width, button.height)
                equal(#paintCalls, count)
                button.hovered = true; button:Paint(button.width, button.height)
                equal(#paintCalls, count + 1, "A hovered live folder gets visual feedback")
            end
        end
        check(); client.resize(1920, 1080); check()
        click(folders, "tools")
        client.resize(800, 600)
        helper.button(helper.entry(client).parent, "Back to folders"):DoClick()
        check()
    end)
end
