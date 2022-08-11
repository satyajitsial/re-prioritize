-- schema.lua
-- Remove spaces from Beginning and Ending of String
local function trim(headerValue)
   return string.gsub(headerValue,"^%s*(.-)%s*$", "%1")
end

-- validate the skipped PluginName
local function validatePluginName(conf)
    local inputPluginNames = conf.plugin_names ;
    local pluginNames = trim(inputPluginNames) ;
    if (string.len(pluginNames) == 0) then
       return false,"Plugin Names can not be empty"
    end
  return true
end

return {
  name = "re-prioritize",
  fields = {
    {
      config = {
	    custom_validator = validatePluginName,
        type = "record",
        fields = {
          { plugin_names = { type = "string", encrypted = true, required = true}}
        },
      },
    },
  },
}

