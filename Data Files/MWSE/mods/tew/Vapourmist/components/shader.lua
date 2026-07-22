local this = {}

--- Tracks which ID currently owns the (single) fog volume for each shader,
--- keyed by shader name. Both tew_dust and tew_fogbox only ever have one
--- fog volume active at a time (see interior.lua / mistShader.lua), so
--- there's no need for the multi-slot index management this used to have.
---@type table<string, string>
local activeFogVolumeOwner = {}

---@param shaderName string
---@return mgeShaderHandle|nil
local function getShader(shaderName)
    return mge.shaders.load({ name = shaderName })
end

---@param shaderName string
---@param params fogParams
local function applyShaderParams(shaderName, params)
    local shader = getShader(shaderName)
    if shader then
        shader.fogCenter = { params.center.x, params.center.y, params.center.z }
        shader.fogRadius = { params.radius.x, params.radius.y, params.radius.z }
        shader.fogColor = { params.color.x, params.color.y, params.color.z }
        shader.fogDensity = params.density
    end
end


function this.setValue(params)
    local shader = getShader(params.shaderName)

    if shader then
        local param = params.param
        local value = params.value
        if param and value then
            shader[param] = value
        end
    end
end

---@param shaderName string
---@param id string
---@param params fogParams
function this.createOrUpdateFog(shaderName, id, params)
    applyShaderParams(shaderName, params)
    activeFogVolumeOwner[shaderName] = id

    local shader = getShader(shaderName)
    if shader then
        shader.enabled = true
    end
end

---@param shaderName string
---@param id string
function this.deleteFog(shaderName, id)
    -- Only clear if this id actually owns the volume - avoids one
    -- caller's delete stomping on another's active fog.
    if activeFogVolumeOwner[shaderName] ~= id then return end

    applyShaderParams(shaderName, {
        color = tes3vector3.new(),
        center = tes3vector3.new(),
        radius = tes3vector3.new(),
        density = 0,
    })

    activeFogVolumeOwner[shaderName] = nil

    local shader = getShader(shaderName)
    if shader then
        shader.enabled = false
    end
end

---@param shaderName string
function this.disableFog(shaderName)
    local shader = getShader(shaderName)
    if shader then
        shader.enabled = false
    end
end

---@param shaderName string
function this.enableFog(shaderName)
    local shader = getShader(shaderName)
    if shader then
        shader.enabled = true
    end
end

return this
