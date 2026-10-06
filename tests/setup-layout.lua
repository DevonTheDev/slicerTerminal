-- Record rectangles around the existing panel doubles, then execute the real
-- setup receiver and server callbacks. This does not emulate native Derma
-- rendering, mouse hit-testing, fonts, dropdowns or display-size changes.
return function(gmod, test, equal)
    local unpackValues = table.unpack or unpack
    local sizes = {{640, 480}, {800, 600}, {1024, 600}, {1280, 720}, {1366, 768}, {1920, 1080}}

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
                assert(self.valid, "Center on removed panel")
                self.x = ((self.parent and self.parent.width or width) - self.width) / 2
                self.y = ((self.parent and self.parent.height or height) - self.height) / 2
            end
            function panel:GetX() return self.x end
            function panel:GetY() return self.y end
            return panel
        end
        return client
    end

    local function deliver(client, packet)
        client.receive(packet.name, nil, unpackValues(packet.values))
    end
    local function openPacket(client, packet)
        local first = #client.panels + 1
        deliver(client, packet)
        local form, entries = {}, {}
        for i = first, #client.panels do
            local panel = client.panels[i]
            if panel.class == "DFrame" then form.frame = panel
            elseif panel.class == "DTextEntry" then entries[#entries + 1] = panel
            elseif panel.class == "DComboBox" then form.folder = panel
            elseif panel.class == "DButton" and panel.text == "Done" then form.done = panel
            elseif panel.class == "DButton" and panel.text == "Set up later" then form.later = panel end
        end
        assert(form.frame and form.folder and form.done and form.later, "Missing setup controls")
        equal(#entries, 3, "Keep the three existing text entries")
        equal(#client.panels - first + 1, 7, "Keep one frame and six control instances")
        form.name, form.delay, form.file = entries[1], entries[2], entries[3]
        form.controls = {
            {"console name", form.name}, {"delay", form.delay}, {"folder", form.folder},
            {"filename", form.file}, {"Set up later", form.later}, {"Done", form.done},
        }
        function form:fill(name, delay, folder, file)
            self.name:SetText(name or "Terminal")
            self.delay:SetText(delay or "2")
            self.folder.selected = folder or "data"
            self.file:SetText(file or "Secret")
        end
        function form:assertBlank()
            equal(self.name:GetValue(), ""); equal(self.delay:GetValue(), "")
            equal(self.folder:GetSelected(), nil); equal(self.file:GetValue(), "")
        end
        return form
    end
    local function fixture(width, height)
        local server, client = gmod.new(), clientAt(width, height)
        local owner = server.player()
        local console = server.console(owner)
        local packet = assert(server.lastMessage("PlayerSpawnedConsole"))
        return server, client, owner, console, openPacket(client, packet), packet
    end
    local function assertVisible(form, width, height)
        equal(form.frame.x, 0); equal(form.frame.y, 0)
        equal(form.frame.width, width); equal(form.frame.height, height)
        equal(form.frame.title, "", "Keep the existing empty-title fullscreen frame")
        local clipped = {}
        for _, item in ipairs(form.controls) do
            local panel = item[2]
            equal(panel.parent, form.frame, "Each control belongs to this setup")
            assert(panel.valid and panel:IsVisible(), item[1] .. " must be live and visible")
            if panel.x < 20 or panel.x + panel.width > width - 20
                or panel.y < 20 or panel.y + panel.height > height - 20 then
                clipped[#clipped + 1] = item[1]
            end
        end
        assert(#clipped == 0, "Setup controls outside viewport margins: " .. table.concat(clipped, ", "))
    end
    local function assertUsable(form, width, height)
        for _, item in ipairs(form.controls) do
            local panel = item[2]
            local visibleHeight = math.max(0, math.min(height, panel.y + panel.height) - math.max(0, panel.y))
            assert(visibleHeight >= 48, item[1] .. " needs at least 48 visible pixels of height")
            assert(panel.width > 0 and panel.width <= 400, item[1] .. " width must be positive and capped at 400")
            assert(panel.x >= 20 and panel.x + panel.width <= width - 20, item[1] .. " needs horizontal margins")
        end
    end
    local function assertColumn(form, width, height)
        local first, last = form.controls[1][2], form.controls[6][2]
        local seen = {}
        for i, item in ipairs(form.controls) do
            local panel = item[2]
            assert(not seen[panel], "Six distinct controls must retain their own callbacks")
            seen[panel] = true
            if i > 1 then
                local previous = form.controls[i - 1][2]
                equal(panel.y - previous.y - previous.height, 12, item[1] .. " gap without overlap")
            end
        end
        for _, item in ipairs(form.controls) do
            local panel = item[2]
            equal(panel.height, 48, item[1] .. " compact row height")
            equal(panel.x * 2 + panel.width, width, item[1] .. " horizontally centered")
            equal(panel.x, first.x); equal(panel.width, first.width)
        end
        equal(first.y + last.y + last.height, height, "Vertically center the whole column")
        equal(last.y + last.height - first.y, 348, "Six rows and five gaps")
    end
    local function relaySetup(server, client, sender)
        local packet = assert(client.lastMessage("AdminFinishedCreation"), "No configuration packet")
        server.receive(packet.name, sender, unpackValues(packet.values))
        return packet
    end
    local function pasteUnconfigured(server, original, actor)
        -- The actual copy/early-paste/post-paste hooks, under the same generic
        -- spawn-then-restore contract used by tests/duplication.lua.
        local data = {Name = original:GetName(), SlicerCreator = original.SlicerCreator}
        original:OnEntityCopyTableFinish(data)
        local copy = setmetatable(server.entity("consoleent"), {__index = server.ENT})
        copy:Initialize()
        copy:SetName(data.Name)
        copy.SlicerCreator = data.SlicerCreator
        copy:OnDuplicated(data)
        copy:PostEntityPaste(actor, copy, {})
        return copy
    end

    for _, size in ipairs(sizes) do
        local width, height = size[1], size[2]
        local label = width .. "x" .. height
        test("initial setup fits viewport margins at " .. label, function()
            local _, _, _, _, form = fixture(width, height)
            assertVisible(form, width, height)
        end)
        test("initial setup controls have usable visible height at " .. label, function()
            local _, _, _, _, form = fixture(width, height)
            assertUsable(form, width, height)
        end)
        test("initial setup is one centered column without overlap at " .. label, function()
            local _, _, _, _, form = fixture(width, height)
            assertColumn(form, width, height)
        end)
        test("duplicate open preserves setup controls, geometry and draft at " .. label, function()
            local server, client, owner, console, form = fixture(width, height)
            form:fill("Partial name", "2.", "server", "Partial file")
            local rects = {}
            for i, item in ipairs(form.controls) do
                local panel = item[2]
                rects[i] = {panel.x, panel.y, panel.width, panel.height}
            end
            local count, popups = #client.panels, form.frame.popupCalls
            server.open(owner, console)
            deliver(client, server.lastMessage("PlayerSpawnedConsole"))
            equal(#client.panels, count); equal(client.focusedPanel, form.frame)
            equal(form.frame.popupCalls, popups + 1); equal(form.frame.frontCalls, 1)
            equal(form.name:GetValue(), "Partial name"); equal(form.delay:GetValue(), "2.")
            equal(form.folder:GetSelected(), "server"); equal(form.file:GetValue(), "Partial file")
            for i, item in ipairs(form.controls) do
                local panel, rect = item[2], rects[i]
                equal(panel.x, rect[1]); equal(panel.y, rect[2])
                equal(panel.width, rect[3]); equal(panel.height, rect[4])
            end
        end)

        for _, path in ipairs({"deferred", "unconfigured copy"}) do
            test(path .. " setup fits and submits current fields for its creator at " .. label, function()
                local server, client, owner, console, initial = fixture(width, height)
                initial:fill("Discarded", "8", "tools", "Old")
                initial.later:DoClick()
                equal(#client.messages, 0, "Set up later must send no submit or quit packet")
                equal(console.SlicerInformation, nil); equal(initial.frame.valid, false)
                local original, outsider = console, server.player()
                if path == "unconfigured copy" then
                    owner = server.player()
                    console = pasteUnconfigured(server, original, owner)
                    equal(console.SlicerCreator, owner); equal(console.SlicerInformation, nil)
                    assert(console:GetName() ~= original:GetName(), "The copy needs its own engine identity")
                    outsider = original.SlicerCreator
                end
                local count = #server.messages
                server.open(outsider, console)
                equal(#server.messages, count, "An outsider cannot reopen this setup")
                owner.weapon = nil
                server.open(owner, console)
                local packet = assert(server.lastMessage("PlayerSpawnedConsole"))
                equal(packet.player, owner); equal(packet.values[2], console:GetName())
                local fresh = openPacket(client, packet)
                fresh:assertBlank()
                assertVisible(fresh, width, height); assertUsable(fresh, width, height)
                assertColumn(fresh, width, height)
                fresh:fill(" Current name ", "bad", "server", "First file")
                fresh.done:DoClick()
                equal(#client.messages, 0, "Invalid input is retained locally")
                equal(fresh.frame.valid, true); equal(fresh.delay:GetValue(), "bad")
                equal(fresh.name:GetValue(), " Current name "); equal(fresh.folder:GetSelected(), "server")
                fresh.delay:SetText("2.5")
                fresh.file:SetText(" Final file ") -- No focus-loss callback before Done.
                fresh.done:DoClick()
                local submitted = assert(client.lastMessage("AdminFinishedCreation"))
                equal(#client.messages, 1, "One existing configuration packet")
                equal(#submitted.values, 1); equal(#submitted.values[1], 5)
                local fields = submitted.values[1]
                equal(fields[1], " Current name "); equal(fields[2], 2.5)
                equal(fields[3], "server"); equal(fields[4], " Final file ")
                equal(fields[5], console:GetName())
                relaySetup(server, client, outsider)
                equal(console.SlicerInformation, nil, "The actual server rejects outsider submission")
                relaySetup(server, client, owner)
                local info = assert(console.SlicerInformation)
                equal(info.name, "current name"); equal(info.delay, 2.5)
                equal(info.fileType, "server"); equal(info.fileName, "final file")
                server.receive("AdminFinishedCreation", owner, {"Changed", 9, "data", "Changed", console:GetName()})
                equal(console.SlicerInformation, info); equal(info.name, "current name", "First write stays immutable")
                if path == "unconfigured copy" then
                    equal(original.SlicerInformation, nil); equal(original.SlicerCreator, outsider)
                end
                initial.done:DoClick(); initial.later:DoClick()
                fresh.done:DoClick(); fresh.later:DoClick()
                equal(#client.messages, 1, "Retired actions cannot submit again")
                client.assertClosed()
            end)
        end
    end

    for _, retirement in ipairs({"defer", "submit", "close", "remove", "hide"}) do
        test("compact setup stale buttons preserve another and replacement form after " .. retirement, function()
            local server, client, owner, alpha, old, packet = fixture(640, 480)
            old:fill("Old", "2", "data", "Old file")
            local beta = server.console(owner)
            local other = openPacket(client, server.lastMessage("PlayerSpawnedConsole"))
            other:fill("Beta", "3", "server", "Beta file")
            client.deferPanelRemoval = true
            if retirement == "defer" then old.later:DoClick()
            elseif retirement == "submit" then old.done:DoClick()
            elseif retirement == "close" then old.frame:Close()
            elseif retirement == "remove" then old.frame:Remove()
            else old.frame:Hide() end
            local count = #client.messages
            local fresh = openPacket(client, packet)
            fresh:assertBlank(); fresh:fill("Alpha", "4", "data", "New file")
            assertVisible(fresh, 640, 480); assertColumn(fresh, 640, 480)
            old.done:DoClick(); old.later:DoClick()
            if old.frame.OnClose then old.frame:OnClose() end
            if old.frame.OnRemove then old.frame:OnRemove() end
            equal(#client.messages, count)
            equal(fresh.frame:IsMarkedForDeletion(), false); equal(fresh.frame:IsVisible(), true)
            equal(other.frame:IsMarkedForDeletion(), false); equal(other.name:GetValue(), "Beta")
            fresh.later:DoClick()
            equal(#client.messages, count, "Deferral stays local")
            equal(other.frame:IsMarkedForDeletion(), false); equal(other.file:GetValue(), "Beta file")
            other.done:DoClick()
            equal(#client.messages, count + 1)
            relaySetup(server, client, owner)
            equal(beta.SlicerInformation.name, "beta"); equal(alpha.SlicerInformation, nil)
        end)
    end
end
