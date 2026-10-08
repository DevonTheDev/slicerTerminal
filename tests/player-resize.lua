-- Exercise actual client callbacks with recorded rectangles. Native GMod pixels,
-- focus/caret/selection, dock layout, animation dispatch and scroll need a game.
return function(gmod, test, equal)
    local helper = dofile("tests/player-resize-support.lua")(gmod)
    local sizes = {{640, 480}, {1366, 768}, {800, 600}}
    local function contained(panel, width, height)
        assert(panel.width > 0 and panel.height > 0, "Positive control rectangle")
        assert(panel.x >= 0 and panel.y >= 0 and panel.x + panel.width <= width
            and panel.y + panel.height <= height, "Control stays inside current screen")
    end
    local function separate(a, b)
        assert(a.x + a.width <= b.x or b.x + b.width <= a.x
            or a.y + a.height <= b.y or b.y + b.height <= a.y, "Reserved control rectangles overlap")
    end
    local function geometry(entry, width, height, stage)
        local page = entry.parent
        equal(page.width, width, "Existing page width follows the current screen")
        equal(page.height, height, "Existing page height follows the current screen")
        equal(page.x, 0); equal(page.y, 0)
        local heading, objective
        for _, label in ipairs(helper.children(page, function(p) return p.class == "DLabel" end)) do
            if label.text:match("^Locate file ") then objective = label
            elseif label.text:match("^terminal") then heading = label end
        end
        assert(heading and objective)
        local commands, quit = helper.button(page, "Commands (/help)"), helper.button(page, "Quit terminal")
        local reserved = {heading, objective, commands, quit, entry}
        for i, control in ipairs(reserved) do
            contained(control, width, height)
            for j = 1, i - 1 do separate(control, reserved[j]) end
        end
        equal(entry.y, height - 68); equal(entry.width, width - 40)
        local images = helper.children(page, function(p) return p.class == "DImage" end)
        for _, image in ipairs(images) do
            if image.image:match("/consoleframe") then
                equal(image.width, width); equal(image.height, height)
                equal(image.x, 0); equal(image.y, 0)
            end
        end
        local items = helper.children(page, function(p)
            if stage == "folders" then return p.class == "DImage" and p.image:match("/folder%d.png$") end
            return p.class == "DTextEntry" and not p.OnEnter
        end)
        equal(#items, stage == "login" and 2 or 3)
        for i, item in ipairs(items) do
            contained(item, width, height)
            assert(item.y >= objective.y + objective.height + 8 and item.y + item.height <= commands.y - 8,
                "Content stays between objective and footer")
            for _, control in ipairs(reserved) do separate(item, control) end
            for j = 1, i - 1 do separate(item, items[j]) end
        end
        if stage == "folders" then
            local captions = helper.children(page, function(p) return p.class == "DLabel" and p.text:match("^{_") end)
            equal(#captions, 3, "One caption per folder")
            table.sort(items, function(a, b) return a.x < b.x end)
            for i, identity in ipairs({"{_tools}", "{_data}", "{_server}"}) do
                local caption
                for _, candidate in ipairs(captions) do if candidate.text == identity then caption = candidate end end
                assert(caption, "Keep folder identity")
                contained(caption, width, height)
                equal(caption.x, items[i].x); equal(caption.width, items[i].width)
                assert(caption.y >= items[i].y + items[i].height + 8)
                assert(caption.y + caption.height <= commands.y - 8)
                assert(items[i].width >= 140); equal(items[i].width, items[i].height)
            end
        end
        return objective
    end
    local function snapshot(client)
        return {panels = #client.panels, messages = #client.messages, timers = #client.timerEvents,
            state = #client.stateCalls, geometry = #client.geometryCalls, stops = #client.stopCalls,
            focus = client.focusedPanel}
    end
    local function untouched(client, before)
        equal(#client.panels, before.panels, "No new panels/captions")
        equal(#client.messages, before.messages, "No packets during reflow")
        equal(#client.timerEvents, before.timers, "No timer operations during reflow")
        equal(#client.stateCalls, before.state, "No input/text/history/visibility/focus setters during reflow")
        equal(client.focusedPanel, before.focus, "Focus proxy remains unchanged")
    end
    for _, stage in ipairs({"login", "folders", "data", "server", "tools"}) do
        test(stage .. " reflows the existing frame when screen size changes", function()
            local client = helper.fixture(1920, 1080)
            local entry = helper.visit(client, stage)
            client.resize(640, 480)
            equal(entry.parent.width, 640, "Existing page width follows the current screen")
            equal(entry.parent.height, 480, "Existing page height follows the current screen")
            equal(entry.y, 412, "Existing command input moves into the current screen")
        end)
    end
    for _, stage in ipairs({"login", "folders", "data", "server", "tools"}) do
        test(stage .. " preserves controls and draft across repeated reflow with open Commands", function()
            local client = helper.fixture(1920, 1080)
            local entry = helper.visit(client, stage)
            local history = entry.History
            history[#history + 1] = "/earlier command"
            entry.HistoryPos = 1
            entry:SetText("unfinished café 日本語 draft")
            entry.caret, entry.selection = 4, {start = 2, finish = 4} -- Proxy state, not native keyboard proof.
            local selection = entry.selection
            local help = helper.help(client, entry)
            local scroll = help.children[1]
            scroll.scrollOffset = 71 -- Docking may naturally clamp this in the native engine.
            local session = helper.upvalue(entry.IsCurrentTerminalPage, "session")
            local layout, historyCount = session.layout, #history
            for _, size in ipairs(sizes) do
                local before = snapshot(client)
                equal(client.resize(size[1], size[2]), nil, "Do not block other screen-size hooks")
                untouched(client, before)
                geometry(entry, size[1], size[2], stage)
                equal(helper.entry(client), entry)
                equal(session.layout, layout, "Captured layout table keeps its identity")
                equal(entry:GetValue(), "unfinished café 日本語 draft")
                equal(entry.History, history); equal(#history, historyCount); equal(entry.HistoryPos, 1)
                equal(entry.caret, 4); equal(entry.selection, selection)
                equal(help.children[1], scroll); equal(scroll.scrollOffset, 71)
                contained(help, size[1], size[2])
                equal(help.width, math.min(760, size[1] - 40))
                equal(help.height, math.min(420, layout.contentHeight))
                equal(#client.stopCalls - before.stops, stage == "login" and 1 or 0)
                local same = snapshot(client)
                client.resize(size[1], size[2])
                untouched(client, same)
                equal(#client.geometryCalls, same.geometry, "Same-size/MSAA event does no geometry work")
                equal(#client.stopCalls, same.stops, "Same-size/MSAA event keeps animations")
            end
            help:Close()
            local closed = snapshot(client)
            client.resize(1024, 600)
            untouched(client, closed)
            equal(help.valid, false, "Closed help stays closed")
            local reopened = helper.help(client, entry)
            assert(reopened ~= help)
            contained(reopened, 1024, 600)
        end)
    end
    test("only a real login size change cancels the obsolete objective animation", function()
        local client = helper.fixture(1920, 1080)
        local entry = helper.entry(client)
        local objective = geometry(entry, 1920, 1080, "login")
        local animation = assert(objective.animation)
        client.resize(1920, 1080)
        equal(objective.animation, animation); equal(#client.stopCalls, 0)
        client.resize(640, 480)
        equal(objective.animation, nil); equal(client.stopCalls[1], objective)
        client.completeAnimations()
        equal(objective.y, 72, "Old animation cannot restore the tall-screen objective position")
    end)
    test("hidden folders and newly opened file pages share the resized session budget", function()
        local client = helper.fixture(1920, 1080)
        client.resize(640, 480)
        local folders = helper.visit(client, "folders")
        geometry(folders, 640, 480, "folders")
        local session = helper.upvalue(folders.IsCurrentTerminalPage, "session")
        for index, stage in ipairs({"data", "server", "tools", "data", "server", "tools"}) do
            client.command("/a[terminal]/{_" .. stage .. "}")
            local current = helper.entry(client)
            local size = sizes[(index - 1) % #sizes + 1]
            client.resize(size[1], size[2])
            equal(folders.parent.hidden, true)
            geometry(folders, size[1], size[2], "folders")
            geometry(current, size[1], size[2], stage)
            client.command("//[terminal]/{_" .. stage .. "}")
            equal(helper.entry(client), folders)
            geometry(folders, size[1], size[2], "folders")
            local count = 0
            for _ in pairs(session.pages) do count = count + 1 end
            assert(count <= 5, "Revisiting folders must not accumulate page records")
        end
    end)
    local invalidSizes = {{0, 0}, {639, 480}, {640, 479}, {-1, 1080}, {"unknown", 480},
        {math.huge, 1080}, {800, math.huge}, {0 / 0, 480}}
    for index, size in ipairs(invalidSizes) do
        test("invalid or below-minimum size " .. index .. " retains the budget and recovers", function()
            local client = helper.fixture(800, 600)
            local entry = helper.entry(client)
            local before = snapshot(client)
            client.resize(size[1], size[2])
            untouched(client, before)
            equal(#client.geometryCalls, before.geometry); equal(#client.stopCalls, before.stops)
            geometry(entry, 800, 600, "login")
            local folders = helper.visit(client, "folders")
            geometry(folders, 800, 600, "folders")
            client.resize(1366, 768)
            geometry(folders, 1366, 768, "folders")
        end)
        test("unsupported initial size " .. index .. " uses a safe minimum budget", function()
            local client = helper.fixture(size[1], size[2])
            geometry(helper.entry(client), 640, 480, "login")
            geometry(helper.visit(client, "folders"), 640, 480, "folders")
            client.resize(800, 600)
            geometry(helper.entry(client), 800, 600, "folders")
        end)
    end
    test("dead and deletion-marked controls are skipped without retiring a live page", function()
        local client = helper.fixture(1920, 1080)
        local entry = helper.visit(client, "folders")
        local doomed = helper.children(entry.parent, function(p) return p.class == "DLabel" and p.text == "{_data}" end)[1]
        doomed.markedForDeletion = true
        local removed = helper.children(entry.parent, function(p) return p.class == "DImage" and p.image == "vgui/folder3.png" end)[1]
        removed:Remove()
        client.resize(640, 480)
        equal(entry.parent.width, 640)
        equal(doomed.width > 140, true, "Marked caption retains old geometry")
    end)
    test("retired page callbacks and the static hook cannot touch a replacement session", function()
        local client, server, hacker, console = helper.fixture(1920, 1080)
        local entry = helper.entry(client)
        local session = helper.upvalue(entry.IsCurrentTerminalPage, "session")
        local oldReflow = session.pages.login.reflow
        local hook = client.hooks.OnScreenSizeChanged.SlicerPlayerTerminalReflow
        client.deferPanelRemoval = true
        entry.QuitTerminal()
        local closed = snapshot(client)
        client.resize(640, 480)
        untouched(client, closed); equal(#client.geometryCalls, closed.geometry)
        helper.deliver(client, server.lastMessage("ServerSendsEntityInformation"))
        local current = helper.entry(client)
        equal(client.hooks.OnScreenSizeChanged.SlicerPlayerTerminalReflow, hook, "One stable hook across sessions")
        local before = snapshot(client)
        oldReflow()
        untouched(client, before); equal(#client.geometryCalls, before.geometry)
        client.resize(800, 600)
        geometry(current, 800, 600, "login")
        equal(entry.parent.width, 1920, "Marked old frame stays untouched")
    end)
    test("marked page records retire and setup geometry stays outside player reflow", function()
        local client = helper.fixture(1920, 1080)
        local entry = helper.entry(client)
        local session = helper.upvalue(entry.IsCurrentTerminalPage, "session")
        entry.parent.markedForDeletion = true
        client.resize(640, 480)
        equal(session.pages.login, nil, "Discard dead stage record")
        local setupStart = #client.panels
        local player = client.entity("player")
        function player:Alive() return true end
        client.receive("PlayerSpawnedConsole", nil, player, "outside-player-session")
        local positions = {}
        for i = setupStart + 1, #client.panels do
            local p = client.panels[i]
            positions[p] = {p.x, p.y, p.width, p.height}
        end
        client.resize(1366, 768)
        for panel, rectangle in pairs(positions) do
            equal(panel.x, rectangle[1]); equal(panel.y, rectangle[2])
            equal(panel.width, rectangle[3]); equal(panel.height, rectangle[4])
        end
    end)
end
