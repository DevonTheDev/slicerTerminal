-- Focused finite qualification, repository-root cwd, Lua 5.3.
-- Register all 130 before execution, then stop on the first unexpected failure.
-- This runner does not assert native GMod framing, UI or multiplayer behavior.
local gmod = dofile("tests/gmod.lua")
local cases, current, environments = {}, nil, {}
local totals = {server_fixtures = 0, client_fixtures = 0, source_loads = 0,
    entities = 0, panels = 0, messages = 0, archive_timers = 0,
    ordinary_timer_creates = 0, archive_read_calls = 0, archive_read_bytes = 0}
-- Source-inspected allocation contract. A client allocates one environment via
-- M.new internally; it is counted once as client, never as an extra server.
local expected = {}
for i = 1, 49 do expected[i] = {server = 1, client = 0, loads = 9} end
expected[48].loads = 18 -- Ordinary includes: 1 + 3 + 5.
expected[49] = {server = 2, client = 0, loads = 18}
for i = 50, 69 do expected[i] = {server = i >= 62 and 1 or 0, client = 1, loads = i >= 62 and 22 or 13} end
for i = 70, 106 do expected[i] = {server = 1, client = 0, loads = 9} end
for _, i in ipairs({70, 71, 72, 73, 75, 91}) do expected[i].client, expected[i].loads = 1, 22 end
expected[97] = {server = 2, client = 0, loads = 27}
expected[98].loads = 10
for i = 107, 114 do expected[i] = {server = 1, client = 0, loads = 9} end
expected[111] = {server = 8, client = 0, loads = 72}
expected[112] = {server = 2, client = 0, loads = 27}
expected[114].loads = 10
for i = 115, 124 do expected[i] = {server = 0, client = 1, loads = 13} end
expected[122] = {server = 0, client = 8, loads = 104}
expected[124].loads = 30
expected[125] = {server = 1, client = 1, loads = 22}
expected[126] = {server = 1, client = 2, loads = 35}
expected[127] = {server = 1, client = 1, loads = 22}
expected[128] = {server = 2, client = 2, loads = 44}
expected[129] = {server = 2, client = 1, loads = 31}
expected[130] = {server = 1, client = 1, loads = 22}
local ceilings = {entities = 128, panels = 256, messages = 512, archive_timers = 128,
    ordinary_timer_creates = 128, archive_read_calls = 256, archive_read_bytes = 262144}
local source, new, client = gmod.source, gmod.new, gmod.client
local constructingClient = false
gmod.source = function(path)
    assert(current, "Product source must not load during registration")
    current.source_loads = current.source_loads + 1
    totals.source_loads = totals.source_loads + 1
    assert(current.source_loads <= expected[current.index].loads, "Case exceeded its frozen source-load allocation")
    current.sources[path] = (current.sources[path] or 0) + 1
    return source(path)
end
gmod.new = function()
    assert(current, "Fixtures must not allocate during registration")
    local key = constructingClient and "client_fixtures" or "server_fixtures"
    current[key], totals[key] = current[key] + 1, totals[key] + 1
    local bound = constructingClient and expected[current.index].client or expected[current.index].server
    assert(current[key] <= bound, "Case exceeded its frozen " .. key .. " allocation")
    local env = new()
    environments[#environments + 1] = env
    return env
end
gmod.client = function()
    constructingClient = true
    local env = client()
    constructingClient = false
    return env
end
local function test(name, callback)
    assert(type(name) == "string" and type(callback) == "function")
    for _, case in ipairs(cases) do assert(case.name ~= name, "Duplicate case: " .. name) end
    cases[#cases + 1] = {name = name, callback = callback}
end
local function equal(actual, expected, message)
    assert(actual == expected, (message or "Unexpected value") .. ": expected " .. tostring(expected) .. ", got " .. tostring(actual))
end
for _, path in ipairs({"tests/readable-intel-server.lua", "tests/readable-intel-client.lua", "tests/readable-intel-workflow.lua",
    "tests/intel-archive-server.lua", "tests/intel-archive-client.lua", "tests/intel-archive-workflow.lua"}) do
    dofile(path)(gmod, test, equal)
end
equal(#cases, 130, "Frozen selection registers exactly existing 106 plus new 24")
local result = {registered = #cases, executed = 0, passed = 0, failed = 0,
    first_failure = false, allocations = totals, cases = {}}
for index, case in ipairs(cases) do
    current = {index = index, name = case.name, server_fixtures = 0, client_fixtures = 0,
        source_loads = 0, sources = {}, entities = 0, panels = 0, messages = 0, archive_timers = 0,
        ordinary_timer_creates = 0, archive_read_calls = 0, archive_read_bytes = 0}
    environments = {}
    result.executed = result.executed + 1
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
        if ok and current[key] > ceiling then ok, problem = false, "Case exceeded resource ceiling: " .. key end
    end
    if ok then
        local bound = expected[index]
        if current.server_fixtures ~= bound.server or current.client_fixtures ~= bound.client or current.source_loads ~= bound.loads then
            ok, problem = false, "Case did not consume its exact source-inspected fixture/source allocation"
        end
    end
    current.passed = ok
    result.cases[#result.cases + 1] = current
    if not ok then
        result.failed, result.first_failure = 1, case.name
        print("FAIL " .. index .. "/130 " .. case.name .. ": " .. tostring(problem))
        print("STOP first unexpected failure; executed=" .. result.executed .. " passed=" .. result.passed)
        print(string.format("Case allocations: server=%d client=%d source_loads=%d entities=%d panels=%d messages=%d archive_timers=%d",
            current.server_fixtures, current.client_fixtures, current.source_loads, current.entities,
            current.panels, current.messages, current.archive_timers))
        error("Focused qualification stopped at " .. case.name .. ": " .. tostring(problem), 0)
    end
    result.passed = result.passed + 1
    print("PASS " .. case.name)
end
current = nil
equal(result.executed, 130); equal(result.passed, 130)
equal(totals.server_fixtures, 120); equal(totals.client_fixtures, 51); equal(totals.source_loads, 1789)
print(string.format("\n%d passed, %d failed; %d server fixtures, %d client fixtures, %d source loads",
    result.passed, result.failed, totals.server_fixtures, totals.client_fixtures, totals.source_loads))
return result
