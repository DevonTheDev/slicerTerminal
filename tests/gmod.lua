-- Minimal test doubles for the Garry's Mod APIs used by this addon.
local M = {}
local root = "devonsSlicing/lua/"

-- Translate only GLua operators/comments, preserving quoted strings and long
-- comments. This lets stock Lua execute the actual addon rather than a copy.
function M.source(path)
    local file = assert(io.open(path, "r"))
    local source = file:read("*a")
    file:close()
    local out, i = {}, 1
    while i <= #source do
        local rest = source:sub(i)
        local quote = source:sub(i, i)
        local long = rest:match("^%-%-%[(=*)%[")
        if long ~= nil then
            local close = "]" .. long .. "]"
            local finish = assert(source:find(close, i + #long + 4, true), "unclosed comment") + #close - 1
            out[#out + 1], i = source:sub(i, finish), finish + 1
        elseif rest:sub(1, 2) == "--" or rest:sub(1, 2) == "//" then
            local finish = source:find("\n", i, true) or (#source + 1)
            out[#out + 1], i = "--" .. source:sub(i + 2, finish - 1), finish
        elseif quote == '"' or quote == "'" then
            local finish = i + 1
            while finish <= #source do
                if source:sub(finish, finish) == "\\" then
                    finish = finish + 2
                elseif source:sub(finish, finish) == quote then
                    break
                else
                    finish = finish + 1
                end
            end
            out[#out + 1], i = source:sub(i, finish), finish + 1
        elseif rest:sub(1, 2) == "!=" then
            out[#out + 1], i = "~=", i + 2
        elseif quote == "!" then
            out[#out + 1], i = "not ", i + 1
        else
            out[#out + 1], i = quote, i + 1
        end
    end
    return table.concat(out)
end

local function copy(value)
    if type(value) ~= "table" then return value end
    local result = {}
    for key, item in pairs(value) do result[key] = copy(item) end
    return result
end

function M.new()
    local env = setmetatable({}, {__index = _G})
    env._G, env.ENT, env.SWEP = env, {}, {}
    env.unpack = unpack or table.unpack
    env.entities, env.messages, env.receivers, env.hooks = {}, {}, {}, {}
    env.now, env.nextID = 0, 0
    env.SOLID_BBOX, env.SIMPLE_USE = 1, 1
    env.IsValid = function(value) return type(value) == "table" and value.valid == true end
    env.isnumber = function(value) return type(value) == "number" end
    env.CurTime = function() return env.now end
    env.AddCSLuaFile = function() end
    env.table = setmetatable({}, {__index = table})
    env.table.Copy = copy
    -- GLua is based on Lua 5.1, which permits insertion at index zero.
    -- Emulate that old behavior when running under Lua 5.3/5.4 so unrelated
    -- session tests reach their actual assertions on the original addon.
    function env.table.insert(values, position, value)
        if value == nil then return table.insert(values, position) end
        if position == 0 then
            for i = #values + 1, 1, -1 do values[i] = values[i - 1] end
            values[0] = value
            return
        end
        return table.insert(values, position, value)
    end
    env.table.maxn = function(value)
        local max = 0
        for key in pairs(value) do if type(key) == "number" and key > max then max = key end end
        return max
    end
    env.table.HasValue = function(values, value)
        for _, candidate in pairs(values) do if candidate == value then return true end end
        return false
    end
    env.string = setmetatable({}, {__index = string})
    env.string.Trim = function(value) return value:match("^%s*(.-)%s*$") end
    env.util = {AddNetworkString = function() end}
    env.net = {}
    function env.net.Receive(name, callback) env.receivers[name] = callback end
    function env.net.Start(name) env.outgoing = {name = name, values = {}} end
    function env.net.WriteEntity(value) table.insert(env.outgoing.values, value) end
    function env.net.WriteString(value) table.insert(env.outgoing.values, value) end
    function env.net.WriteTable(value) table.insert(env.outgoing.values, copy(value)) end
    function env.net.Send(player)
        env.outgoing.player = player
        table.insert(env.messages, env.outgoing)
        env.outgoing = nil
    end
    local function read() return table.remove(env.incoming, 1) end
    env.net.ReadEntity, env.net.ReadString, env.net.ReadTable = read, read, read
    function env.receive(name, sender, ...)
        env.incoming = {...}
        assert(env.receivers[name], "Missing receiver: " .. name)(0, sender)
    end
    env.hook = {}
    function env.hook.Add(event, name, callback)
        env.hooks[event] = env.hooks[event] or {}
        env.hooks[event][name] = callback
    end
    function env.hook.Remove(event, name)
        if env.hooks[event] then env.hooks[event][name] = nil end
    end
    function env.fire(event, ...)
        for _, callback in pairs(env.hooks[event] or {}) do
            local result = callback(...)
            if result ~= nil then return result end
        end
    end
    env.ents = {}
    function env.ents.FindByClass(class)
        local found = {}
        for _, ent in ipairs(env.entities) do
            if ent.valid and ent.class == class then table.insert(found, ent) end
        end
        return found
    end
    function env.include(path)
        local source = M.source(root .. path)
        local chunk
        if _VERSION == "Lua 5.1" then
            chunk = assert(loadstring(source, "@" .. path))
            setfenv(chunk, env)
        else
            chunk = assert(load(source, "@" .. path, "t", env))
        end
        return chunk()
    end
    function env.entity(class)
        env.nextID = env.nextID + 1
        local ent = {valid = true, class = class, id = env.nextID, name = "", inputs = {}}
        function ent:IsPlayer() return self.class == "player" end
        function ent:GetClass() return self.class end
        function ent:GetCreationID() return self.id end
        function ent:GetName() return self.name end
        function ent:SetName(value) self.name = value end
        function ent:SetModel() end
        function ent:SetSolid() end
        function ent:SetUseType() end
        function ent:Fire(input) table.insert(self.inputs, input) end
        function ent:Remove()
            if self.OnRemove then self:OnRemove() end
            self.valid, self.removed = false, true
        end
        table.insert(env.entities, ent)
        return ent
    end
    function env.player()
        local ply = env.entity("player")
        ply.alive, ply.chats = true, {}
        ply.weapon = env.entity("weapon_hacking")
        function ply:SteamID64() return "76561198000000000" .. self.id end
        function ply:Alive() return self.alive end
        function ply:GetActiveWeapon() return self.weapon end
        function ply:ChatPrint(text) table.insert(self.chats, text) end
        function ply:GetEyeTrace() return {Entity = self.target} end
        return ply
    end
    function env.console(creator)
        local console = setmetatable(env.entity("consoleent"), {__index = env.ENT})
        console:Initialize()
        env.fire("PlayerSpawnedSENT", creator, console)
        return console
    end
    function env.configure(ply, console, fileType, delay)
        env.receive("AdminFinishedCreation", ply, {"Terminal", delay or 2, fileType or "data", "Secret", console:GetName()})
        local entries = env.returnSpawnedEntities()
        for _, entry in pairs(entries) do
            if entry.entityName == console:GetName() then return entry.information end
        end
    end
    function env.open(ply, console) console:AcceptInput("Use", ply, ply) end
    function env.lastMessage(name)
        for i = #env.messages, 1, -1 do
            if env.messages[i].name == name then return env.messages[i] end
        end
    end
    env.include("autorun/server/sv_config.lua")
    env.include("entities/consoleent/init.lua")
    return env
end

function M.client()
    local env = M.new()
    env.ENT, env.receivers, env.hooks, env.panels, env.timers = {}, {}, {}, {}, {}
    env.surface = {CreateFont = function() end, PlaySound = function() end}
    env.Color = function(...) return {...} end
    env.ScrW, env.ScrH = function() return 1920 end, function() return 1080 end
    env.player = {GetAll = function() return {1} end}
    env.chatMessages = {}
    env.chat = {AddText = function(...) table.insert(env.chatMessages, {...}) end}
    env.table.RemoveByValue = function(values, value)
        for i, entry in ipairs(values) do if entry == value then return table.remove(values, i) end end
    end
    env.math = setmetatable({Round = function(value) return value end}, {__index = math})
    env.timer = {}
    function env.timer.Create(name, delay, repeats, callback)
        env.timers[name] = {delay = delay, callback = callback}
    end
    function env.timer.Remove(name) env.timers[name] = nil end
    function env.timer.Stop(name) if env.timers[name] then env.timers[name].stopped = true end end
    function env.timer.Start(name) if env.timers[name] then env.timers[name].stopped = false end end
    function env.timer.Exists(name) return env.timers[name] ~= nil end
    function env.timer.TimeLeft(name) return env.timers[name].delay end
    function env.fireTimer(name)
        local timer = assert(env.timers[name], "Missing timer: " .. name)
        env.timers[name] = nil
        timer.callback()
    end
    function env.net.SendToServer() env.net.Send("server") end
    env.vgui = {}
    function env.vgui.Create(class, parent)
        local panel = {valid = true, class = class, parent = parent, text = "", children = {}}
        if parent then table.insert(parent.children, panel) end
        for _, name in ipairs({"SetSize", "Center", "ShowCloseButton", "MakePopup", "SetTitle", "SetDeleteOnClose", "SetDraggable", "SetFont", "SetPlaceholderText", "SetPlaceholderColor", "SetPos", "SetTextColor", "SetEditable", "SetPaintBackground", "SetCursorColor", "SetContentAlignment", "MoveTo", "SetImage", "AllowInput", "AddChoice"}) do
            panel[name] = function(self, ...) assert(self.valid, name .. " on removed panel") end
        end
        function panel:SetText(value) assert(self.valid, "SetText on removed panel"); self.text = value end
        function panel:GetValue() assert(self.valid, "GetValue on removed panel"); return self.text end
        function panel:GetSelected() return self.selected end
        function panel:GetX() return 0 end
        function panel:GetY() return 0 end
        function panel:GetTextSize() return 100, 20 end
        function panel:Hide() self.hidden = true end
        function panel:Show() self.hidden = false end
        function panel:Remove()
            assert(self.valid, "Remove on removed panel")
            self.valid = false
            for _, child in ipairs(self.children) do if child.valid then child:Remove() end end
        end
        panel.Close = panel.Remove
        table.insert(env.panels, panel)
        return panel
    end
    function env.command(command)
        for i = #env.panels, 1, -1 do
            local panel = env.panels[i]
            local visible, ancestor = panel.valid, panel
            while ancestor do
                if ancestor.hidden or not ancestor.valid then visible = false end
                ancestor = ancestor.parent
            end
            if visible and panel.OnEnter then
                panel:SetText(command)
                panel:OnEnter()
                return
            end
        end
        error("No active command input")
    end
    function env.assertClosed()
        for _, panel in ipairs(env.panels) do assert(not panel.valid, "Leaked " .. panel.class) end
        assert(next(env.timers) == nil, "Leaked timer")
        assert(next(env.hooks.Think or {}) == nil, "Leaked Think hook")
    end
    env.include("entities/consoleent/cl_init.lua")
    return env
end

return M
