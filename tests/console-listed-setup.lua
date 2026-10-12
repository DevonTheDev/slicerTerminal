-- Actual public chat/lifecycle callbacks and recorded native packet calls.
-- No private lease/session state is read; these doubles do not certify GMod.
return function(gmod, test, equal)
    local support = dofile("tests/console-locator-support.lua")(gmod)
    local function say(env, actor, command) return env.fire("PlayerSay", actor, command) end
    local function list(env, actor, command) equal(say(env, actor, command or "!listConsoles"), "") end
    local function fixture(count)
        local env = support.server()
        local owner, other, consoles = env.player(), env.player(), {}
        function owner:GetPos() return support.vector(0, 0, 0) end
        for i = 1, count or 2 do
            consoles[i] = env.console(owner)
            local console = consoles[i]
            function console:GetPos() return self.position end
        end
        function owner:GetEyeTrace() error("Listed setup must never use an eye trace") end
        function owner:GetActiveWeapon() error("Listed setup must never need a weapon") end
        return env, owner, other, consoles
    end
    local function opening(env, owner, row, console)
        local before, chats, calls = #env.messages, #owner.chats, {}
        local start, entity, str = env.net.Start, env.net.WriteEntity, env.net.WriteString
        env.net.Start = function(name) calls[#calls + 1] = "Start:" .. name; start(name) end
        env.net.WriteEntity = function(value) calls[#calls + 1] = "Entity"; entity(value) end
        env.net.WriteString = function(value) calls[#calls + 1] = "String"; str(value) end
        local handled = say(env, owner, "!setupConsole " .. row)
        env.net.Start, env.net.WriteEntity, env.net.WriteString = start, entity, str
        -- First success assertion deliberately fails at the missing public
        -- command on the unchanged production baseline, rather than a helper.
        equal(#env.messages, before + 1, "Listed setup must emit one fresh opening")
        equal(handled, ""); equal(#owner.chats, chats)
        local packet = env.messages[#env.messages]
        equal(packet.name, "PlayerSpawnedConsole"); equal(packet.player, owner)
        equal(#packet.values, 3); equal(packet.values[1], owner); equal(packet.values[2], console:GetName())
        equal(table.concat(calls, ","), "Start:PlayerSpawnedConsole,Entity,String,String")
        return packet
    end
    local function reject(env, owner, row, hint)
        local before, chats = #env.messages, owner and #owner.chats or 0
        equal(say(env, owner, "!setupConsole " .. (row or "1")), "", "Recognized refusal is consumed")
        equal(#env.messages, before, "A refused opening has no packet or fallback")
        if hint then
            equal(#owner.chats, chats + 1, "At most one private failure line")
            local text = owner.chats[#owner.chats]
            assert(#text < 255 and text:find(hint, 1, true), "Missing bounded refusal: " .. text)
        end
    end

    test("listed setup opens the exact unconfigured second row through public chat", function()
        local env, owner, other, consoles = fixture()
        list(env, owner)
        opening(env, owner, 2, consoles[2])
        equal(consoles[1].SlicerInformation, nil); equal(consoles[2].SlicerInformation, nil)
        equal(#env.returnSpawnedEntities(), 0); equal(owner.SlicerPendingConsole, nil)
        equal(#other.chats, 0)
    end)

    test("listed setup accepts precisely five row spellings and no near matches", function()
        local env, owner, _, consoles = fixture(5)
        list(env, owner)
        for row = 1, 5 do opening(env, owner, row, consoles[row]) end
        local packets, chats = #env.messages, #owner.chats
        for _, command in ipairs({"!setupConsole", "!setupconsole 1", "!SetupConsole 1", " !setupConsole 1",
            "!setupConsole ", "!setupConsole 0", "!setupConsole 6", "!setupConsole 01", "!setupConsole -1",
            "!setupConsole +1", "!setupConsole 1.0", "!setupConsole 1e0", "!setupConsole  1", "!setupConsole\t1",
            "!setupConsole 1 ", "!setupConsole 1\n", "!setupConsole\n1", "!setupConsole 1\0",
            "!setupConsole 1 2", "!setupConsole1", "!setupConsoleNow", "!setupConsole １", "!setupConsole ١",
            "!setupConsole " .. string.rep("1", 200000)}) do
            equal(say(env, owner, command), nil, "Near-match text stays ordinary chat")
        end
        equal(#env.messages, packets); equal(#owner.chats, chats)
        opening(env, owner, 5, consoles[5])
    end)

    test("listed setup requires a page and never borrows another creator's page", function()
        local env, owner, other, consoles = fixture()
        reject(env, owner, 1, "!listConsoles")
        list(env, owner); reject(env, owner, 3, "!listConsoles")
        local foreign = env.console(other); list(env, other)
        opening(env, other, 1, foreign); opening(env, owner, 2, consoles[2])
    end)

    test("listed setup follows page two setup filtering nearest and changed search rows", function()
        local env, owner, _, consoles = fixture(7)
        list(env, owner, "!listConsoles 2"); opening(env, owner, 1, consoles[6])
        reject(env, owner, 3, "!listConsoles")
        env.configure(owner, consoles[1]); env.configure(owner, consoles[2])
        list(env, owner, "!listConsoles 1 setup"); opening(env, owner, 1, consoles[3])
        consoles[7].position = support.vector(1, 0, 0)
        list(env, owner, "!nearConsoles"); opening(env, owner, 1, consoles[7])
        list(env, owner, "!findConsoles 1 terminal")
        consoles[2].SlicerInformation = nil
        opening(env, owner, 2, consoles[2])
        equal(say(env, owner, "!locateConsole 2"), "")
        equal(env.lastMessage("SlicerConsoleLocation").values[3].x, consoles[2].position.x)
    end)

    for _, command in ipairs({"!listConsoles 01", "!listConsoles 2", "!listConsoles 1 linked",
        "!listConsoles 1 setup ignored", "!findConsoles 1 missing", "!findConsoles 01 terminal",
        "!findConsoles 1 ", "!nearConsoles 01", "!nearConsoles 2"}) do
        test("listed setup loses an old page after recognized relisting " .. command, function()
            local env, owner = fixture(); list(env, owner); list(env, owner, command)
            reject(env, owner, 1, "!listConsoles")
        end)
    end
    test("listed setup loses an old page after unavailable nearest origin", function()
        local env, owner = fixture(); list(env, owner)
        owner.GetPos = nil; list(env, owner, "!nearConsoles")
        reject(env, owner, 1, "!listConsoles")
    end)
    test("listed setup success does not consume renew or change shared actions' lease", function()
        local env, owner, _, consoles = fixture()
        list(env, owner); opening(env, owner, 2, consoles[2])
        equal(say(env, owner, "!locateConsole 2"), "")
        equal(say(env, owner, "!locateConsole clear"), "")
        env.now = 59.99; opening(env, owner, 2, consoles[2])
        env.now = 60 -- Deliberately no Think sweep.
        reject(env, owner, 2, "!listConsoles")
        local packets = #env.messages
        equal(say(env, owner, "!locateConsole 2"), ""); equal(#env.messages, packets)
        equal(say(env, owner, "!editConsole 2"), ""); equal(#env.messages, packets)
        equal(say(env, owner, "!setEntity 2"), ""); equal(#env.messages, packets)
        list(env, owner); opening(env, owner, 2, consoles[2])
    end)
    test("listed setup rejects removed reference even with a replacement's synthetic name and IDs", function()
        local env, owner, _, consoles = fixture(); list(env, owner)
        local old = consoles[2]; local name, id, index = old:GetName(), old:GetCreationID(), old:EntIndex()
        old:Remove()
        local replacement = env.console(owner); replacement:SetName(name); replacement.id = id
        function replacement:EntIndex() return index end
        reject(env, owner, 2, "!listConsoles")
        equal(replacement.SlicerInformation, nil)
        list(env, owner); opening(env, owner, 2, replacement)
    end)
    test("ordinary removal and paste use CreationID names for a new unconfigured creator", function()
        local env, owner, other, consoles = fixture(); local oldName = consoles[1]:GetName()
        consoles[1]:Remove()
        local copy = env.console(owner)
        assert(copy:GetName() ~= oldName, "Ordinary removal does not reuse a live-count name")
        copy.SlicerCreator = owner; copy:SetName(oldName); copy:OnDuplicated(); copy:PostEntityPaste(other)
        equal(copy:GetName(), "DevonsConsoleEntity" .. copy:GetCreationID()); assert(copy:GetName() ~= oldName)
        list(env, other); opening(env, other, 1, copy)
        list(env, owner); reject(env, owner, 2, "!listConsoles")
        env.configure(other, copy); list(env, other); reject(env, other, 1, "eligible")
    end)

    for _, kind in ipairs({"owner", "class", "configured", "malformed", "false", "actual session"}) do
        test("listed setup refuses current ineligibility: " .. kind, function()
            local env, owner, other, consoles = fixture(); local console = consoles[2]
            if kind == "actual session" then env.configure(owner, console); env.open(other, console) end
            list(env, owner)
            if kind == "owner" then console.SlicerCreator = other
            elseif kind == "class" then console.class = "prop_physics"
            elseif kind == "configured" then env.configure(owner, console)
            elseif kind == "malformed" then console.SlicerInformation = {}
            elseif kind == "false" then console.SlicerInformation = false
            else console.SlicerInformation = nil end
            reject(env, owner, 2, (kind == "owner" or kind == "class") and "!listConsoles" or "eligible")
            if kind == "actual session" then equal(say(env, other, "!quitConsole"), ""); equal(console.SlicerInformation, nil) end
        end)
    end
    for _, case in ipairs({{"empty", ""}, {"257 bytes", string.rep("x", 257)}, {"embedded NUL", "bad\0name"},
        {"boolean", false}, {"table", {}}}) do
        test("listed setup refuses a receipt-incompatible runtime name: " .. case[1], function()
            local env, owner, _, consoles = fixture(); list(env, owner); consoles[2].name = case[2]
            reject(env, owner, 2, "eligible")
        end)
    end
    test("listed setup allows a 256-byte runtime name without changing it", function()
        local env, owner, _, consoles = fixture(); list(env, owner); consoles[2].name = string.rep("x", 256)
        opening(env, owner, 2, consoles[2])
    end)
    for _, configured in ipairs({false, true}) do
        test("listed setup refuses present same-owner raw-name collision even if configured " .. tostring(configured), function()
            local env, owner, _, consoles = fixture(); list(env, owner)
            if configured then env.configure(owner, consoles[1]) end
            consoles[1]:SetName(consoles[2]:GetName())
            reject(env, owner, 2, "eligible")
            equal(consoles[2].SlicerInformation, nil)
        end)
    end
    test("listed setup ignores foreign raw-name matches", function()
        local env, owner, other, consoles = fixture(); local foreign = env.console(other)
        foreign:SetName(consoles[2]:GetName()); list(env, owner); opening(env, owner, 2, consoles[2])
    end)
    for _, kind in ipairs({"missing", "invalid", "non-player", "dead"}) do
        test("listed setup silently consumes command for " .. kind .. " actor", function()
            local env, owner = fixture(); list(env, owner)
            if kind == "missing" then owner = nil elseif kind == "invalid" then owner.valid = false
            elseif kind == "non-player" then owner.class = "prop_physics" else owner.alive = false end
            if owner then function owner:ChatPrint() error("Unsafe actor output") end end
            reject(env, owner, 1)
        end)
    end
    for _, event in ipairs({"PlayerDeath", "PlayerDisconnected", "reinclude"}) do
        test("listed setup old page is unavailable after " .. event, function()
            local env, owner = fixture(); list(env, owner)
            if event == "reinclude" then env.include("entities/consoleent/init.lua") else env.fire(event, owner) end
            reject(env, owner, 1, "!listConsoles")
        end)
    end
    test("config reinclude does not consume the existing current setup page", function()
        local env, owner, _, consoles = fixture(); list(env, owner)
        env.include("autorun/server/sv_config.lua"); opening(env, owner, 2, consoles[2])
    end)

    local mutations = {"replacement page", "same-row newer page", "name", "creation ID", "entity index",
        "creator", "configuration", "class", "remove", "death", "disconnect", "expiry", "ambiguity"}
    for _, boundary in ipairs({"resolver", "name accessor", "creation accessor", "index accessor", "class accessor", "player accessor", "scan"}) do
        for _, mutation in ipairs(mutations) do
            test("listed setup rechecks " .. mutation .. " after " .. boundary .. " callback", function()
                local env, owner, other, consoles = fixture(); list(env, owner); local selected = consoles[2]
                local fired = false
                local function change()
                    if fired then return end
                    fired = true
                    if mutation == "replacement page" then list(env, owner, "!nearConsoles"); list(env, owner, "!listConsoles 1 setup")
                        -- Force a different row without privately changing its lease.
                        consoles[1].id, selected.id = selected.id, consoles[1].id; list(env, owner)
                    elseif mutation == "same-row newer page" then list(env, owner)
                    elseif mutation == "name" then selected:SetName("ChangedRuntimeName")
                    elseif mutation == "creation ID" then selected.id = selected.id + 50
                    elseif mutation == "entity index" then function selected:EntIndex() return 900 end
                    elseif mutation == "creator" then selected.SlicerCreator = other
                    elseif mutation == "configuration" then selected.SlicerInformation = false
                    elseif mutation == "class" then selected.class = "prop_physics"
                    elseif mutation == "remove" then selected:Remove()
                    elseif mutation == "death" then owner.alive = false; env.fire("PlayerDeath", owner)
                    elseif mutation == "disconnect" then owner.valid = false; env.fire("PlayerDisconnected", owner)
                    elseif mutation == "expiry" then env.now = 60
                    else consoles[1]:SetName(selected.name) end
                end
                if boundary == "resolver" then
                    local resolve = env.slicerListedConsole
                    env.slicerListedConsole = function(...)
                        local result = resolve(...); change(); return result
                    end
                elseif boundary == "scan" then
                    local scan = env.ents.FindByClass
                    env.ents.FindByClass = function(...) local result = scan(...); change(); return result end
                else
                    local method = boundary == "name accessor" and "GetName" or boundary == "creation accessor" and "GetCreationID"
                        or boundary == "index accessor" and "EntIndex" or boundary == "class accessor" and "GetClass" or "IsPlayer"
                    local target = boundary == "player accessor" and owner or selected
                    local original, reads = target[method], 0
                    target[method] = function(self)
                        local result = original(self); reads = reads + 1
                        -- Establish the opening snapshot first, then mutate a
                        -- subsequent validation read. An atomic native getter
                        -- does not expose an earlier unsampled scalar value.
                        if reads == 2 then change() end
                        return result
                    end
                end
                reject(env, owner, 2)
                equal(fired, true, "The callback mutation must actually execute")
                if mutation == "same-row newer page" then
                    equal(env.slicerListedConsole(owner, 2), selected, "Refusal must retain the newer page")
                elseif mutation == "replacement page" then
                    equal(env.slicerListedConsole(owner, 1), selected, "Refusal must not restore the old page")
                end
                if mutation == "death" or mutation == "disconnect" then equal(#owner.chats, 3, "No unsafe refusal output") end
            end)
        end
    end
    test("final setup opener actor check cannot bypass a newly replaced same-row page", function()
        local env, owner, _, consoles = fixture(); list(env, owner)
        local alive, changed = owner.Alive, false
        function owner:Alive()
            -- The existing helper remains the final physical actor check.
            local info = debug.getinfo(2, "n")
            if not changed and info and info.name == "openSetup" then changed = true; list(env, owner) end
            return alive(self)
        end
        reject(env, owner, 2); equal(changed, true)
        equal(env.slicerListedConsole(owner, 2), consoles[2])
    end)
    for _, mutation in ipairs({"name", "creation ID", "entity index", "configuration", "creator", "remove", "dead", "invalid", "ambiguity"}) do
        test("final physical actor check is followed by listed context validation for " .. mutation, function()
            local env, owner, other, consoles = fixture(); list(env, owner)
            local selected, alive, changed = consoles[2], owner.Alive, false
            for _, method in ipairs({"GetName", "GetCreationID", "EntIndex", "GetClass"}) do
                local original = selected[method]
                selected[method] = function(self) assert(self.valid, "Unsafe " .. method .. " on removed entity"); return original(self) end
            end
            function owner:Alive()
                local info = debug.getinfo(2, "n")
                if not changed and info and info.name == "openSetup" then
                    changed = true
                    if mutation == "name" then selected:SetName("ChangedDuringActorCheck")
                    elseif mutation == "creation ID" then selected.id = selected.id + 10
                    elseif mutation == "entity index" then function selected:EntIndex() return 800 end
                    elseif mutation == "configuration" then selected.SlicerInformation = false
                    elseif mutation == "creator" then selected.SlicerCreator = other
                    elseif mutation == "remove" then selected:Remove()
                    elseif mutation == "dead" then owner.alive = false
                    elseif mutation == "invalid" then owner.valid = false
                    else consoles[1]:SetName(selected.name) end
                    -- A stale accessor return must not bypass the listed guard.
                    return true
                end
                return alive(self)
            end
            reject(env, owner, 2); equal(changed, true)
        end)
    end
    test("listed opening writes the captured name without an accessor after net.Start", function()
        local env, owner, _, consoles = fixture(); list(env, owner)
        local selected, start, name, emission = consoles[2], env.net.Start, consoles[2]:GetName(), false
        function selected:GetName() assert(not emission, "Name accessor after final guard"); return name end
        env.net.Start = function(packet) if packet == "PlayerSpawnedConsole" then emission = true end; return start(packet) end
        local before = #env.messages
        equal(say(env, owner, "!setupConsole 2"), ""); equal(#env.messages, before + 1)
        equal(env.messages[#env.messages].values[2], name)
    end)
    test("final setup opener does not call a retiring actor's Alive method", function()
        local env, owner = fixture(); list(env, owner)
        local isPlayer, alive, changed = owner.IsPlayer, owner.Alive, false
        function owner:IsPlayer()
            local result, info = isPlayer(self), debug.getinfo(2, "n")
            if not changed and info and info.name == "openSetup" then changed = true; self.valid = false end
            return result
        end
        function owner:Alive() assert(self.valid, "Unsafe Alive on retiring actor"); return alive(self) end
        reject(env, owner, 2); equal(changed, true)
    end)
end
