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
    local env, _, hacker, console = fixture()
    env.open(hacker, console)
    env.receive("destroyOnServer", hacker, console)
    equal(console.removed, nil)
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
    return env
end

test("a late death notification with no UI is harmless", function()
    local env = gmod.client()
    env.receive("PlayerDied", nil)
end)

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

print(string.format("\n%d passed, %d failed", passed, failed))
if failed > 0 then os.exit(1) end
