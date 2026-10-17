-- Source-prepared finite cases. Host seams exercise real addon callbacks;
-- they do not qualify native Derma, glyphs, focus, networking or multiplayer.
return function(gmod, test, equal)
    local H = dofile("tests/intel-archive-support.lua")(gmod, equal)
    local unpackValues = table.unpack or unpack
    local title = "Mission intel preview (unsaved)"
    local headingText = "Normalized draft snapshot"
    local footerText = "Unsaved normalized draft snapshot. Save changes submits the current editor draft. Preview again after editing."

    local function live(panel)
        while panel do
            if not panel.valid or panel:IsMarkedForDeletion() or not panel:IsVisible() then return false end
            panel = panel.parent
        end
        return true
    end
    -- Every new case allocates exactly one explicit server and one client.
    -- The client internally allocates M.new, which belongs to the client count.
    local function fixture(folder, body)
        local server = gmod.new()
        local owner = server.player()
        local console = server.console(owner)
        assert(server.configure(owner, console, folder or "data"))
        if folder ~= "tools" then assert(server.slicerIntel.SetBody(console, body or "Stored clue")) end
        return server, owner, console, H.client()
    end
    local function capture(client, first)
        local form = {inputs = {}}
        for i = first, #client.panels do
            local panel = client.panels[i]
            if panel.class == "DFrame" then form.frame = panel
            elseif panel.class == "DScrollPanel" then form.scroll = panel
            elseif panel.class == "DTextEntry" then form.inputs[#form.inputs + 1] = panel
            elseif panel.class == "DButton" and panel.text == "Save changes" then form.save = panel
            elseif panel.class == "DButton" and panel.text == "Cancel" then form.cancel = panel
            elseif panel.class == "DButton" and panel.text == "Preview intel" then form.preview = panel
            elseif panel.class == "DLabel" then
                if panel.text:find(" / 4096 bytes", 1, true) then form.counter = panel end
                if panel.parent == form.frame then form.status = panel end
                if panel.text:find("The downloader", 1, true) then form.explanation = panel end
            end
        end
        form.name, form.delay, form.fileName, form.intel = form.inputs[1], form.inputs[2], form.inputs[3], form.inputs[4]
        assert(form.frame and form.save and form.cancel and form.status)
        return form
    end
    local function open(client, owner, console, folder, body, token)
        local first = #client.panels + 1
        client.receive("SlicerSetupEditOpen", nil, console, owner, token or "101", {
            name = "terminal", delay = 2, fileName = "secret", fileType = folder or "data", intelBody = body or "Draft A"})
        return capture(client, first)
    end
    local function preview(client, expectedCount)
        local frames = H.frames(client, title)
        equal(#frames, expectedCount or 1, "Exact live preview count")
        if expectedCount == 0 then return end
        local view = {frame = frames[1]}
        for _, child in ipairs(view.frame.children) do
            if child.class == "DTextEntry" then assert(not view.body); view.body = child
            elseif child.class == "DLabel" and child.text == headingText then view.heading = child
            elseif child.class == "DLabel" and child.text == footerText then view.footer = child
            else error("Unexpected preview widget") end
        end
        assert(view.body and view.heading and view.footer)
        equal(#view.frame.children, 3, "Preview has only heading, body and footer")
        equal(view.body.multiline, true); equal(view.body.editable, false)
        equal(view.body.OnEnter, nil)
        return view
    end
    local function unchanged(server, console, client, messages, body)
        equal(#client.messages, messages, "Preview adds zero transport")
        equal(server.slicerIntel.GetBody(console), body or "Stored clue")
        equal(console.SlicerInformation.name, "terminal")
        equal(console.SlicerInformation.fileName, "secret")
        equal(console.SlicerInformation.delay, 2)
        equal(console.SlicerInformation.inUse, false)
        equal(console.removed, nil)
        equal(#client.chatMessages, 0)
    end
    local function rectangle(panel, x, y, width, height)
        equal(panel.x, x); equal(panel.y, y); equal(panel.width, width); equal(panel.height, height)
    end
    local function geometry(view, screenWidth, screenHeight)
        local width, height = math.min(620, screenWidth - 40), math.min(520, screenHeight - 40)
        rectangle(view.frame, (screenWidth - width) / 2, (screenHeight - height) / 2, width, height)
        rectangle(view.heading, 16, 32, width - 32, 40)
        rectangle(view.body, 16, 80, width - 32, height - 212)
        assert(view.footer.x >= 0 and view.footer.y >= view.body.y + view.body.height)
        assert(view.footer.width > 0 and view.footer.height > 0)
        assert(view.footer.x + view.footer.width <= width and view.footer.y + view.footer.height <= height)
    end
    local function call(callback, panel) if callback then callback(panel) end end
    local function deliver(client, packet)
        assert(packet); client.receive(packet.name, nil, unpackValues(packet.values))
    end
    local function relayOpen(server, owner, console, client)
        owner.target = console
        equal(server.fire("PlayerSay", owner, "!editConsole"), "")
        local packet, first = assert(server.lastMessage("SlicerSetupEditOpen")), #client.panels + 1
        equal(packet.player, owner); deliver(client, packet)
        local form = capture(client, first); form.token = packet.values[3]
        return form
    end

    local function presentation(folder)
        local server, owner, console, client = fixture(folder)
        local raw = "<b>https://example.invalid</b>\n/run[no] cafe\195\169 \230\151\165\230\156\172\232\170\158\t Clue"
        local form = open(client, owner, console, folder, raw)
        assert(form.preview and form.scroll and form.counter and form.explanation)
        equal(#form.inputs, 4); rectangle(form.frame, 90, 25, 460, 430)
        equal(form.preview.parent, form.intel.parent)
        assert(form.preview.y >= form.counter.y + form.counter.height)
        assert(form.explanation.y >= form.preview.y + form.preview.height)
        assert(form.intel.parent.height >= form.explanation.y + form.explanation.height)
        assert(form.intel.parent.height > 600)
        rectangle(form.save, 20, 366, 204, 44); rectangle(form.cancel, 236, 366, 204, 44)
        equal(form.status.parent, form.frame); equal(form.status.y, 286)
        form.name:SetText("Editable title must not appear")
        form.preview:DoClick()
        local view = preview(client); equal(view.body.text, raw); geometry(view, 640, 480)
        equal(form.intel.text, raw); equal(view.frame.popupCalls, 1)
        unchanged(server, console, client, 0)
        view.frame:Close(); preview(client, 0); equal(live(form.frame), true)
        equal(form.intel.text, raw); unchanged(server, console, client, 0)
    end
    test("preview-001", "data preview uses literal fixed presentation and scrolling placement", function() presentation("data") end)
    test("preview-002", "server preview uses literal fixed presentation and scrolling placement", function() presentation("server") end)

    test("preview-003", "tools editor initial setup and terminal expose no preview action", function()
        local server, owner, console, client = fixture("tools")
        local form = open(client, owner, console, "tools")
        equal(form.preview, nil); equal(form.intel, nil)
        client.receive("PlayerSpawnedConsole", nil, owner, "initial-legacy")
        client.receive("PlayerSpawnedConsole", nil, owner, "initial-modern", "slicer-initial-v2:72")
        client.receive("ServerSendsEntityInformation", nil, console, owner,
            {name = "terminal", delay = 2, fileName = "secret", fileType = "tools", inUse = false}, console:GetName())
        for _, panel in ipairs(client.panels) do assert(panel.text ~= "Preview intel") end
        preview(client, 0); equal(#client.messages, 1)
        equal(client.messages[1].name, "updateInUse", "Ordinary terminal opening keeps its existing packet")
        equal(server.slicerIntel.GetBody(console), "")
    end)

    test("preview-004", "4096 normalized bytes succeed without truncation", function()
        local server, owner, console, client = fixture()
        local raw = string.rep("a", 4095) .. "\r\n"
        local form = open(client, owner, console, "data", raw)
        form.preview:DoClick()
        equal(preview(client).body.text, string.rep("a", 4095) .. "\n")
        equal(form.intel.text, raw); unchanged(server, console, client, 0)
    end)
    test("preview-005", "4097 bytes retire prior preview and preserve rejected raw draft", function()
        local server, owner, console, client = fixture()
        local form = open(client, owner, console); form.preview:DoClick()
        local prior = preview(client).frame; local raw = string.rep("a", 4097)
        form.intel:SetText(raw); form.preview:DoClick()
        preview(client, 0); equal(live(prior), false); equal(form.intel.text, raw)
        local _, message = client.normalizeSlicerIntel(raw); equal(form.status.text, message)
        unchanged(server, console, client, 0)
    end)
    test("preview-006", "empty and ASCII blank replacements retire prior snapshots", function()
        local server, owner, console, client = fixture()
        local form = open(client, owner, console)
        for _, raw in ipairs({"", " \t\r\n\r "}) do
            form.intel:SetText("Valid before blank"); form.preview:DoClick()
            local prior = preview(client).frame
            form.intel:SetText(raw); form.preview:DoClick()
            equal(live(prior), false); preview(client, 0)
            equal(form.status.text, "No mission intel to preview"); equal(form.intel.text, raw)
        end
        form.intel:SetText("\194\160"); form.preview:DoClick()
        equal(preview(client).body.text, "\194\160", "Non-ASCII whitespace is not ASCII blank")
        unchanged(server, console, client, 0)
    end)
    test("preview-007", "invalid UTF8 and forbidden control replacements use shared validator", function()
        local server, owner, console, client = fixture()
        local form = open(client, owner, console)
        local invalid = {"bad\255", "bad\192\175", "bad\237\160\128", "bad\244\144\128\128",
            "bad\0tail", "bad\1", "bad\127", "bad\194\128", "bad\194\159"}
        for _, raw in ipairs(invalid) do
            form.intel:SetText("Valid before invalid"); form.preview:DoClick()
            local prior = preview(client).frame
            form.intel:SetText(raw); form.preview:DoClick()
            preview(client, 0); equal(live(prior), false); equal(form.intel.text, raw)
            local canonical, message = client.normalizeSlicerIntel(raw)
            equal(canonical, nil); equal(form.status.text, message)
        end
        unchanged(server, console, client, 0)
    end)
    test("preview-008", "focused raw draft normalizes into immutable per-click snapshots", function()
        local server, owner, console, client = fixture()
        local raw, canonical = "  Case\r\nSecond\r\tFinal  ", "  Case\nSecond\n\tFinal  "
        local form = open(client, owner, console, "data", raw)
        form.intel:RequestFocus(); form.preview:DoClick()
        local first = preview(client); equal(first.body.text, canonical); equal(form.intel.text, raw)
        form.intel:SetText("Current B\r\nMore") -- No OnChange/blur: click reads GetValue now.
        equal(first.body.text, canonical)
        form.preview:DoClick()
        local second = preview(client); assert(second.frame ~= first.frame)
        equal(live(first.frame), false); equal(second.body.text, "Current B\nMore")
        equal(form.intel.text, "Current B\r\nMore"); unchanged(server, console, client, 0)
    end)

    local function saveRelay(folder)
        local server, owner, console, client = fixture(folder)
        local form = relayOpen(server, owner, console, client)
        form.intel:SetText("Snapshot A"); form.preview:DoClick()
        local view = preview(client); equal(view.body.text, "Snapshot A")
        unchanged(server, console, client, 0)
        form.intel:SetText("Current B\r\nSecond")
        equal(view.body.text, "Snapshot A")
        form.save:DoClick(); preview(client, 0); equal(live(view.frame), false)
        equal(#client.messages, 1); local request = assert(client.lastMessage("SlicerSetupEditSave"))
        equal(request.values[1], console); equal(request.values[2], form.token)
        equal(request.values[3].intelBody, "Current B\nSecond")
        equal(server.slicerIntel.GetBody(console), "Stored clue")
        server.receive(request.name, owner, unpackValues(request.values))
        local reply = assert(server.lastMessage("SlicerSetupEditReply"))
        equal(reply.player, owner); equal(reply.values[2].ok, true)
        equal(server.slicerIntel.GetBody(console), "Current B\nSecond")
        deliver(client, reply); equal(live(form.frame), false); preview(client, 0)
        equal(#client.messages, 1, "Accepted reply does not add preview or cancel transport")
        equal(console.removed, nil); equal(console.SlicerInformation.inUse, false)
        equal(server.lastMessage("SlicerIntel"), nil); equal(server.lastMessage("SlicerCompleted"), nil)
    end
    test("preview-009", "data ordinary save relay submits current B after previewing A", function() saveRelay("data") end)
    test("preview-010", "server ordinary save relay submits current B after previewing A", function() saveRelay("server") end)

    test("preview-011", "distinct console tokens own independent previews", function()
        local server, owner, console, client = fixture()
        local other = server.console(owner); assert(server.configure(owner, other, "server"))
        assert(server.slicerIntel.SetBody(other, "Other stored"))
        local a = open(client, owner, console, "data", "A", "101")
        local b = open(client, owner, other, "server", "B", "102")
        a.preview:DoClick(); local first = preview(client).frame
        b.preview:DoClick(); equal(#H.frames(client, title), 2)
        local second = H.frames(client, title)[2]
        a.intel:SetText("A2"); a.preview:DoClick()
        equal(live(first), false); equal(live(second), true); equal(#H.frames(client, title), 2)
        a.cancel:DoClick(); equal(#H.frames(client, title), 1)
        equal(H.frames(client, title)[1], second); equal(live(b.frame), true); equal(b.intel.text, "B")
        equal(#client.messages, 1); equal(client.messages[1].name, "SlicerSetupEditCancel")
        equal(client.messages[1].values[2], "101")
        equal(server.slicerIntel.GetBody(other), "Other stored")
        unchanged(server, console, client, 1)
    end)
    test("preview-012", "same live token reopening preserves draft and preview instance", function()
        local server, owner, console, client = fixture()
        local form = open(client, owner, console); form.preview:DoClick()
        local view, count = preview(client), #client.panels
        form.intel:SetText("Unsaved current B")
        client.receive("SlicerSetupEditOpen", nil, console, owner, "101", {
            name = "replacement", delay = 8, fileName = "replacement", fileType = "data", intelBody = "Server resend"})
        equal(#client.panels, count); equal(preview(client).frame, view.frame)
        equal(view.body.text, "Draft A"); equal(form.intel.text, "Unsaved current B")
        equal(form.frame.popupCalls, 2); unchanged(server, console, client, 0)
    end)
    test("preview-013", "new token retires old editor preview and stale callbacks stay inert", function()
        local server, owner, console, client = fixture()
        local old = open(client, owner, console); old.preview:DoClick()
        local prior = preview(client).frame; local onClose, onRemove = prior.OnClose, prior.OnRemove
        local current = open(client, owner, console, "data", "Fresh B", "102")
        preview(client, 0); equal(live(prior), false); equal(live(old.frame), false)
        current.preview:DoClick(); local view, count = preview(client), #client.panels
        old.preview:DoClick(); call(onClose, prior); call(onRemove, prior)
        equal(#client.panels, count); equal(preview(client).frame, view.frame); equal(view.body.text, "Fresh B")
        unchanged(server, console, client, 1)
    end)
    test("preview-014", "reopened same token is a fresh edit instance immune to old cleanup", function()
        local server, owner, console, client = fixture()
        local old = open(client, owner, console); old.preview:DoClick()
        local prior = preview(client).frame; local onClose, onRemove = prior.OnClose, prior.OnRemove
        old.frame:Remove(); preview(client, 0)
        local current = open(client, owner, console, "data", "New instance", "101")
        preview(client, 0); assert(current.frame ~= old.frame)
        current.preview:DoClick(); local view, count = preview(client), #client.panels
        old.preview:DoClick(); call(onClose, prior); call(onRemove, prior); call(old.frame.OnRemove, old.frame)
        equal(#client.panels, count); equal(preview(client).frame, view.frame)
        equal(view.body.text, "New instance"); equal(live(current.frame), true)
        unchanged(server, console, client, 1)
    end)
    test("preview-015", "closing preview alone preserves raw editor and delayed cleanup cannot clear replacement", function()
        local server, owner, console, client = fixture()
        local form = open(client, owner, console, "data", "Raw\r\nDraft"); form.preview:DoClick()
        local prior = preview(client).frame; local onClose, onRemove = prior.OnClose, prior.OnRemove
        prior:Close(); preview(client, 0); equal(live(form.frame), true); equal(form.intel.text, "Raw\r\nDraft")
        form.preview:DoClick(); local current = preview(client)
        call(onClose, prior); call(onRemove, prior)
        equal(preview(client).frame, current.frame); equal(current.body.text, "Raw\nDraft")
        unchanged(server, console, client, 0)
    end)
    test("preview-016", "deferred preview removal and stale lifecycle callbacks preserve replacement", function()
        local server, owner, console, client = fixture()
        local form = open(client, owner, console); form.preview:DoClick()
        local prior = preview(client).frame; local onClose, onRemove = prior.OnClose, prior.OnRemove
        client.deferPanelRemoval = true
        prior:Close(); equal(prior.valid, true); equal(prior:IsMarkedForDeletion(), true)
        form.intel:SetText("Replacement"); form.preview:DoClick()
        local view = preview(client); assert(view.frame ~= prior)
        call(onClose, prior); call(onRemove, prior)
        equal(preview(client).frame, view.frame); equal(view.body.text, "Replacement")
        unchanged(server, console, client, 0)
    end)
    test("preview-017", "native cleanup reentrancy preserves newer preview of the same edit", function()
        local server, owner, console, client = fixture()
        local form = open(client, owner, console)
        local create, armed = client.vgui.Create, false
        client.vgui.Create = function(class, parent)
            local panel = create(class, parent)
            if class == "DFrame" then
                local nativeRemove = panel.Remove
                function panel:Remove()
                    if armed then
                        armed = false
                        form.intel:SetText("Reentrant newer snapshot")
                        form.preview:DoClick()
                    end
                    return nativeRemove(self)
                end
            end
            return panel
        end
        form.preview:DoClick(); local prior = preview(client).frame
        form.intel:SetText("Outer stale click"); armed = true; form.preview:DoClick()
        local current = preview(client)
        equal(armed, false); assert(current.frame ~= prior); equal(live(prior), false)
        equal(current.body.text, "Reentrant newer snapshot")
        equal(current.frame.popupCalls, 1)
        unchanged(server, console, client, 0)
    end)
    test("preview-018", "native frame creation reentrancy cannot leave an orphan or close new edit preview", function()
        local server, owner, console, client = fixture()
        local old = open(client, owner, console)
        local create, armed, abandoned, current = client.vgui.Create, true
        client.vgui.Create = function(class, parent)
            local panel = create(class, parent)
            if class == "DFrame" and armed then
                armed, abandoned = false, panel
                current = open(client, owner, console, "data", "New edit snapshot", "102")
                current.preview:DoClick()
            end
            return panel
        end
        old.preview:DoClick()
        local view = preview(client)
        equal(live(abandoned), false); equal(live(old.frame), false); equal(live(current.frame), true)
        equal(view.body.text, "New edit snapshot"); equal(view.frame.popupCalls, 1)
        unchanged(server, console, client, 1)
    end)
    test("preview-019", "pending save disables direct preview and ordinary rejected relay reenables it", function()
        local server, owner, console, client = fixture()
        local form = relayOpen(server, owner, console, client)
        form.intel:SetText("Keep this draft"); form.preview:DoClick()
        form.save:DoClick(); preview(client, 0); equal(form.preview:IsEnabled(), false)
        local count = #client.panels; form.preview:DoClick()
        equal(#client.panels, count); equal(#client.messages, 1)
        -- Retire server eligibility after a valid local submission. This is one
        -- ordinary rejection, with no receipt, retry or lost-reply mechanism.
        server.retireSlicerSetupEdit(console)
        local request = assert(client.lastMessage("SlicerSetupEditSave"))
        server.receive(request.name, owner, unpackValues(request.values))
        local reply = assert(server.lastMessage("SlicerSetupEditReply")); equal(reply.values[2].ok, false)
        deliver(client, reply); equal(form.preview:IsEnabled(), true); preview(client, 0)
        equal(form.intel.text, "Keep this draft"); equal(form.intel.editable, true)
        form.preview:DoClick(); equal(preview(client).body.text, "Keep this draft")
        unchanged(server, console, client, 1)
    end)
    test("preview-020", "body preview succeeds independently of metadata and invalid local save keeps snapshot", function()
        local server, owner, console, client = fixture()
        local form = open(client, owner, console)
        form.name:SetText(" "); form.delay:SetText("invalid")
        form.preview:DoClick(); local view = preview(client)
        form.save:DoClick(); equal(preview(client).frame, view.frame); equal(form.preview:IsEnabled(), true)
        form.name:SetText("terminal"); form.save:DoClick()
        equal(preview(client).frame, view.frame); unchanged(server, console, client, 0)
    end)
    test("preview-021", "locally current stale eligibility can preview without claiming save acceptance", function()
        local server, owner, console, client = fixture()
        local form = open(client, owner, console)
        owner.alive = false; console.valid = false
        form.preview:DoClick(); local view = preview(client); equal(view.body.text, "Draft A")
        form.save:DoClick(); equal(preview(client).frame, view.frame)
        assert(form.status.text:find("no longer current", 1, true)); equal(#client.messages, 0)
        owner.alive = true; console.valid = true
        unchanged(server, console, client, 0)
    end)
    test("preview-022", "preview refresh close and editor retirement leave latest reader and archive independent", function()
        local server, owner, console, client = fixture()
        H.latest(client, "9", "Latest awarded clue")
        local latest = H.frames(client, "Mission intel: secret.data")[1]; assert(latest)
        local archive, request = H.open(client)
        H.list(client, request, {H.entry("9", "terminal", "secret", "data", "Latest awarded clue")})
        local form = open(client, owner, console); local messages = #client.messages
        local latestPopups, archivePopups = latest.popupCalls, archive.frame.popupCalls
        local archiveBody, archiveStatus = archive.body.text, archive.status.text
        form.preview:DoClick(); local first = preview(client).frame
        form.intel:SetText("Second preview"); form.preview:DoClick(); equal(live(first), false)
        preview(client).frame:Close(); form.preview:DoClick(); form.cancel:DoClick()
        preview(client, 0); equal(live(latest), true); equal(live(archive.frame), true)
        equal(latest.popupCalls, latestPopups); equal(archive.frame.popupCalls, archivePopups)
        equal(archive.body.text, archiveBody); equal(archive.status.text, archiveStatus)
        for _, child in ipairs(latest.children) do
            if child.class == "DTextEntry" then equal(child.text, "Latest awarded clue") end
        end
        equal(#H.frames(client, "Mission intel: secret.data"), 1)
        equal(#H.frames(client, "Saved mission intel"), 1)
        H.latest(client, "9", "Duplicate must not overwrite")
        equal(latest.popupCalls, latestPopups)
        for _, child in ipairs(latest.children) do
            if child.class == "DTextEntry" then equal(child.text, "Latest awarded clue") end
        end
        unchanged(server, console, client, messages + 1)
    end)
    test("preview-023", "small large and supported resizes preserve exact geometry body identity and focus counts", function()
        local server, owner, console, client = fixture()
        local form = open(client, owner, console, "data", "Raw\r\nDraft"); form.preview:DoClick()
        local view, count = preview(client), #client.panels; geometry(view, 640, 480)
        local focus, popups = #client.focusCalls, view.frame.popupCalls
        for _, size in ipairs({{1920, 1080}, {800, 600}, {640, 480}}) do
            client.ScrW, client.ScrH = function() return size[1] end, function() return size[2] end
            client.fire("OnScreenSizeChanged", 0, 0)
            equal(preview(client).frame, view.frame); equal(preview(client).body, view.body)
            geometry(view, size[1], size[2]); equal(#client.panels, count)
            equal(view.body.text, "Raw\nDraft"); equal(form.intel.text, "Raw\r\nDraft")
            equal(#client.focusCalls, focus); equal(view.frame.popupCalls, popups)
        end
        unchanged(server, console, client, 0)
    end)
    test("preview-024", "unsupported opening falls back and unsupported resize retains last supported geometry", function()
        local server, owner, console, client = fixture()
        client.ScrW, client.ScrH = function() return 639 end, function() return 479 end
        local form = open(client, owner, console, "data", "Raw\rDraft"); form.preview:DoClick()
        local view = preview(client); geometry(view, 640, 480)
        client.ScrW, client.ScrH = function() return 1920 end, function() return 1080 end
        client.fire("OnScreenSizeChanged", 639, 479); geometry(view, 1920, 1080)
        local count, focus, popups = #client.panels, #client.focusCalls, view.frame.popupCalls
        for _, size in ipairs({{639, 480}, {640, 479}, {0 / 0, 480}, {math.huge, 480}, {"640", 480}}) do
            client.ScrW, client.ScrH = function() return size[1] end, function() return size[2] end
            client.fire("OnScreenSizeChanged", 1920, 1080); geometry(view, 1920, 1080)
            equal(preview(client).frame, view.frame); equal(preview(client).body, view.body)
        end
        client.ScrW, client.ScrH = function() return 640 end, function() return 480 end
        client.fire("OnScreenSizeChanged", 0, 0); geometry(view, 640, 480)
        equal(#client.panels, count); equal(#client.focusCalls, focus); equal(view.frame.popupCalls, popups)
        equal(view.body.text, "Raw\nDraft"); equal(form.intel.text, "Raw\rDraft")
        unchanged(server, console, client, 0)
    end)
end
