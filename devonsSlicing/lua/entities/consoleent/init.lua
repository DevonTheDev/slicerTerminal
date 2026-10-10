AddCSLuaFile("entities/consoleent/cl_init.lua")
AddCSLuaFile("entities/consoleent/shared.lua")

include("entities/consoleent/shared.lua")
include("autorun/server/sv_config.lua")

local sessions = {}
local linkedDoors = {}
local consoleListings = {}
local listingLifetime = 60

-- Configuration flags can be changed by legacy callers independently of a
-- reservation. Editing and link recovery also consult server-owned sessions.
function slicerConsoleHasActiveSession(console)
    for _, session in pairs(sessions) do
        if session.console == console then return true end
    end
    return false
end

for _, name in ipairs({
    "PlayerSpawnedConsole", "ServerSendsEntityInformation", "updateInUse",
    "PlayerDied", "playerQuitConsole", "ServerWaitingForEntity", "PlayerAlert",
    "PlayerActivatedDoor", "destroyOnServer", "SlicerCompleted", "SlicerConsoleLocation",
}) do
    util.AddNetworkString(name)
end

local function releaseSession(ply, closeUI)
    local session = sessions[ply]
    if not session then return end
    sessions[ply] = nil
    if session.console.SlicerInformation then
        session.console.SlicerInformation.inUse = false
    end
    if closeUI and IsValid(ply) then
        net.Start("PlayerDied")
        net.Send(ply)
    end
end

local function hasHackingTool(ply)
    if not IsValid(ply) or not ply:IsPlayer() or not ply:Alive() then return false end
    local weapon = ply:GetActiveWeapon()
    return IsValid(weapon) and weapon:GetClass() == "weapon_hacking"
end

local function canLinkConsole(ply, console)
    if not IsValid(console) or console:GetClass() ~= "consoleent" or console.SlicerCreator ~= ply then return false end
    local information = console.SlicerInformation
    -- A removed door still counts as a previous assignment until its creator
    -- explicitly clears it with !resetLink. Selection cannot redirect a hack.
    return information and information.fileType == "tools"
        and console.SlicerDoor == nil and not information.inUse
end

local selectionInstruction = "Look at one of your configured, unlinked tools consoles and type !setEntity to select it."
local supportedDoors = {func_door = true, func_door_rotating = true}
local doorClassNames = "func_door or func_door_rotating"

function ENT:Initialize()
    self:SetModel(returnEntityModel())
    self:SetSolid(SOLID_BBOX)
    self:SetUseType(SIMPLE_USE)
    -- Counting live consoles reuses names when an earlier console is removed.
    self:SetName("DevonsConsoleEntity" .. self:GetCreationID())
end

function ENT:OnEntityCopyTableFinish(data)
    -- Replace this table rather than editing inUse on an aliased live original.
    data.SlicerInformation = normalizeSlicerInformation(data.SlicerInformation)
    data.SlicerCreator, data.SlicerDoor = nil, nil
end

local function resetCopiedState(console)
    retireSlicerSetupEdit(console)
    console.SlicerCreator, console.SlicerDoor = nil, nil
    console.SlicerInformation = normalizeSlicerInformation(console.SlicerInformation)
    if IsValid(console) then
        console:SetName("DevonsConsoleEntity" .. console:GetCreationID())
    end
end

function ENT:OnDuplicated()
    -- Generic restoration precedes this hook; modifiers run afterward. Remove
    -- copied authority before a modifier can remove the newly spawned entity.
    resetCopiedState(self)
end

function ENT:PostEntityPaste(ply)
    if not IsValid(self) then return end
    -- Modifiers may have restored legacy fields. Revalidate and clear again,
    -- even on invalid-actor paths, before rejecting only this new entity.
    resetCopiedState(self)
    if not IsValid(ply) or not ply:IsPlayer() then
        self:Remove()
        return
    end
    self.SlicerCreator = ply

    -- Rebuild only this entity's record, without reusing a copied table or
    -- appending duplicates if another paste hook already registered it.
    for i = #spawnedEntities, 1, -1 do
        if spawnedEntities[i].entity == self then table.remove(spawnedEntities, i) end
    end
    local information = self.SlicerInformation
    if information then
        table.insert(spawnedEntities, {entityName = self:GetName(), entity = self, information = information})
        if information.fileType == "tools" then
            ply:ChatPrint("Copied tools console is unlinked. Look at it and type !setEntity, then look at a " .. doorClassNames .. " and type !setEntity to link it.")
        end
    else
        ply:ChatPrint("Copied console needs setup. Use it to configure it.")
    end
end

local function openSetup(ply, ent)
    if not IsValid(ply) or not ply:IsPlayer() or not ply:Alive() then return end
    net.Start("PlayerSpawnedConsole")
        net.WriteEntity(ply)
        net.WriteString(ent:GetName())
    net.Send(ply)
end

hook.Add("PlayerSpawnedSENT", "checkForConsole", function(ply, ent)
    if not IsValid(ent) or ent:GetClass() ~= "consoleent" then return end
    ent.SlicerCreator = ply
    openSetup(ply, ent)
end)

function ENT:AcceptInput(name, activator, caller)
    if name ~= "Use" or not IsValid(self) or not IsValid(activator) or not activator:IsPlayer() then return end
    local information = self.SlicerInformation
    if not information then
        -- Initial setup belongs to the creator and needs no hacking tool.
        -- Reopening does not reserve a hack or change a pending door choice.
        if self.SlicerCreator == activator then openSetup(activator, self) end
        return
    end
    if not hasHackingTool(activator) then
        activator:ChatPrint("You don't have the necessary tools to hack this console.")
        return
    end

    if information.fileType == "tools" and not IsValid(self.SlicerDoor) then
        local message = "This console does not have a linked door yet."
        if canLinkConsole(activator, self) then message = message .. " " .. selectionInstruction end
        activator:ChatPrint(message)
        return
    end
    if information.inUse or sessions[activator] then
        local message = "This console or your hacking tool is already in use."
        if sessions[activator] then message = message .. " Type !quitConsole to leave your current session." end
        activator:ChatPrint(message)
        return
    end

    -- Reserve on the server before another player's Use can be handled. The
    -- client expects inUse=false in its own opening message.
    local clientInformation = table.Copy(information)
    retireSlicerSetupEdit(self)
    information.inUse = true
    sessions[activator] = {
        console = self,
        completeAt = CurTime() + information.delay * (information.fileType == "tools" and 1 or 2),
    }
    net.Start("ServerSendsEntityInformation")
        net.WriteEntity(self)
        net.WriteEntity(activator)
        net.WriteTable(clientInformation)
        net.WriteString(self:GetName())
    net.Send(activator)
end

-- Kept for existing clients; reservation is now authoritative in AcceptInput.
net.Receive("updateInUse", function() end)

hook.Add("PlayerDeath", "checkForInConsole", function(victim)
    consoleListings[victim] = nil
    retireSlicerSetupEditsForPlayer(victim)
    releaseSession(victim, true)
end)

hook.Add("PlayerDisconnected", "slicerReleaseConsole", function(ply)
    consoleListings[ply] = nil
    retireSlicerSetupEditsForPlayer(ply)
    releaseSession(ply, false)
    ply.SlicerPendingConsole = nil
end)

net.Receive("playerQuitConsole", function(_, ply)
    -- Never trust the player/entity IDs in the legacy payload.
    releaseSession(ply, false)
end)

-- A lost terminal page must not strand its player's server reservation.
hook.Add("PlayerSay", "slicerQuitConsole", function(ply, text)
    if text ~= "!quitConsole" then return end
    if not IsValid(ply) or not ply:IsPlayer() or not ply:Alive() then return "" end
    if sessions[ply] then
        releaseSession(ply, true)
        ply:ChatPrint("You left your hacking session. Use the console again to start a fresh attempt.")
    else
        ply:ChatPrint("You are not in a hacking session.")
    end
    return ""
end)

-- Configuration records the pending console on the authenticated creator.
-- The legacy packet is unnecessary and must not select another player's door.
net.Receive("ServerWaitingForEntity", function() end)

hook.Add("PlayerSay", "doesThePlayerSetAnEntity", function(ply, text)
    if text ~= "!setEntity" then return end
    local target = ply:GetEyeTrace().Entity
    if IsValid(target) and target:GetClass() == "consoleent" then
        if not canLinkConsole(ply, target) then
            ply:ChatPrint("That console cannot be selected. " .. selectionInstruction .. " It must not be in use.")
            return
        end
        ply.SlicerPendingConsole = target
        ply:ChatPrint("Selected '" .. target.SlicerInformation.name .. "'. Look at a " .. doorClassNames .. " and type !setEntity to link it.")
        return ""
    end

    local console = ply.SlicerPendingConsole
    -- Recheck every condition at the final link, including setup's automatic
    -- selection. Rejected targets never replace the current pending choice.
    if not canLinkConsole(ply, console) then
        ply:ChatPrint(selectionInstruction)
        return
    end
    local door = target
    if not IsValid(door) or not supportedDoors[door:GetClass()] then
        ply:ChatPrint("That is not a valid door object. Look at a " .. doorClassNames .. " and type !setEntity to retry.")
        return
    end
    if IsValid(linkedDoors[door]) then
        ply:ChatPrint("That door is already linked to a console. Look at another " .. doorClassNames .. " and type !setEntity to retry.")
        return
    end
    console.SlicerDoor = door
    linkedDoors[door] = console
    ply.SlicerPendingConsole = nil
    door:Fire("Lock")
    ply:ChatPrint("Entity successfully set")
    return ""
end)

local function inspectionLabel(console)
    local information = console.SlicerInformation
    local name = type(information) == "table" and information.name or nil
    local label = "Console"
    if type(name) == "string" and #name <= 128 and string.Trim(name) ~= "" then
        -- Sanitize only the displayed copy. Keeping the whole bounded name
        -- avoids cutting a valid multibyte character at ChatPrint's byte limit.
        name = name:gsub("[%z\1-\31\127]", "?"):gsub("\194[\128-\159]", "?")
            :gsub("\226\128[\168\169]", "?")
        label = label .. " '" .. name .. "'"
    end
    -- Native creation IDs wrap; these are current labels, never authority.
    return label .. " (current ID #" .. console:GetCreationID() .. "): "
end

hook.Add("PlayerSay", "slicerResetLink", function(ply, text)
    if text ~= "!resetLink" then return end
    if not IsValid(ply) or not ply:IsPlayer() or not ply:Alive() then return "" end
    local console = ply:GetEyeTrace().Entity
    local information = IsValid(console) and console:GetClass() == "consoleent" and console.SlicerCreator == ply
        and normalizeSlicerInformation(console.SlicerInformation)
    -- Validate a separate copy without replacing saved fields, records or edit
    -- tickets. The raw busy flag and actual reservation independently veto reset.
    if not information or information.fileType ~= "tools" or console.SlicerInformation.inUse
        or slicerConsoleHasActiveSession(console) then
        ply:ChatPrint("Look at one of your configured, idle tools consoles with a removed door and type !resetLink.")
        return ""
    end
    local door, message = console.SlicerDoor
    if door == nil then
        message = "has no link to reset. Use !setEntity to select it."
    elseif IsValid(door) then
        message = "still has an available door; its link was not changed."
    else
        console.SlicerDoor = nil
        if linkedDoors[door] == console then linkedDoors[door] = nil end
        message = "old link cleared. Use !setEntity on this console, then on a replacement door."
    end
    ply:ChatPrint(inspectionLabel(console) .. message)
    return ""
end)

hook.Add("PlayerSay", "slicerUnlinkConsole", function(ply, text)
    if text ~= "!unlinkConsole" then return end
    if not IsValid(ply) or not ply:IsPlayer() or not ply:Alive() then return "" end
    local console = ply:GetEyeTrace().Entity
    local information = IsValid(console) and console:GetClass() == "consoleent" and console.SlicerCreator == ply
        and normalizeSlicerInformation(console.SlicerInformation)
    if not information or information.fileType ~= "tools" or console.SlicerInformation.inUse
        or slicerConsoleHasActiveSession(console) then
        ply:ChatPrint("Look at one of your configured, idle tools consoles and type !unlinkConsole.")
        return ""
    end
    local label, door, message = inspectionLabel(console), console.SlicerDoor
    if door == nil then
        message = "has no door link. Use !setEntity to select it."
    elseif not IsValid(door) then
        message = "previous door is no longer available. Use !resetLink on this console."
    elseif not supportedDoors[door:GetClass()] or linkedDoors[door] ~= console then
        message = "no registered link can be confirmed; nothing was changed."
    else
        -- Relinquish only this proven association before native input can
        -- remove the console or reenter linking. Never roll back over a new link.
        console.SlicerDoor, linkedDoors[door] = nil, nil
        local sent = pcall(door.Fire, door, "Unlock")
        message = sent
            and "old link cleared; Unlock sent. If still unlinked, use !setEntity here, then on a door."
            or "old link cleared; Unlock failed. Check the previous door before using !setEntity."
    end
    -- Native input may remove either entity. Report the captured old association
    -- without inspecting the console again or promising physical door movement.
    if IsValid(ply) then ply:ChatPrint(label .. message) end
    return ""
end)

local function inspectConsoleLink(console, information)
    local label = inspectionLabel(console)
    if console.SlicerInformation == nil then return label .. "needs setup. Use it to configure it." end
    if not information then return label .. "invalid configuration; no registered link can be confirmed." end
    if information.fileType ~= "tools" then
        return label .. "configured for " .. information.fileType .. "; door linking is for tools consoles."
    end
    local door = console.SlicerDoor
    if door == nil then return label .. "has no door link." end
    if not IsValid(door) then
        return label .. "previous door is no longer available. When idle, use !resetLink on this console."
    end
    if not supportedDoors[door:GetClass()] or linkedDoors[door] ~= console then
        return label .. "no registered link can be confirmed in this server session."
    end
    return label .. "registered link to " .. door:GetClass() .. " (current ID #" .. door:GetCreationID() .. ")."
end

hook.Add("PlayerSay", "slicerInspectLink", function(ply, text)
    if text ~= "!inspectLink" then return end
    if not IsValid(ply) or not ply:IsPlayer() or not ply:Alive() then return "" end
    local target = ply:GetEyeTrace().Entity
    local message = "Look at one of your consoles or its registered door and type !inspectLink."
    if IsValid(target) then
        if target:GetClass() == "consoleent" and target.SlicerCreator == ply then
            -- Validation returns a separate copy; inspection never normalizes
            -- saved data or repairs a missing link, selection, ticket or session.
            message = inspectConsoleLink(target, normalizeSlicerInformation(target.SlicerInformation))
        elseif supportedDoors[target:GetClass()] then
            local console = linkedDoors[target]
            if IsValid(console) and console:GetClass() == "consoleent"
                and console.SlicerCreator == ply and console.SlicerDoor == target then
                local information = normalizeSlicerInformation(console.SlicerInformation)
                if information and information.fileType == "tools" then
                    message = inspectConsoleLink(console, information)
                end
            end
        end
    end
    -- One private line stays below 255 bytes even with a 128-byte name and
    -- maximum native IDs. No weapon, busy-state claim or network/UI is needed.
    ply:ChatPrint(message)
    return ""
end)

local listConsolesCommand = "!listConsoles"
local consolesPerPage = 5

hook.Add("PlayerSay", "slicerListConsoles", function(ply, text)
    if text ~= listConsolesCommand and not text:find("^!listConsoles%s") then return end
    if ply ~= nil then consoleListings[ply] = nil end
    if not IsValid(ply) or not ply:IsPlayer() or not ply:Alive() then return "" end

    local page = 1
    if text ~= listConsolesCommand then
        -- Bound decimal text before conversion, and require exactly one ASCII
        -- space followed by 1-7 digits without a leading zero or extra text.
        local suffix = #text <= #listConsolesCommand + 8 and text:sub(#listConsolesCommand + 1) or ""
        if not suffix:match("^ [1-9][0-9]*$") then
            ply:ChatPrint("Usage: !listConsoles or !listConsoles <page> (1-7 digits, no leading zero).")
            return ""
        end
        page = tonumber(suffix:sub(2))
    end

    -- Enumerate every live owned console, including deferred setup and copies
    -- missing from the configuration registry. Sort only our separate array.
    local consoles = {}
    for _, console in ipairs(ents.FindByClass("consoleent")) do
        if IsValid(console) and console:GetClass() == "consoleent" and console.SlicerCreator == ply then
            consoles[#consoles + 1] = console
        end
    end
    table.sort(consoles, function(first, second)
        local firstID, secondID = first:GetCreationID(), second:GetCreationID()
        if firstID == secondID then return first:EntIndex() < second:EntIndex() end
        return firstID < secondID
    end)

    local total = #consoles
    local pages = math.ceil(total / consolesPerPage)
    local messages = {}
    if total == 0 then
        messages[1] = "You have no consoles."
    elseif page > pages then
        messages[1] = "Console page must be between 1 and " .. pages .. ". Use !listConsoles <page>."
    else
        messages[1] = "Your consoles: page " .. page .. " of " .. pages .. " (" .. total .. " total). Locate: !locateConsole <row>."
        local first = (page - 1) * consolesPerPage + 1
        local rows = {}
        for i = first, math.min(first + consolesPerPage - 1, total) do
            local console = consoles[i]
            rows[#rows + 1] = console
            messages[#messages + 1] = #rows .. ". " .. inspectConsoleLink(console, normalizeSlicerInformation(console.SlicerInformation))
        end
        consoleListings[ply] = {rows = rows, expires = CurTime() + listingLifetime}
        if page < pages then
            messages[#messages + 1] = "Next page: !listConsoles " .. (page + 1) .. "."
        elseif page > 1 then
            messages[#messages + 1] = "First page: !listConsoles."
        end
    end
    -- Prepare the complete reply before ChatPrint callbacks can remove or
    -- change an entity. Every row retains inspection's existing byte budget.
    for _, message in ipairs(messages) do ply:ChatPrint(message) end
    return ""
end)

-- Row numbers belong only to this player's last displayed page. Exact entity
-- references, rather than wrapping IDs or names, retain their identity.
hook.Add("PlayerSay", "slicerLocateConsole", function(ply, text)
    if text ~= "!locateConsole" and not text:find("^!locateConsole%s") then return end
    if not IsValid(ply) or not ply:IsPlayer() or not ply:Alive() then
        if ply ~= nil then consoleListings[ply] = nil end
        return ""
    end
    if text == "!locateConsole clear" then
        net.Start("SlicerConsoleLocation")
            net.WriteBool(false)
        net.Send(ply)
        return ""
    end
    local row = #text == 16 and text:match("^!locateConsole ([1-5])$")
    if not row then
        ply:ChatPrint("Usage: !locateConsole <row> (1-5 from your last !listConsoles page), or !locateConsole clear.")
        return ""
    end
    local listing = consoleListings[ply]
    if listing and CurTime() >= listing.expires then consoleListings[ply], listing = nil, nil end
    local console = listing and listing.rows[tonumber(row)]
    if not IsValid(console) or console:GetClass() ~= "consoleent" or console.SlicerCreator ~= ply then
        ply:ChatPrint("That console row is unavailable or expired. Use !listConsoles again, then !locateConsole <row>.")
        return ""
    end
    net.Start("SlicerConsoleLocation")
        net.WriteBool(true)
        net.WriteString(inspectionLabel(console):sub(1, -3))
        net.WriteVector(console:WorldSpaceCenter())
    net.Send(ply)
    return ""
end)

local nextListingCleanup = 0
hook.Add("Think", "slicerExpireConsoleListings", function()
    local now = CurTime()
    if now < nextListingCleanup then return end
    nextListingCleanup = now + 5
    for ply, listing in pairs(consoleListings) do
        if not IsValid(ply) or not ply:IsPlayer() or not ply:Alive() or now >= listing.expires then
            consoleListings[ply] = nil
        end
    end
end)

hook.Add("PlayerUse", "isUsingOurObject", function(ply, ent)
    if IsValid(linkedDoors[ent]) then
        net.Start("PlayerAlert")
        net.Send(ply)
        return false
    end
    -- Return nil for unrelated entities so other addons can handle the hook.
end)

local function canComplete(ply, console, isDoor)
    local session = sessions[ply]
    if not session or session.console ~= console or not IsValid(console) then return false end
    local information = console.SlicerInformation
    local validType = information and (isDoor
        and information.fileType == "tools" and IsValid(console.SlicerDoor)
        or not isDoor and (information.fileType == "data" or information.fileType == "server"))
    if not hasHackingTool(ply) or CurTime() < session.completeAt or not validType then
        -- The client has closed its completed countdown. Do not strand this
        -- authenticated session if a tool or other requirement changed.
        releaseSession(ply, true)
        ply:ChatPrint("Hacking was not completed. Equip the hacking tool and use the console again to retry.")
        return false
    end
    return true
end

local function finishConsole(ply, console)
    local information = console.SlicerInformation
    releaseSession(ply, false)
    console:Remove() -- OnRemove unlocks only this console's linked door.
    net.Start("SlicerCompleted")
        net.WriteString(information.name)
        net.WriteString(information.fileName)
        net.WriteString(information.fileType)
        net.WriteString(ply:GetName())
    net.Send(ply)
end

net.Receive("PlayerActivatedDoor", function(_, ply)
    local console = net.ReadEntity()
    if not canComplete(ply, console, true) then return end
    finishConsole(ply, console)
end)

net.Receive("destroyOnServer", function(_, ply)
    local console = net.ReadEntity()
    if not canComplete(ply, console, false) then return end
    finishConsole(ply, console)
end)

function ENT:OnRemove()
    retireSlicerSetupEdit(self)
    for ply, session in pairs(sessions) do
        if session.console == self then releaseSession(ply, true) end
    end
    if IsValid(self.SlicerDoor) and linkedDoors[self.SlicerDoor] == self then
        linkedDoors[self.SlicerDoor] = nil
        self.SlicerDoor:Fire("Unlock")
    end
    if IsValid(self.SlicerCreator) and self.SlicerCreator.SlicerPendingConsole == self then
        self.SlicerCreator.SlicerPendingConsole = nil
    end
    for i = #spawnedEntities, 1, -1 do
        if spawnedEntities[i].entity == self then table.remove(spawnedEntities, i) end
    end
end
