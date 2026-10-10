-- Real PlayerUse packets reach the real client receiver. Test-local font and
-- rectangle recording checks layout intent, not native Derma text rendering.
return function(gmod, test, equal)
    local support = dofile("tests/player-resize-support.lua")(gmod)
    local unpackValues = table.unpack or unpack
    local notice = "This door is locked. Find a console to open it."
    local sizes = {{640, 480}, {800, 600}, {1024, 600}, {1280, 720}, {1366, 768}, {1920, 1080}}

    local function fixture(class, width, height)
        local server, client = gmod.new(), support.clientAt(width or 1920, height or 1080)
        client.fonts = {}
        client.surface.CreateFont = function(name, options) client.fonts[name] = options end
        client.include("entities/consoleent/cl_init.lua") -- Record actual font registrations before opening UI.
        local create = client.vgui.Create
        client.vgui.Create = function(kind, parent)
            local panel = create(kind, parent)
            local setFont = panel.SetFont
            function panel:SetFont(name) setFont(self, name); self.font = name end
            function panel:SetTextInset(x, y) self.insetX, self.insetY = x, y end
            return panel
        end
        local owner, hacker = server.player(), server.player()
        local console, door = server.console(owner), server.entity(class)
        local info = assert(server.configure(owner, console, "tools"))
        owner.target = door
        server.fire("PlayerSay", owner, "!setEntity")
        equal(console.SlicerDoor, door)
        equal(door.inputs[1], "Lock")
        return {server = server, client = client, owner = owner, hacker = hacker,
            console = console, door = door, info = info}
    end

    local function use(f)
        local before = #f.server.messages
        equal(f.server.fire("PlayerUse", f.hacker, f.door), false, "Registered door Use stays blocked")
        equal(#f.server.messages, before + 1)
        local packet = f.server.messages[#f.server.messages]
        equal(packet.name, "PlayerAlert"); equal(packet.player, f.hacker, "Only the using player receives the notice")
        equal(#packet.values, 0, "Do not disclose extra door or console data")
        support.deliver(f.client, packet)
        return f.client.panels[#f.client.panels]
    end

    local function contained(client, panel, width, height)
        equal(support.live(panel), true)
        equal(panel.text, notice, "Keep the entire original notice")
        assert(panel.x >= 0 and panel.y >= 0 and panel.width > 0 and panel.height > 0)
        assert(panel.x + panel.width <= width, "Notice overflows the viewport width")
        equal(panel.y + panel.height, height, "Notice stays anchored to the current bottom edge")
    end

    local function readable(client, panel)
        equal(panel.wrap, true, "The complete notice must wrap at narrow sizes")
        local font = assert(client.fonts[panel.font], "Use an actual registered font")
        assert(font.size >= 20 and font.size <= 32, "Use a readable compact font")
        assert(panel.height >= font.size * 2 + (panel.insetY or 0), "Reserve two text lines at the minimum width")
        equal(panel.popupCalls, nil, "The notice must not request popup input")
        equal(panel:IsKeyboardInputEnabled(), false)
    end

    for _, class in ipairs({"func_door", "func_door_rotating"}) do
        test(class .. " private locked-door notice contains its complete wrapped message at supported sizes", function()
            for _, size in ipairs(sizes) do
                local f = fixture(class, size[1], size[2])
                local alert = use(f)
                contained(f.client, alert, size[1], size[2]); readable(f.client, alert)
                equal(f.client.timers.removeAlert.delay, 4)
                equal(f.client.timers.removeAlert.repeats, 1)
                equal(f.client.focusedPanel, nil)
                equal(#f.client.messages, 0)
                equal(f.console.SlicerDoor, f.door); equal(f.info.inUse, false)
                equal(#f.door.inputs, 1, "Showing the notice never unlocks the door")
            end
        end)

        test(class .. " live notice follows down and up resize without replacement or timer restart", function()
            local f = fixture(class)
            local alert = use(f)
            local timer, callback = f.client.timers.removeAlert, f.client.timers.removeAlert.callback
            local panels, timerEvents = #f.client.panels, #f.client.timerEvents
            for _, size in ipairs({{640, 480}, {1920, 1080}, {800, 600}, {1366, 768}}) do
                f.client.resize(size[1], size[2])
                contained(f.client, alert, size[1], size[2])
                equal(#f.client.panels, panels, "Resize retains the same label")
                equal(f.client.timers.removeAlert, timer); equal(timer.callback, callback)
                equal(timer.delay, 4); equal(#f.client.timerEvents, timerEvents)
                equal(#f.client.messages, 0); equal(f.client.focusedPanel, nil)
                equal(f.console.SlicerDoor, f.door); equal(#f.door.inputs, 1)
            end
        end)

        test(class .. " repeated Use preserves original expiry and a later notice uses current dimensions", function()
            local f = fixture(class)
            local alert = use(f)
            local timer, events, panels = f.client.timers.removeAlert, #f.client.timerEvents, #f.client.panels
            f.client.now = 3.9
            f.client.resize(640, 480)
            for _ = 1, 3 do equal(use(f), alert) end
            equal(#f.client.panels, panels); equal(f.client.timers.removeAlert, timer)
            equal(#f.client.timerEvents, events, "Duplicate alerts never refresh or restart the deadline")
            f.client.fireTimer("removeAlert") -- Fire the originally scheduled callback, not a replacement.
            equal(alert.valid, false); equal(f.client.timers.removeAlert, nil)
            local replacement = use(f)
            assert(replacement ~= alert)
            contained(f.client, replacement, 640, 480); readable(f.client, replacement)
            equal(f.client.timers.removeAlert.delay, 4)
            f.client.resize(1920, 1080)
            contained(f.client, replacement, 1920, 1080)
        end)

        test(class .. " unrelated door Use remains nil and sends no alert", function()
            local f = fixture(class)
            local messages = #f.server.messages
            equal(f.server.fire("PlayerUse", f.hacker, f.server.entity(class)), nil)
            equal(f.server.fire("PlayerUse", f.hacker, f.server.entity("prop_physics")), nil)
            equal(#f.server.messages, messages); equal(#f.client.panels, 0)
            equal(f.console.SlicerDoor, f.door); equal(#f.door.inputs, 1)
        end)
    end

    test("door notice retains supported geometry through invalid sizes and ignores retired panels", function()
        local f = fixture("func_door")
        local alert = use(f)
        f.client.resize(640, 480)
        contained(f.client, alert, 640, 480)
        local geometry, events = #f.client.geometryCalls, #f.client.timerEvents
        for _, size in ipairs({{320, 240}, {0, 0}, {0 / 0, 480}, {640, math.huge}}) do
            f.client.resize(size[1], size[2])
            equal(#f.client.geometryCalls, geometry); equal(#f.client.timerEvents, events)
            contained(f.client, alert, 640, 480)
        end
        f.client.resize(1366, 768); contained(f.client, alert, 1366, 768)
        alert.markedForDeletion = true
        geometry = #f.client.geometryCalls
        f.client.resize(800, 600)
        equal(#f.client.geometryCalls, geometry, "Do not reflow a deletion-marked notice")
        f.client.fireTimer("removeAlert")
        geometry = #f.client.geometryCalls
        f.client.resize(1920, 1080)
        equal(#f.client.geometryCalls, geometry, "No label remains after expiry")
        contained(f.client, use(f), 1920, 1080)
    end)

    test("door notice opened at a transient sub-minimum size recovers to the current screen", function()
        local f = fixture("func_door_rotating", 320, 240)
        local alert = use(f)
        contained(f.client, alert, 640, 480)
        f.client.resize(800, 600)
        contained(f.client, alert, 800, 600)
    end)

    test("door notice resize and expiry preserve an active hack, Commands and creator draft", function()
        local f = fixture("func_door_rotating")
        local server, client = f.server, f.client
        local setupConsole = server.console(f.hacker)
        support.deliver(client, assert(server.lastMessage("PlayerSpawnedConsole")))
        local form, fields, folder = client.panels[1], {}
        for _, panel in ipairs(client.panels) do
            if panel.class == "DTextEntry" then fields[#fields + 1] = panel end
            if panel.class == "DComboBox" then folder = panel end
        end
        equal(#fields, 3)
        assert(folder).selected = "tools"
        fields[1]:SetText("  creator draft  "); fields[2]:SetText("2."); fields[3]:SetText("  file  ")
        local active = server.console(f.owner)
        local info = assert(server.configure(f.owner, active, "data", 2))
        server.now = 37
        server.open(f.hacker, active)
        local sessions = support.upvalue(server.ENT.AcceptInput, "sessions")
        local reservation = assert(sessions[f.hacker])
        equal(reservation.completeAt, 41)
        support.deliver(client, assert(server.lastMessage("ServerSendsEntityInformation")))
        client.command("/a[terminal]")
        local entry, countdown = support.entry(client), assert(client.timers.AccessDelay)
        local help = support.help(client, entry)
        entry:SetText("  active draft  "); entry:SetCaretPos(7); entry:RequestFocus()
        local alert = use(f)
        local alertTimer, panels, messages = client.timers.removeAlert, #client.panels, #client.messages
        local timerEvents, stateCalls = #client.timerEvents, #client.stateCalls
        for _, size in ipairs({{640, 480}, {1366, 768}, {1920, 1080}}) do
            client.resize(size[1], size[2]); contained(client, alert, size[1], size[2])
            equal(#client.panels, panels); equal(#client.messages, messages)
            equal(#client.timerEvents, timerEvents); equal(#client.stateCalls, stateCalls)
            equal(client.timers.removeAlert, alertTimer); equal(client.timers.AccessDelay, countdown)
            equal(support.entry(client), entry); equal(support.live(help), true); equal(support.live(form), true)
            equal(client.focusedPanel, entry); equal(entry.caret, 7)
            equal(entry:GetValue(), "  active draft  "); equal(entry.History[1], "/a[terminal]")
            equal(fields[1]:GetValue(), "  creator draft  "); equal(fields[2]:GetValue(), "2.")
            equal(fields[3]:GetValue(), "  file  "); equal(setupConsole.SlicerInformation, nil)
            equal(folder.selected, "tools"); equal(sessions[f.hacker], reservation)
            equal(reservation.console, active); equal(reservation.completeAt, 41)
            equal(info.inUse, true); equal(f.console.SlicerDoor, f.door); equal(#f.door.inputs, 1)
        end
        client.fireTimer("removeAlert")
        equal(client.timers.AccessDelay, countdown); equal(support.live(help), true); equal(support.live(form), true)
        client.fireTimer("AccessDelay")
        client.command("/a[terminal]/{_data}"); client.command("/d{_data}/secret.data")
        client.fireTimer("DownloadDataFile")
        server.now = 41 -- The original server-open time plus both original delays.
        local completion = assert(client.lastMessage("destroyOnServer"))
        server.receive(completion.name, f.hacker, unpackValues(completion.values))
        equal(active.removed, true, "Resize did not postpone the original completion deadline")
        equal(f.console.removed, nil); equal(f.console.SlicerDoor, f.door); equal(#f.door.inputs, 1)
        equal(support.live(form), true); equal(fields[1]:GetValue(), "  creator draft  ")
    end)
end
