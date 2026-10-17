-- Fresh finite selector: 24 preview cases + 8 named existing regressions.
-- Source-prepared only. Run from a separately qualified repository root.
-- This does not invoke or modify run.lua, run-intel.lua or run-intel-archive.lua.
local gmod = dofile("tests/gmod.lua")
local cases, byID, current, environments = {}, {}, nil, {}
local totals = {server_fixtures = 0, client_fixtures = 0, source_loads = 0,
    entities = 0, panels = 0, messages = 0, archive_timers = 0,
    ordinary_timer_creates = 0, archive_read_calls = 0, archive_read_bytes = 0}
local selectedExisting = {
    {id = "existing-001", name = "data editor has scrolling intel with fixed save cancel and byte counter", server = 1},
    {id = "existing-002", name = "server editor has scrolling intel with fixed save cancel and byte counter", server = 1},
    {id = "existing-003", name = "tools editor keeps original three inputs and no intel field", server = 1},
    {id = "existing-004", name = "explicit blank intel is sent to clear and cancel sends only exact ticket", server = 1},
    {id = "existing-005", name = "duplicate intel delivery neither creates a second window nor repeats focus", server = 0},
    {id = "existing-006", name = "explicit recovery reopens same closed award with deferred removal true", server = 0},
    {id = "existing-007", name = "explicit recovery focuses current reader without altering content or terminal state", server = 0},
    {id = "existing-008", name = "reader resize preserves the same body and uses no commands or focus change", server = 0},
}
-- Source inspection: gmod.new includes config -> validator -> intel -> validator,
-- then entity init -> shared -> config -> validator -> already-loaded intel.
-- gmod.client starts with that M.new then adds cl_init -> shared -> validator -> archive.
local root = "devonsSlicing/lua/"
local sourceWeights = {
    [root .. "autorun/server/sv_config.lua"] = {server = 2, client = 2},
    [root .. "autorun/server/sv_slicer_intel.lua"] = {server = 2, client = 2},
    [root .. "entities/consoleent/init.lua"] = {server = 1, client = 1},
    [root .. "entities/consoleent/shared.lua"] = {server = 1, client = 2},
    [root .. "slicer/sh_intel.lua"] = {server = 3, client = 4},
    [root .. "entities/consoleent/cl_init.lua"] = {server = 0, client = 1},
    [root .. "slicer/cl_intel_archive.lua"] = {server = 0, client = 1},
}
local ceilings = {entities = 32, panels = 256, messages = 32, archive_timers = 16,
    ordinary_timer_creates = 16, archive_read_calls = 16, archive_read_bytes = 65536}
local source, new, client = gmod.source, gmod.new, gmod.client
local constructingClient = false
gmod.source = function(path)
    assert(current, "Product source load during registration")
    local weights = assert(sourceWeights[path], "Unexpected product source dependency")
    local allowed = weights.server * current.expected.server + weights.client * current.expected.client
    current.sources[path] = (current.sources[path] or 0) + 1
    assert(current.sources[path] <= allowed, "Frozen per-path source allocation exceeded")
    current.source_loads, totals.source_loads = current.source_loads + 1, totals.source_loads + 1
    assert(current.source_loads <= current.expected.loads, "Frozen source-load allocation exceeded")
    return source(path)
end
gmod.new = function()
    assert(current, "Fixture allocation during registration")
    local key = constructingClient and "client_fixtures" or "server_fixtures"
    local allowed = constructingClient and current.expected.client or current.expected.server
    current[key], totals[key] = current[key] + 1, totals[key] + 1
    assert(current[key] <= allowed, "Frozen fixture allocation exceeded")
    local env = new(); environments[#environments + 1] = env
    return env
end
gmod.client = function()
    assert(not constructingClient, "Unexpected nested client fixture")
    constructingClient = true
    local ok, env = pcall(client)
    constructingClient = false
    if not ok then error(env, 0) end
    return env
end
local function equal(actual, expected, message)
    assert(actual == expected, (message or "Unexpected value") .. ": expected " .. tostring(expected) .. ", got " .. tostring(actual))
end
local function add(id, name, callback, servers)
    assert(type(id) == "string" and id:match("^[a-z]+%-%d%d%d$"), "Stable ASCII case ID required")
    assert(not byID[id], "Duplicate case ID")
    assert(type(name) == "string" and type(callback) == "function")
    local case = {id = id, name = name, callback = callback,
        expected = {server = servers, client = 1, loads = servers * 9 + 13}}
    byID[id], cases[#cases + 1] = case, case
end
dofile("tests/creator-intel-preview.lua")(gmod, function(id, name, callback)
    local expectedID = string.format("preview-%03d", #cases + 1)
    assert(#cases < 24 and id == expectedID, "New selection identity/order differs from frozen 24")
    add(id, name, callback, 1)
end, equal)
equal(#cases, 24, "Frozen new case count")
local existing, discovered = {}, 0
dofile("tests/readable-intel-client.lua")(gmod, function(name, callback)
    assert(type(name) == "string" and type(callback) == "function")
    assert(not existing[name], "Duplicate existing test name")
    existing[name] = callback; discovered = discovered + 1
end, equal)
equal(discovered, 20, "Unchanged existing client module registration count")
for _, selected in ipairs(selectedExisting) do
    add(selected.id, selected.name, assert(existing[selected.name], "Missing named existing regression"), selected.server)
end
equal(#cases, 32, "Frozen selection count")
-- Lua strings can contain any byte, including invalid UTF-8 in an existing
-- generated test label or assertion. Console output uses only ASCII IDs/hex.
-- Return raw strings separately for a byte-aware host reporter (encoding=None).
local function hex(value)
    return (tostring(value):gsub(".", function(byte) return string.format("%02x", string.byte(byte)) end))
end
local result = {registered = #cases, existing_discovered = discovered, executed = 0, passed = 0, failed = 0,
    first_failure = false, allocations = totals, cases = {}}
for index, case in ipairs(cases) do
    current = {index = index, id = case.id, name = case.name, name_hex = hex(case.name), expected = case.expected,
        server_fixtures = 0, client_fixtures = 0, source_loads = 0, sources = {},
        entities = 0, panels = 0, messages = 0, archive_timers = 0,
        ordinary_timer_creates = 0, archive_read_calls = 0, archive_read_bytes = 0}
    environments = {}; result.executed = result.executed + 1
    local ok, problem = pcall(case.callback)
    for _, env in ipairs(environments) do
        current.entities = current.entities + #env.entities
        current.panels = current.panels + #(env.panels or {})
        current.messages = current.messages + #env.messages
        current.archive_timers = current.archive_timers + (env.archiveTimerID or 0)
        current.archive_read_calls = current.archive_read_calls + (env.archiveReads or 0)
        current.archive_read_bytes = current.archive_read_bytes + (env.archiveReadBytes or 0)
        for _, event in ipairs(env.timerEvents or {}) do
            if event.operation == "Create" then current.ordinary_timer_creates = current.ordinary_timer_creates + 1 end
        end
    end
    for key, ceiling in pairs(ceilings) do
        totals[key] = totals[key] + current[key]
        if ok and current[key] > ceiling then ok, problem = false, "Case resource ceiling exceeded: " .. key end
    end
    if ok and (current.server_fixtures ~= case.expected.server or current.client_fixtures ~= case.expected.client
        or current.source_loads ~= case.expected.loads) then
        ok, problem = false, "Exact source-inspected fixture/load allocation mismatch"
    end
    for path, weights in pairs(sourceWeights) do
        local expected = weights.server * case.expected.server + weights.client * case.expected.client
        if ok and (current.sources[path] or 0) ~= expected then
            ok, problem = false, "Exact per-path source allocation mismatch: " .. path
        end
    end
    current.passed = ok; result.cases[#result.cases + 1] = current
    if not ok then
        current.problem, current.problem_hex = tostring(problem), hex(problem)
        result.failed, result.first_failure = 1, case.id
        print("FAIL " .. case.id .. " problem_hex=" .. current.problem_hex)
        print("STOP first unexpected failure; executed=" .. result.executed .. " passed=" .. result.passed)
        current = nil
        return result -- The host must treat failed ~= 0 as a failed qualification.
    end
    result.passed = result.passed + 1
    print("PASS " .. case.id)
end
current = nil
equal(result.executed, 32); equal(result.passed, 32)
equal(totals.server_fixtures, 28); equal(totals.client_fixtures, 32); equal(totals.source_loads, 668)
print("32 passed, 0 failed; 28 server fixtures, 32 client fixtures, 668 source loads")
return result
