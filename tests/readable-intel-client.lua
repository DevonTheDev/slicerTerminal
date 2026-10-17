-- Real client receivers and callbacks; geometry/transport are host models, not
-- native Derma, packet delivery, glyph rendering or multiplayer evidence.
return function(gmod, test, equal)
    local function client()
        local env = gmod.client()
        env.ScrW, env.ScrH = function() return 640 end, function() return 480 end
        local create = env.vgui.Create
        env.vgui.Create = function(class, parent)
            local panel = create(class, parent)
            function panel:SetPos(x, y) self.x, self.y = x, y end
            function panel:SetSize(width, height) self.width, self.height = width, height end
            return panel
        end
        return env
    end
    local function packet(env, award, body, recovery, name, folder)
        env.receive("SlicerIntel", nil, award or "1", name or "terminal", "secret", folder or "data", body or "Next instruction", recovery == true)
    end
    local function readers(env)
        local found = {}
        for _, panel in ipairs(env.panels) do
            if panel.valid and not panel:IsMarkedForDeletion() and panel.class == "DFrame"
                and panel.title and panel.title:find("Mission intel: ", 1, true) == 1 then found[#found + 1] = panel end
        end
        return found
    end
    local function bodyOf(frame)
        for _, panel in ipairs(frame.children) do if panel.class == "DTextEntry" then return panel end end
        error("Missing literal reader body")
    end
    local function editor(env, folder, body, token)
        local server = gmod.new()
        local owner, console = server.player(), server.entity("consoleent")
        local first = #env.panels + 1
        env.receive("SlicerSetupEditOpen", nil, console, owner, token or "1",
            {name = "terminal", delay = 2, fileName = "secret", fileType = folder or "data", intelBody = body or ""})
        local form = {inputs = {}}
        for i = first, #env.panels do
            local panel = env.panels[i]
            if panel.class == "DFrame" then form.frame = panel
            elseif panel.class == "DScrollPanel" then form.scroll = panel
            elseif panel.class == "DTextEntry" then form.inputs[#form.inputs + 1] = panel
            elseif panel.class == "DButton" and panel.text == "Save changes" then form.save = panel
            elseif panel.class == "DButton" and panel.text == "Cancel" then form.cancel = panel
            elseif panel.class == "DLabel" then
                form.status = panel
                if panel.text:find(" / 4096 bytes", 1, true) then form.counter = panel end
            end
        end
        form.intel = form.inputs[4]
        return form, owner, console
    end

    test("intel reader presents literal bounded text without chat body or outgoing commands", function()
        local env = client()
        local text = "<b>https://example.invalid</b>\n/run[no] café 日本語\t clue"
        packet(env, "1", text)
        local frames = readers(env); equal(#frames, 1)
        local body = bodyOf(frames[1])
        equal(body.text, text); equal(body.editable, false); equal(body.multiline, true)
        equal(#env.chatMessages, 0); equal(#env.messages, 0)
        equal(frames[1].width, 600); equal(frames[1].height, 440)
        for _, control in ipairs(frames[1].children) do
            assert(control.x >= 0 and control.y >= 0 and control.width > 0 and control.height > 0)
            assert(control.x + control.width <= frames[1].width and control.y + control.height <= frames[1].height)
        end
        assert(frames[1].children[3].text:find("newest 10 clues", 1, true))
        equal(frames[1].children[4].text, "Saved intel")
        equal(frames[1].children[4].class, "DButton")
    end)

    test("duplicate intel delivery neither creates a second window nor repeats focus", function()
        local env = client(); packet(env)
        local frame = readers(env)[1]
        local count, popups = #env.panels, frame.popupCalls
        packet(env)
        equal(#env.panels, count); equal(frame.popupCalls, popups); equal(#readers(env), 1)
        equal(#env.chatMessages, 0)
    end)

    for _, deferred in ipairs({false, true}) do
        test("explicit recovery reopens same closed award with deferred removal " .. tostring(deferred), function()
            local env = client(); packet(env)
            local old = readers(env)[1]
            env.deferPanelRemoval = deferred
            old:Close()
            local count = #env.panels
            packet(env); equal(#env.panels, count, "Unsolicited duplicate does not reopen")
            packet(env, "1", "Next instruction", true)
            local current = readers(env)[1]
            assert(current and current ~= old); equal(#readers(env), 1)
            if old.OnRemove then old.OnRemove() end
            packet(env, "1", "Next instruction", true)
            equal(readers(env)[1], current, "Old cleanup cannot retire the recovered reader")
            equal(#env.messages, 0)
        end)
    end

    test("explicit recovery focuses current reader without altering content or terminal state", function()
        local env = client(); packet(env)
        local frame = readers(env)[1]; local before = #env.panels
        packet(env, "1", "Changed duplicate must not overwrite original", true)
        equal(#env.panels, before); equal(frame.popupCalls, 2); equal(frame.frontCalls, 1)
        equal(bodyOf(frame).text, "Next instruction"); equal(#env.messages, 0)
    end)

    test("newer intel replaces old unread record and delayed older recovery cannot regress it", function()
        local env = client(); packet(env, "9", "Unread first")
        local first = readers(env)[1]
        packet(env, "10", "New intel")
        equal(first.valid, false); equal(#readers(env), 1)
        local second = readers(env)[1]
        packet(env, "9", "Late old intel", true)
        equal(readers(env)[1], second); equal(bodyOf(second).text, "New intel")
        packet(env, "9007199254740991", "Maximum award")
        equal(bodyOf(readers(env)[1]).text, "Maximum award")
        packet(env, "9007199254740990", "Older maximum", true)
        equal(bodyOf(readers(env)[1]).text, "Maximum award")
    end)

    test("failed presentation retains identity and explicit recovery creates a usable reader", function()
        local env = client()
        local create = env.vgui.Create
        env.vgui.Create = function(class, parent)
            if class == "DTextEntry" then error("simulated rendering failure") end
            return create(class, parent)
        end
        packet(env, "1", "Private after failure")
        equal(#readers(env), 0); equal(#env.chatMessages, 1)
        for _, value in ipairs(env.chatMessages[1]) do assert(type(value) ~= "string" or not value:find("Private after failure", 1, true)) end
        env.vgui.Create = create
        packet(env, "1", "Private after failure")
        equal(#readers(env), 0, "Duplicate does not retry presentation automatically")
        packet(env, "1", "Private after failure", true)
        equal(#readers(env), 1); equal(bodyOf(readers(env)[1]).text, "Private after failure")
    end)

    test("invalid intel packets cannot replace a valid reader", function()
        local env = client(); packet(env, "1", "Retained")
        local old = readers(env)[1]
        for _, award in ipairs({"0", "01", "-1", "1.2", "9007199254740992", string.rep("9", 200)}) do
            packet(env, award, "Wrong", true); equal(readers(env)[1], old)
        end
        for _, body in ipairs({"", " \t\n", "bad\0text", "bad\194\128", "bad\255", string.rep("x", 4097), "cr\r\ntext"}) do
            packet(env, "2", body, true); equal(readers(env)[1], old)
        end
        packet(env, "2", "Wrong", true, string.rep("n", 129))
        packet(env, "2", "Wrong", true, "name", "tools")
        equal(readers(env)[1], old); equal(bodyOf(old).text, "Retained")
    end)

    test("death closes ordinary terminal UI without erasing standalone reader", function()
        local env = client(); packet(env)
        local frame = readers(env)[1]
        env.receive("PlayerDied", nil)
        equal(readers(env)[1], frame); equal(#env.messages, 0)
        frame:Close(); packet(env, "1", "Next instruction", true)
        equal(#readers(env), 1)
    end)

    for _, event in ipairs({"ShutDown", "InitPostEntity"}) do
        test("reader lifecycle reset clears frame and ordering on " .. event, function()
            local env = client(); packet(env, "10", "Old map")
            env.fire(event); equal(#readers(env), 0)
            packet(env, "1", "New map")
            equal(bodyOf(readers(env)[1]).text, "New map")
        end)
    end

    test("reader resize preserves the same body and uses no commands or focus change", function()
        local env = client(); packet(env)
        local frame, before = readers(env)[1], #env.panels
        env.ScrW, env.ScrH = function() return 1920 end, function() return 1080 end
        env.fire("OnScreenSizeChanged", 640, 480)
        equal(#env.panels, before); equal(frame.width, 620); equal(frame.height, 520)
        equal(bodyOf(frame).text, "Next instruction"); equal(frame.popupCalls, 1); equal(#env.messages, 0)
    end)

    for _, folder in ipairs({"data", "server"}) do
        test(folder .. " editor has scrolling intel with fixed save cancel and byte counter", function()
            local env = client(); local form = editor(env, folder, "  Clue\n日本語")
            equal(#form.inputs, 4); equal(form.intel.multiline, true)
            equal(form.intel.text, "  Clue\n日本語")
            assert(form.scroll and form.intel.parent ~= form.frame)
            equal(form.save.parent, form.frame); equal(form.cancel.parent, form.frame); equal(form.status.parent, form.frame)
            assert(form.scroll.y + form.scroll.height <= form.status.y)
            assert(form.save.y + form.save.height <= form.frame.height)
            equal(form.counter.text, tostring(#form.intel.text) .. " / 4096 bytes")
            form.intel:SetText("a\r\nb\rc"); form.intel:OnChange()
            equal(form.counter.text, "5 / 4096 bytes")
            form.save:DoClick()
            equal(env.lastMessage("SlicerSetupEditSave").values[3].intelBody, "a\nb\nc")
            for _, input in ipairs(form.inputs) do equal(input.editable, false) end
            equal(form.save.enabled, false)
            env.receive("SlicerSetupEditReply", nil, "1", {ok = false, message = "Keep draft"})
            for _, input in ipairs(form.inputs) do equal(input.editable, true) end
            equal(form.intel.text, "a\r\nb\rc")
        end)
    end

    test("tools editor keeps original three inputs and no intel field", function()
        local env = client(); local form = editor(env, "tools")
        equal(#form.inputs, 3); equal(form.intel, nil); equal(form.scroll, nil)
        form.save:DoClick(); equal(env.lastMessage("SlicerSetupEditSave").values[3].intelBody, nil)
    end)

    for _, input in ipairs({string.rep("a", 4097), "invalid\255", "control\1", "c1\194\159"}) do
        test("intel validation blocks whole client save for " .. (#input > 100 and "over-limit text" or string.format("%q", input)), function()
            local env = client(); local form = editor(env)
            form.intel:SetText(input); form.save:DoClick()
            equal(env.lastMessage("SlicerSetupEditSave"), nil)
            equal(form.intel.text, input, "Never truncate the clue")
            equal(env.focusedPanel, form.intel); equal(form.intel.editable, true)
            assert(form.status.text:find("Mission intel", 1, true))
        end)
    end

    test("explicit blank intel is sent to clear and cancel sends only exact ticket", function()
        local env = client(); local form = editor(env, "data", "Previously saved")
        form.intel:SetText(" \t\r\n"); form.save:DoClick()
        equal(env.lastMessage("SlicerSetupEditSave").values[3].intelBody, "")
        local before = #env.messages
        form.cancel:DoClick()
        equal(#env.messages, before + 1); equal(env.lastMessage("SlicerSetupEditCancel").values[2], "1")
        form.save:DoClick(); equal(#env.messages, before + 1, "Closed callback cannot resubmit")
    end)
end
