-- Test-local vector/wire/drawing doubles; the addon callbacks remain real.
-- This verifies numeric layout decisions, not native projection or rendering.
return function(gmod)
    local M = {}
    local vector = {}
    vector.__index = vector
    function M.vector(x, y, z) return setmetatable({x = x, y = y, z = z}, vector) end
    function vector.__sub(a, b) return M.vector(a.x - b.x, a.y - b.y, a.z - b.z) end
    function vector:Dot(b) return self.x * b.x + self.y * b.y + self.z * b.z end
    function vector:Length() return math.sqrt(self:Dot(self)) end
    function M.wire(env)
        env.net.WriteBool = env.net.WriteString
        env.net.WriteVector = function(value)
            env.net.WriteString(M.vector(value.x, value.y, value.z))
        end
        env.net.ReadBool, env.net.ReadVector = env.net.ReadString, env.net.ReadString
    end
    function M.server()
        local env = gmod.new()
        M.wire(env)
        local console = env.console
        env.console = function(owner)
            local ent = console(owner)
            ent.position = M.vector(ent:EntIndex() * 100, 0, 0)
            function ent:WorldSpaceCenter() return self.position end
            return ent
        end
        return env
    end
    function M.client(width, height)
        local env = gmod.client()
        M.wire(env)
        env.width, env.height, env.draws, env.lines = width or 640, height or 480, {}, {}
        env.ScrW, env.ScrH = function() return env.width end, function() return env.height end
        env.localPlayer = {valid = true, alive = true}
        function env.localPlayer:Alive() return self.alive end
        env.LocalPlayer = function() return env.localPlayer end
        env.eye = M.vector(0, 0, 0)
        env.EyePos = function() return env.eye end
        env.EyeAngles = function() return {
            Forward = function() return M.vector(1, 0, 0) end,
            Right = function() return M.vector(0, 1, 0) end,
            Up = function() return M.vector(0, 0, 1) end,
        } end
        env.TEXT_ALIGN_LEFT, env.TEXT_ALIGN_TOP = 0, 0
        env.surface.SetFont = function() end
        env.surface.GetTextSize = function(text) return (env.utf8.len(text) or #text) * 8, 16 end
        env.surface.SetDrawColor = function() end
        env.surface.DrawLine = function(x1, y1, x2, y2)
            env.lines[#env.lines + 1] = {x1, y1, x2, y2}
        end
        env.draw = {
            RoundedBox = function() end,
            SimpleText = function(text, font, x, y)
                env.draws[#env.draws + 1] = {text = text, x = x, y = y, width = env.surface.GetTextSize(text)}
            end,
        }
        function env.position(x, y, z, screenX, screenY, visible)
            local value = M.vector(x, y, z)
            function value:ToScreen()
                return {x = screenX or env.width / 2, y = screenY or env.height / 2, visible = visible ~= false}
            end
            return value
        end
        function env.paint()
            env.draws, env.lines = {}, {}
            env.fire("HUDPaint")
            return table.concat((function()
                local text = {}; for _, item in ipairs(env.draws) do text[#text + 1] = item.text end
                return text
            end)(), " | ")
        end
        return env
    end
    function M.deliver(client, packet)
        local values = packet.values
        if values[1] then
            local v = values[3]
            client.receive(packet.name, nil, true, values[2], client.position(v.x, v.y, v.z))
        else client.receive(packet.name, nil, false) end
    end
    return M
end
