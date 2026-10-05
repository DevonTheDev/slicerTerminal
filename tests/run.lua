local gmod = dofile("tests/gmod.lua")
local passed, failed = 0, 0
local function test(name, callback)
    local ok, err = pcall(callback)
    if ok then passed = passed + 1; print("PASS " .. name)
    else failed = failed + 1; print("FAIL " .. name .. ": " .. tostring(err)) end
end
local function equal(actual, expected, message)
    assert(actual == expected, (message or "Unexpected value") .. ": expected " .. tostring(expected) .. ", got " .. tostring(actual))
end
local function fixture(fileType)
    local env = gmod.new()
    local owner, hacker = env.player(), env.player()
    local console = env.console(owner)
    local info = assert(env.configure(owner, console, fileType))
    return env, owner, hacker, console, info
end

test("unrelated entities cannot be removed by a client packet", function()
    local env = gmod.new()
    local player, prop = env.player(), env.entity("prop_physics")
    env.receive("destroyOnServer", player, prop)
    equal(prop.removed, nil, "An arbitrary prop was removed")
end)

test("configured consoles cannot be deleted without a session", function()
    local env, _, hacker, console = fixture()
    env.receive("destroyOnServer", hacker, console)
    equal(console.removed, nil)
end)

test("opening a console reserves it immediately", function()
    local env, _, hacker, console, info = fixture()
    env.open(hacker, console)
    equal(info.inUse, true)
    equal(env.lastMessage("ServerSendsEntityInformation").values[3].inUse, false, "The owner must still be allowed to open the client UI")
end)

test("another player cannot enter a reserved console", function()
    local env, _, hacker, console = fixture()
    env.open(hacker, console)
    local count = #env.messages
    env.open(env.player(), console)
    equal(#env.messages, count)
end)

test("quit releases only the authenticated sender's session", function()
    local env, owner, hacker, console, info = fixture()
    env.open(hacker, console)
    env.receive("updateInUse", hacker, console:GetName())
    env.receive("playerQuitConsole", owner, hacker, console)
    equal(info.inUse, true)
    env.receive("playerQuitConsole", hacker, owner, console)
    equal(info.inUse, false)
end)

test("death releases the terminal and notifies its player", function()
    local env, _, hacker, console, info = fixture()
    env.open(hacker, console)
    env.receive("updateInUse", hacker, console:GetName())
    hacker.alive = false
    env.fire("PlayerDeath", hacker)
    equal(info.inUse, false)
    equal(env.lastMessage("PlayerDied").player, hacker)
end)

test("disconnect releases a reserved console", function()
    local env, _, hacker, console, info = fixture()
    env.open(hacker, console)
    env.receive("updateInUse", hacker, console:GetName())
    env.fire("PlayerDisconnected", hacker)
    equal(info.inUse, false)
end)

test("invalid activators and missing weapons do not crash Use", function()
    local env, _, hacker, console = fixture()
    env.open(nil, console)
    env.open(env.entity("prop_physics"), console)
    hacker.weapon = nil
    env.open(hacker, console)
end)

test("download completion cannot skip the configured minimum delays", function()
    local env, _, hacker, console, info = fixture()
    env.open(hacker, console)
    env.receive("destroyOnServer", hacker, console)
    equal(console.removed, nil)
    equal(info.inUse, false, "An early completion must release its rejected session")
    env.open(hacker, console) -- Retry explicitly; the rejected session cannot resume.
    env.now = 4
    env.receive("destroyOnServer", hacker, console)
    equal(console.removed, true)
end)

test("another client cannot finish someone else's session", function()
    local env, owner, hacker, console = fixture()
    env.open(hacker, console)
    env.now = 10
    env.receive("destroyOnServer", owner, console)
    equal(console.removed, nil)
end)

test("only the console creator can configure it", function()
    local env = gmod.new()
    local owner, attacker = env.player(), env.player()
    local console = env.console(owner)
    env.configure(attacker, console)
    equal(#env.returnSpawnedEntities(), 0)
    assert(env.configure(owner, console))
end)

test("malformed configuration is rejected without crashing", function()
    local env = gmod.new()
    local owner = env.player()
    local console = env.console(owner)
    for _, info in ipairs({{}, {false, 2, "data", "file", console:GetName()}, {"name", -1, "data", "file", console:GetName()}, {"name", math.huge, "data", "file", console:GetName()}, {"name", 2, "invalid", "file", console:GetName()}}) do
        env.receive("AdminFinishedCreation", owner, info)
    end
    equal(#env.returnSpawnedEntities(), 0)
end)

test("configuration is not duplicated or reset on reinclude", function()
    local env, owner, _, console = fixture()
    env.configure(owner, console)
    equal(#env.returnSpawnedEntities(), 1)
    env.include("autorun/server/sv_config.lua")
    equal(#env.returnSpawnedEntities(), 1)
end)

test("console names stay unique after deleting an earlier console", function()
    local env = gmod.new()
    local owner = env.player()
    local first, second = env.console(owner), env.console(owner)
    first:Remove()
    local third = env.console(owner)
    assert(second:GetName() ~= third:GetName(), "Console name collision")
end)

test("door completion without a session is harmless", function()
    local env = gmod.new()
    env.receive("PlayerActivatedDoor", env.player(), env.entity("prop_physics"))
end)

test("two tools consoles unlock only their own doors", function()
    local env, owner, hacker, console = fixture("tools")
    local owner2 = env.player()
    local console2 = env.console(owner2)
    assert(env.configure(owner2, console2, "tools"))
    local door, door2 = env.entity("func_door"), env.entity("func_door")
    owner.target, owner2.target = door, door2
    env.receive("ServerWaitingForEntity", owner, owner)
    env.fire("PlayerSay", owner, "!setEntity")
    env.receive("ServerWaitingForEntity", owner2, owner2)
    env.fire("PlayerSay", owner2, "!setEntity")
    env.open(hacker, console)
    env.now = 2
    env.receive("PlayerActivatedDoor", hacker, console)
    equal(door.inputs[#door.inputs], "Unlock")
    equal(door2.inputs[#door2.inputs], "Lock")
    equal(console.removed, true)
    equal(console2.removed, nil)
end)

test("the legacy update packet cannot lock another console", function()
    local env, owner, _, console, info = fixture()
    env.receive("updateInUse", owner, console:GetName())
    equal(info.inUse, false)
end)

test("removing a busy console closes its session and clears configuration", function()
    local env, _, hacker, console = fixture()
    env.open(hacker, console)
    console:Remove()
    equal(#env.returnSpawnedEntities(), 0)
    equal(env.lastMessage("PlayerDied").player, hacker)
end)

test("a player can open a new console after quitting", function()
    local env, owner, hacker, first = fixture()
    local second = env.console(owner)
    local secondInfo = env.configure(owner, second)
    env.open(hacker, first)
    env.receive("playerQuitConsole", hacker, hacker, first)
    env.open(hacker, second)
    equal(secondInfo.inUse, true)
end)

test("data sessions cannot unlock doors", function()
    local env, _, hacker, console = fixture()
    env.open(hacker, console)
    env.now = 100
    env.receive("PlayerActivatedDoor", hacker, console)
    equal(console.removed, nil)
end)

test("a tools console cannot be opened before a door is linked", function()
    local env, _, hacker, console, info = fixture("tools")
    env.open(hacker, console)
    equal(env.lastMessage("ServerSendsEntityInformation"), nil)
    equal(info.inUse, false)
end)

test("door linking ignores a forged player in the legacy packet", function()
    local env, owner, hacker, console = fixture("tools")
    local door = env.entity("func_door")
    hacker.target = door
    env.receive("ServerWaitingForEntity", hacker, owner)
    env.fire("PlayerSay", hacker, "!setEntity")
    equal(#door.inputs, 0)
    equal(console.SlicerDoor, nil)
end)

test("an unrelated door Use leaves other addons in control", function()
    local env = gmod.new()
    equal(env.fire("PlayerUse", env.player(), env.entity("func_door")), nil)
end)

local function openClient(fileType)
    local env = gmod.client()
    local player = env.entity("player")
    env.receive("ServerSendsEntityInformation", nil, env.entity("consoleent"), player,
        {name = "terminal", delay = 2, fileType = fileType or "data", fileName = "secret", inUse = false}, "console1")
    return env, player
end

local function openSetup(env, entityName, player)
    player = player or env.entity("player")
    player.chats = player.chats or {}
    function player:ChatPrint(message) table.insert(self.chats, message) end
    local start = #env.panels
    env.receive("PlayerSpawnedConsole", nil, player, entityName or "console1")
    local form, entries = {player = player}, {}
    for i = start + 1, #env.panels do
        local panel = env.panels[i]
        if panel.class == "DFrame" then form.frame = panel
        elseif panel.class == "DComboBox" then form.folder = panel
        elseif panel.class == "DButton" then form.done = panel
        elseif panel.class == "DTextEntry" then entries[#entries + 1] = panel end
    end
    form.name, form.delay, form.file = entries[1], entries[2], entries[3]
    function form:fill(name, delay, folder, file, blur)
        self.name:SetText(name)
        self.delay:SetText(delay)
        self.file:SetText(file)
        self.folder.selected = folder
        if self.folder.OnSelect then self.folder:OnSelect() end
        if blur then
            for _, entry in ipairs(entries) do
                if entry.OnLoseFocus then entry:OnLoseFocus() end
            end
        end
    end
    return form
end

test("setup submits current fields without requiring focus loss", function()
    local env = gmod.client()
    local form = openSetup(env)
    form:fill("Terminal", "2.5", "data", "Secret", false)
    form.done:DoClick()
    local message = assert(env.lastMessage("AdminFinishedCreation"), "No configuration sent")
    local information = message.values[1]
    equal(information[1], "Terminal")
    equal(information[2], 2.5)
    equal(information[3], "data")
    equal(information[4], "Secret")
    equal(information[5], "console1")
    equal(form.frame.valid, false)
end)

test("setup uses edits made after the last focus loss", function()
    local env = gmod.client()
    local form = openSetup(env)
    form:fill("Original", "2", "data", "OldFile", true)
    form:fill("Current", "3", "server", "NewFile", false)
    form.done:DoClick()
    local information = assert(env.lastMessage("AdminFinishedCreation")).values[1]
    equal(information[1], "Current")
    equal(information[2], 3)
    equal(information[3], "server")
    equal(information[4], "NewFile")
end)

test("a new setup never reuses a completed form's values", function()
    local env = gmod.client()
    local first = openSetup(env, "first")
    first:fill("First", "2", "data", "Secret", true)
    first.done:DoClick()
    local messageCount = #env.messages
    local second = openSetup(env, "second")
    second.done:DoClick()
    equal(#env.messages, messageCount, "The blank second form was submitted")
    equal(second.frame.valid, true)
    equal(#second.player.chats, 1)
end)

test("overlapping setup forms keep their own values and console IDs", function()
    local env = gmod.client()
    local first, second = openSetup(env, "first"), openSetup(env, "second")
    first:fill("First", "2", "data", "FirstFile", true)
    second:fill("Second", "3", "server", "SecondFile", true)
    first.done:DoClick()
    local information = assert(env.lastMessage("AdminFinishedCreation")).values[1]
    equal(information[1], "First")
    equal(information[2], 2)
    equal(information[3], "data")
    equal(information[4], "FirstFile")
    equal(information[5], "first")
    equal(second.frame.valid, true)
    second.done:DoClick()
    information = env.lastMessage("AdminFinishedCreation").values[1]
    equal(information[1], "Second")
    equal(information[4], "SecondFile")
    equal(information[5], "second")
end)

for _, invalid in ipairs({
    {label = "blank name", field = "name", value = ""},
    {label = "whitespace name", field = "name", value = " \t "},
    {label = "overlong name", field = "name", value = string.rep("n", 129)},
    {label = "blank file", field = "file", value = ""},
    {label = "whitespace file", field = "file", value = " \t "},
    {label = "overlong file", field = "file", value = string.rep("f", 129)},
    {label = "blank delay", field = "delay", value = ""},
    {label = "nonnumeric delay", field = "delay", value = "later"},
    {label = "zero delay", field = "delay", value = "0"},
    {label = "negative delay", field = "delay", value = "-1"},
    {label = "infinite delay", field = "delay", value = "1e309"},
    {label = "missing folder", field = "folder"},
    {label = "unknown folder", field = "folder", value = "invalid"},
}) do
    test("setup rejects " .. invalid.label .. " without closing", function()
        local env = gmod.client()
        local form = openSetup(env)
        local values = {name = "Terminal", delay = "2", folder = "data", file = "Secret"}
        values[invalid.field] = invalid.value
        form:fill(values.name, values.delay, values.folder, values.file, true)
        form.done:DoClick()
        equal(#env.messages, 0, "Invalid configuration was sent")
        equal(form.frame.valid, true)
        equal(#form.player.chats, 1)
    end)
end

test("an invalid setup can be corrected and submitted", function()
    local env = gmod.client()
    local form = openSetup(env)
    form:fill("Terminal", "0", "data", "Secret", true)
    form.done:DoClick()
    equal(#env.messages, 0)
    form.delay:SetText("0.5")
    form.done:DoClick()
    equal(env.lastMessage("AdminFinishedCreation").values[1][2], 0.5)
    equal(form.frame.valid, false)
end)

for _, folder in ipairs({"data", "server", "tools"}) do
    test("valid " .. folder .. " setup still satisfies creator-only server validation", function()
        local server, client = gmod.new(), gmod.client()
        local owner, attacker = server.player(), server.player()
        local console = server.console(owner)
        local form = openSetup(client, console:GetName(), owner)
        local name, file = string.rep("N", 128), " MixedCase "
        form:fill(name, "0.5", folder, file, true)
        form.done:DoClick()
        local payload = assert(client.lastMessage("AdminFinishedCreation")).values[1]
        server.receive("AdminFinishedCreation", attacker, payload)
        equal(console.SlicerInformation, nil)
        server.receive("AdminFinishedCreation", owner, payload)
        local info = assert(console.SlicerInformation)
        equal(info.name, string.lower(name))
        equal(info.fileName, "mixedcase")
        equal(info.fileType, folder)
        equal(info.delay, 0.5)
        equal(owner.SlicerPendingConsole, folder == "tools" and console or nil)
        if folder == "tools" then
            equal(owner.chats[#owner.chats], "Please type !setEntity when looking at a door to link the console.")
        else
            equal(#owner.chats, 0)
        end
    end)
end

test("hacking tool initializes its hold type through the inherited engine method", function()
    local env = gmod.new()
    local function setHoldType(self, value) self.holdType = value end
    setmetatable(env.SWEP, {__index = {SetHoldType = setHoldType}})
    env.include("weapons/weapon_hacking.lua")
    local weapon = setmetatable({}, {__index = env.SWEP})
    equal(weapon.SetHoldType, setHoldType, "The engine method was overwritten")
    assert(type(weapon.Initialize) == "function", "Missing weapon initialization")
    weapon:Initialize()
    equal(weapon.holdType, "pistol")
    equal(weapon:CanPrimaryAttack(), false)
end)

test("a late death notification with no UI is harmless", function()
    local env = gmod.client()
    env.receive("PlayerDied", nil)
end)

test("the hacking tool exposes a callable death-drop hook that overrides the base policy", function()
    local env = gmod.new()
    local base = {ShouldDropOnDie = function() return true end}
    setmetatable(env.SWEP, {__index = base})
    env.include("weapons/weapon_hacking.lua")
    local weapon = setmetatable({}, {__index = env.SWEP})
    -- https://wiki.facepunch.com/gmod/WEAPON:ShouldDropOnDie documents a method,
    -- not a boolean configuration field. This exercises the Lua hook contract;
    -- the native engine's death dispatch still needs a game smoke test.
    equal(type(weapon.ShouldDropOnDie), "function")
    equal(weapon:ShouldDropOnDie(), false)
    equal(base:ShouldDropOnDie(), true, "The inherited base policy remains untouched")
end)

-- The official weapon_base routes SecondaryAttack through CanSecondaryAttack:
-- https://github.com/Facepunch/garrysmod/blob/master/garrysmod/gamemodes/base/entities/weapons/weapon_base/shared.lua
-- This local inheritance boundary records the effects rather than firing real
-- bullets. Engine prediction, animations and damage remain smoke-test scope.
for _, clip in ipairs({8, 0}) do
    test("the hacking tool blocks inherited secondary attack with clip " .. clip, function()
        local env = gmod.new()
        local base = {}
        function base:CanSecondaryAttack()
            if self.clip <= 0 then
                self.emptySounds = self.emptySounds + 1
                return false
            end
            return true
        end
        function base:SecondaryAttack()
            if not self:CanSecondaryAttack() then return end
            self.shots = self.shots + 1
            self.clip = self.clip - 1
        end
        setmetatable(env.SWEP, {__index = base})
        env.include("weapons/weapon_hacking.lua")
        local weapon = setmetatable({clip = clip, shots = 0, emptySounds = 0}, {__index = env.SWEP})
        for _ = 1, 3 do weapon:SecondaryAttack() end
        equal(weapon.shots, 0, "A utility tool must not inherit gunfire")
        equal(weapon.clip, clip, "Right-click must not consume ammunition")
        equal(weapon.emptySounds, 0, "Right-click must not use the gun's empty-clip path")
        equal(weapon:CanSecondaryAttack(), false)
        equal(weapon:CanPrimaryAttack(), false)
    end)
end

test("death during login cancels the access timer and all UI", function()
    local env = openClient()
    env.command("/a[terminal]")
    env.receive("PlayerDied", nil)
    env.assertClosed()
end)

test("death after login removes the remaining UI safely", function()
    local env = openClient()
    env.command("/a[terminal]")
    env.fireTimer("AccessDelay")
    env.receive("PlayerDied", nil)
    env.assertClosed()
end)

test("quitting after login cleans up frames and hooks", function()
    local env = openClient()
    env.command("/a[terminal]")
    env.fireTimer("AccessDelay")
    env.command("/q[terminal]")
    env.assertClosed()
    equal(env.lastMessage("playerQuitConsole").player, "server")
end)

for _, kind in ipairs({{folder = "data", extension = "data", timer = "DownloadDataFile"}, {folder = "server", extension = "sys", timer = "DownloadServerFile"}, {folder = "tools", extension = "exe"}}) do
    test("completing " .. kind.folder .. " closes all panels and timers", function()
        local env = openClient(kind.folder)
        env.command("/a[terminal]")
        env.fireTimer("AccessDelay")
        env.command("/a[terminal]/{_" .. kind.folder .. "}")
        env.command((kind.timer and "/d" or "/r") .. "{_" .. kind.folder .. "}/secret." .. kind.extension)
        if kind.timer then env.fireTimer(kind.timer) end
        env.assertClosed()
        assert(env.lastMessage(kind.timer and "destroyOnServer" or "PlayerActivatedDoor"))
    end)
end

for _, kind in ipairs({{folder = "data", extension = "data", timer = "DownloadDataFile", verb = "downloaded"}, {folder = "server", extension = "sys", timer = "DownloadServerFile", verb = "downloaded"}, {folder = "tools", extension = "exe", verb = "executed"}}) do
    for _, playerCount in ipairs({1, 2, 12}) do
        test(kind.folder .. " completion prints once with " .. playerCount .. " connected players", function()
            local env, caller = openClient(kind.folder)
            env.player.GetAll = function()
                local players = {}
                for i = 1, playerCount do players[i] = i end
                return players
            end
            env.command("/a[terminal]")
            env.fireTimer("AccessDelay")
            env.command("/a[terminal]/{_" .. kind.folder .. "}")
            equal(#env.chatMessages, 0, "Completion was announced before the action")
            env.command((kind.timer and "/d" or "/r") .. "{_" .. kind.folder .. "}/secret." .. kind.extension)
            if kind.timer then
                equal(#env.chatMessages, 0, "Download was announced before its timer completed")
                env.fireTimer(kind.timer)
            end
            equal(#env.chatMessages, 0, "The request is not yet an accepted completion")
            env.receive("SlicerCompleted", nil, "terminal", "secret", kind.folder, caller:GetName())
            equal(#env.chatMessages, 1, "Completion feedback must be local and independent of server population")
            local message = env.chatMessages[1]
            equal(message[2], "[TERMINAL]: ")
            equal(message[4], caller:GetName() .. " has " .. kind.verb .. " 'secret." .. kind.extension .. "'")
            equal(message[1][1], 255); equal(message[1][2], 251); equal(message[1][3], 0)
            equal(message[3][1], 255); equal(message[3][2], 255); equal(message[3][3], 255); equal(message[3][4], 255)
            env.assertClosed()
        end)
    end
end

for _, kind in ipairs({{folder = "data", extension = "data", timer = "DownloadDataFile"}, {folder = "server", extension = "sys", timer = "DownloadServerFile"}}) do
    test("death during " .. kind.folder .. " download cancels completion", function()
        local env = openClient(kind.folder)
        env.command("/a[terminal]")
        env.fireTimer("AccessDelay")
        env.command("/a[terminal]/{_" .. kind.folder .. "}")
        env.command("/d{_" .. kind.folder .. "}/secret." .. kind.extension)
        env.receive("PlayerDied", nil)
        env.assertClosed()
        equal(env.lastMessage("destroyOnServer"), nil)
        equal(#env.chatMessages, 0, "Canceled downloads must not announce completion")
    end)
end

for _, folder in ipairs({"data", "server", "tools"}) do
    test("reopening " .. folder .. " does not leak hidden frames", function()
        local env = openClient(folder)
        env.command("/a[terminal]")
        env.fireTimer("AccessDelay")
        env.command("/a[terminal]/{_" .. folder .. "}")
        env.command("//[terminal]/{_" .. folder .. "}")
        env.command("/a[terminal]/{_" .. folder .. "}")
        env.receive("PlayerDied", nil)
        env.assertClosed()
    end)
end

test("all five addon Lua files compile with GLua syntax translation", function()
    for _, path in ipairs({"autorun/server/sv_config.lua", "entities/consoleent/shared.lua", "entities/consoleent/init.lua", "entities/consoleent/cl_init.lua", "weapons/weapon_hacking.lua"}) do
        local source = gmod.source("devonsSlicing/lua/" .. path)
        assert((loadstring or load)(source, "@" .. path))
    end
end)

dofile("tests/completion.lua")(gmod, test, equal)
dofile("tests/command-assistance.lua")(gmod, test, equal)
dofile("tests/terminal-quit.lua")(gmod, test, equal)

print(string.format("\n%d passed, %d failed", passed, failed))
if failed > 0 then os.exit(1) end
