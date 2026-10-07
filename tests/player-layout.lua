-- Execute the real client and server paths with locally recorded rectangles.
-- These are initial-open geometry/callback tests, not native rendering, font
-- readability, mouse hit-testing, keyboard dispatch or live-resize tests.
return function(gmod, test, equal)
    local unpackValues = table.unpack or unpack
    local sizes = {{640, 480}, {800, 600}, {1024, 600}, {1280, 720}, {1366, 768}, {1920, 1080}}
    local kinds = {
        {folder = "data", extension = "data", timer = "DownloadDataFile"},
        {folder = "server", extension = "sys", timer = "DownloadServerFile"},
        {folder = "tools", extension = "exe"},
    }
    local function clientAt(width, height)
        local client = gmod.client()
        client.ScrW, client.ScrH = function() return width end, function() return height end
        local create = client.vgui.Create
        client.vgui.Create = function(class, parent)
            local panel = create(class, parent)
            panel.x, panel.y, panel.width, panel.height = 0, 0, 0, 0
            function panel:SetSize(w, h)
                assert(self.valid, "SetSize on removed panel")
                self.width, self.height = w, h
            end
            function panel:SetPos(x, y)
                assert(self.valid, "SetPos on removed panel")
                self.x, self.y = x, y
            end
            function panel:Center()
                self:SetPos(((self.parent and self.parent.width or width) - self.width) / 2,
                    ((self.parent and self.parent.height or height) - self.height) / 2)
            end
            function panel:MoveTo(x, y) self:SetPos(x, y) end -- Record the animation destination only.
            function panel:GetX() return self.x end
            function panel:GetY() return self.y end
            function panel:SetImage(path) self.image = path end
            return panel
        end
        return client
    end
    local function live(panel)
        while panel do
            if not panel.valid or panel:IsMarkedForDeletion() or not panel:IsVisible() then return false end
            panel = panel.parent
        end
        return true
    end
    local function activeEntry(client)
        for i = #client.panels, 1, -1 do
            local panel = client.panels[i]
            if live(panel) and panel.OnEnter then return panel end
        end
        error("Missing live command input")
    end
    local function children(page, predicate)
        local found = {}
        for _, panel in ipairs(page.children) do
            if live(panel) and predicate(panel) then found[#found + 1] = panel end
        end
        return found
    end
    local function button(page, text)
        return assert(children(page, function(p) return p.class == "DButton" and p.text == text end)[1], text)
    end
    local function contained(panel, width, height, label)
        assert(panel.width > 0 and panel.height > 0, label .. " has no rectangle")
        assert(panel.x >= 0 and panel.y >= 0 and panel.x + panel.width <= width
            and panel.y + panel.height <= height, label .. " is clipped by the viewport")
    end
    local function separate(a, b, label)
        assert(a.x + a.width <= b.x or b.x + b.width <= a.x
            or a.y + a.height <= b.y or b.y + b.height <= a.y, label .. " rectangles overlap")
    end
    local function bands(entry, width, height, measureOnly)
        local page = entry.parent
        local labels = children(page, function(p) return p.class == "DLabel" end)
        local objective, heading
        for _, label in ipairs(labels) do
            if label.text:match("^Locate file ") then objective = label
            elseif label.text:match("^terminal") then heading = label end
        end
        assert(heading and objective, "Keep the terminal heading and file objective")
        local commands, quit = button(page, "Commands (/help)"), button(page, "Quit terminal")
        local reserved = {heading, objective, commands, quit, entry}
        if measureOnly then return objective.y + objective.height, math.min(commands.y, quit.y), reserved end
        for i, panel in ipairs(reserved) do
            contained(panel, width, height, "Reserved control " .. i)
            for j = 1, i - 1 do separate(panel, reserved[j], "Reserved controls") end
        end
        assert(entry.height >= 32 and commands.height >= 26 and quit.height >= 26, "Keep usable footer heights")
        assert(heading.y + heading.height <= objective.y, "Objective follows the heading")
        assert(commands.y + commands.height <= entry.y and quit.y + quit.height <= entry.y,
            "Actions must be above the command input")
        return objective.y + objective.height, math.min(commands.y, quit.y), reserved
    end
    local function contentGeometry(entry, width, height, folders)
        local page = entry.parent
        local items = children(page, function(p)
            if folders then return p.class == "DImage" and p.image and p.image:match("/folder%d.png$") end
            return p.class == "DTextEntry" and not p.OnEnter
        end)
        equal(#items, 3, "Keep all three " .. (folders and "folder clues" or "file rows"))
        -- Check artwork/rows first: the baseline must fail for the actual browser defect.
        for _, panel in ipairs(items) do contained(panel, width, height, folders and "Folder artwork" or "File row") end
        local top, bottom, reserved = bands(entry, width, height, true)
        for i, panel in ipairs(items) do
            assert(panel.y >= top + 8 and panel.y + panel.height <= bottom - 8, "Browser content escapes its reserved band")
            for _, other in ipairs(reserved) do separate(panel, other, "Content and reserved control") end
            for j = 1, i - 1 do separate(panel, items[j], "Browser items") end
        end
        if folders then
            table.sort(items, function(a, b) return a.x < b.x end)
            for i, expected in ipairs({"vgui/folder3.png", "vgui/folder1.png", "vgui/folder2.png"}) do
                equal(items[i].image, expected, "Keep tools, data, server in their original left-to-right order")
                equal(items[i].width, items[i].height, "Keep folder artwork square")
                assert(items[i].width >= 140, "Keep the clue artwork substantial at the smallest initial size")
                local caption = assert(children(page, function(p)
                    return p.class == "DLabel" and p.text == ({"{_tools}", "{_data}", "{_server}"})[i]
                end)[1], "Small folder artwork needs its explicit command identity")
                contained(caption, width, height, "Folder caption")
                assert(caption.height >= 20 and caption.y >= items[i].y + items[i].height,
                    "Each caption needs a separate line below its artwork")
                assert(caption.y + caption.height <= bottom - 8, "Caption escapes the content band")
                equal(caption.x * 2 + caption.width, items[i].x * 2 + items[i].width, "Caption aligns with its folder")
                for _, other in ipairs(reserved) do separate(caption, other, "Caption and reserved control") end
            end
        else
            table.sort(items, function(a, b) return a.y < b.y end)
            for i, row in ipairs(items) do
                assert(row.height >= 40 and row.width >= 300, "File rows need space for their names")
                equal(row.x * 2 + row.width, width, "File rows stay centered")
                if i > 1 then assert(row.y >= items[i - 1].y + items[i - 1].height + 8, "Separate file rows") end
            end
        end
        bands(entry, width, height)
    end
    local function deliver(client, packet)
        assert(packet, "Missing server packet")
        client.receive(packet.name, nil, unpackValues(packet.values))
    end
    local function fixture(width, height, kind)
        local server, client = gmod.new(), clientAt(width, height)
        local owner, hacker = server.player(), server.player()
        local console = server.console(owner)
        local info = assert(server.configure(owner, console, kind.folder, 2))
        local door
        if kind.folder == "tools" then
            door = server.entity("func_door_rotating")
            owner.target = door
            server.fire("PlayerSay", owner, "!setEntity")
            equal(door.inputs[1], "Lock")
        end
        server.open(hacker, console)
        deliver(client, server.lastMessage("ServerSendsEntityInformation"))
        return server, client, hacker, console, info, door
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
    local function openHelp(client, entry)
        button(entry.parent, "Commands (/help)"):DoClick()
        return assert(children(entry.parent, function(p) return p.class == "DFrame" and p.title:match("^Commands") end)[1])
    end
    local function insertFor(help, command)
        local scroll = assert(help.children[1])
        for i, panel in ipairs(scroll.children) do
            if panel.class == "DLabel" and panel.text:sub(1, #command + 1) == command .. "\n" then
                return assert(scroll.children[i + 1])
            end
        end
        error("Missing insertion for " .. command)
    end

    for _, size in ipairs(sizes) do
        local width, height = size[1], size[2]
        local label = width .. "x" .. height
        for _, kind in ipairs(kinds) do
            test(kind.folder .. " folder clues fit reserved content at " .. label, function()
                local _, client = fixture(width, height, kind)
                contentGeometry(visit(client, "folders"), width, height, true)
            end)
            for _, folder in ipairs({"data", "server", "tools"}) do
                test(kind.folder .. " target in " .. folder .. " fits three file rows at " .. label, function()
                    local _, client = fixture(width, height, kind)
                    contentGeometry(visit(client, folder), width, height, false)
                    client.command("//[terminal]/{_" .. folder .. "}")
                    contentGeometry(activeEntry(client), width, height, true)
                    client.command("/a[terminal]/{_" .. folder .. "}")
                    contentGeometry(activeEntry(client), width, height, false)
                end)
            end
            test(kind.folder .. " browser navigation and accepted completion at " .. label, function()
                local server, client, hacker, console, info, door = fixture(width, height, kind)
                local selection = visit(client, "folders")
                for pass = 1, 2 do
                    for _, folder in ipairs({"data", "server", "tools"}) do
                        client.command("/a[terminal]/{_" .. folder .. "}")
                        local entry = activeEntry(client)
                        if folder ~= kind.folder then
                            client.command(action(kind))
                            equal(client.lastMessage("destroyOnServer"), nil)
                            equal(client.lastMessage("PlayerActivatedDoor"), nil)
                        end
                        local back = "//[terminal]/{_" .. folder .. "}"
                        local help = openHelp(client, entry)
                        contained(help, width, height, "Commands window")
                        local insert = insertFor(help, back)
                        local sent, events = #client.messages, #client.timerEvents
                        insert:DoClick()
                        equal(entry:GetValue(), back); equal(client.focusedPanel, entry)
                        equal(#client.messages, sent); equal(#client.timerEvents, events)
                        entry:OnEnter()
                        equal(activeEntry(client), selection)
                        local count = #client.panels
                        insert:DoClick(); entry:OnEnter()
                        equal(#client.panels, count, "Retired file callbacks must not reopen a page")
                        equal(#client.messages, sent)
                    end
                end
                client.command("/a[terminal]/{_" .. kind.folder .. "}")
                client.command(action(kind))
                if kind.timer then
                    equal(client.timers[kind.timer].delay, 2)
                    client.fire("Think"); client.fireTimer(kind.timer)
                end
                client.assertClosed()
                equal(#client.chatMessages, 0, "Only server acceptance announces success")
                local packet = assert(client.lastMessage(kind.timer and "destroyOnServer" or "PlayerActivatedDoor"))
                equal(#packet.values, 1); equal(packet.values[1], console)
                server.now = kind.timer and 4 or 2
                server.receive(packet.name, hacker, unpackValues(packet.values))
                equal(console.removed, true); equal(info.inUse, false)
                if door then equal(#door.inputs, 2); equal(door.inputs[2], "Unlock") end
                deliver(client, server.lastMessage("SlicerCompleted"))
                equal(#client.chatMessages, 1)
            end)
        end
        for _, stage in ipairs({"login", "folders", "data", "server", "tools"}) do
            test(stage .. " header and actions stay separate at " .. label, function()
                local _, client = fixture(width, height, kinds[1])
                bands(visit(client, stage), width, height)
            end)
        end
        for _, stage in ipairs({"login", "folders", "data", "server", "tools"}) do
            test(stage .. " Commands stays inside content and leaves Quit exposed at " .. label, function()
                local server, client, hacker, console, info = fixture(width, height, kinds[1])
                local entry = visit(client, stage)
                local function boundedHelp()
                    local help = openHelp(client, entry)
                    contained(help, width, height, "Commands window")
                    local top, bottom, reserved = bands(entry, width, height)
                    for _, control in ipairs(reserved) do separate(help, control, "Commands and reserved control") end
                    assert(help.y >= top + 8 and help.y + help.height <= bottom - 8,
                        "Commands must stay within the browser content band")
                    equal(help.children[1].class, "DScrollPanel", "Keep the existing scrollable help content")
                    equal(help.children[1].dock, 5)
                    return help
                end
                local command = stage == "login" and "/a[terminal]"
                    or (stage == "folders" and "/a[terminal]/{_data}" or "//[terminal]/{_" .. stage .. "}")
                local help = boundedHelp()
                local sent, events = #client.messages, #client.timerEvents
                insertFor(help, command):DoClick()
                equal(entry:GetValue(), command); equal(client.focusedPanel, entry)
                equal(help.valid, false); equal(#client.messages, sent); equal(#client.timerEvents, events)
                help = boundedHelp()
                help:Close()
                equal(help.valid, false); equal(entry:GetValue(), command); assert(live(entry))
                equal(#client.messages, sent); equal(#client.timerEvents, events)
                boundedHelp()
                button(entry.parent, "Quit terminal"):DoClick()
                client.assertClosed()
                local packet = assert(client.lastMessage("playerQuitConsole"))
                server.receive(packet.name, hacker, unpackValues(packet.values))
                equal(info.inUse, false); equal(console.removed, nil)
                equal(server.lastMessage("SlicerCompleted"), nil)
            end)
        end
        for _, countdown in ipairs({
            {kind = kinds[1], stage = "login", timer = "AccessDelay", command = "/a[terminal]"},
            {kind = kinds[1], stage = "data", timer = "DownloadDataFile", command = action(kinds[1])},
            {kind = kinds[2], stage = "server", timer = "DownloadServerFile", command = action(kinds[2])},
        }) do
            test(countdown.timer .. " keeps help and Quit safe at " .. label, function()
                local server, client, hacker, console, info = fixture(width, height, countdown.kind)
                local entry = visit(client, countdown.stage)
                client.command(countdown.command)
                client.fire("Think")
                equal(entry.editable, false)
                local help = openHelp(client, entry)
                contained(help, width, height, "Countdown Commands window")
                local inserts = children(help.children[1], function(p) return p.class == "DButton" end)
                assert(#inserts > 0)
                for _, insert in ipairs(inserts) do
                    insert:Think(); equal(insert.enabled, false)
                    local draft = entry:GetValue()
                    insert:DoClick(); equal(entry:GetValue(), draft)
                end
                local quit = button(entry.parent, "Quit terminal")
                assert(quit.enabled ~= false)
                quit:DoClick(); client.assertClosed()
                local count = #client.messages
                quit:DoClick(); entry:OnEnter()
                equal(#client.messages, count)
                local packet = assert(client.lastMessage("playerQuitConsole"))
                server.receive(packet.name, hacker, unpackValues(packet.values))
                equal(info.inUse, false); equal(console.removed, nil)
                equal(server.lastMessage("SlicerCompleted"), nil)
                equal(client.lastMessage("destroyOnServer"), nil)
                equal(client.lastMessage("PlayerActivatedDoor"), nil)
                server.now = 100
                server.open(hacker, console)
                deliver(client, server.lastMessage("ServerSendsEntityInformation"))
                local current = activeEntry(client)
                quit:DoClick()
                equal(activeEntry(client), current, "Old Quit cannot close the reopened terminal")
                assert(live(current), "Reopening restores a live input")
            end)
        end
        for _, kind in ipairs(kinds) do
            test(kind.folder .. " long names stay bounded and preserve full commands at " .. label, function()
                local server, client = gmod.new(), clientAt(width, height)
                local owner, hacker = server.player(), server.player()
                local console = server.console(owner)
                local name, file = "terminal" .. string.rep("n", 120), string.rep("f", 128)
                server.receive("AdminFinishedCreation", owner, {name, 2, kind.folder, file, console:GetName()})
                if kind.folder == "tools" then
                    owner.target = server.entity("func_door_rotating")
                    server.fire("PlayerSay", owner, "!setEntity")
                end
                server.open(hacker, console)
                deliver(client, server.lastMessage("ServerSendsEntityInformation"))
                bands(activeEntry(client), width, height)
                local login = "/a[" .. name .. "]"
                local help = openHelp(client, activeEntry(client))
                insertFor(help, login):DoClick()
                equal(activeEntry(client):GetValue(), login)
                activeEntry(client):OnEnter(); client.fireTimer("AccessDelay")
                contentGeometry(activeEntry(client), width, height, true)
                client.command("/a[" .. name .. "]/{_" .. kind.folder .. "}")
                local entry = activeEntry(client)
                contentGeometry(entry, width, height, false)
                local rows = children(entry.parent, function(p) return p.class == "DTextEntry" and not p.OnEnter end)
                equal(rows[1]:GetValue(), string.upper(file) .. "." .. kind.extension, "The complete target filename remains in the row")
                local command = (kind.timer and "/d" or "/r") .. "{_" .. kind.folder .. "}/" .. file .. "." .. kind.extension
                insertFor(openHelp(client, entry), command):DoClick()
                equal(entry:GetValue(), command, "Presentation must preserve the authoritative command")
                entry:OnEnter()
                if kind.timer then client.fireTimer(kind.timer) end
                local packet = assert(client.lastMessage(kind.timer and "destroyOnServer" or "PlayerActivatedDoor"))
                server.now = kind.timer and 4 or 2
                server.receive(packet.name, hacker, unpackValues(packet.values))
                equal(console.removed, true)
                deliver(client, server.lastMessage("SlicerCompleted"))
                equal(#client.chatMessages, 1); client.assertClosed()
            end)
        end
    end
end
