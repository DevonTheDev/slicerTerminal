-- Run actual creator receivers/callbacks with recorded geometry and state calls.
-- These rectangles and focus proxies do not certify native Derma behavior.
return function(gmod, test, equal)
    local helper = dofile("tests/player-resize-support.lua")(gmod)
    local sizes = {{640, 480}, {800, 600}, {1024, 600}, {1280, 720}, {1366, 768}, {1920, 1080}}
    local invalidSizes = {{0, 0}, {639, 480}, {640, 479}, {-1, 1080}, {"unknown", 480},
        {800, "unknown"}, {math.huge, 1080}, {800, math.huge}, {-math.huge, 480},
        {0 / 0, 480}, {800, 0 / 0}, {false, false}}
    local function clientAt(width, height)
        local client = helper.clientAt(width, height)
        local create = client.vgui.Create
        client.vgui.Create = function(class, parent)
            local panel = create(class, parent)
            for _, name in ipairs({"SetEnabled", "MoveToFront", "SetTitle", "ShowCloseButton",
                "SetDeleteOnClose", "SetDraggable", "AllowInput", "AddChoice"}) do
                local original = panel[name]
                panel[name] = function(self, ...)
                    client.stateCalls[#client.stateCalls + 1] = {panel = self, operation = name}
                    return original(self, ...)
                end
            end
            return panel
        end
        return client
    end
    local function readForm(client, first, kind)
        local form, entries = {kind = kind, controls = {}, labels = {}}, {}
        for i = first, #client.panels do
            local panel = client.panels[i]
            if panel.class == "DFrame" then form.frame = panel
            else form.controls[#form.controls + 1] = panel end
            if panel.class == "DTextEntry" then entries[#entries + 1] = panel
            elseif panel.class == "DComboBox" then form.folder = panel
            elseif panel.class == "DLabel" then form.labels[#form.labels + 1] = panel
            elseif panel.class == "DButton" and (panel.text == "Done" or panel.text == "Save changes") then
                form.submit = panel
            elseif panel.class == "DButton" then form.dismiss = panel end
        end
        equal(#entries, 3, "Keep the exact three editable fields")
        form.name, form.delay, form.file = entries[1], entries[2], entries[3]
        form.status = form.labels[#form.labels]
        assert(form.frame and form.submit and form.dismiss and form.status)
        form.record = helper.upvalue(form.submit.DoClick, kind == "initial" and "setup" or "edit")
        function form:fill(name, delay, file, folder)
            self.name:SetText(name or "draft café 日本語")
            self.delay:SetText(delay or "2.")
            self.file:SetText(file or "draft file")
            if self.folder then self.folder.selected = folder or "server" end
        end
        return form
    end
    local function openInitial(client, owner, identity)
        local first = #client.panels + 1
        client.receive("PlayerSpawnedConsole", nil, owner, identity or "initial:one")
        return readForm(client, first, "initial")
    end
    local function openEdit(client, owner, console, token, delay)
        local first = #client.panels + 1
        client.receive("SlicerSetupEditOpen", nil, console, owner, token or "edit:one",
            {name = "terminal", delay = delay or 0.12345678901234566, fileName = "secret", fileType = "tools"})
        return readForm(client, first, "edit")
    end
    local function fixture(kind, width, height)
        local server, client = gmod.new(), clientAt(width, height)
        local owner = server.player()
        local console = server.console(owner)
        local form = kind == "initial" and openInitial(client, owner) or openEdit(client, owner, console)
        return client, form, owner, console
    end
    local function contained(panel, width, height)
        assert(panel.width > 0 and panel.height > 0, "Positive creator control rectangle")
        assert(panel.x >= 0 and panel.y >= 0 and panel.x + panel.width <= width
            and panel.y + panel.height <= height, "Creator control stays inside its current parent")
    end
    local function separate(a, b)
        assert(a.x + a.width <= b.x or b.x + b.width <= a.x
            or a.y + a.height <= b.y or b.y + b.height <= a.y, "Creator controls do not overlap")
    end
    local function geometry(form, width, height)
        local frame = form.frame
        if form.kind == "initial" then
            equal(frame.x, 0); equal(frame.y, 0)
            equal(frame.width, width, "Initial setup follows current width")
            equal(frame.height, height, "Initial setup follows current height")
            local rows = {form.name, form.delay, form.folder, form.file, form.dismiss, form.submit, form.status}
            for index, panel in ipairs(rows) do
                equal(panel.width, 400); equal(panel.x, (width - 400) / 2)
                equal(panel.height, index == 7 and 72 or 48)
                equal(panel.y, (height - 432) / 2 + (index - 1) * 60)
            end
        else
            equal(frame.width, 460); equal(frame.height, 430)
            equal(frame.x, (width - 460) / 2, "Saved edit stays centered in current width")
            equal(frame.y, (height - 430) / 2, "Saved edit stays centered in current height")
            equal(form.name.y, 62); equal(form.delay.y, 132); equal(form.file.y, 202)
            equal(form.status.y, 286); equal(form.status.height, 60)
            equal(form.submit.y, 366); equal(form.dismiss.y, 366)
            equal(form.submit.height, 44); equal(form.dismiss.height, 44)
        end
        contained(frame, width, height)
        for index, panel in ipairs(form.controls) do
            equal(panel.parent, frame, "Original control keeps its parent")
            contained(panel, frame.width, frame.height)
            for previous = 1, index - 1 do separate(panel, form.controls[previous]) end
        end
    end
    local function snapshot(client, form)
        local before = {panels = #client.panels, messages = #client.messages, timers = #client.timerEvents,
            state = #client.stateCalls, geometry = #client.geometryCalls, stops = #client.stopCalls,
            focus = client.focusedPanel, focusCalls = #client.focusCalls, caretCalls = #client.caretCalls,
            frame = form.frame, record = form.record, controls = {}, serial = client.slicerInitialSetupSerial,
            pending = form.record.pending, token = form.record.token, status = form.status.text,
            name = form.name:GetValue(), delay = form.delay:GetValue(), file = form.file:GetValue(),
            folder = form.folder and form.folder:GetSelected(), selection = form.file.selection, caret = form.file.caret}
        for index, panel in ipairs(form.controls) do
            before.controls[index] = {panel = panel, editable = panel.editable, enabled = panel.enabled,
                keyboard = panel.keyboardInputEnabled, text = panel.text}
        end
        return before
    end
    local function untouched(client, form, before, noGeometry)
        equal(#client.panels, before.panels, "Resize allocates no panels")
        equal(#client.messages, before.messages, "Resize sends no packets")
        equal(#client.timerEvents, before.timers, "Resize changes no timers")
        equal(#client.stateCalls, before.state, "Resize calls no state/focus setters")
        equal(#client.stopCalls, before.stops, "Resize changes no animations")
        equal(client.focusedPanel, before.focus); equal(#client.focusCalls, before.focusCalls)
        equal(#client.caretCalls, before.caretCalls)
        equal(form.frame, before.frame); equal(form.record, before.record)
        equal(form.record.pending, before.pending, "Pending request retains exact identity")
        equal(form.record.token, before.token); equal(client.slicerInitialSetupSerial, before.serial)
        equal(form.status.text, before.status); equal(form.name:GetValue(), before.name)
        equal(form.delay:GetValue(), before.delay); equal(form.file:GetValue(), before.file)
        equal(form.folder and form.folder:GetSelected(), before.folder)
        equal(form.file.selection, before.selection); equal(form.file.caret, before.caret)
        for index, old in ipairs(before.controls) do
            local panel = form.controls[index]
            equal(panel, old.panel); equal(panel.editable, old.editable); equal(panel.enabled, old.enabled)
            equal(panel.keyboardInputEnabled, old.keyboard); equal(panel.text, old.text)
        end
        if noGeometry then equal(#client.geometryCalls, before.geometry, "No geometry work for this event") end
    end

    test("initial creator form reflows without an active player terminal", function()
        local client, form = fixture("initial", 1920, 1080)
        client.resize(640, 480)
        geometry(form, 640, 480)
    end)
    test("saved creator edit reflows without an active player terminal", function()
        local client, form = fixture("edit", 1920, 1080)
        client.resize(640, 480)
        geometry(form, 640, 480)
    end)

    for _, kind in ipairs({"initial", "edit"}) do
        test(kind .. " creator preserves raw rejected draft and controls through both resize directions", function()
            local client, form = fixture(kind, 1920, 1080)
            form:fill("", "2.", "draft file")
            form.submit:DoClick() -- Actual validation retains the draft and sets the status.
            assert(form.status.text:find("Invalid", 1, true))
            form:fill()
            form.file:RequestFocus()
            form.file.caret, form.file.selection = 3, {start = 1, finish = 3}
            for direction = 1, 2 do
                for step = 1, #sizes do
                    local size = sizes[direction == 1 and step or #sizes - step + 1]
                    local before = snapshot(client, form)
                    equal(client.resize(size[1], size[2]), nil, "Creator hook does not suppress other hooks")
                    untouched(client, form, before)
                    geometry(form, size[1], size[2])
                    local same = snapshot(client, form)
                    client.resize(size[1], size[2])
                    untouched(client, form, same, true)
                end
            end
        end)
        for index, size in ipairs(invalidSizes) do
            test(kind .. " creator ignores unsupported dimensions " .. index .. " then recovers", function()
                local client, form = fixture(kind, 800, 600)
                form:fill()
                local before = snapshot(client, form)
                client.resize(size[1], size[2])
                untouched(client, form, before, true)
                geometry(form, 800, 600)
                client.resize(1366, 768)
                untouched(client, form, before)
                geometry(form, 1366, 768)
            end)
            test(kind .. " creator opened during unsupported dimensions " .. index .. " uses minimum budget", function()
                local client, form = fixture(kind, size[1], size[2])
                geometry(form, 640, 480)
                local before = snapshot(client, form)
                client.resize(640, 480)
                untouched(client, form, before, true)
                client.resize(800, 600)
                untouched(client, form, before)
                geometry(form, 800, 600)
            end)
        end
        for _, retirement in ipairs({"close", "remove", "hide", "marked", "deleted"}) do
            test(kind .. " creator old callbacks cannot reflow a replacement after " .. retirement, function()
                local client, old, owner, console = fixture(kind, 1920, 1080)
                local oldReflow = assert(old.record.reflow, "Each creator record owns a geometry callback")
                client.deferPanelRemoval = true
                if retirement == "close" then old.frame:Close()
                elseif retirement == "remove" then old.frame:Remove()
                elseif retirement == "hide" then old.frame:Hide()
                elseif retirement == "marked" then old.frame.markedForDeletion = true
                else old.frame.valid = false end
                local oldGeometry = #client.geometryCalls
                client.resize(640, 480)
                equal(#client.geometryCalls, oldGeometry, "Dead/hidden frame receives no geometry calls")
                local fresh = kind == "initial" and openInitial(client, owner)
                    or openEdit(client, owner, console, "edit:two")
                fresh:fill("replacement", "3.", "replacement file")
                local before = snapshot(client, fresh)
                oldReflow(800, 600)
                old.submit:DoClick(); old.dismiss:DoClick()
                if old.frame.OnClose then old.frame:OnClose() end
                if old.frame.OnRemove then old.frame:OnRemove() end
                untouched(client, fresh, before, true)
                geometry(fresh, 640, 480)
                client.resize(1366, 768)
                untouched(client, fresh, before)
                geometry(fresh, 1366, 768)
            end)
        end
        test(kind .. " creator callback requires its exact current registry owner", function()
            local client, form = fixture(kind, 1920, 1080)
            local callback = assert(form.record.reflow)
            local registry = kind == "initial" and client.slicerInitialSetupState.forms
                or helper.upvalue(form.record.isCurrent, "setupEditForms")
            local key
            for candidate, record in pairs(registry) do if record == form.record then key = candidate end end
            assert(key)
            registry[key] = {frame = form.frame} -- Same panel does not confer record ownership.
            local before = snapshot(client, form)
            callback(640, 480)
            untouched(client, form, before, true)
            registry[key] = form.record
            if kind == "edit" then
                local tokens = helper.upvalue(form.record.isCurrent, "setupEditTokens")
                tokens[form.record.token] = {frame = form.frame}
                callback(640, 480)
                untouched(client, form, before, true)
                tokens[form.record.token] = form.record
            end
            callback(640, 480)
            geometry(form, 640, 480)
        end)
        test(kind .. " creator skips dead marked and hidden child panels", function()
            local client, form = fixture(kind, 1920, 1080)
            form.name:Remove()
            form.delay.markedForDeletion = true
            form.file:Hide()
            local before = #client.geometryCalls
            client.resize(640, 480)
            for index = before + 1, #client.geometryCalls do
                local panel = client.geometryCalls[index].panel
                assert(panel ~= form.name and panel ~= form.delay and panel ~= form.file,
                    "Resize ignores dead, marked and hidden children")
            end
            equal(form.frame.x, kind == "initial" and 0 or 90)
            equal(form.frame.y, kind == "initial" and 0 or 25)
            equal(form.frame.width, kind == "initial" and 640 or 460)
            equal(form.frame.height, kind == "initial" and 480 or 430)
        end)
    end
    test("saved creator name-only edit preserves exact fractional delay across resize", function()
        local client, form = fixture("edit", 1920, 1080)
        local rawDelay = form.delay:GetValue()
        form.name:SetText("Renamed café terminal")
        for _, size in ipairs(sizes) do
            local before = snapshot(client, form)
            client.resize(size[1], size[2])
            untouched(client, form, before)
            geometry(form, size[1], size[2])
        end
        equal(form.delay:GetValue(), rawDelay)
        form.submit:DoClick()
        local packet = assert(client.lastMessage("SlicerSetupEditSave"))
        equal(packet.values[3].delay, 0.12345678901234566)
        equal(packet.values[3].name, "Renamed café terminal")
    end)
    test("creator dimensions are remembered per visible form on duplicate screen events", function()
        local client, old, owner = fixture("initial", 800, 600)
        old.frame:Hide()
        local before = #client.geometryCalls
        client.resize(1366, 768)
        equal(#client.geometryCalls, before)
        local fresh = openInitial(client, owner, "initial:two")
        old.frame:Show()
        local freshBefore = snapshot(client, fresh)
        client.resize(1366, 768) -- Same screen size; only the formerly hidden form is stale.
        untouched(client, fresh, freshBefore)
        geometry(old, 1366, 768); geometry(fresh, 1366, 768)
        for index = freshBefore.geometry + 1, #client.geometryCalls do
            local panel = client.geometryCalls[index].panel
            assert(panel == old.frame or panel.parent == old.frame, "Current form has its own remembered dimensions")
        end
        local same = snapshot(client, fresh)
        client.resize(1366, 768)
        untouched(client, fresh, same, true)
    end)
    test("initial creator registry and callback survive client reinclude", function()
        local client, form, owner = fixture("initial", 1920, 1080)
        form:fill(); form.submit:DoClick()
        local registry, serial = client.slicerInitialSetupState, client.slicerInitialSetupSerial
        local callback, pending = form.record.reflow, form.record.pending
        client.include("entities/consoleent/cl_init.lua")
        equal(client.slicerInitialSetupState, registry); equal(client.slicerInitialSetupSerial, serial)
        equal(registry.forms["initial:one"], form.record)
        equal(form.record.reflow, callback); equal(form.record.pending, pending)
        local before = snapshot(client, form)
        client.resize(640, 480)
        untouched(client, form, before)
        geometry(form, 640, 480)
        client.receive("PlayerSpawnedConsole", nil, owner, "initial:one")
        equal(#client.panels, before.panels); equal(form.record.pending, pending)
    end)
    test("visible creator forms stay independent when the player session closes", function()
        local client, _, _, _, _, owner = helper.fixture(1920, 1080)
        local entry = helper.entry(client)
        local initial = openInitial(client, owner, "initial:independent")
        local console = client.entity("consoleent")
        local edit = openEdit(client, owner, console, "edit:independent")
        initial:fill(); edit:fill()
        client.receive("PlayerDied", nil)
        equal(entry.parent.valid, false)
        local initialBefore, editBefore = snapshot(client, initial), snapshot(client, edit)
        client.resize(640, 480)
        untouched(client, initial, initialBefore); untouched(client, edit, editBefore)
        geometry(initial, 640, 480); geometry(edit, 640, 480)
        local hook = client.hooks.OnScreenSizeChanged.SlicerCreatorFormReflow
        assert(type(hook) == "function", "Creator reflow uses one independent hook")
        initial.frame:Close(); edit.frame:Close()
        local panels, messages, calls = #client.panels, #client.messages, #client.geometryCalls
        client.resize(1366, 768)
        equal(#client.panels, panels); equal(#client.messages, messages); equal(#client.geometryCalls, calls)
        equal(client.hooks.OnScreenSizeChanged.SlicerCreatorFormReflow, hook, "Creator hook stays stable across form lifetimes")
    end)
end
