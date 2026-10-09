-- Independent workflow review: relay the real public chat/network/UI callbacks.
-- Coordinates and drawing are doubles; this is not native movement, projection,
-- font rendering, PVS or multiplayer evidence. No private session/ticket state
-- is inspected: preserved authority is proved by the next accepted operation.
return function(gmod, test, equal)
    local support = dofile("tests/console-locator-support.lua")(gmod)
    local unpackValues = table.unpack or unpack
    local function contains(text, part)
        assert(text:find(part, 1, true), "Missing '" .. part .. "' in " .. text)
    end
    local function deliver(client, packet)
        assert(packet, "Missing packet")
        if packet.name == "SlicerConsoleLocation" then return support.deliver(client, packet) end
        client.receive(packet.name, nil, unpackValues(packet.values))
    end
    local function relay(server, actor, packet)
        assert(packet, "Missing client request")
        server.receive(packet.name, actor, unpackValues(packet.values))
    end
    local function say(server, owner, text) return server.fire("PlayerSay", owner, text) end
    local function list(server, owner, page)
        local first = #owner.chats + 1
        equal(say(server, owner, "!listConsoles" .. (page and " " .. page or "")), "")
        local rows = {}
        for index = first, #owner.chats do
            assert(#owner.chats[index] <= 255, "Listing exceeds the native byte budget")
            if owner.chats[index]:match("^[1-5]%. Console") then rows[#rows + 1] = owner.chats[index] end
        end
        return rows
    end
    local function locate(server, client, owner, row, console)
        local count, otherChats = #server.messages, {}
        for _, ent in ipairs(server.entities) do if ent:IsPlayer() and ent ~= owner then otherChats[ent] = #ent.chats end end
        local trace, weapon = owner.GetEyeTrace, owner.GetActiveWeapon
        owner.GetEyeTrace = function() error("Locate must not trace a target") end
        owner.GetActiveWeapon = function() error("Locate must not require a weapon") end
        local ok, result = pcall(say, server, owner, "!locateConsole " .. row)
        owner.GetEyeTrace, owner.GetActiveWeapon = trace, weapon
        assert(ok, result); equal(result, ""); equal(#server.messages, count + 1)
        local packet = server.messages[#server.messages]
        equal(packet.name, "SlicerConsoleLocation"); equal(packet.player, owner)
        equal(packet.values[1], row ~= "clear"); equal(#packet.values, row == "clear" and 1 or 3)
        if console then
            equal(packet.values[3].x, console.position.x)
            equal(packet.values[3].y, console.position.y)
            equal(packet.values[3].z, console.position.z)
            equal(type(packet.values[2]), "string")
            if console.SlicerInformation then
                assert(not packet.values[2]:find(console.SlicerInformation.fileName, 1, true), "Locator leaked saved filename")
            end
        end
        for other, before in pairs(otherChats) do equal(#other.chats, before, "Private command leaked chat") end
        if client then deliver(client, packet) end
        return packet
    end
    local function form(client, packet, editing)
        local first = #client.panels + 1; deliver(client, packet)
        local result, entries = {}, {}
        for index = first, #client.panels do
            local panel = client.panels[index]
            if panel.class == "DFrame" then result.frame = panel
            elseif panel.class == "DTextEntry" then entries[#entries + 1] = panel
            elseif panel.class == "DComboBox" then result.folder = panel
            elseif panel.class == "DButton" and panel.text == (editing and "Save changes" or "Done") then result.submit = panel
            elseif panel.class == "DButton" and panel.text == "Set up later" then result.later = panel end
        end
        equal(#entries, 3); assert(result.frame and result.submit)
        result.name, result.delay, result.file = entries[1], entries[2], entries[3]
        function result:fill(name, delay, file, folder)
            self.name:SetText(name); self.delay:SetText(tostring(delay)); self.file:SetText(file)
            if self.folder then self.folder.selected = folder end
        end
        return result
    end
    local function accept(server, client, owner, current, editing)
        current.submit:DoClick()
        local request = assert(client.lastMessage(editing and "SlicerSetupEditSave" or "AdminFinishedCreation"))
        equal(current.frame.valid, true, "The form must wait for its reply")
        relay(server, owner, request)
        local reply = assert(server.lastMessage(editing and "SlicerSetupEditReply" or "SlicerInitialSetupReply"))
        equal(reply.player, owner); equal(reply.values[2].ok, true)
        deliver(client, reply); equal(current.frame.valid, false)
        return request
    end
    local function link(server, owner, console, class)
        local door = server.entity(class)
        owner.target = console; equal(say(server, owner, "!setEntity"), "")
        owner.target = door; equal(say(server, owner, "!setEntity"), "")
        equal(console.SlicerDoor, door); equal(#door.inputs, 1); equal(door.inputs[1], "Lock")
        return door
    end
    local function finishRequest(client, kind, name, file)
        client.command("/a[" .. name .. "]")
        client.fireTimer("AccessDelay")
        client.command("/a[" .. name .. "]/{_" .. kind.folder .. "}")
        client.command((kind.timer and "/d" or "/r") .. "{_" .. kind.folder .. "}/" .. file .. "." .. kind.extension)
        if kind.timer then client.fireTimer(kind.timer) end
        return assert(client.lastMessage(kind.timer and "destroyOnServer" or "PlayerActivatedDoor"))
    end
    local kinds = {
        {folder = "data", extension = "data", timer = "DownloadDataFile"},
        {folder = "server", extension = "sys", timer = "DownloadServerFile"},
        {folder = "tools", extension = "exe", door = "func_door"},
        {folder = "tools", extension = "exe", door = "func_door_rotating"},
    }
    for _, kind in ipairs(kinds) do
        test("locator workflow reaches deferred setup, saved edit and exact " .. (kind.door or kind.folder) .. " completion", function()
            local server, client = support.server(), support.client()
            local owner, rival = server.player(), server.player()
            local console = server.console(owner)
            local initial = form(client, server.lastMessage("PlayerSpawnedConsole"))
            initial:fill("Discarded", 99, "discarded-file", kind.folder); initial.later:DoClick()
            equal(console.SlicerInformation, nil)
            equal(#list(server, owner), 1)
            locate(server, client, owner, 1, console)
            contains(client.paint(), "Location snapshot")
            local sampled = console.position.x
            console.position = support.vector(sampled + 200, 80, 60)
            contains(client.paint(), tostring(sampled))
            client.eye = support.vector(sampled, 0, 0) -- Simulated walk; Use remains an explicit public callback.
            local weapon = owner.weapon; owner.weapon = nil
            server.open(owner, console)
            local reopened = form(client, server.lastMessage("PlayerSpawnedConsole"))
            equal(reopened.name:GetValue(), "", "Deferred draft must be fresh")
            reopened:fill("Located terminal", 2, "private-file", kind.folder)
            accept(server, client, owner, reopened)
            equal(console.SlicerInformation.name, "located terminal")
            equal(#list(server, owner), 1); locate(server, client, owner, 1, console)
            owner.target = console; equal(say(server, owner, "!editConsole"), "")
            local editing = form(client, server.lastMessage("SlicerSetupEditOpen"), true)
            editing:fill("Reviewed terminal", 3.25, "private-renamed", kind.folder)
            local serial, information = server.slicerSetupEditSerial, console.SlicerInformation
            locate(server, client, owner, 1, console); locate(server, client, owner, "clear")
            equal(console.SlicerInformation, information); equal(server.slicerSetupEditSerial, serial)
            equal(editing.name:GetValue(), "Reviewed terminal")
            accept(server, client, owner, editing, true)
            equal(console.SlicerInformation.delay, 3.25); equal(console.SlicerInformation.fileName, "private-renamed")
            local door = kind.door and link(server, owner, console, kind.door)
            owner.weapon = weapon; server.now = 20
            server.open(owner, console); deliver(client, server.lastMessage("ServerSendsEntityInformation"))
            client.command("/a[reviewed terminal]")
            local login = assert(client.timers.AccessDelay)
            list(server, owner); locate(server, client, owner, 1, console)
            equal(client.timers.AccessDelay, login, "Locating cannot restart an existing countdown")
            local before = #server.messages; server.open(rival, console); equal(#server.messages, before)
            locate(server, client, owner, "clear")
            local request = finishRequest(client, kind, "reviewed terminal", "private-renamed")
            local deadline = 20 + 3.25 * (kind.timer and 2 or 1)
            server.now = deadline - 0.001; relay(server, owner, request)
            equal(console.removed, nil, "Locate cannot bypass minimum time")
            equal(console.SlicerInformation.inUse, false)
            deliver(client, server.lastMessage("PlayerDied")); client.assertClosed()
            server.now = 40; server.open(owner, console); deliver(client, server.lastMessage("ServerSendsEntityInformation"))
            list(server, owner); locate(server, client, owner, 1, console); locate(server, client, owner, "clear")
            request = finishRequest(client, kind, "reviewed terminal", "private-renamed")
            server.now = 40 + 3.25 * (kind.timer and 2 or 1)
            relay(server, owner, request); equal(console.removed, true)
            deliver(client, server.lastMessage("SlicerCompleted")); client.assertClosed()
            if door then equal(#door.inputs, 2); equal(door.inputs[2], "Unlock") end
            before = #server.messages; relay(server, owner, request); equal(#server.messages, before)
        end)
    end

    test("locator preserves pending form submissions, edit tickets, links and an unrelated countdown together", function()
        local server, client = support.server(), support.client()
        local owner = server.player()
        local active, editable, selected = server.console(owner), server.console(owner), server.console(owner)
        server.configure(owner, active, "data", 2); server.configure(owner, editable, "server", 3)
        server.configure(owner, selected, "tools", 4)
        server.now = 10; server.open(owner, active); deliver(client, server.lastMessage("ServerSendsEntityInformation"))
        client.command("/a[terminal]")
        local login = client.timers.AccessDelay
        owner.target = editable; say(server, owner, "!editConsole")
        local editOpen = server.lastMessage("SlicerSetupEditOpen")
        local editing = form(client, editOpen, true); editing:fill("Accepted edit", 3.5, "private-edit")
        editing.submit:DoClick(); local editSave = client.lastMessage("SlicerSetupEditSave")
        local deferred = server.console(owner)
        local setup = form(client, server.lastMessage("PlayerSpawnedConsole"))
        setup:fill("Accepted setup", 5, "private-setup", "data")
        setup.submit:DoClick(); local setupSave = client.lastMessage("AdminFinishedCreation")
        local entityFields, playerFields = {}, {}
        for key, value in pairs(editable) do entityFields[key] = value end
        for key, value in pairs(owner) do playerFields[key] = value end
        local serial = server.slicerSetupEditSerial
        list(server, owner)
        for _, row in ipairs({1, 2, 3, 4}) do locate(server, client, owner, row) end
        locate(server, client, owner, "clear")
        equal(server.slicerSetupEditSerial, serial); equal(client.timers.AccessDelay, login)
        equal(owner.SlicerPendingConsole, selected); equal(active.SlicerInformation.inUse, true)
        for key, value in pairs(editable) do equal(value, entityFields[key], "Locator changed entity field " .. key) end
        for key, value in pairs(owner) do equal(value, playerFields[key], "Locator changed player field " .. key) end
        equal(client.lastMessage("SlicerSetupEditSave"), editSave)
        equal(client.lastMessage("AdminFinishedCreation"), setupSave)
        equal(editing.name.editable, false); equal(setup.name.editable, false)
        relay(server, owner, editSave)
        local reply = server.lastMessage("SlicerSetupEditReply")
        equal(reply.values[1], editOpen.values[3]); equal(reply.values[2].ok, true); deliver(client, reply)
        relay(server, owner, setupSave)
        reply = server.lastMessage("SlicerInitialSetupReply"); equal(reply.values[2].ok, true); deliver(client, reply)
        equal(editable.SlicerInformation.name, "accepted edit"); equal(deferred.SlicerInformation.name, "accepted setup")
        equal(owner.SlicerPendingConsole, selected)
        local door = server.entity("func_door_rotating"); owner.target = door; say(server, owner, "!setEntity")
        equal(selected.SlicerDoor, door)
        local request = finishRequest(client, kinds[1], "terminal", "secret")
        server.now = 14; relay(server, owner, request); equal(active.removed, true)
        equal(#door.inputs, 1); equal(door.inputs[1], "Lock")
        deliver(client, server.lastMessage("SlicerCompleted")); client.assertClosed()
    end)

    test("locator retains exact last-page objects after reordering, identity reuse and callback removal", function()
        local server, client = support.server(), support.client()
        local owner, other = server.player(), server.player()
        local consoles = {}
        for index = 1, 7 do consoles[index] = server.console(owner); server.configure(owner, consoles[index]) end
        local sixth, seventh = consoles[6], consoles[7]
        list(server, owner, 2)
        for index = 1, 5 do consoles[index]:Remove() end
        sixth.id, seventh.id = 0, 0
        local replacement = server.console(owner); replacement.id = 0
        locate(server, client, owner, 1, sixth); locate(server, client, owner, 2, seventh)
        sixth:Remove(); replacement.position = sixth.position
        local count = #server.messages; say(server, owner, "!locateConsole 1"); equal(#server.messages, count)
        seventh.SlicerCreator = other
        count = #server.messages; say(server, owner, "!locateConsole 2"); equal(#server.messages, count)
        seventh.SlicerCreator = owner
        local chatPrint = owner.ChatPrint
        function owner:ChatPrint(text)
            chatPrint(self, text)
            if text:find("Your consoles:", 1, true) then seventh:Remove() end
        end
        local rows = list(server, owner); equal(#rows, 2)
        owner.ChatPrint = chatPrint
        count = #server.messages; say(server, owner, "!locateConsole 1"); equal(#server.messages, count)
        locate(server, client, owner, 2, replacement)
        owner.valid = false; equal(say(server, owner, "!listConsoles"), ""); owner.valid = true
        count = #server.messages; say(server, owner, "!locateConsole 2"); equal(#server.messages, count)
        list(server, owner); locate(server, client, owner, 1, replacement)
        server.now = 60; server.fire("Think")
        count = #server.messages; say(server, owner, "!locateConsole 1"); equal(#server.messages, count)
    end)

    test("locator clear and expiry remove only their cleanup hook while an active hack continues", function()
        local server, client = support.server(), support.client()
        local owner = server.player(); local console = server.console(owner); server.configure(owner, console)
        server.open(owner, console); deliver(client, server.lastMessage("ServerSendsEntityInformation"))
        client.command("/a[terminal]")
        local login, existing = client.timers.AccessDelay, {}
        for name, callback in pairs(client.hooks.Think) do existing[name] = callback end
        list(server, owner); locate(server, client, owner, 1, console)
        client.now = 15; client.fire("Think")
        equal(client.paint(), ""); equal(client.timers.AccessDelay, login)
        for name, callback in pairs(existing) do equal(client.hooks.Think[name], callback) end
        for name in pairs(client.hooks.Think) do assert(existing[name], "Locator cleanup hook survived expiry") end
        locate(server, client, owner, 1, console); locate(server, client, owner, "clear")
        for name, callback in pairs(existing) do equal(client.hooks.Think[name], callback) end
        client.command("/q[terminal]"); relay(server, owner, client.lastMessage("playerQuitConsole"))
        equal(console.SlicerInformation.inUse, false); client.assertClosed()
    end)

    local function assertDrawingFits(client)
        for _, item in ipairs(client.draws) do
            assert(item.x == item.x and item.y == item.y, "HUD emitted a NaN position")
            assert(item.x >= 0 and item.x + item.width <= client.width, "Text escaped resized width: " .. item.text)
            assert(item.y >= 0 and item.y + 16 <= client.height, "Text escaped resized height")
            assert(client.utf8.len(item.text), "HUD split or retained invalid UTF-8")
        end
        for _, line in ipairs(client.lines) do
            for index, value in ipairs(line) do
                assert(value == value and value >= 0 and value <= (index % 2 == 1 and client.width or client.height),
                    "Marker pointer escaped the viewport")
            end
        end
    end

    test("locator camera-space directions rotate with view while height context stays world-relative", function()
        local client = support.client()
        local cases = {
            {forward = {0, 1, 0}, right = {-1, 0, 0}, up = {0, 0, 1}, target = {-200, -100, 0}, side = "right", text = "behind"},
            {forward = {-1, 0, 0}, right = {0, -1, 0}, up = {0, 0, 1}, target = {-100, 400, 0}, side = "left", text = "ahead"},
            {forward = {0, 0, 1}, right = {0, 1, 0}, up = {-1, 0, 0}, target = {-400, 0, 100}, side = "top", text = "above"},
            {forward = {0, 0, -1}, right = {0, 1, 0}, up = {1, 0, 0}, target = {-400, 0, -100}, side = "bottom", text = "below"},
        }
        for _, case in ipairs(cases) do
            client.EyeAngles = function() return {
                Forward = function() return support.vector(unpackValues(case.forward)) end,
                Right = function() return support.vector(unpackValues(case.right)) end,
                Up = function() return support.vector(unpackValues(case.up)) end,
            } end
            local position = client.position(case.target[1], case.target[2], case.target[3], -999, -999, false)
            client.receive("SlicerConsoleLocation", nil, true, "Rotated target", position)
            contains(client.paint(), case.text); assertDrawingFits(client)
            local line = assert(client.lines[1], "Edge marker was not drawn")
            if case.side == "right" then assert(line[1] > client.width / 2)
            elseif case.side == "left" then assert(line[1] < client.width / 2)
            elseif case.side == "top" then assert(line[2] < client.height / 4)
            else assert(line[2] > client.height * 0.75) end
        end
    end)

    test("locator remeasures mixed-width UTF-8 after tiny and invalid viewport transitions", function()
        local client = support.client()
        client.surface.GetTextSize = function(text)
            assert(client.utf8.len(text), "Text measurement received malformed UTF-8")
            local width, index = 0, 1
            while index <= #text do
                local byte = text:byte(index)
                local bytes = byte < 128 and 1 or (byte < 224 and 2 or (byte < 240 and 3 or 4))
                width = width + (bytes > 1 and 24 or (byte == 87 and 18 or (byte == 73 and 4 or 8)))
                index = index + bytes
            end
            return width, 16
        end
        local label = "Console '" .. string.rep("界", 40) .. "WIééé' (current ID #77)"
        client.receive("SlicerConsoleLocation", nil, true, label, client.position(-100, 400, -500, 9999, 9999, false))
        for _, size in ipairs({{1920, 1080}, {160, 160}, {161, 160}, {320, 180}, {800, 600}, {640, 480}}) do
            client.width, client.height = size[1], size[2]
            client.paint(); equal(#client.draws, 3); assertDrawingFits(client)
        end
        for _, size in ipairs({{8, 8}, {0, 480}, {640, -1}, {0 / 0, 480}, {640, math.huge}}) do
            client.width, client.height = size[1], size[2]
            equal(client.paint(), ""); equal(#client.lines, 0)
        end
        client.width, client.height = 640, 480
        contains(client.paint(), "Location snapshot"); assertDrawingFits(client)
        equal(#client.messages, 0); equal(#client.panels, 0)
        client.now = 15; client.fire("Think"); equal(client.paint(), "")
    end)

    test("locator malformed UTF-8 and overflowing finite geometry never reach invalid drawing", function()
        local client = support.client()
        for _, label in ipairs({"\128", "\192\128", "\226\130", "\237\160\128", "\244\144\128\128", string.rep("x", 257)}) do
            client.receive("SlicerConsoleLocation", nil, true, "Old marker", client.position(100, 0, 0))
            client.receive("SlicerConsoleLocation", nil, true, label, client.position(100, 0, 0))
            local text, bytes = client.paint(), {}
            for index = 1, #label do bytes[#bytes + 1] = string.format("%02X", label:byte(index)) end
            assert(text:find("Console", 1, true), "Expected display fallback for label bytes " .. table.concat(bytes, " "))
            assert(not text:find("Old marker", 1, true)); assertDrawingFits(client)
        end
        local huge = client.position(1e308, 1e308, 1e308)
        function huge:ToScreen() error("Overflowing geometry reached projection") end
        client.receive("SlicerConsoleLocation", nil, true, "Overflow", huge)
        equal(client.paint(), ""); equal(#client.lines, 0)
        client.receive("SlicerConsoleLocation", nil, true, "Recovered", client.position(100, 200, 0, 0 / 0, math.huge))
        contains(client.paint(), "Recovered"); assertDrawingFits(client)
        client.localPlayer.alive = false
        equal(client.paint(), ""); equal(next(client.hooks.Think or {}), nil)
        client.localPlayer.alive = true; equal(client.paint(), "")
    end)

    -- Facepunch's utf8 decoder can count malformed scalar encodings as one
    -- character. This permissive helper covers that relevant acceptance only,
    -- so display validation cannot silently rely on host/runtime strictness.
    -- https://github.com/Facepunch/garrysmod/blob/master/garrysmod/lua/includes/modules/utf8.lua
    local function permissiveClient()
        local client = support.client()
        client.utf8.len = function(value)
            local _, count = value:gsub("[^\128-\191]", "")
            return count
        end
        return client
    end
    for _, case in ipairs({
        {"high surrogate", "\237\160\128"},
        {"low surrogate", "\237\191\191"},
        {"overlong three-byte slash", "\224\128\175"},
        {"overlong four-byte slash", "\240\128\128\175"},
        {"above U+10FFFF", "\244\144\128\128"},
        {"largest structural four-byte value", "\247\191\191\191"},
        {"stray continuation", "\128"},
        {"truncated three-byte character", "\226\130"},
    }) do
        test("locator strictly rejects " .. case[1] .. " with permissive utf8.len", function()
            local client = permissiveClient()
            client.receive("SlicerConsoleLocation", nil, true, "Old label", client.position(100, 0, 0))
            client.receive("SlicerConsoleLocation", nil, true, case[2], client.position(100, 0, 0))
            client.paint()
            equal(#client.draws, 3)
            equal(client.draws[2].text, "Console", "Invalid scalar encoding reached text rendering")
        end)
    end
    for _, case in ipairs({
        {"ASCII", "Visible label"},
        {"U+07FF", "\223\191"},
        {"U+0800", "\224\160\128"},
        {"U+D7FF", "\237\159\191"},
        {"U+E000", "\238\128\128"},
        {"U+FFFF", "\239\191\191"},
        {"U+10000", "\240\144\128\128"},
        {"U+10FFFF", "\244\143\191\191"},
    }) do
        test("locator preserves valid " .. case[1] .. " with permissive utf8.len", function()
            local client = permissiveClient()
            client.receive("SlicerConsoleLocation", nil, true, case[2], client.position(100, 0, 0))
            client.paint()
            equal(#client.draws, 3); equal(client.draws[2].text, case[2])
        end)
    end
end
