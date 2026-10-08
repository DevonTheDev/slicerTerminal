-- Exercise real setup callbacks with the repository's deterministic host doubles.
-- These checks cannot certify native Derma rendering, focus or packet delivery.
return function(gmod, test, equal)
    local unpackValues = table.unpack or unpack
    local replyName = "SlicerInitialSetupReply"
    local function count(env, name)
        local total = 0
        for _, packet in ipairs(env.messages) do if packet.name == name then total = total + 1 end end
        return total
    end
    local function clientAt(width, height)
        local client = gmod.client()
        client.ScrW, client.ScrH = function() return width or 640 end, function() return height or 480 end
        local create = client.vgui.Create
        client.vgui.Create = function(class, parent)
            local panel = create(class, parent)
            function panel:SetSize(w, h) self.width, self.height = w, h end
            function panel:SetPos(x, y) self.x, self.y = x, y end
            local nativeClose, nativeRemove = panel.Close, panel.Remove
            function panel:Close()
                if self.beforeNativeClose then self:beforeNativeClose() end
                return nativeClose(self)
            end
            function panel:Remove()
                if self.beforeNativeRemove then self:beforeNativeRemove() end
                return nativeRemove(self)
            end
            return panel
        end
        return client
    end
    local function open(client, owner, console, folder)
        local first = #client.panels + 1
        client.receive("PlayerSpawnedConsole", nil, owner, console:GetName())
        local form, entries = {controls = {}}, {}
        for i = first, #client.panels do
            local panel = client.panels[i]
            if panel.class == "DFrame" then form.frame = panel
            else form.controls[#form.controls + 1] = panel end
            if panel.class == "DTextEntry" then entries[#entries + 1] = panel
            elseif panel.class == "DComboBox" then form.folder = panel
            elseif panel.class == "DLabel" then form.status = panel
            elseif panel.class == "DButton" and panel.text == "Done" then form.done = panel
            elseif panel.class == "DButton" and panel.text == "Set up later" then form.later = panel end
        end
        assert(form.frame and form.folder and form.done and form.later, "Expected setup controls")
        equal(#entries, 3)
        form.name, form.delay, form.file = entries[1], entries[2], entries[3]
        function form:fill(name, delay, file)
            self.name:SetText(name or " Current terminal ")
            self.delay:SetText(delay or "2.5")
            self.file:SetText(file or " Current file ")
            self.folder.selected = folder or "data"
        end
        form:fill()
        return form
    end
    local function fixture(folder, width, height)
        local server, client = gmod.new(), clientAt(width, height)
        local owner = server.player()
        local console = server.console(owner)
        return server, client, owner, console, open(client, owner, console, folder)
    end
    local function submit(client, form)
        form.done:DoClick()
        return assert(client.lastMessage("AdminFinishedCreation"), "Done must submit setup")
    end
    local function deliver(client, packet)
        client.receive(packet.name, nil, unpackValues(packet.values))
    end
    local function reply(client, token, result)
        if result == nil then result = {ok = true, name = "current terminal", fileType = "data"} end
        client.receive(replyName, nil, token, result)
    end
    local function pending(form, value)
        equal(form.frame.valid, true, "Draft stays visible until acceptance")
        equal(form.done.enabled, not value)
        equal(form.folder.enabled, not value)
        for _, input in ipairs({form.name, form.delay, form.file}) do equal(input.editable, not value) end
        equal(form.later.text, value and "Close" or "Set up later")
    end
    local function serverFields(console, token, folder)
        return {" Accepted name ", 2.5, folder or "data", " Accepted file ", console:GetName(), token}
    end
    local function assertReply(server, owner, token, ok)
        local packet = assert(server.lastMessage(replyName), "Server must acknowledge correlated setup")
        equal(packet.player, owner, "Reply only to authenticated sender")
        equal(#packet.values, 2); equal(packet.values[1], token)
        equal(packet.values[2].ok, ok)
        return packet.values[2]
    end

    for _, folder in ipairs({"data", "server", "tools"}) do
        test("initial correlated " .. folder .. " setup commits once and acknowledges normalized fields", function()
            local server, client, owner, console, form = fixture(folder)
            form.file:RequestFocus()
            local packet = submit(client, form)
            equal(#packet.values, 1); equal(#packet.values[1], 6)
            local fields = packet.values[1]
            equal(fields[1], " Current terminal "); equal(fields[2], 2.5); equal(fields[3], folder)
            equal(fields[4], " Current file "); equal(fields[5], console:GetName())
            assert(type(fields[6]) == "string" and fields[6]:match("^[1-9]%d*$"), "Exact decimal correlation token")
            pending(form, true)
            assert(form.status and form.status.text:find("Closing cannot undo", 1, true), "Explain pending dismissal")
            equal(#owner.chats, 0, "No optimistic link guidance")
            form.done:DoClick(); equal(count(client, "AdminFinishedCreation"), 1)
            server.receive(packet.name, owner, unpackValues(packet.values))
            local information = console.SlicerInformation
            equal(information.name, "current terminal"); equal(information.fileName, "current file")
            equal(information.inUse, false); equal(#server.returnSpawnedEntities(), 1)
            local result = assertReply(server, owner, fields[6], true)
            equal(result.name, "current terminal"); equal(result.fileType, folder)
            local keys = 0; for key in pairs(result) do
                assert(key == "ok" or key == "name" or key == "fileType", "Allowlisted success data")
                keys = keys + 1
            end
            equal(keys, 3)
            local accepted = server.lastMessage(replyName)
            server.receive(packet.name, owner, unpackValues(packet.values))
            assertReply(server, owner, fields[6], false)
            equal(console.SlicerInformation, information); equal(#server.returnSpawnedEntities(), 1)
            deliver(client, accepted)
            equal(form.frame.valid, false)
            local chats = #owner.chats
            deliver(client, accepted); form.done:DoClick(); form.later:DoClick()
            equal(#owner.chats, chats); equal(count(client, "AdminFinishedCreation"), 1)
            equal(count(client, "ServerWaitingForEntity"), 0)
            if folder ~= "tools" then equal(chats, 0) end
        end)
    end

    for _, folder in ipairs({"data", "server", "tools"}) do
        test("legacy five-field " .. folder .. " setup retains acceptance without acknowledgement", function()
            local server = gmod.new()
            local owner = server.player()
            local console = server.console(owner)
            server.receive("AdminFinishedCreation", owner, serverFields(console, nil, folder))
            equal(console.SlicerInformation.fileType, folder); equal(count(server, replyName), 0)
            equal(owner.SlicerPendingConsole, folder == "tools" and console or nil)
            local information = console.SlicerInformation
            server.receive("AdminFinishedCreation", owner, serverFields(console, nil, folder))
            equal(console.SlicerInformation, information); equal(#server.returnSpawnedEntities(), 1)
        end)
    end

    for _, token in ipairs({"", "0", "01", "-1", "+1", "1.0", "1e3", " 1", "1\n", "9007199254740992", string.rep("9", 1000), 1, false, {}}) do
        test("initial setup rejects malformed supplied token " .. tostring(token):sub(1, 25), function()
            local server = gmod.new()
            local owner = server.player()
            local console = server.console(owner)
            server.receive("AdminFinishedCreation", owner, serverFields(console, token))
            equal(console.SlicerInformation, nil, "Malformed correlation must not fall back to legacy success")
            equal(#server.returnSpawnedEntities(), 0); equal(count(server, replyName), 0)
        end)
    end

    test("initial server accepts largest exact token without treating correlation as authority", function()
        local server = gmod.new()
        local owner, other = server.player(), server.player()
        local console = server.console(owner)
        server.receive("AdminFinishedCreation", other, serverFields(console, "9007199254740991"))
        local failure = assertReply(server, other, "9007199254740991", false)
        equal(failure.name, nil); equal(failure.fileType, nil); equal(console.SlicerInformation, nil)
        server.receive("AdminFinishedCreation", owner, serverFields(console, "9007199254740991"))
        assertReply(server, owner, "9007199254740991", true)
    end)

    for _, invalid in ipairs({
        {"empty name", 1, ""}, {"blank name", 1, " \t"}, {"long name", 1, string.rep("n", 129)},
        {"wrong name type", 1, false}, {"empty file", 4, ""}, {"long file", 4, string.rep("f", 129)},
        {"zero delay", 2, 0}, {"negative delay", 2, -1}, {"NaN delay", 2, 0/0},
        {"infinite delay", 2, math.huge}, {"delay string", 2, "2"},
        {"unknown folder", 3, "elsewhere"}, {"invalid entity name", 5, false},
    }) do
        test("correlated invalid " .. invalid[1] .. " receives useful rejection without mutation", function()
            local server = gmod.new()
            local owner = server.player()
            local console = server.console(owner)
            local fields = serverFields(console, "123")
            fields[invalid[2]] = invalid[3]
            server.receive("AdminFinishedCreation", owner, fields)
            local result = assertReply(server, owner, "123", false)
            assert(type(result.message) == "string" and #result.message > 0 and #result.message <= 256)
            equal(result.name, nil); equal(result.fileType, nil)
            equal(console.SlicerInformation, nil); equal(#server.returnSpawnedEntities(), 0)
        end)
    end

    for _, reason in ipairs({"removed", "foreign", "configured", "ambiguous", "missing"}) do
        test("initial " .. reason .. " target rejects and preserves unrelated pending console and door", function()
            local server = gmod.new()
            local owner, other = server.player(), server.player()
            local beta, console = server.console(owner), server.console(owner)
            server.configure(owner, beta, "tools")
            local door = server.entity("func_door")
            beta.SlicerDoor = door
            local fields = serverFields(console, "31", "tools")
            if reason == "removed" then console:Remove()
            elseif reason == "foreign" then console.SlicerCreator = other
            elseif reason == "configured" then server.configure(owner, console, "data")
            elseif reason == "ambiguous" then
                local duplicate = server.console(owner)
                duplicate:SetName(console:GetName())
            else fields[5] = "no-console-with-this-name" end
            local information, entries = console.SlicerInformation, #server.returnSpawnedEntities()
            server.receive("AdminFinishedCreation", owner, fields)
            assertReply(server, owner, "31", false)
            equal(console.SlicerInformation, information); equal(#server.returnSpawnedEntities(), entries)
            equal(owner.SlicerPendingConsole, beta); equal(beta.SlicerDoor, door); equal(#door.inputs, 0)
        end)
    end

    test("invalid sender cannot configure or receive an initial setup reply", function()
        local server = gmod.new()
        local owner = server.player()
        local console = server.console(owner)
        for _, sender in ipairs({server.entity("prop_physics"), {valid = false}}) do
            server.receive("AdminFinishedCreation", sender, serverFields(console, "1"))
        end
        server.receive("AdminFinishedCreation", nil, serverFields(console, "1"))
        equal(console.SlicerInformation, nil); equal(count(server, replyName), 0)
    end)

    test("initial rejection retains focused draft and fresh retry ignores old replies", function()
        local _, client, owner, _, form = fixture()
        local first = submit(client, form).values[1][6]
        reply(client, first, {ok = false, message = "The console is unavailable. Close and reopen setup."})
        pending(form, false)
        equal(form.name:GetValue(), " Current terminal "); equal(form.delay:GetValue(), "2.5")
        equal(form.file:GetValue(), " Current file ")
        assert(form.status.text:find("unavailable", 1, true))
        reply(client, first); pending(form, false)
        form:fill("New name", "3.5", "New file")
        local second = submit(client, form).values[1][6]
        assert(second ~= first, "Every submission gets a new token")
        reply(client, first); reply(client, first, {ok = false, message = "Old failure"})
        pending(form, true); equal(form.name:GetValue(), "New name")
        reply(client, second, {ok = true, name = "new name", fileType = "data"})
        equal(form.frame.valid, false); equal(#owner.chats, 0)
    end)

    for _, invalid in ipairs({
        false, "not a table", {}, {ok = "true"}, {ok = true},
        {ok = true, name = "", fileType = "data"}, {ok = true, name = string.rep("x", 129), fileType = "data"},
        {ok = true, name = "name", fileType = "unknown"}, {ok = false},
        {ok = false, message = false}, {ok = false, message = ""}, {ok = false, message = string.rep("x", 257)},
    }) do
        test("malformed initial reply " .. tostring(invalid) .. " cannot finish a pending form", function()
            local _, client, _, _, form = fixture()
            local token = submit(client, form).values[1][6]
            reply(client, token, invalid)
            pending(form, true)
            reply(client, token); equal(form.frame.valid, false)
        end)
    end

    test("unknown or non-string reply tokens cannot change any pending form", function()
        local _, client, _, _, form = fixture()
        local token = submit(client, form).values[1][6]
        for _, invalid in ipairs({"0", "999999", "01", false, {}, 1}) do reply(client, invalid); pending(form, true) end
        reply(client, token); equal(form.frame.valid, false)
    end)

    test("synchronous reply and reentrant Done observe the registered immutable submission", function()
        local server, client, owner, _, form = fixture()
        local send = client.net.SendToServer
        client.net.SendToServer = function()
            local outgoing = client.outgoing
            if outgoing.name == "AdminFinishedCreation" then
                form.done:DoClick()
                pending(form, true)
                server.receive(outgoing.name, owner, unpackValues(outgoing.values))
                deliver(client, assert(server.lastMessage(replyName)))
            end
            send()
        end
        submit(client, form)
        equal(count(client, "AdminFinishedCreation"), 1); equal(form.frame.valid, false)
    end)

    test("independent forms match reordered replies and repeated opens retain pending state", function()
        local server, client, owner, console, alpha = fixture()
        local otherConsole = server.console(owner)
        local beta = open(client, owner, otherConsole, "server")
        beta:fill("Beta", "7", "Beta file")
        local first = submit(client, alpha).values[1][6]
        local second = submit(client, beta).values[1][6]
        assert(first ~= second)
        local panels = #client.panels
        client.receive("PlayerSpawnedConsole", nil, owner, console:GetName())
        equal(#client.panels, panels); pending(alpha, true)
        equal(alpha.name:GetValue(), " Current terminal ")
        reply(client, second, {ok = true, name = "beta", fileType = "server"})
        equal(beta.frame.valid, false); pending(alpha, true)
        reply(client, first); equal(alpha.frame.valid, false)
    end)

    for _, removal in ipairs({"Close", "Remove", "later", "hide"}) do
        test("initial " .. removal .. " retires pending ownership before deferred native cleanup", function()
            local _, client, owner, console, old = fixture("tools")
            local token = submit(client, old).values[1][6]
            client.deferPanelRemoval = true
            local calls = 0
            local function reenter()
                calls = calls + 1
                old.done:DoClick()
                reply(client, token, {ok = true, name = "old", fileType = "tools"})
                equal(#owner.chats, 0, "Native entry retires before callbacks can deliver acceptance")
            end
            old.frame.beforeNativeClose, old.frame.beforeNativeRemove = reenter, reenter
            if removal == "later" then old.later:DoClick()
            elseif removal == "hide" then old.frame:Hide()
            else old.frame[removal](old.frame) end
            if removal ~= "hide" then assert(calls > 0) end
            local fresh = open(client, owner, console, "data")
            old.done:DoClick(); old.later:DoClick(); old.frame:OnClose(); old.frame:OnRemove()
            reply(client, token); reply(client, token, {ok = false, message = "Obsolete rejection"})
            equal(fresh.frame.valid, true); equal(fresh.frame:IsMarkedForDeletion(), false)
            equal(fresh.name:GetValue(), " Current terminal "); equal(count(client, "AdminFinishedCreation"), 1)
            local current = submit(client, fresh).values[1][6]
            assert(current ~= token); reply(client, current)
            equal(fresh.frame:IsMarkedForDeletion(), true)
        end)
    end

    test("client reinclude preserves existing draft and pending token while advancing shared serial", function()
        local server, client, owner, console, form = fixture()
        local first = submit(client, form).values[1][6]
        client.include("entities/consoleent/cl_init.lua")
        local panels = #client.panels
        client.receive("PlayerSpawnedConsole", nil, owner, console:GetName())
        equal(#client.panels, panels); pending(form, true)
        reply(client, first); equal(form.frame.valid, false)
        local other = open(client, owner, server.console(owner))
        local second = submit(client, other).values[1][6]
        assert(tonumber(second) > tonumber(first), "Reinclude must not reuse tokens")
        reply(client, first); pending(other, true)
        reply(client, second); equal(other.frame.valid, false)
    end)

    test("client serial reaches exact maximum once and refuses exhausted submission without wrapping", function()
        local server, client, owner, _, form = fixture()
        client.slicerInitialSetupSerial = 9007199254740990
        local token = submit(client, form).values[1][6]
        equal(token, "9007199254740991")
        reply(client, token)
        local other = open(client, owner, server.console(owner))
        other.done:DoClick()
        equal(count(client, "AdminFinishedCreation"), 1)
        equal(other.frame.valid, true); equal(other.name.editable, true)
        assert(other.status and other.status.text:lower():find("unavailable", 1, true), "Explain exhausted client serial")
        equal(client.slicerInitialSetupSerial, 9007199254740991)
    end)

    for _, invalid in ipairs({-1, 0.5, 0/0, math.huge, "1", false}) do
        test("invalid client serial " .. tostring(invalid) .. " never emits or reuses a token", function()
            local _, client, _, _, form = fixture()
            client.slicerInitialSetupSerial = invalid
            form.done:DoClick()
            equal(count(client, "AdminFinishedCreation"), 0); equal(form.frame.valid, true)
        end)
    end

    test("local invalid setup still reports and retains fields before a corrected submission", function()
        local _, client, owner, _, form = fixture()
        form.delay:SetText("bad"); form.done:DoClick()
        equal(count(client, "AdminFinishedCreation"), 0); equal(form.frame.valid, true)
        equal(form.delay:GetValue(), "bad"); equal(#owner.chats, 1)
        assert(form.status and form.status.text:lower():find("invalid", 1, true))
        form.delay:SetText("3"); submit(client, form); pending(form, true)
    end)

    test("accepted tools guidance sanitizes display only and fits native chat byte bound", function()
        local server, client, owner, console, form = fixture("tools")
        local name = string.rep("N", 123) .. "\n\t\0\r" .. string.char(127)
        form.name:SetText(name)
        local packet = submit(client, form)
        server.receive(packet.name, owner, unpackValues(packet.values))
        local normalized = console.SlicerInformation.name
        deliver(client, server.lastMessage(replyName))
        equal(console.SlicerInformation.name, normalized, "Display cleanup cannot rewrite configuration")
        local text = table.concat(owner.chats, " ")
        assert(text:find(string.rep("n", 123), 1, true), "Name the accepted normalized console")
        assert(text:find("!setEntity", 1, true) and text:find("console", 1, true) and text:find("door", 1, true))
        assert(text:find("first", 1, true), "Require explicit console selection before door selection")
        for _, message in ipairs(owner.chats) do
            assert(#message <= 255, "ChatPrint byte bound")
            assert(not message:find("[%z\1-\31\127]"), "No raw display control characters")
        end
    end)

    for _, size in ipairs({{640, 480}, {800, 600}, {1920, 1080}}) do
        test("initial status and original controls fit without overlap at " .. size[1] .. "x" .. size[2], function()
            local _, client, _, _, form = fixture(nil, size[1], size[2])
            assert(form.status and form.status.wrap, "Visible wrapped setup status")
            equal(#form.controls, 7)
            for i, panel in ipairs(form.controls) do
                assert(panel.x >= 20 and panel.x + panel.width <= size[1] - 20)
                assert(panel.y >= 20 and panel.y + panel.height <= size[2] - 20)
                assert(panel.width > 0 and panel.width <= 400)
                equal(panel.height, panel == form.status and 72 or 48)
                for j = i + 1, #form.controls do
                    local other = form.controls[j]
                    assert(panel.y + panel.height <= other.y or other.y + other.height <= panel.y, "No overlapping setup rows")
                end
            end
            submit(client, form)
            equal(form.status.valid, true); equal(form.status:IsVisible(), true)
        end)
    end
end
