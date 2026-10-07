AddCSLuaFile("entities/consoleent/cl_init.lua")
AddCSLuaFile("entities/consoleent/shared.lua")

include("entities/consoleent/shared.lua")
include("autorun/server/sv_config.lua")

local sessions = {}
local linkedDoors = {}

-- Configuration flags can be changed by legacy callers independently of a
-- reservation. Editing must also consult the actual server-owned sessions.
function slicerConsoleHasActiveSession(console)
    for _, session in pairs(sessions) do
        if session.console == console then return true end
    end
    return false
end

for _, name in ipairs({
    "PlayerSpawnedConsole", "ServerSendsEntityInformation", "updateInUse",
    "PlayerDied", "playerQuitConsole", "ServerWaitingForEntity", "PlayerAlert",
    "PlayerActivatedDoor", "destroyOnServer", "SlicerCompleted",
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
    -- A removed door still counts as a previous assignment. This is selection
    -- of a never-linked console, not permission to redirect an existing hack.
    return information and information.fileType == "tools"
        and console.SlicerDoor == nil and not information.inUse
end

local selectionInstruction = "Look at one of your configured, never-linked tools consoles and type !setEntity to select it."
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
        activator:ChatPrint("This console or your hacking tool is already in use.")
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
    retireSlicerSetupEditsForPlayer(victim)
    releaseSession(victim, true)
end)

hook.Add("PlayerDisconnected", "slicerReleaseConsole", function(ply)
    retireSlicerSetupEditsForPlayer(ply)
    releaseSession(ply, false)
    ply.SlicerPendingConsole = nil
end)

net.Receive("playerQuitConsole", function(_, ply)
    -- Never trust the player/entity IDs in the legacy payload.
    releaseSession(ply, false)
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
