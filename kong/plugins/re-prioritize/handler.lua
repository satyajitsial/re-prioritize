local kong = kong
local ngx = require "ngx"
local BasePlugin = require "kong.plugins.base_plugin"
local runloop = require "kong.runloop.handler"
local update_time = ngx.update_time
local now = ngx.now
local kong_global = require "kong.global"
local PHASES = kong_global.phases
local reprioritizePlugins = BasePlugin:extend()
local portal_auth = require "kong.portal.auth"
local currentpluginName = 're-prioritize'
reprioritizePlugins.PRIORITY = 200000

function reprioritizePlugins:new()
  reprioritizePlugins.super.new(self, "re-prioritize")
end

-- Get Current Time
local function get_now_ms()
  update_time()
  return now() * 1000 -- time is kept in seconds with millisecond resolution.
end

-- Split using delimiter
local function split(string, delimiter)
   local result = {};
   for match in (string..delimiter):gmatch("(.-)"..delimiter) do
      table.insert(result, match);
   end
   return result;
end

-- Remove spaces from Beginning and Ending of String
local function trim(headerValue)
   return string.gsub(headerValue,"^%s*(.-)%s*$", "%1")
end

-- Validate the Plugin Names
local function validatePluginNames(conf,ctx)
   local plugins_iterator = runloop.get_plugins_iterator()
    local pluginstable = {}
    for plugin, plugin_conf in plugins_iterator:iterate("access", ctx) do
	    if(plugin.name ~= currentpluginName) then
		  local priority = plugin.handler.PRIORITY
		  pluginstable[plugin.name] = priority
		end
	end
	local pluginNames = split(conf.plugin_names,  ",+")
    for _,configPlugin in pairs(pluginNames) do
	   if ( pluginstable[configPlugin] == nil or configPlugin == currentpluginName) then
	     kong.log.err("Invalid Plugin Configuration : ", configPlugin)
         return kong.response.exit(400, { message = "Plugin " .. configPlugin .. " is not enabled, Please check re-prioritize plugin configuration" .. " to add plugin names which are enabled for the service or workspace"})
	   end
	end
end

-- flush the response
local function flush_delayed_response(ctx)
  ctx.delay_response = false

  if type(ctx.delayed_response_callback) == "function" then
    ctx.delayed_response_callback(ctx)
    return -- avoid tail call
  end

  kong.response.exit(ctx.delayed_response.status_code,
                     ctx.delayed_response.content,
                     ctx.delayed_response.headers)
end

-- Reset Plugin Context
local function reset_plugin_context(ctx, old_ws)
  kong_global.reset_log(kong, ctx)
  if old_ws then
    ctx.workspace = old_ws
  end
end

-- Run the Plugins
local function executePlugin(old_ws,plugin,plugin_conf,ctx)
   if not ctx.delayed_response then
      if plugin.handler._go then
         ctx.ran_go_plugin = true
      end
      kong_global.set_named_ctx(kong, "plugin", plugin.handler, ctx)
      kong_global.set_namespaced_log(kong, plugin.name, ctx)
      local co = coroutine.create(plugin.handler.access)
      local cok, cerr = coroutine.resume(co, plugin.handler, plugin_conf)
      if not cok then
        kong.log.err(cerr)
        ctx.delayed_response = {
          status_code = 500,
          content = { message  = "An unexpected error occurred" },
        }
      end

      local ok, err = portal_auth.verify_developer_status(ctx.authenticated_consumer)
      if not ok then
        ctx.delay_response = false
        return kong.response.exit(401, { message = err })
      end
      reset_plugin_context(ctx, old_ws)
    end
end

-- Method to override the access phase
local function kongaccess(conf)
  local ctx = ngx.ctx
  ctx.is_proxy_request = true
  if not ctx.KONG_ACCESS_START then
    ctx.KONG_ACCESS_START = get_now_ms()
    if ctx.KONG_REWRITE_START and not ctx.KONG_REWRITE_ENDED_AT then
      ctx.KONG_REWRITE_ENDED_AT = ctx.KONG_ACCESS_START
      ctx.KONG_REWRITE_TIME = ctx.KONG_REWRITE_ENDED_AT - ctx.KONG_REWRITE_START
    end
  end
  ctx.KONG_PHASE = PHASES.access
  runloop.access.before(ctx)
  validatePluginNames(conf,ctx)
  ctx.delay_response = true
  local old_ws = ctx.workspace
  local pluginNames = split(conf.plugin_names,  ",+")
  local configuredPluginTable = {}
  local configPluginSize = table.getn(pluginNames)
  for _,configPlugin in pairs(pluginNames) do
  local configPluginName = trim(configPlugin)
  local plugins_iterator = runloop.get_plugins_iterator()
  for plugin, plugin_conf in plugins_iterator:iterate("access", ctx) do
    if(plugin.name ~= currentpluginName) then
      if(plugin.name == configPluginName) then
	    configPluginSize = configPluginSize - 1
		local priority = plugin.handler.PRIORITY
		configuredPluginTable[plugin.name] = priority
		kong.log("###### Executing Plugin : ###### ".. plugin.name)
        executePlugin(old_ws,plugin,plugin_conf,ctx)
		ctx.KONG_PHASE = PHASES.access
        runloop.access.before(ctx)
		if(configPluginSize == 0) then
		  break
		end
      end
    end
   end
  end
 
  local plugins_iterator = runloop.get_plugins_iterator()
  for plugin, plugin_conf in plugins_iterator:iterate("access", ctx) do
    if(plugin.name ~= currentpluginName) then
	  local pluginName = plugin.name
      if(configuredPluginTable[pluginName] == nil) then
		 kong.log("###### Executing Plugin : ###### ".. plugin.name)
         executePlugin(old_ws,plugin,plugin_conf,ctx)
      end
    end
  end
    ctx.delay_response = nil
    if ctx.delayed_response then
      ctx.KONG_ACCESS_ENDED_AT = get_now_ms()
      ctx.KONG_ACCESS_TIME = ctx.KONG_ACCESS_ENDED_AT - ctx.KONG_ACCESS_START
      ctx.KONG_RESPONSE_LATENCY = ctx.KONG_ACCESS_ENDED_AT - ctx.KONG_PROCESSING_START
      return flush_delayed_response(ctx)
    end

    ctx.delay_response = nil

    if not ctx.service then
      ctx.KONG_ACCESS_ENDED_AT = get_now_ms()
      ctx.KONG_ACCESS_TIME = ctx.KONG_ACCESS_ENDED_AT - ctx.KONG_ACCESS_START
      ctx.KONG_RESPONSE_LATENCY = ctx.KONG_ACCESS_ENDED_AT - ctx.KONG_PROCESSING_START

      return kong.response.exit(503, { message = "no Service found with those values"})
    end

    runloop.access.after(ctx)

    ctx.KONG_ACCESS_ENDED_AT = get_now_ms()
    ctx.KONG_ACCESS_TIME = ctx.KONG_ACCESS_ENDED_AT - ctx.KONG_ACCESS_START

    -- we intent to proxy, though balancer may fail on that
    ctx.KONG_PROXIED = true

    if ctx.buffered_proxying then
    local version = ngx.req.http_version()
    local upgrade = var.upstream_upgrade or ""
    if version < 2 and upgrade == "" then
      return Kong.response()
    end

    if version >= 2 then
      ngx_log(ngx_NOTICE, "response buffering was turned off: incompatible HTTP version (", version, ")")
    else
      ngx_log(ngx_NOTICE, "response buffering was turned off: connection upgrade (", upgrade, ")")
    end

    ctx.buffered_proxying = nil
    end
  runloop.access.after(ngx.ctx)
  return ngx.exit(ngx.OK)
end

-- This will execute when the client request hits the plugin
function reprioritizePlugins:access(conf)
  kong.log("#### re-prioritize Plugin:  Executing Access Phase")
  kongaccess(conf)
end

return reprioritizePlugins

