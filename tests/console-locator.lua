return function(gmod, test, equal)
    local support = dofile("tests/console-locator-support.lua")(gmod)
    local function contains(text, fragment) assert(text:find(fragment, 1, true), "Missing " .. fragment .. " in " .. text) end
    local function say(env, owner, command) return env.fire("PlayerSay", owner, command) end
    local function list(env, owner, page) equal(say(env, owner, "!listConsoles" .. (page and " " .. page or "")), "") end
    local function locate(env, owner, row)
        local before = #env.messages
        equal(say(env, owner, "!locateConsole " .. row), "", "Locator command is consumed")
        equal(#env.messages, before + 1, "Exactly one private locator packet")
        local packet = env.messages[#env.messages]
        equal(packet.name, "SlicerConsoleLocation"); equal(packet.player, owner)
        return packet
    end
    local function reject(env, owner, command, fragment)
        local before = #env.messages
        equal(say(env, owner, command), "", "Rejected locator command is consumed")
        equal(#env.messages, before, "Rejected request cannot send a position")
        if fragment then contains(owner.chats[#owner.chats], fragment) end
    end
    test("locator numbers five exact last-page rows and sends only the creator a sampled vector", function()
        local env = support.server()
        local owner, other = env.player(), env.player()
        local consoles = {}; for i = 1, 7 do consoles[i] = env.console(owner) end
        local foreign = env.console(other)
        list(env, owner)
        contains(owner.chats[#owner.chats - 6], "!locateConsole <row>")
        for i = 1, 5 do
            contains(owner.chats[#owner.chats - 6 + i], i .. ". Console")
            local packet = locate(env, owner, i)
            equal(packet.values[1], true); equal(#packet.values, 3)
            equal(packet.values[3].x, consoles[i].position.x)
            assert(packet.values[3] ~= consoles[i].position, "Wire samples rather than tracks position")
        end
        list(env, owner, 2)
        equal(locate(env, owner, 1).values[3].x, consoles[6].position.x)
        reject(env, owner, "!locateConsole 3", "!listConsoles")
        reject(env, other, "!locateConsole 1", "!listConsoles")
        list(env, other)
        equal(locate(env, other, 1).values[3].x, foreign.position.x)
        equal(locate(env, owner, 2).values[3].x, consoles[7].position.x)
    end)
    test("locator never re-resolves duplicate names colliding IDs or shifted ordinals", function()
        local env = support.server(); local owner = env.player()
        local first, second = env.console(owner), env.console(owner)
        env.configure(owner, first); env.configure(owner, second)
        first.id, second.id = 0, 0
        list(env, owner)
        first:Remove()
        local third = env.console(owner); third.id = 0
        equal(locate(env, owner, 2).values[3].x, second.position.x)
        reject(env, owner, "!locateConsole 1", "!listConsoles")
        list(env, owner)
        equal(locate(env, owner, 1).values[3].x, second.position.x)
        equal(locate(env, owner, 2).values[3].x, third.position.x)
    end)
    for _, invalidation in ipairs({"removed", "ownership", "class", "expired", "death", "disconnect", "invalid list", "empty list", "range list"}) do
        test("locator rejects stale references after " .. invalidation, function()
            local env = support.server(); local owner = env.player(); local ent = env.console(owner)
            list(env, owner)
            if invalidation == "removed" then ent:Remove()
            elseif invalidation == "ownership" then ent.SlicerCreator = env.player()
            elseif invalidation == "class" then ent.class = "prop_physics"
            elseif invalidation == "expired" then env.now = 60
            elseif invalidation == "death" then env.fire("PlayerDeath", owner)
            elseif invalidation == "disconnect" then env.fire("PlayerDisconnected", owner)
            elseif invalidation == "invalid list" then say(env, owner, "!listConsoles 01")
            elseif invalidation == "empty list" then ent.SlicerCreator = nil; list(env, owner); ent.SlicerCreator = owner
            else list(env, owner, 2) end
            reject(env, owner, "!locateConsole 1", "!listConsoles")
        end)
    end
    test("locator accepts the snapshot just before expiry and clear keeps current rows", function()
        local env = support.server(); local owner = env.player(); env.console(owner); list(env, owner)
        env.now = 59.99
        equal(locate(env, owner, 1).values[1], true)
        local clear = locate(env, owner, "clear")
        equal(clear.values[1], false); equal(#clear.values, 1)
        equal(locate(env, owner, 1).values[1], true)
        env.now = 60; reject(env, owner, "!locateConsole 1", "!listConsoles")
    end)
    test("locator snapshot sweep releases retained removed entities without another request", function()
        local env = support.server(); local owner = env.player(); local ent = env.console(owner)
        local weak = setmetatable({ent}, {__mode = "v"})
        list(env, owner); ent:Remove(); table.remove(env.entities, #env.entities); ent = nil
        collectgarbage("collect"); assert(weak[1], "Live listing should retain its exact reference")
        env.now = 65; env.fire("Think"); collectgarbage("collect")
        equal(weak[1], nil, "Expired snapshots must release entity references during cleanup")
    end)
    test("locator strictly consumes malformed grammar while preserving ordinary near matches", function()
        local env = support.server(); local owner = env.player(); env.console(owner); list(env, owner)
        for _, text in ipairs({"!locateConsole", "!locateConsole 0", "!locateConsole 6", "!locateConsole 01",
            "!locateConsole -1", "!locateConsole 1.0", "!locateConsole 1 2", "!locateConsole  1",
            "!locateConsole\t1", "!locateConsole clear ", "!locateConsole " .. string.rep("9", 200000)}) do
            reject(env, owner, text, "Usage:")
        end
        for _, text in ipairs({"!locateConsoleNow", "!locateConsole1", "!locateconsole 1", "hello"}) do
            equal(say(env, owner, text), nil)
        end
        equal(locate(env, owner, 1).values[1], true)
    end)
    for _, kind in ipairs({"missing", "invalid", "non-player", "dead"}) do
        test("locator rejects " .. kind .. " callers before entity or position access", function()
            local env = support.server(); local owner = env.player(); env.console(owner); list(env, owner)
            if kind == "missing" then owner = nil
            elseif kind == "invalid" then owner.valid = false
            elseif kind == "non-player" then owner.class = "prop_physics"
            else owner.alive = false end
            if owner then function owner:ChatPrint() error("Invalid player output") end end
            reject(env, owner, "!locateConsole 1"); reject(env, owner, "!locateConsole clear")
        end)
    end
    test("locator samples current position and sanitizes only displayed identity", function()
        local env = support.server(); local owner = env.player(); local ent = env.console(owner)
        local info = env.configure(owner, ent)
        local original = "a\0b\9c\194\133d\226\128\168e"
        info.name = original
        list(env, owner); ent.position = support.vector(111, 222, 333)
        local packet = locate(env, owner, 1)
        contains(packet.values[2], "a?b?c?d?e"); equal(info.name, original)
        equal(packet.values[3].x, 111); equal(packet.values[3].y, 222); equal(packet.values[3].z, 333)
        equal(env.receivers.SlicerConsoleLocation, nil, "No client locator packet grants server authority")
    end)
end
