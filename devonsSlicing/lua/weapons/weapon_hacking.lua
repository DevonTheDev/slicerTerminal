SWEP.Author = "Devon"
SWEP.Base = "weapon_base"
SWEP.PrintName = "Devons Hacking Tool"

SWEP.ViewModel = "models/weapons/c_toolgun.mdl" -- Gets the model path
SWEP.WorldModel = "models/weapons/w_toolgun.mdl" -- Gets the model path 

SWEP.Spawnable = true
SWEP.UseHands = true

SWEP.DrawAmmo = false

SWEP.Slot = 1
SWEP.SlotPos = 0

-- ShouldDropOnDie is an engine hook, not a boolean weapon field.
function SWEP:ShouldDropOnDie()
    return false
end

-- Apply the hold type without replacing the engine's SetHoldType method.
function SWEP:Initialize()
    self:SetHoldType("pistol")
end

-- Disables attacking with the weapon
function SWEP:CanPrimaryAttack()
    return false
end

function SWEP:CanSecondaryAttack()
    return false
end