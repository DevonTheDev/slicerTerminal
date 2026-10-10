-- Exercise the production callbacks before native Think has had a chance to
-- run. API doubles cover ordering and ownership, not native keyboard dispatch.
return function(gmod, test, equal)
    local countdowns = {
        {stage = "login", folder = "data", timer = "AccessDelay", think = "printDelay", command = "/a[terminal]", leave = "/q[terminal]"},
        {stage = "data", folder = "data", timer = "DownloadDataFile", think = "downloadDataFile", command = "/d{_data}/secret.data", leave = "//[terminal]/{_data}"},
        {stage = "server", folder = "server", timer = "DownloadServerFile", think = "downloadServerFile", command = "/d{_server}/secret.sys", leave = "//[terminal]/{_server}"},
    }
    local unpackValues = table.unpack or unpack
    local function activeEntry(client)
        for i = #client.panels, 1, -1 do
            local panel, live = client.panels[i], true
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
        error("Missing " .. text .. " button")
    end
    local function relayOpening(server, client)
        local packet = assert(server.lastMessage("ServerSendsEntityInformation"))
        client.receive(packet.name, nil, unpackValues(packet.values))
    end
    local function fixture(countdown)
        local server, client = gmod.new(), gmod.client()
        local owner, hacker = server.player(), server.player()
        local console = server.console(owner)
        local info = assert(server.configure(owner, console, countdown.folder, 2))
        server.open(hacker, console)
        relayOpening(server, client)
        client.sounds = {}
        client.surface.PlaySound = function(sound) client.sounds[#client.sounds + 1] = sound end
        if countdown.stage ~= "login" then
            client.command("/a[terminal]")
            client.fireTimer("AccessDelay")
            server.now, client.now = 2, 2
            client.command("/a[terminal]/{_" .. countdown.folder .. "}")
        end
        return server, client, hacker, console, info, activeEntry(client)
    end
    local function countPackets(env, name)
        local count = 0
        for _, packet in ipairs(env.messages) do if packet.name == name then count = count + 1 end end
        return count
    end
    local function snapshot(client)
        return {messages = #client.messages, timers = #client.timerEvents, history = #client.historyCalls,
            sounds = #client.sounds, panels = #client.panels}
    end
    local function unchanged(client, before)
        local after = snapshot(client)
        for key, value in pairs(before) do equal(after[key], value, "Blocked submission changed " .. key) end
    end
    local function complete(client, countdown)
        client.fireTimer(countdown.timer)
        if countdown.stage == "login" then
            client.command("/a[terminal]/{_data}")
            client.command("/d{_data}/secret.data")
            client.fireTimer("DownloadDataFile")
        end
        client.assertClosed()
        equal(countPackets(client, "destroyOnServer"), 1, "Exactly one completion request")
        equal(#client.chatMessages, 0, "Client countdown alone cannot announce success")
        return assert(client.lastMessage("destroyOnServer"))
    end

    for _, countdown in ipairs(countdowns) do
        for _, early in ipairs({false, true}) do
            test("control: " .. countdown.timer .. " normal completion respects the " .. (early and "early" or "original") .. " server deadline", function()
                local server, client, hacker, console, info = fixture(countdown)
                client.command(countdown.command)
                local packet = complete(client, countdown)
                server.now = early and 3.99 or 4
                server.receive(packet.name, hacker, unpackValues(packet.values))
                if early then equal(console.removed, nil) else equal(console.removed, true) end
                equal(info.inUse, false)
                equal(countPackets(server, "SlicerCompleted"), early and 0 or 1)
            end)
        end

        test("control: " .. countdown.timer .. " permits help and quit during the countdown", function()
            local server, client, hacker, console, info, entry = fixture(countdown)
            client.command(countdown.command)
            local pending = client.timers[countdown.timer]
            button(entry.parent, "Commands (/help)"):DoClick()
            local help
            for _, panel in ipairs(client.panels) do
                if panel.valid and panel.parent == entry.parent and (panel.title or ""):match("^Commands") then help = panel end
            end
            assert(help and help:IsVisible(), "Countdown help must be readable")
            equal(client.timers[countdown.timer], pending)
            button(entry.parent, "Quit terminal"):DoClick()
            client.assertClosed()
            equal(countPackets(client, "playerQuitConsole"), 1)
            equal(countPackets(client, "destroyOnServer"), 0)
            local packet = assert(client.lastMessage("playerQuitConsole"))
            server.receive(packet.name, hacker, unpackValues(packet.values))
            equal(info.inUse, false); equal(console.removed, nil)
        end)

        if countdown.stage ~= "login" then
            test("control: " .. countdown.stage .. " return and reentry work outside a countdown", function()
                local _, client, _, _, _, entry = fixture(countdown)
                client.command(countdown.leave)
                equal(entry.valid, false, "Ordinary return retires the folder")
                local folders = activeEntry(client)
                client.command("/a[terminal]/{_" .. countdown.folder .. "}")
                assert(activeEntry(client) ~= folders, "Ordinary folder selection must still work")
                client.command(countdown.command)
                complete(client, countdown)
            end)
        end

        test(countdown.timer .. " preserves its first timer on duplicate Enter before and after Think", function()
            local _, client, _, _, _, entry = fixture(countdown)
            client.command(countdown.command)
            local pending, before = assert(client.timers[countdown.timer]), snapshot(client)
            entry:OnEnter() -- A second callback in the same input interval.
            equal(client.timers[countdown.timer], pending, "Duplicate Enter replaced the original countdown")
            unchanged(client, before)
            client.fire("Think")
            entry:SetText(countdown.command)
            before = snapshot(client)
            entry:OnEnter()
            equal(client.timers[countdown.timer], pending, "Enter after Think replaced the original countdown")
            unchanged(client, before)
            complete(client, countdown)
            before = snapshot(client)
            pending.callback()
            unchanged(client, before)
            equal(countPackets(client, "destroyOnServer"), 1, "Completed callback cannot send again")
        end)

        test(countdown.timer .. " locks command input immediately", function()
            local _, client, _, _, _, entry = fixture(countdown)
            client.command(countdown.command)
            equal(entry.editable, false, "Countdown must lock input before its first Think")
            equal(entry:IsKeyboardInputEnabled(), false, "Countdown must disable keyboard input immediately")
            equal(client.timers[countdown.timer].delay, 2)
            button(entry.parent, "Quit terminal"):DoClick()
            client.assertClosed()
        end)

        test(countdown.timer .. " ignores other submissions while help and quit stay available", function()
            local server, client, hacker, console, info, entry = fixture(countdown)
            client.command(countdown.command)
            local pending = client.timers[countdown.timer]
            for _, command in ipairs({countdown.leave, "/help", "invalid command"}) do
                entry:SetText(command)
                local before = snapshot(client)
                entry:OnEnter()
                unchanged(client, before)
                equal(activeEntry(client), entry, "A countdown submission changed its page")
                equal(client.timers[countdown.timer], pending)
            end
            button(entry.parent, "Commands (/help)"):DoClick()
            local help
            for _, panel in ipairs(client.panels) do
                if panel.valid and panel.parent == entry.parent and (panel.title or ""):match("^Commands") then help = panel end
            end
            assert(help and help:IsVisible(), "Help remains readable during a countdown")
            equal(client.timers[countdown.timer], pending)
            local quit = button(entry.parent, "Quit terminal")
            assert(quit.enabled ~= false, "Quit remains available during a countdown")
            quit:DoClick(); quit:DoClick()
            client.assertClosed()
            equal(countPackets(client, "playerQuitConsole"), 1)
            equal(countPackets(client, "destroyOnServer"), 0)
            local packet = assert(client.lastMessage("playerQuitConsole"))
            server.receive(packet.name, hacker, unpackValues(packet.values))
            equal(info.inUse, false); equal(console.removed, nil)
        end)

        if countdown.stage ~= "login" then
            test(countdown.timer .. " rejects return before Think without touching a removed panel", function()
                local _, client, _, _, _, entry = fixture(countdown)
                client.command(countdown.command)
                local pending = client.timers[countdown.timer]
                entry:SetText(countdown.leave)
                entry:OnEnter()
                -- Fire first so a removed-panel fault cannot be masked by a
                -- simpler page/timer assertion in this separate regression.
                client.fire("Think")
                equal(activeEntry(client), entry, "Return escaped the active download page")
                equal(entry.valid, true)
                equal(client.timers[countdown.timer], pending)
                complete(client, countdown)
            end)
        end

        for _, reopen in ipairs({false, true}) do
            test(countdown.timer .. " retires retained callbacks after quit" .. (reopen and " and reopen" or ""), function()
                local server, client, hacker, console, info, entry = fixture(countdown)
                client.command(countdown.command)
                local callback = assert(client.timers[countdown.timer]).callback
                local think = assert(client.hooks.Think[countdown.think])
                local enter = entry.OnEnter
                button(entry.parent, "Quit terminal"):DoClick()
                client.assertClosed()
                local packet = assert(client.lastMessage("playerQuitConsole"))
                server.receive(packet.name, hacker, unpackValues(packet.values))
                equal(info.inUse, false)
                local current, pending
                if reopen then
                    server.open(hacker, console); relayOpening(server, client)
                    if countdown.stage ~= "login" then
                        client.command("/a[terminal]"); client.fireTimer("AccessDelay")
                        client.command("/a[terminal]/{_" .. countdown.folder .. "}")
                    end
                    current = activeEntry(client)
                    client.command(countdown.command)
                    pending = assert(client.timers[countdown.timer])
                end
                local before = snapshot(client)
                enter(entry); think(); callback()
                unchanged(client, before)
                equal(countPackets(client, "destroyOnServer"), 0, "Retired countdown sent completion")
                equal(console.removed, nil)
                if reopen then
                    equal(activeEntry(client), current)
                    equal(client.timers[countdown.timer], pending, "Old countdown changed the new session's timer")
                    equal(info.inUse, true)
                    button(current.parent, "Quit terminal"):DoClick()
                end
                client.assertClosed()
            end)
        end

        for _, early in ipairs({false, true}) do
            test(countdown.timer .. " keeps the original server deadline " .. (early and "before" or "at") .. " completion", function()
                local server, client, hacker, console, info, entry = fixture(countdown)
                client.command(countdown.command)
                local pending = client.timers[countdown.timer]
                server.now, client.now = server.now + 0.5, client.now + 0.5
                entry:OnEnter()
                equal(client.timers[countdown.timer], pending, "Repeat submission restarted the configured delay")
                local packet = complete(client, countdown)
                server.now = early and 3.99 or 4
                server.receive(packet.name, hacker, unpackValues(packet.values))
                if early then equal(console.removed, nil) else equal(console.removed, true) end
                equal(info.inUse, false)
                equal(countPackets(server, "SlicerCompleted"), early and 0 or 1)
                local messages = #server.messages
                server.receive(packet.name, hacker, unpackValues(packet.values))
                equal(#server.messages, messages, "Repeated completion was accepted twice")
                if not early then
                    local accepted = assert(server.lastMessage("SlicerCompleted"))
                    client.receive(accepted.name, nil, unpackValues(accepted.values))
                    equal(#client.chatMessages, 1)
                else
                    equal(#client.chatMessages, 0)
                end
            end)
        end
    end
end
