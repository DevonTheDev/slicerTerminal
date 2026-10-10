-- The actual client net receivers and VGUI callbacks run against the existing
-- host substitutions. Rectangles do not certify native fonts or pointer input.
return function(gmod, test, equal)
    local function clientAt(width, height)
        local client = gmod.client()
        client.ScrW, client.ScrH = function() return width or 640 end, function() return height or 480 end
        local create = client.vgui.Create
        client.vgui.Create = function(class, parent)
            local panel = create(class, parent)
            panel.x, panel.y, panel.width, panel.height = 0, 0, 0, 0
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
            function panel:Center()
                self.x = ((self.parent and self.parent.width or client.ScrW()) - self.width) / 2
                self.y = ((self.parent and self.parent.height or client.ScrH()) - self.height) / 2
            end
            return panel
        end
        return client
    end
    local function packetCount(client, name)
        local count = 0
        for _, packet in ipairs(client.messages) do if not name or packet.name == name then count = count + 1 end end
        return count
    end
    local function readForm(client, first)
        local form, entries = {labels = {}, controls = {}}, {}
        for i = first, #client.panels do
            local panel = client.panels[i]
            if panel.class == "DFrame" then form.frame = panel
            else form.controls[#form.controls + 1] = panel end
            if panel.class == "DTextEntry" then entries[#entries + 1] = panel
            elseif panel.class == "DLabel" then form.labels[#form.labels + 1] = panel
            elseif panel.class == "DButton" and panel.text == "Save changes" then form.save = panel
            elseif panel.class == "DButton" and panel.text == "Cancel" then form.cancel = panel end
            assert(panel.class ~= "DComboBox", "Editing must not offer folder reassignment")
        end
        assert(form.frame and form.save and form.cancel, "Expected edit frame, Save changes and Cancel")
        equal(#entries, 3, "Only name, delay and filename are editable")
        form.name, form.delay, form.file = entries[1], entries[2], entries[3]
        function form:fill(name, delay, file)
            self.name:SetText(name or "New terminal")
            self.delay:SetText(delay or "4.5")
            self.file:SetText(file or "New secret")
        end
        function form:text()
            local text = ""
            for _, label in ipairs(self.labels) do text = text .. " " .. label.text end
            return text
        end
        return form
    end
    local function open(client, owner, console, token, info)
        local first = #client.panels + 1
        client.receive("SlicerSetupEditOpen", nil, console, owner, token,
            info or {name = "terminal", delay = 2, fileName = "secret", fileType = "tools"})
        return readForm(client, first)
    end
    local function fixture(width, height)
        local server, client = gmod.new(), clientAt(width, height)
        local owner = server.player()
        local console = server.console(owner)
        return client, owner, console, open(client, owner, console, "edit:one")
    end
    local function reply(client, token, ok, message)
        client.receive("SlicerSetupEditReply", nil, token, {ok = ok, message = message or "Saved."})
    end
    local function assertCancel(client, console, token, count)
        equal(packetCount(client, "SlicerSetupEditCancel"), count or 1)
        local packet = assert(client.lastMessage("SlicerSetupEditCancel"))
        equal(#packet.values, 2); equal(packet.values[1], console); equal(packet.values[2], token)
        for _, outgoing in ipairs(client.messages) do
            assert(outgoing.name == "SlicerSetupEditSave" or outgoing.name == "SlicerSetupEditCancel",
                "Editing must not send terminal/setup/link packets: " .. outgoing.name)
        end
    end

    test("edit open prefills current settings and displays the fixed folder", function()
        local client, _, _, form = fixture()
        equal(form.name:GetValue(), "terminal"); equal(form.delay:GetValue(), "2")
        equal(form.file:GetValue(), "secret")
        assert(form:text():find("tools", 1, true), "Display the fixed folder")
        for _, label in ipairs({"Console name", "Slice delay (seconds)", "Filename (no extension)"}) do
            assert(form:text():find(label, 1, true), "Prefilled inputs need visible labels: " .. label)
        end
        equal(packetCount(client), 0, "Opening must not start a terminal session")
    end)

    test("edit save reads focused live values and waits for matching acknowledgement", function()
        local client, _, console, form = fixture()
        form:fill(" Current terminal ", "2.5", " Current file ")
        form.file:RequestFocus() -- No focus-loss or OnEnter callback.
        form.save:DoClick()
        local packet = assert(client.lastMessage("SlicerSetupEditSave"))
        equal(#packet.values, 3); equal(packet.values[1], console); equal(packet.values[2], "edit:one")
        local value = packet.values[3]
        equal(value.name, " Current terminal "); equal(value.delay, 2.5); equal(value.fileName, " Current file ")
        local fields = 0; for _ in pairs(value) do fields = fields + 1 end
        equal(fields, 3, "Only editable settings may leave the form")
        equal(form.frame.valid, true, "Save must not close optimistically")
        equal(form.save.enabled, false); equal(form.cancel.enabled ~= false, true)
        for _, input in ipairs({form.name, form.delay, form.file}) do
            equal(input.editable, false, "Pending acknowledgement must not lose newer typing")
        end
        assert(form:text():lower():find("saving", 1, true), "Show pending status")
        assert(form:text():find("Closing cannot undo a submitted save", 1, true), "Pending dismissal must explain that Save may already be applied")
        equal(form.cancel.text, "Close", "A pending dismissal must not promise to cancel the submitted write")
        equal(packetCount(client), 1)
        reply(client, "another-token", true)
        equal(form.frame.valid, true, "Unrelated acknowledgement cannot close this form")
        reply(client, "edit:one", true)
        equal(form.frame.valid, false); equal(packetCount(client), 1, "Success must not cancel a consumed ticket")
        form.save:DoClick(); form.cancel:DoClick()
        reply(client, "edit:one", true)
        equal(packetCount(client), 1, "Saved callbacks remain retired")
    end)

    for _, invalid in ipairs({
        {"empty name", "", "2", "file"}, {"blank name", " \t ", "2", "file"},
        {"long name", string.rep("a", 129), "2", "file"},
        {"empty file", "name", "2", ""}, {"blank file", "name", "2", " \t "},
        {"long file", "name", "2", string.rep("f", 129)},
        {"zero", "name", "0", "file"}, {"negative", "name", "-1", "file"},
        {"text delay", "name", "later", "file"}, {"infinite delay", "name", "1e999", "file"},
        {"negative infinity", "name", "-1e999", "file"}, {"NaN delay", "name", "nan", "file"},
        {"blank delay", "name", "", "file"},
    }) do
        test("edit validation retains invalid " .. invalid[1] .. " for correction", function()
            local client, _, _, form = fixture()
            form:fill(invalid[2], invalid[3], invalid[4])
            form.save:DoClick()
            equal(packetCount(client), 0); equal(form.frame.valid, true)
            equal(form.name:GetValue(), invalid[2]); equal(form.delay:GetValue(), invalid[3]); equal(form.file:GetValue(), invalid[4])
            assert(form:text():lower():find("invalid", 1, true) or form:text():find("128", 1, true), "Explain invalid fields")
            form:fill(); form.save:DoClick()
            equal(packetCount(client, "SlicerSetupEditSave"), 1, "Correction must remain available")
        end)
    end

    for _, sample in ipairs({
        {"fractional", 0.12345678901234566},
        {"near one", 1.0000000000000002},
        {"large finite", 1.7976931348623157e308},
    }) do
        test("name-only edit preserves the exact stored " .. sample[1] .. " delay", function()
            local server, client = gmod.new(), clientAt()
            local owner = server.player()
            local console = server.console(owner)
            local original = sample[2]
            local form = open(client, owner, console, "edit:precision", {
                name = "terminal", delay = original, fileName = "secret", fileType = "data",
            })
            form.name:SetText("Renamed terminal") -- Keep the displayed delay untouched.
            form.save:DoClick()
            local packet = assert(client.lastMessage("SlicerSetupEditSave"))
            local actual = packet.values[3].delay
            assert(actual == original, "Unedited delay changed: expected " .. string.format("%.17g", original)
                .. ", got " .. string.format("%.17g", actual))
            equal(packet.values[3].name, "Renamed terminal")
            equal(packet.values[3].fileName, "secret")
        end)
    end

    test("simple delay prefills remain short and editable", function()
        for _, sample in ipairs({{2, "2"}, {2.5, "2.5"}, {0.1, "0.1"}}) do
            local server, client = gmod.new(), clientAt()
            local owner = server.player()
            local console = server.console(owner)
            local form = open(client, owner, console, "edit:simple", {
                name = "terminal", delay = sample[1], fileName = "secret", fileType = "data",
            })
            equal(form.delay:GetValue(), sample[2], "A simple number needs no noisy decimal tail")
            form.delay:SetText("3.25"); form.save:DoClick()
            equal(client.lastMessage("SlicerSetupEditSave").values[3].delay, 3.25, "Save still reads the edited field")
        end
    end)

    test("edit names allow the existing 128 byte boundary and positive fractional delay", function()
        local client, _, _, form = fixture()
        form:fill(string.rep("n", 128), "0.1", string.rep("f", 128)); form.save:DoClick()
        equal(packetCount(client, "SlicerSetupEditSave"), 1)
    end)

    test("edit rejection preserves the draft and permits a corrected retry", function()
        local client, _, _, form = fixture()
        form:fill(); form.save:DoClick(); form.save:DoClick()
        equal(packetCount(client, "SlicerSetupEditSave"), 1, "Pending Save must not resend")
        reply(client, "edit:one", false, "The delay is invalid; choose a positive number.")
        equal(form.frame.valid, true); equal(form.name:GetValue(), "New terminal")
        equal(form.delay:GetValue(), "4.5"); equal(form.file:GetValue(), "New secret")
        equal(form.save.enabled, true); equal(form.cancel.text, "Cancel")
        for _, input in ipairs({form.name, form.delay, form.file}) do equal(input.editable, true) end
        assert(form:text():find("The delay is invalid", 1, true), "Explain the server rejection")
        form.delay:SetText("3"); form.save:DoClick()
        equal(packetCount(client, "SlicerSetupEditSave"), 2)
        equal(client.lastMessage("SlicerSetupEditSave").values[3].delay, 3)
    end)

    test("obsolete token-only reply preserves draft and displays close reopen guidance", function()
        local client, _, console, form = fixture()
        form:fill(); form.save:DoClick(); console.valid = false
        reply(client, "edit:one", false, "This edit is no longer current. Close and reopen with !editConsole.")
        equal(form.frame.valid, true); equal(form.name:GetValue(), "New terminal")
        assert(form:text():find("Close and reopen with !editConsole", 1, true))
        form.cancel:DoClick(); assertCancel(client, console, "edit:one")
    end)

    test("repeated current edit opens bring forward the existing draft including pending save", function()
        local client, owner, console, form = fixture()
        form:fill(); local count, popups = #client.panels, form.frame.popupCalls
        client.receive("SlicerSetupEditOpen", nil, console, owner, "edit:one", {name = "stale", delay = 9, fileName = "stale", fileType = "tools"})
        equal(#client.panels, count); equal(form.name:GetValue(), "New terminal")
        equal(form.frame.popupCalls, popups + 1); equal(form.frame.frontCalls, 1)
        form.save:DoClick()
        client.receive("SlicerSetupEditOpen", nil, console, owner, "edit:one", {})
        equal(#client.panels, count); form.save:DoClick()
        equal(packetCount(client, "SlicerSetupEditSave"), 1)
        form.cancel:DoClick(); assertCancel(client, console, "edit:one")
    end)

    test("replacement token retires old buttons and acknowledgements without affecting another form", function()
        local client, owner, console, old = fixture()
        old:fill(); old.save:DoClick()
        local otherConsole = client.entity("consoleent")
        local other = open(client, owner, otherConsole, "edit:other")
        other:fill("Other draft", "3", "Other file")
        local fresh = open(client, owner, console, "edit:new")
        equal(old.frame.valid, false); assertCancel(client, console, "edit:one")
        fresh:fill("Newest draft", "7", "Newest file")
        local count = packetCount(client)
        old.save:DoClick(); old.cancel:DoClick(); old.frame.OnClose(); old.frame.OnRemove()
        reply(client, "edit:one", true); reply(client, "edit:one", false, "Old rejection")
        equal(packetCount(client), count); equal(fresh.frame.valid, true); equal(other.frame.valid, true)
        equal(fresh.name:GetValue(), "Newest draft"); equal(other.name:GetValue(), "Other draft")
        fresh.save:DoClick(); reply(client, "edit:new", true)
        equal(fresh.frame.valid, false); equal(other.frame.valid, true)
        other.cancel:DoClick(); assertCancel(client, otherConsole, "edit:other", 2)
    end)

    for _, action in ipairs({"cancel", "close", "remove"}) do
        for _, deferred in ipairs({false, true}) do
            test("edit " .. action .. " synchronously cancels only its ticket with deferred removal " .. tostring(deferred), function()
                local client, owner, console, form = fixture()
                local otherConsole = client.entity("consoleent")
                local other = open(client, owner, otherConsole, "edit:other")
                form.save:DoClick()
                client.deferPanelRemoval = deferred
                if action == "cancel" then form.cancel:DoClick()
                elseif action == "close" then form.frame:Close()
                else form.frame:Remove() end
                assertCancel(client, console, "edit:one")
                equal(other.frame.valid, true)
                local fresh = open(client, owner, console, "edit:new")
                local count = packetCount(client)
                form.save:DoClick(); form.cancel:DoClick()
                reply(client, "edit:one", true); reply(client, "edit:one", false, "Old rejection")
                if form.frame.OnClose then form.frame:OnClose() end
                if form.frame.OnRemove then form.frame:OnRemove() end
                equal(packetCount(client), count); equal(fresh.frame.valid, true); equal(other.frame.valid, true)
                fresh.save:DoClick(); reply(client, "edit:new", true)
                equal(packetCount(client, "SlicerSetupEditCancel"), 1, "Success cannot cancel or retire another edit")
                other.save:DoClick(); reply(client, "edit:other", true)
                equal(packetCount(client, "SlicerSetupEditCancel"), 1)
            end)
        end
    end

    test("pending Close stays available and late success leaves other and replacement forms alone", function()
        local client, owner, console, form = fixture()
        form.save:DoClick()
        equal(form.cancel.text, "Close"); equal(form.cancel.enabled ~= false, true)
        client.deferPanelRemoval = true
        form.cancel:DoClick(); assertCancel(client, console, "edit:one")
        local fresh = open(client, owner, console, "edit:new")
        local other = open(client, owner, client.entity("consoleent"), "edit:other")
        local count = #client.panels
        reply(client, "edit:one", true)
        equal(#client.panels, count, "Late success cannot reopen a closed form")
        equal(fresh.frame.valid, true); equal(other.frame.valid, true)
        equal(packetCount(client), 2, "Only the original Save and exact-ticket Cancel were sent")
    end)

    test("an unsolicited success cannot close an unsaved current edit", function()
        local client, _, _, form = fixture()
        form:fill()
        reply(client, "edit:one", true)
        equal(form.frame.valid, true); equal(form.name:GetValue(), "New terminal")
        form.save:DoClick(); reply(client, "edit:one", true)
        equal(form.frame.valid, false); equal(packetCount(client), 1)
    end)

    for _, native in ipairs({"Close", "Remove"}) do
        test("edit retires before native " .. native .. " can reenter callbacks", function()
            local client, _, console, form = fixture()
            form.frame["beforeNative" .. native] = function()
                assertCancel(client, console, "edit:one")
                local count = packetCount(client)
                form.save:DoClick(); form.cancel:DoClick()
                reply(client, "edit:one", false, "Late rejection")
                equal(packetCount(client), count, "Callbacks retired before native cleanup starts")
            end
            form.frame[native](form.frame)
            equal(packetCount(client), 1); equal(form.frame.valid, false)
        end)
    end

    for _, size in ipairs({{640, 480}, {800, 600}, {1024, 600}, {1280, 720}, {1366, 768}, {1920, 1080}}) do
        test("edit initial form geometry fits " .. size[1] .. "x" .. size[2], function()
            local _, _, _, form = fixture(size[1], size[2])
            local frame = form.frame
            assert(frame.width > 0 and frame.height > 0)
            assert(frame.x >= 0 and frame.y >= 0 and frame.x + frame.width <= size[1] and frame.y + frame.height <= size[2])
            for _, panel in ipairs(form.controls) do
                equal(panel.parent, frame)
                assert(panel.width > 0 and panel.height > 0, panel.class .. " needs a visible rectangle")
                assert(panel.x >= 12 and panel.y >= 12 and panel.x + panel.width <= frame.width - 12
                    and panel.y + panel.height <= frame.height - 12, panel.class .. " leaves the form margins")
            end
            for _, control in ipairs({form.name, form.delay, form.file, form.save, form.cancel}) do
                assert(control.height >= 36, "Interactive controls need usable initial height")
            end
            for i, left in ipairs(form.controls) do
                for j = i + 1, #form.controls do
                    local right = form.controls[j]
                    assert(left.x + left.width <= right.x or right.x + right.width <= left.x
                        or left.y + left.height <= right.y or right.y + right.height <= left.y,
                        "Edit controls overlap: " .. left.class .. " / " .. right.class)
                end
            end
        end)
    end

    local function identityInfo(identity)
        return {name = "terminal", delay = 2, fileName = "secret", fileType = "tools", displayIdentity = identity}
    end
    for _, sample in ipairs({{0, 1}, {123, 45}, {4294967295, 65535}}) do
        test("edit title uses bounded server identity " .. sample[1] .. "/" .. sample[2], function()
            local client, owner, console, previous = fixture()
            local info = identityInfo({creationID = sample[1], entityIndex = sample[2]})
            local form = open(client, owner, console, "identity:new", info)
            equal(form.frame.title, string.format("Edit console #%.0f (entity %.0f)", sample[1], sample[2]))
            assert(form.frame.title ~= previous.frame.title)
            info.displayIdentity.creationID = 999; info.displayIdentity.entityIndex = 999
            info.name = "untrusted title\ntext"
            form.name:SetText("Draft\nname")
            equal(form.frame.title, string.format("Edit console #%.0f (entity %.0f)", sample[1], sample[2]), "Captured title must not alias packet or editable text")
            local messages = packetCount(client)
            form.save:DoClick()
            equal(packetCount(client), messages + 1)
            local fields = client.lastMessage("SlicerSetupEditSave").values[3]
            equal(fields.displayIdentity, nil)
            local count = 0; for _ in pairs(fields) do count = count + 1 end; equal(count, 3)
        end)
    end

    local invalidIdentities = {
        {"legacy absent"}, {"boolean", false}, {"text", "#42"}, {"number", 42},
        {"empty table", {}}, {"missing creation", {entityIndex = 1}}, {"missing index", {creationID = 1}},
    }
    for _, field in ipairs({"creationID", "entityIndex"}) do
        for _, bad in ipairs({{"text", "1"}, {"table", {}}, {"boolean", false},
            {"negative", -1}, {"fraction", 1.5}, {"NaN", 0/0}, {"infinity", math.huge}, {"negative infinity", -math.huge}}) do
            local identity = {creationID = 42, entityIndex = 7}; identity[field] = bad[2]
            invalidIdentities[#invalidIdentities + 1] = {field .. " " .. bad[1], identity}
        end
    end
    invalidIdentities[#invalidIdentities + 1] = {"oversized creation", {creationID = 4294967296, entityIndex = 1}}
    invalidIdentities[#invalidIdentities + 1] = {"zero index", {creationID = 1, entityIndex = 0}}
    invalidIdentities[#invalidIdentities + 1] = {"oversized index", {creationID = 1, entityIndex = 65536}}
    for _, sample in ipairs(invalidIdentities) do
        test("edit " .. sample[1] .. " display metadata keeps a usable generic title", function()
            local client, owner, console = fixture()
            local form = open(client, owner, console, "identity:fallback", identityInfo(sample[2]))
            equal(form.frame.title, "Edit console settings")
            form:fill(); form.save:DoClick()
            equal(client.lastMessage("SlicerSetupEditSave").values[2], "identity:fallback")
            equal(client.lastMessage("SlicerSetupEditSave").values[3].displayIdentity, nil)
            reply(client, "identity:fallback", true)
            equal(form.frame.valid, false, "Optional display failure cannot prevent editing")
        end)
    end

    test("identity title and draft survive repeated opens pending rejection and resize", function()
        local client, owner, console = fixture()
        local form = open(client, owner, console, "identity:stable", identityInfo({creationID = 42, entityIndex = 7}))
        local title = "Edit console #42 (entity 7)"
        equal(form.frame.title, title)
        form:fill("Renamed draft", "3", "Draft file")
        local panelCount = #client.panels
        local function reopen(info)
            client.receive("SlicerSetupEditOpen", nil, console, owner, "identity:stable", info)
            equal(#client.panels, panelCount); equal(form.frame.title, title)
            equal(form.name:GetValue(), "Renamed draft")
        end
        reopen(identityInfo({creationID = 99, entityIndex = 11}))
        form.save:DoClick(); local messages = packetCount(client)
        reopen({}); form.save:DoClick(); equal(packetCount(client), messages)
        for _, size in ipairs({{1920, 1080}, {640, 480}, {800, 600}}) do
            client.ScrW, client.ScrH = function() return size[1] end, function() return size[2] end
            client.fire("OnScreenSizeChanged", 640, 480)
            equal(form.frame.title, title); equal(form.name:GetValue(), "Renamed draft")
            equal(form.save.enabled, false); equal(form.cancel.text, "Close")
            assert(form.frame.x >= 0 and form.frame.y >= 0
                and form.frame.x + form.frame.width <= size[1] and form.frame.y + form.frame.height <= size[2])
        end
        reply(client, "identity:stable", false, "Correct the delay.")
        equal(form.frame.title, title); equal(form.save.enabled, true)
        equal(form.name:GetValue(), "Renamed draft")
        client.ScrW, client.ScrH = function() return 640 end, function() return 480 end
        client.fire("OnScreenSizeChanged", 800, 600); equal(form.frame.title, title)
    end)
end
