AddCSLuaFile("entities/consoleent/shared.lua")
AddCSLuaFile("entities/consoleent/cl_init.lua")
AddCSLuaFile("weapons/weapon_hacking.lua")

entityModel = "models/props_combine/combine_interface001.mdl" -- The console model

-- Keep configuration when this file is included again by the entity loader.
spawnedEntities = spawnedEntities or {}

function returnEntityModel()
    return entityModel or "models/props_combine/combine_interface001.mdl"
end

local function validName(value)
    return type(value) == "string" and #value <= 128 and string.Trim(value) ~= ""
end

-- Setup and duplication share the same rules. Always return a new allowlisted
-- table: copied entity fields can alias the original console's live state.
function normalizeSlicerInformation(givenInformation)
    if type(givenInformation) ~= "table" then return end
    local name, delay = givenInformation.name, givenInformation.delay
    local fileType, fileName = givenInformation.fileType, givenInformation.fileName
    if not validName(name) or not validName(fileName) then return end
    if type(delay) ~= "number" or delay ~= delay or delay <= 0 or delay == math.huge then return end
    if fileType ~= "data" and fileType ~= "server" and fileType ~= "tools" then return end
    return {
        name = string.lower(string.Trim(name)),
        delay = delay,
        fileType = fileType,
        fileName = string.lower(string.Trim(fileName)),
        inUse = false,
    }
end

-- Edit authority is server-only and never travels through copied entity data.
-- Reincluding this file retires its tickets, but preserves the serial so an
-- older form can never acquire a new ticket's identity. Stop rather than wrap.
slicerSetupEditSerial = slicerSetupEditSerial or 0
local editTickets = {}
local maximumEditSerial = 9007199254740991
local reopenEdit = "Close this form and use !editConsole to reopen it."
local informationFields = {"name", "delay", "fileType", "fileName", "inUse"}

function retireSlicerSetupEdit(console)
    if console ~= nil then editTickets[console] = nil end
end

function retireSlicerSetupEditsForPlayer(ply)
    for console, ticket in pairs(editTickets) do
        if ticket.player == ply then editTickets[console] = nil end
    end
end

local function editContext(ply, console)
    if not IsValid(ply) or not ply:IsPlayer() or not ply:Alive() then return end
    if not IsValid(console) or console:GetClass() ~= "consoleent" or console.SlicerCreator ~= ply then return end
    local information = console.SlicerInformation
    local normalized = normalizeSlicerInformation(information)
    if not normalized or information.inUse
        or (slicerConsoleHasActiveSession and slicerConsoleHasActiveSession(console)) then return end
    for _, field in ipairs(informationFields) do
        if information[field] ~= normalized[field] then return end
    end
    local record
    for _, entry in pairs(spawnedEntities) do
        if entry.entity == console then
            if record or entry.entityName ~= console:GetName() or entry.information ~= information then return end
            record = entry
        end
    end
    if not record then return end
    return information, normalized, record
end

local function currentEdit(ticket, ply, console)
    local information, normalized, record = editContext(ply, console)
    if not information or ticket.player ~= ply or ticket.console ~= console
        or ticket.information ~= information or ticket.record ~= record
        or ticket.entityName ~= console:GetName() then return false end
    for _, field in ipairs(informationFields) do
        if ticket.snapshot[field] ~= normalized[field] then return false end
    end
    return true
end

local function nextEditToken()
    if type(slicerSetupEditSerial) ~= "number" or slicerSetupEditSerial < 0
        or slicerSetupEditSerial % 1 ~= 0 or slicerSetupEditSerial >= maximumEditSerial then return end
    slicerSetupEditSerial = slicerSetupEditSerial + 1
    return string.format("%.0f", slicerSetupEditSerial)
end

local function validEditToken(token)
    return type(token) == "string" and #token > 0 and #token <= 16 and token:match("^%d+$") ~= nil
end

local function editReply(ply, token, ok, message)
    -- No Entity is written: stale forms still receive errors after removal.
    net.Start("SlicerSetupEditReply")
        net.WriteString(token)
        net.WriteTable({ok = ok, message = message})
    net.Send(ply)
end

for _, name in ipairs({"SlicerSetupEditOpen", "SlicerSetupEditSave", "SlicerSetupEditReply", "SlicerSetupEditCancel"}) do
    util.AddNetworkString(name)
end

hook.Add("PlayerSay", "slicerEditConsole", function(ply, text)
    local row = #text == 14 and text:match("^!editConsole ([1-5])$")
    if text ~= "!editConsole" and not row then return end
    if not IsValid(ply) or not ply:IsPlayer() or not ply:Alive() then return "" end
    local console
    if row then
        -- Resolve at command time: config can be included before entity init,
        -- and init reinclude replaces the private listing closure.
        if type(slicerListedConsole) == "function" then console = slicerListedConsole(ply, tonumber(row)) end
        if not console then
            ply:ChatPrint("That console row is unavailable or expired. Use !listConsoles or !findConsoles again, then !editConsole <row>.")
            return ""
        end
    else
        console = ply:GetEyeTrace().Entity
    end
    local ticket = console ~= nil and editTickets[console] or nil
    if ticket and not currentEdit(ticket, ticket.player, console) then
        retireSlicerSetupEdit(console)
        ticket = nil
    end
    local information, normalized, record = editContext(ply, console)
    if not information then
        ply:ChatPrint(row and "That listed console must be one of your configured, idle consoles before you can edit it."
            or "Look at one of your configured, idle consoles and type !editConsole to edit it.")
        return ""
    end
    if not ticket then
        local token = nextEditToken()
        if not token then
            ply:ChatPrint("An edit cannot be opened right now.")
            return ""
        end
        ticket = {player = ply, console = console, token = token,
            information = information, snapshot = normalized, record = record, entityName = console:GetName(),
            displayIdentity = {creationID = console:GetCreationID(), entityIndex = console:EntIndex()}}
        editTickets[console] = ticket
    end
    -- Display context is captured per ticket, separate from its five saved fields.
    local payload = table.Copy(ticket.snapshot)
    payload.displayIdentity = table.Copy(ticket.displayIdentity)
    net.Start("SlicerSetupEditOpen")
        net.WriteEntity(console)
        net.WriteEntity(ply)
        net.WriteString(ticket.token)
        net.WriteTable(payload)
    net.Send(ply)
    return ""
end)

net.Receive("SlicerSetupEditSave", function(_, ply)
    if not IsValid(ply) or not ply:IsPlayer() then return end
    local console, token, fields = net.ReadEntity(), net.ReadString(), net.ReadTable()
    if not validEditToken(token) then return end
    local ticket = console ~= nil and editTickets[console] or nil
    if not ticket or ticket.player ~= ply or ticket.console ~= console or ticket.token ~= token then
        editReply(ply, token, false, "This edit is no longer current. " .. reopenEdit)
        return
    end
    if not currentEdit(ticket, ply, console) then
        retireSlicerSetupEdit(console)
        editReply(ply, token, false, "This console is unavailable or its setup has changed. " .. reopenEdit)
        return
    end
    local information = type(fields) == "table" and normalizeSlicerInformation({
        name = fields.name, delay = fields.delay, fileName = fields.fileName,
        fileType = ticket.snapshot.fileType,
    }) or nil
    if not information then
        editReply(ply, token, false, "Use nonblank names of at most 128 bytes and a finite positive delay.")
        return
    end
    console.SlicerInformation = information
    ticket.record.information = information
    retireSlicerSetupEdit(console)
    editReply(ply, token, true, "Console setup updated.")
end)

net.Receive("SlicerSetupEditCancel", function(_, ply)
    if not IsValid(ply) or not ply:IsPlayer() then return end
    local console, token = net.ReadEntity(), net.ReadString()
    local ticket = console ~= nil and editTickets[console] or nil
    if ticket and ticket.player == ply and ticket.console == console and ticket.token == token then
        retireSlicerSetupEdit(console)
    end
end)

-- Initial setup keeps the legacy five fields. A sixth field only correlates a
-- reply; it never grants authority or permits an existing setup to be replaced.
local function validInitialSetupToken(token)
    return type(token) == "string" and #token <= 16 and token:match("^[1-9]%d*$") ~= nil
        and (#token < 16 or token <= "9007199254740991")
end

-- The target serial survives reinclude; maps and generation deliberately do not.
-- Nil alone initializes it: corruption (including false) must fail closed.
if slicerInitialSetupTargetSerial == nil then slicerInitialSetupTargetSerial = 0 end
local initialGeneration = {}
slicerInitialSetupGeneration = initialGeneration
local initialTickets, initialTokens, initialSetupReceipts, initialReceiptTokens = {}, {}, {}, {}

local function initialRegistryCurrent()
    return slicerInitialSetupGeneration == initialGeneration
end

local function retireInitialTicket(ticket)
    if initialTickets[ticket.console] == ticket then initialTickets[ticket.console] = nil end
    if initialTokens[ticket.targetToken] == ticket then initialTokens[ticket.targetToken] = nil end
end

local function retireInitialReceipt(console, receipt)
    if initialSetupReceipts[console] == receipt then initialSetupReceipts[console] = nil end
    if receipt.targetToken and initialReceiptTokens[receipt.targetToken] == receipt then
        initialReceiptTokens[receipt.targetToken] = nil
    end
end

function retireSlicerInitialSetupReceipt(console)
    local receipt = console ~= nil and initialSetupReceipts[console] or nil
    if receipt then retireInitialReceipt(console, receipt) end
end

function retireSlicerInitialSetup(console)
    local ticket = console ~= nil and initialTickets[console] or nil
    if ticket then retireInitialTicket(ticket) end
    retireSlicerInitialSetupReceipt(console)
end

function retireSlicerInitialSetupsForPlayer(ply)
    for _, ticket in pairs(initialTickets) do
        if ticket.player == ply then retireInitialTicket(ticket) end
    end
    for console, receipt in pairs(initialSetupReceipts) do
        if receipt.player == ply then retireInitialReceipt(console, receipt) end
    end
end

local function validInitialName(name)
    return type(name) == "string" and #name > 0 and #name <= 256 and not name:find("%z")
end

local function ownsInitialTicket(ticket)
    return initialRegistryCurrent() and initialTickets[ticket.console] == ticket
        and initialTokens[ticket.targetToken] == ticket
end

local function initialIdentityCurrent(record, pending)
    local console, ply = record.console, record.player
    if not IsValid(console) or console:GetClass() ~= "consoleent" or not IsValid(console)
        or not IsValid(ply) or not ply:IsPlayer() or not IsValid(ply) or not IsValid(console) then return false end
    local creationID = console:GetCreationID()
    if not IsValid(console) then return false end
    local entityIndex = console:EntIndex()
    if not IsValid(console) then return false end
    local name = pending and console:GetName() or nil
    return IsValid(console) and IsValid(ply) and console.SlicerCreator == ply
        and creationID == record.creationID and entityIndex == record.entityIndex
        and (not pending or (name == record.entityName and console.SlicerInformation == nil))
end

local function currentInitialTicket(ticket)
    if not ownsInitialTicket(ticket) then return false end
    if not initialIdentityCurrent(ticket, true) then
        retireInitialTicket(ticket)
        return false
    end
    return ownsInitialTicket(ticket)
end

local function initialUnreserved(console)
    return not slicerConsoleHasActiveSession or not slicerConsoleHasActiveSession(console)
end

-- Return only captured opening data and a map-ownership guard. Listed opening
-- runs its existing final entity/page checks after preparation, with no new
-- target accessor after that guard.
function prepareSlicerInitialSetup(ply, console, name)
    if not initialRegistryCurrent() then return end
    local ticket = console ~= nil and initialTickets[console] or nil
    if ticket and not currentInitialTicket(ticket) then ticket = nil end
    if not IsValid(ply) or not ply:IsPlayer() or not IsValid(console)
        or console:GetClass() ~= "consoleent" or console.SlicerCreator ~= ply
        or console.SlicerInformation ~= nil or not validInitialName(name) then return end
    local candidate = ticket
    if not candidate then
        if not IsValid(console) then return end
        local creationID = console:GetCreationID()
        if not IsValid(console) then return end
        local entityIndex = console:EntIndex()
        if not IsValid(console) then return end
        candidate = {console = console, player = ply, entityName = name,
            creationID = creationID, entityIndex = entityIndex}
    end
    if candidate.player ~= ply or candidate.entityName ~= name or not initialUnreserved(console)
        or not initialIdentityCurrent(candidate, true) or not initialRegistryCurrent() then return end
    -- A native callback may have opened this target or retired an earlier ticket.
    if ticket then
        if not ownsInitialTicket(ticket) then return end
    elseif initialTickets[console] ~= nil then
        return -- A reentrant opening owns the new record; never replace it.
    else
        local serial = slicerInitialSetupTargetSerial
        if type(serial) ~= "number" or serial < 0 or serial % 1 ~= 0 or serial >= 9007199254740991 then return end
        slicerInitialSetupTargetSerial = serial + 1
        candidate.targetToken = string.format("%.0f", slicerInitialSetupTargetSerial)
        ticket = candidate
        initialTickets[console], initialTokens[ticket.targetToken] = ticket, ticket
    end
    return ticket.targetToken, function() return ownsInitialTicket(ticket) end
end

local function modernInitialFields(fields)
    if type(fields) ~= "table" then return end
    for key in pairs(fields) do
        if type(key) ~= "number" or key % 1 ~= 0 or key < 1 or key > 6 then return end
    end
    local descriptor = fields[5]
    if type(descriptor) ~= "table" then return end
    for key in pairs(descriptor) do
        if key ~= "version" and key ~= "targetToken" and key ~= "originalName" then return end
    end
    if descriptor.version ~= 2 or not validInitialSetupToken(descriptor.targetToken)
        or not validInitialSetupToken(fields[6]) or not validInitialName(descriptor.originalName) then return end
    local information = normalizeSlicerInformation({name = fields[1], delay = fields[2], fileType = fields[3], fileName = fields[4]})
    if not information then return end
    -- Copy scalars before any callback-capable target access. No nested alias.
    return information, {fields[1], fields[2], fields[3], fields[4], descriptor.originalName},
        descriptor.targetToken, fields[6]
end

local function usableInitialSetupReceipt(console, receipt)
    if receipt.targetToken then
        return initialRegistryCurrent() and initialReceiptTokens[receipt.targetToken] == receipt
            and initialIdentityCurrent(receipt, false) and initialRegistryCurrent()
            and initialSetupReceipts[console] == receipt and initialReceiptTokens[receipt.targetToken] == receipt
    end
    return IsValid(console) and console:GetClass() == "consoleent"
        and console:GetCreationID() == receipt.creationID and console:EntIndex() == receipt.entityIndex
        and IsValid(receipt.player) and receipt.player:IsPlayer() and console.SlicerCreator == receipt.player
end

util.AddNetworkString("SlicerInitialSetupStatusRequest")
util.AddNetworkString("SlicerInitialSetupStatusReply")
net.Receive("SlicerInitialSetupStatusRequest", function(_, ply)
    if not IsValid(ply) or not ply:IsPlayer() then return end
    local fields = net.ReadTable()
    if type(fields) ~= "table" or not validInitialSetupToken(fields[6]) then return end
    local token, result = fields[6], {confirmed = false}
    if type(fields[5]) == "table" then
        local _, raw, targetToken = modernInitialFields(fields)
        result.targetToken = validInitialSetupToken(fields[5].targetToken) and fields[5].targetToken or nil
        local receipt = targetToken and initialReceiptTokens[targetToken] or nil
        if receipt and receipt.player == ply then
            if not usableInitialSetupReceipt(receipt.console, receipt) then
                retireInitialReceipt(receipt.console, receipt)
            elseif receipt.token == token then
                local exact = true
                for i = 1, 5 do if receipt.fields[i] ~= raw[i] then exact = false end end
                if exact then result = {confirmed = true, name = receipt.name,
                    fileType = receipt.fileType, targetToken = targetToken} end
            end
        end
    elseif type(fields[5]) == "string" and #fields[5] <= 256
        and normalizeSlicerInformation({name = fields[1], delay = fields[2], fileType = fields[3], fileName = fields[4]}) then
        local candidate, matches = nil, 0
        for console, receipt in pairs(initialSetupReceipts) do
            if not usableInitialSetupReceipt(console, receipt) then
                retireInitialReceipt(console, receipt)
            elseif not receipt.targetToken and receipt.player == ply and receipt.token == token then
                candidate, matches = receipt, matches + 1
            end
        end
        -- Count player/token candidates before comparing fields: ambiguous
        -- identities must never choose the first otherwise matching receipt.
        if matches == 1 then
            local exact = true
            for i = 1, 5 do if candidate.fields[i] ~= fields[i] then exact = false end end
            if exact then
                result = {confirmed = true, name = candidate.name, fileType = candidate.fileType}
            end
        end
    end
    net.Start("SlicerInitialSetupStatusReply")
        net.WriteString(token)
        net.WriteTable(result)
    net.Send(ply)
end)

local function initialSetupReply(ply, token, result)
    if token == nil then return end -- Legacy clients did not request a reply.
    net.Start("SlicerInitialSetupReply")
        net.WriteString(token)
        net.WriteTable(result)
    net.Send(ply)
end

local function saveModernInitialSetup(ply, fields)
    local descriptor, requestToken = fields[5], fields[6]
    local targetToken = descriptor.targetToken
    local ticket = validInitialSetupToken(targetToken) and initialTokens[targetToken] or nil
    -- Own the ticket before target/native validation can call this receiver again.
    -- A nested attempt has no independent result and must not unlock the outer UI.
    if ticket and ticket.player == ply and ticket.inProgress then return end
    local operation = {}
    if ticket and ticket.player == ply and ownsInitialTicket(ticket) then ticket.inProgress = operation end
    local function reply(result)
        if ticket and ownsInitialTicket(ticket) and ticket.inProgress == operation then ticket.inProgress = nil end
        result.targetToken = validInitialSetupToken(targetToken) and targetToken or nil
        initialSetupReply(ply, requestToken, result)
    end
    local information, raw, parsedToken = modernInitialFields(fields)
    if not information then
        reply({ok = false, message = "Invalid bound setup fields. Check your draft or close this form and reopen the console."})
        return
    end
    if not ticket or ticket.player ~= ply or ticket.entityName ~= raw[5] or parsedToken ~= targetToken
        or ticket.inProgress ~= operation or not currentInitialTicket(ticket) then
        reply({ok = false, message = "This setup target is unavailable or already configured. Close this form and use the console again."})
        return
    end
    local target = ticket.console
    local ambiguous = false
    for _, sibling in ipairs(ents.FindByClass("consoleent")) do
        if sibling ~= target and IsValid(sibling) and sibling:GetName() == raw[5]
            and sibling.SlicerCreator == ply and not sibling.SlicerInformation then ambiguous = true end
    end
    local unreserved = initialUnreserved(target)
    if not currentInitialTicket(ticket) or ticket.inProgress ~= operation then
        reply({ok = false, message = "This setup target changed. Close this form and use the console again."})
        return
    end
    if ambiguous or not unreserved then
        reply({ok = false, message = "This console's name is ambiguous or it is reserved. Try again when it is available."})
        return
    end
    -- Capture evidence before commit; getters are never called after assignment.
    local receipt = {console = target, player = ply, creationID = ticket.creationID, entityIndex = ticket.entityIndex,
        targetToken = targetToken, token = requestToken, fields = raw, name = information.name, fileType = information.fileType}
    if not currentInitialTicket(ticket) or ticket.inProgress ~= operation then
        reply({ok = false, message = "This setup target changed. Close this form and use the console again."})
        return
    end
    target.SlicerInformation = information
    spawnedEntities[#spawnedEntities + 1] = {entityName = raw[5], entity = target, information = information}
    if information.fileType == "tools" then ply.SlicerPendingConsole = target end
    retireInitialTicket(ticket)
    local previous = initialSetupReceipts[target]
    if previous then retireInitialReceipt(target, previous) end
    initialSetupReceipts[target], initialReceiptTokens[targetToken] = receipt, receipt
    reply({ok = true, name = information.name, fileType = information.fileType})
end

util.AddNetworkString("AdminFinishedCreation")
util.AddNetworkString("SlicerInitialSetupReply")
net.Receive("AdminFinishedCreation", function(_, ply)
    if not IsValid(ply) or not ply:IsPlayer() then return end

    local givenInformation = net.ReadTable()
    if type(givenInformation) ~= "table" then return end

    local token = givenInformation[6]
    if token ~= nil and not validInitialSetupToken(token) then return end
    if type(givenInformation[5]) == "table" then
        -- A descriptor is always modern, including malformed attempts. Never
        -- downgrade it into the old name lookup, even without a request token.
        if token ~= nil then saveModernInitialSetup(ply, givenInformation) end
        return
    end

    -- [name, delay, fileType, fileName, entityName, optional token] comes from the client.
    local name, delay, fileType, fileName, entityName = givenInformation[1], givenInformation[2], givenInformation[3], givenInformation[4], givenInformation[5]
    local information = normalizeSlicerInformation({name = name, delay = delay, fileType = fileType, fileName = fileName})
    if type(entityName) ~= "string" or not information then
        initialSetupReply(ply, token, {ok = false,
            message = "Invalid setup: choose a folder, nonblank names of at most 128 bytes, and a finite positive delay."})
        return
    end

    local target
    for _, console in ipairs(ents.FindByClass("consoleent")) do
        if console:GetName() == entityName and console.SlicerCreator == ply and not console.SlicerInformation then
            if target then
                initialSetupReply(ply, token, {ok = false,
                    message = "This console's identity is ambiguous. Close this form and use a uniquely named console."})
                return
            end
            target = console
        end
    end
    if not target then
        initialSetupReply(ply, token, {ok = false,
            message = "This console is unavailable or already configured. Close this form and use the console again if setup is still available."})
        return
    end

    local pendingTicket = initialTickets[target]
    if pendingTicket then retireInitialTicket(pendingTicket) end
    target.SlicerInformation = information
    table.insert(spawnedEntities, {entityName = entityName, entity = target, information = information})
    if fileType == "tools" then ply.SlicerPendingConsole = target end
    -- Commit the receipt before any response can reenter. Identity length only
    -- limits recovery storage, never changes the original setup admission.
    if token ~= nil then
        local previous = initialSetupReceipts[target]
        if previous then retireInitialReceipt(target, previous) end
        if #entityName <= 256 then
            initialSetupReceipts[target] = {player = ply, creationID = target:GetCreationID(), entityIndex = target:EntIndex(),
                token = token, fields = {name, delay, fileType, fileName, entityName},
                name = information.name, fileType = information.fileType}
        end
    end
    initialSetupReply(ply, token, {ok = true, name = information.name, fileType = information.fileType})
end)

function returnSpawnedEntities()
    return spawnedEntities
end

function updateInUse(consoleName, setValue)
    for _, entry in pairs(spawnedEntities) do
        if entry.entityName == consoleName then
            if setValue ~= nil then
                entry.information.inUse = setValue
            else
                entry.information.inUse = not entry.information.inUse
            end
        end
    end
end
