-- mod_push_appserver
--
-- Copyright (C) 2017 Thilo Molitor
--
-- This file is MIT/X11 licensed.
--
-- Implementation of a simple push app server
--

-- imports
local os = require "os";
local pretty = require "pl.pretty";
local http = require "net.http";
local hashes = require "util.hashes";
local datetime = require "util.datetime";
local st = require "util.stanza";
local dataform = require "util.dataforms".new;
local string = string;

-- config
local body_size_limit = 4096; -- 4 KB
local debugging = module:get_option_boolean("push_appserver_debugging", false);

--- sanity
local parser_body_limit = module:context("*"):get_option_number("http_max_content_size", 10*1024*1024);
if body_size_limit > parser_body_limit then
	module:log("warn", "%s_body_size_limit exceeds HTTP parser limit on body size, capping file size to %d B", module.name, parser_body_limit);
	body_size_limit = parser_body_limit;
end

-- depends
module:depends("http");
module:depends("disco");

-- namespace
local xmlns_pubsub = "http://jabber.org/protocol/pubsub";
local xmlns_push = "urn:xmpp:push:0";

-- For keeping state across reloads while caching reads
local push_store = (function()
	local store = module:open_store();
	local cache = {};
	local token2node_cache = {};
	local api = {};
	function api:get(node)
		if not cache[node] then
			local err;
			cache[node], err = store:get(node);
			if not cache[node] and err then
				module:log("error", "Error reading push notification storage for node '%s': %s", node, tostring(err));
				cache[node] = {};
				return cache[node], false;
			end
		end
		if not cache[node] then cache[node] = {} end
		return cache[node], true;
	end
	function api:set(node, data)
		local settings = api:get(node);		-- load node's data
		if settings.token then token2node_cache[settings.token] = nil; end		-- invalidate token2node cache
		cache[node] = data;
		local ok, err = store:set(node, cache[node]);
		if not ok then
			module:log("error", "Error writing push notification storage for node '%s': %s", node, tostring(err));
			return false;
		end
		return true;
	end
	function api:list()
		return store:users();
	end
	function api:token2node(token)
		if token2node_cache[token] then return token2node_cache[token].node; end
		for node in store:users() do
			local err;
			-- read data directly, we don't want to cache full copies of stale entries as api:get() would do
			settings, err = store:get(node);
			if not settings and err then
				module:log("error", "Error reading push notification storage for node '%s': %s", node, tostring(err));
				settings = {};
			end
			if settings.token and settings.node then token2node_cache[settings.token] = settings.node; end
		end
		if token2node_cache[token] then return token2node_cache[token].node; end
		return nil;
	end
	return api;
end)();

-- html helper
local function html_skeleton()
	local header, footer;
	header = "<!DOCTYPE html>\n<html><head><title>mod_"..module.name.." settings</title></head><body>\n";
	footer = "\n</body></html>";
	return header, footer;
end

local function get_html_form(...)
	local html = '<form method="post"><table>\n';
	for i,v in ipairs(arg) do
		html = html..'<tr><td>'..tostring(v)..'</td><td><input type="text" name="'..tostring(v)..'" required></td></tr>\n';
	end
	html = html..'<tr><td>&nbsp;</td><td><button type="submit">send request</button></td></tr>\n</table></form>';
	return html;
end

-- hooks
local function sendError(origin, stanza)
	origin.send(st.error_reply(stanza, "cancel", "item-not-found", "Unknown push node/secret"));
	return true;
end

local options_form = dataform {
	{ name = "FORM_TYPE"; value = "http://jabber.org/protocol/pubsub#publish-options"; };
	{ name = "secret"; type = "hidden"; required = true; };
};

module:hook("iq/host", function (event)
	local stanza, origin = event.stanza, event.origin;
	
	local publishNode = stanza:find("{http://jabber.org/protocol/pubsub}/publish");
	if not publishNode then return; end
	local pushNode = publishNode:find("item/{urn:xmpp:push:0}notification");
	if not pushNode then return; end
	
	-- push options and the secret therein are mandatory
	local optionsNode = stanza:find("{http://jabber.org/protocol/pubsub}/publish-options/{jabber:x:data}");
	if not optionsNode then return sendError(origin, stanza); end
	local data, errors = options_form:data(optionsNode);
	if errors then return sendError(origin, stanza); end
	
	local node = publishNode.attr.node;
	local secret = data["secret"];
	module:log("debug", "node: %s, secret: %s", tostring(node), tostring(secret));
	if not node or not secret then return sendError(origin, stanza); end
	
	local settings = push_store:get(node);
	if not settings or not #settings then return sendError(origin, stanza); end
	if secret ~= settings["secret"] then return sendError(origin, stanza); end
	
	module:log("info", "Firing event '%s' (node = '%s', secret = '%s')", "incoming-push-to-"..settings["type"], settings["node"], settings["secret"]);
	local success = module:fire_event("incoming-push-to-"..settings["type"], {origin = origin, settings = settings, stanza = stanza});
	if success or success == nil then
		module:log("error", "Push handler for type '%s' not executed successfully%s", settings["type"], type(success) == "string" and ": "..success or ": handler not found");
		origin.send(st.error_reply(stanza, "wait", "internal-server-error", type(success) == "string" and success or "Internal error in push handler"));
		settings["last_push_error"] = datetime.datetime();
	else
		origin.send(st.reply(stanza));
		settings["last_successful_push"] = datetime.datetime();
	end
	push_store:set(node, settings);
	return true;
end);

local function unregister_push_node(node, type)
	local settings = push_store:get(node);
	if settings["type"] == type then
		module:log("info", "Unregistered push device, returning: 'OK', '%s', '%s'", tostring(node), tostring(settings["secret"]));
		module:log("debug", "settings: %s", pretty.write(settings));
		push_store:set(node, nil);
		return "OK\n"..node.."\n"..settings["secret"];
	end
	
	module:log("info", "Node not found in unregister, returning: 'ERROR', 'Node not found!'", tostring(node));
	return "ERROR\nNode not found!";
end

module:hook("unregister-push-token", function(event)
	local token, type, timestamp = event.token, event.type, event.timestamp or os.time();
	local node = push_store:token2node(token);
	if node then
		local settings = push_store:get(node);
		local register_timestamp = datetime.parse(settings["renewed"] or settings["registered"]);
		if timestamp > register_timestamp then
			return unregister_push_node(node, type);
		else
			module:log("warn", "Unregister via token failed: node '%s' was re-registered after delete timestamp %s", node, datetime.datetime(timestamp));
		end
	else
		module:log("warn", "Unregister via token failed: could not find '%s' node for push token '%s'", type, token);
	end
	return false;
end);

-- http service
local function serve_hello(event, path)
	local header, footer = html_skeleton();
	event.response.headers.content_type = "text/html;charset=utf-8";
	return header.."<h1>Hello from mod_"..module.name.."!</h1>"..footer;
end

local function serve_register_v1(event, path)
	if #event.request.body > body_size_limit then
		module:log("warn", "Post body too large: %d bytes", #event.request.body);
		return 400;
	end
	
	local arguments = http.formdecode(event.request.body);
	if not arguments["type"] or not arguments["node"] or not arguments["token"] then
		module:log("warn", "Post data contains unexpected contents");
		return 400;
	end
	
	local settings = push_store:get(arguments["node"]);
	if settings["type"] == arguments["type"] and settings["token"] == arguments["token"] then
		module:log("info", "Re-registered push device, returning: 'OK', '%s', '%s'", tostring(arguments["node"]), tostring(settings["secret"]));
		module:log("debug", "settings: %s", pretty.write(settings));
		settings["renewed"] = datetime.datetime();
		push_store:set(arguments["node"], settings);
		return "OK\n"..arguments["node"].."\n"..settings["secret"];
	end
	
	-- store this new token-node combination
	settings["type"]       = arguments["type"];
	settings["node"]       = arguments["node"];
	settings["secret"]     = hashes.hmac_sha256(arguments["type"]..":"..arguments["token"].."@"..arguments["node"], os.clock(), true);
	settings["token"]      = arguments["token"];
	settings["registered"] = datetime.datetime();
	push_store:set(arguments["node"], settings);
	
	module:log("info", "Registered push device, returning: 'OK', '%s', '%s'", tostring(arguments["node"]), tostring(settings["secret"]));
	module:log("debug", "settings: %s", pretty.write(settings));
	return "OK\n"..arguments["node"].."\n"..settings["secret"];
end

local function serve_register_form_v1(event, path)
	if not debugging then return 403; end
	local header, footer = html_skeleton();
	event.response.headers.content_type = "text/html;charset=utf-8";
	return header.."<h1>Register Push Node</h1>"..get_html_form("type", "node", "token")..footer;
end

local function serve_unregister_v1(event, path)
	if #event.request.body > body_size_limit then
		module:log("warn", "Post body too large: %d bytes", #event.request.body);
		return 400;
	end
	
	local arguments = http.formdecode(event.request.body);
	if not arguments["type"] or not arguments["node"] then
		module:log("warn", "Post data contains unexpected contents");
		return 400;
	end
	
	return unregister_push_node(arguments["node"], arguments["type"]);
end

local function serve_unregister_form_v1(event, path)
	if not debugging then return 403; end
	local header, footer = html_skeleton();
	event.response.headers.content_type = "text/html;charset=utf-8";
	return header.."<h1>Unregister Push Node</h1>"..get_html_form("type", "node")..footer;
end

local function serve_push_v1(event, path)
	if #event.request.body > body_size_limit then
		module:log("warn", "Post body too large: %d bytes", #event.request.body);
		return 400;
	end
	
	local arguments = http.formdecode(event.request.body);
	if not arguments["node"] or not arguments["secret"] then
		module:log("warn", "Post data contains unexpected contents");
		return 400;
	end
	
	local node, secret = arguments["node"], arguments["secret"];
	local settings = push_store:get(node);
	if not settings or not #settings or secret ~= settings["secret"] then
		module:log("info", "Node or secret not found in push, returning: 'ERROR', 'Node or secret not found!'", tostring(node));
		return "ERROR\nNode or secret not found!";
	end
	
	local response = "ERROR\nInternal server error!";
	module:log("info", "Firing event '%s' (node = '%s', secret = '%s')", "incoming-push-to-"..settings["type"], settings["node"], settings["secret"]);
	local success = module:fire_event("incoming-push-to-"..settings["type"], {origin = nil, settings = settings, stanza = nil});
	if success or success == nil then
		module:log("error", "Push handler for type '%s' not executed successfully%s", settings["type"], type(success) == "string" and ": "..success or "");
		settings["last_push_error"] = datetime.datetime();
	else
		settings["last_successful_push"] = datetime.datetime();
		response = "OK\n"..node;
	end
	push_store:set(node, settings);
	module:log("debug", "settings: %s", pretty.write(settings));
	return response;
end

local function serve_push_form_v1(event, path)
	if not debugging then return 403; end
	local header, footer = html_skeleton();
	event.response.headers.content_type = "text/html;charset=utf-8";
	return header.."<h1>Send Push Request</h1>"..get_html_form("node", "secret")..footer;
end

local function serve_settings_v1(event, path)
	if not debugging then return 403; end
	local output, footer = html_skeleton();
	event.response.headers.content_type = "text/html;charset=utf-8";
	if not path or path == "" then
		output = output.."<h1>List of devices (node uuids)</h1>";
		for node in push_store:list() do
			output = output .. '<a href="/v1/settings/'..node..'">'..node.."</a><br>\n";
		end
		return output.."</body></html>";
	end
	path = path:match("^([^/]+).*$");
	local settings = push_store:get(path);
	return output..'<a href="/v1/settings">Back to List</a><br>\n<pre>'..pretty.write(settings).."</pre>"..footer;
end

module:provides("http", {
	route = {
		["GET"] = serve_hello;
		["GET /"] = serve_hello;
		["GET /v1/register"] = serve_register_form_v1;
		["POST /v1/register"] = serve_register_v1;
		["GET /v1/unregister"] = serve_unregister_form_v1;
		["POST /v1/unregister"] = serve_unregister_v1;
		["GET /v1/push"] = serve_push_form_v1;
		["POST /v1/push"] = serve_push_v1;
		["GET /v1/settings"] = serve_settings_v1;
		["GET /v1/settings/*"] = serve_settings_v1;
	};
});

module:log("info", "Appserver started at URL: <%s>", module:http_url().."/");
