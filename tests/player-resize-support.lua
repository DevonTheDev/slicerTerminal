-- Test-local geometry and callback instrumentation. It does not model native
-- rendering, docking, keyboard dispatch, focus, caret, selection or scrolling.
return function(gmod)
    local M = {}
    local unpackValues = table.unpack or unpack
    function M.clientAt(width, height)
        local client = gmod.client()
        client.ScrW, client.ScrH = function() return width end, function() return height end
        client.geometryCalls, client.stateCalls, client.stopCalls = {}, {}, {}
        local create = client.vgui.Create
        client.vgui.Create = function(class, parent)
            local panel = create(class, parent)
            panel.x, panel.y, panel.width, panel.height = 0, 0, 0, 0
            local function geometry(self, operation, a, b)
                assert(self.valid and not self:IsMarkedForDeletion(), operation .. " on dead/marked panel")
                client.geometryCalls[#client.geometryCalls + 1] = {panel = self, operation = operation}
                if operation == "SetSize" then self.width, self.height = a, b else self.x, self.y = a, b end
            end
            function panel:SetSize(w, h) geometry(self, "SetSize", w, h) end
            function panel:SetPos(x, y) geometry(self, "SetPos", x, y) end
            function panel:Center()
                self:SetPos(((self.parent and self.parent.width or width) - self.width) / 2,
                    ((self.parent and self.parent.height or height) - self.height) / 2)
            end
            function panel:MoveTo(x, y)
                self.animation = {x = x, y = y}
                self:SetPos(x, y) -- Record the destination; completeAnimations can replay it.
            end
            function panel:Stop()
                assert(self.valid and not self:IsMarkedForDeletion(), "Stop on dead/marked panel")
                client.stopCalls[#client.stopCalls + 1] = self
                self.animation = nil
            end
            function panel:GetX() return self.x end
            function panel:GetY() return self.y end
            function panel:SetImage(value) self.image = value end
            for _, name in ipairs({"SetText", "SetPlaceholderText", "SetPlaceholderColor", "SetTextColor",
                "SetEditable", "SetKeyboardInputEnabled", "SetHistoryEnabled", "AddHistory", "SetCaretPos",
                "RequestFocus", "MakePopup", "SetFont", "SetWrap", "SetContentAlignment", "Hide", "Show"}) do
                local original = panel[name]
                panel[name] = function(self, ...)
                    client.stateCalls[#client.stateCalls + 1] = {panel = self, operation = name}
                    return original(self, ...)
                end
            end
            return panel
        end
        function client.resize(w, h)
            local oldWidth, oldHeight = width, height
            width, height = w, h
            return client.fire("OnScreenSizeChanged", oldWidth, oldHeight)
        end
        function client.completeAnimations()
            for _, panel in ipairs(client.panels) do
                if panel.valid and not panel:IsMarkedForDeletion() and panel.animation then
                    panel:SetPos(panel.animation.x, panel.animation.y)
                    panel.animation = nil
                end
            end
        end
        return client
    end
    function M.live(panel)
        while panel do
            if not panel.valid or panel:IsMarkedForDeletion() or not panel:IsVisible() then return false end
            panel = panel.parent
        end
        return true
    end
    function M.entry(client)
        for i = #client.panels, 1, -1 do
            local panel = client.panels[i]
            if M.live(panel) and panel.OnEnter then return panel end
        end
        error("No live command input")
    end
    function M.children(page, predicate)
        local found = {}
        for _, panel in ipairs(page.children) do
            if panel.valid and not panel:IsMarkedForDeletion() and predicate(panel) then found[#found + 1] = panel end
        end
        return found
    end
    function M.button(page, caption)
        return assert(M.children(page, function(p) return p.class == "DButton" and p.text == caption end)[1], caption)
    end
    function M.help(client, entry)
        entry.ShowCommandHelp()
        return assert(M.children(entry.parent, function(p) return p.class == "DFrame" and M.live(p) end)[1], "Commands window")
    end
    function M.visit(client, stage)
        if stage ~= "login" then
            client.command("/a[terminal]")
            client.fireTimer("AccessDelay")
            if stage ~= "folders" then client.command("/a[terminal]/{_" .. stage .. "}") end
        end
        return M.entry(client)
    end
    function M.deliver(client, packet)
        client.receive(packet.name, nil, unpackValues(packet.values))
    end
    function M.fixture(width, height, kind)
        local server, client = gmod.new(), M.clientAt(width, height)
        local owner, hacker = server.player(), server.player()
        local console = server.console(owner)
        local info = server.configure(owner, console, kind or "data", 2)
        if kind == "tools" then
            owner.target = server.entity("func_door")
            server.fire("PlayerSay", owner, "!setEntity")
        end
        server.open(hacker, console)
        M.deliver(client, assert(server.lastMessage("ServerSendsEntityInformation")))
        return client, server, hacker, console, info, owner
    end
    function M.upvalue(callback, name)
        for i = 1, math.huge do
            local key, value = debug.getupvalue(callback, i)
            if not key then break end
            if key == name then return value end
        end
        error("Missing upvalue " .. name)
    end
    return M
end
