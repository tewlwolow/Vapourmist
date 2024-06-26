-- Util module
-->>>---------------------------------------------------------------------------------------------<<<--

local util = {}

local config = require("tew.Vapourmist.config")
local metadata = toml.loadMetadata("Vapourmist")


-- Print debug messages --
---@type fun(message: string): nil
function util.debugLog(message)
	if config.debugLogOn then
		if not message then message = "n/a" end
		message = tostring(message)
		local info = debug.getinfo(2, "Sl")
		local module = info.short_src:match("^.+\\(.+).lua$")
		local prepend = ("[%s.%s.%s:%s]:"):format(metadata.package.name, metadata.package.version, module,
			info.currentline)
		local aligned = ("%-36s"):format(prepend)
		mwse.log(aligned .. " -- " .. string.format("%s", message))
	end
end

function util.metadataMissing()
	local errorMessage = "Error! Vapourmist-metadata.toml file is missing. Please install."
	tes3.messageBox {
		message = errorMessage,
	}
	error(errorMessage)
end

function util.safeAddToTable(obj, tab)
	tab[obj] = tes3.makeSafeObjectHandle(obj)
end

function util.safeGetFromTable(obj, tab)
	if table.empty(tab) or not obj or not tab[obj] then return end
	local obj_safe = tab[obj]
	return obj_safe:valid() and obj_safe:getObject()
end

return util
