-- Ordinary entity/config includes must preserve this closure. No store or body
-- is attached to an entity, public settings, a registry row or Duplicator data.
if slicerIntel then return end
include("slicer/sh_intel.lua")
local bodies, players = {}, {}
local awardSerial = 0
local maximumAwardSerial = 9007199254740991
slicerIntel = {}

local function sameGeneration(entity, state)
    return IsValid(entity) and state.creationID == entity:GetCreationID()
        and state.entityIndex == entity:EntIndex()
end

function slicerIntel.GetBody(console)
    local state = bodies[console]
    if not state then return "" end
    if not sameGeneration(console, state) then bodies[console] = nil; return "" end
    return state.body
end

function slicerIntel.SetBody(console, body)
    if not IsValid(console) or console:GetClass() ~= "consoleent" then return false end
    local text = normalizeSlicerIntel(body)
    if text == nil then return false end
    bodies[console] = text ~= "" and {creationID = console:GetCreationID(),
        entityIndex = console:EntIndex(), body = text} or nil
    return true
end

function slicerIntel.ClearBody(console)
    bodies[console] = nil
end

local function playerState(ply, create)
    local state = players[ply]
    -- Every engine getter can reenter in a model or through an addon. Never
    -- clear or return a replacement connection installed by such a callback.
    if not IsValid(ply) or players[ply] ~= state then return end
    if not ply:IsPlayer() or players[ply] ~= state then return end
    local creationID = ply:GetCreationID()
    if players[ply] ~= state then return end
    local entityIndex = ply:EntIndex()
    if players[ply] ~= state then return end
    if state and (state.creationID ~= creationID or state.entityIndex ~= entityIndex) then
        players[ply], state = nil, nil
    end
    if not state and create then
        state = {creationID = creationID, entityIndex = entityIndex, records = {}, order = {}}
        players[ply] = state
    end
    return state
end

local function currentPlayer(ply, state)
    if players[ply] ~= state then return false end
    local current = playerState(ply, false)
    return current == state and players[ply] == state
end

-- Called only after canComplete accepts. The record has copied scalar values,
-- no console/session reference, and is stored before any removal or delivery.
function slicerIntel.Award(ply, console, information)
    if information.fileType ~= "data" and information.fileType ~= "server" then return end
    local body = slicerIntel.GetBody(console)
    if body == "" then return end
    local state = playerState(ply, true)
    if not state or awardSerial >= maximumAwardSerial then
        return nil, "Mission intel could not be recorded. The console was kept; try again later."
    end
    awardSerial = awardSerial + 1 -- Never wrap or reuse an award identity.
    local record = {award = string.format("%.0f", awardSerial), body = body,
        consoleName = information.name, fileName = information.fileName, fileType = information.fileType}
    state.records[record.award] = record
    table.insert(state.order, 1, record)
    if #state.order > 10 then
        local oldest = table.remove(state.order)
        state.records[oldest.award] = nil
    end
    state.record = record
    return record
end

util.AddNetworkString("SlicerIntel")
function slicerIntel.Send(ply, record, recovery)
    local state = playerState(ply, false)
    if not state or state.record ~= record then return end
    net.Start("SlicerIntel")
        net.WriteString(record.award)
        net.WriteString(record.consoleName)
        net.WriteString(record.fileName)
        net.WriteString(record.fileType)
        net.WriteString(record.body)
        net.WriteBool(recovery == true)
    net.Send(ply)
end

hook.Add("PlayerSay", "slicerReadIntel", function(ply, text)
    if text ~= "!readIntel" and text:sub(1, 11) ~= "!readIntel " then return end
    local state = playerState(ply, true)
    if not state then return "" end
    local now = CurTime()
    if state.nextRead and now < state.nextRead then return "" end
    state.nextRead = now + 1
    if text ~= "!readIntel" then
        ply:ChatPrint("Use !readIntel with no arguments to read your most recent mission intel.")
    elseif state.record then
        slicerIntel.Send(ply, state.record, true)
    else
        ply:ChatPrint("No mission intel is available for this connection. Complete a data/server download with authored intel first.")
    end
    return ""
end)

util.AddNetworkString("SlicerIntelArchiveRequest")
util.AddNetworkString("SlicerIntelArchiveReply")

local function writeArchiveMetadata(record)
    net.WriteString(record.award)
    net.WriteString(slicerIntelArchiveName(record.consoleName))
    net.WriteString(slicerIntelArchiveName(record.fileName))
    net.WriteUInt(record.fileType == "data" and 0 or 1, 8)
end

local function archiveReply(ply, state, operation, request, status, record)
    if not currentPlayer(ply, state) then return end
    if record and state.records[record.award] ~= record then return end
    local snapshot
    if status == 0 and operation == 1 then
        snapshot = {}
        for index, saved in ipairs(state.order) do snapshot[index] = saved end
    end
    net.Start("SlicerIntelArchiveReply")
        if not currentPlayer(ply, state) then return end
        if record and state.records[record.award] ~= record then return end
        net.WriteUInt(operation, 8)
        net.WriteString(request)
        net.WriteUInt(status, 8)
        if snapshot then
            net.WriteUInt(#snapshot, 8)
            for _, saved in ipairs(snapshot) do writeArchiveMetadata(saved) end
        elseif record then
            writeArchiveMetadata(record)
            net.WriteString(record.body)
        end
    -- An eviction or connection replacement during a callback must not expose
    -- a body captured earlier. No send occurs until exact ownership is checked
    -- again after the callback-capable generation getters.
    if not currentPlayer(ply, state) then return end
    if record and state.records[record.award] ~= record then return end
    net.Send(ply)
end

net.Receive("SlicerIntelArchiveRequest", function(bitLength, ply)
    local packet = slicerIntelArchiveReadPacket(bitLength, 35)
    if not packet then return end
    local operation, request, award = packet:byte(), packet:string(16), packet:string(16)
    if not packet:done() or (operation ~= 1 and operation ~= 2)
        or not validSlicerIntelAward(request)
        or (operation == 1 and award ~= "")
        or (operation == 2 and not validSlicerIntelAward(award)) then return end
    -- Malformed traffic cannot allocate player state or spend a throttle.
    local state = playerState(ply, true)
    if not state then return end
    local now = CurTime()
    if not currentPlayer(ply, state) then return end
    local key = operation == 1 and "nextArchiveList" or "nextArchiveRead"
    if state[key] and now < state[key] then
        archiveReply(ply, state, operation, request, 2)
        return
    end
    state[key] = now + 1
    if operation == 1 then
        archiveReply(ply, state, operation, request, 0)
    else
        local record = state.records[award]
        archiveReply(ply, state, operation, request, record and 0 or 1, record)
    end
end)

local function clearPlayer(ply) players[ply] = nil end
hook.Add("PlayerDisconnected", "slicerClearIntel", clearPlayer)
hook.Add("PlayerInitialSpawn", "slicerClearIntel", clearPlayer)
