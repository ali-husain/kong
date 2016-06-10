local BIN_PATH = "bin/kong"
local TEST_CONF_PATH = "spec/kong_tests.conf"

local conf_loader = require "kong.conf_loader"
local DAOFactory = require "kong.dao.factory"
local pl_stringx = require "pl.stringx"
local pl_utils = require "pl.utils"
local pl_path = require "pl.path"
local pl_file = require "pl.file"
local pl_dir = require "pl.dir"
local http = require "resty.http"
local log = require "kong.cmd.utils.log"
local cjson = require "cjson.safe"

log.set_lvl(log.levels.quiet) -- disable stdout logs in tests

---------------
-- Conf and DAO
---------------
local conf = assert(conf_loader(TEST_CONF_PATH))
local dao = DAOFactory(conf)
-- make sure migrations are up-to-date
--assert(dao:run_migrations())

--------------------
-- Custom properties
--------------------
local admin_port = string.match(conf.admin_listen, ":([%d]+)$")
local proxy_port = string.match(conf.proxy_listen, ":([%d]+)$")
local ssl_proxy_port = string.match(conf.proxy_listen_ssl, ":([%d]+)$")

-----------------
-- Custom helpers
-----------------
local resty_http_proxy_mt = {}

-- Case insensitive lookup function, returns the value and the original key. Or if not
-- found nil and the search key
-- @usage -- sample usage
-- local test = { SoMeKeY = 10 }
-- print(lookup(test, "somekey"))  --> 10, "SoMeKeY"
-- print(lookup(test, "NotFound")) --> nil, "NotFound"
local function lookup(t, k)
  local ok = k
  if type(k) ~= "string" then
    return t[k], k
  else
    k = k:lower()
  end
  for key, value in pairs(t) do
    if tostring(key):lower() == k then 
      return value, key
    end
  end
  return nil, ok
end

--- Send a http request. Based on https://github.com/pintsized/lua-resty-http.
-- If `opts.body` is a table and "Content-Type" header contains `application/json`,
-- `www-form-urlencoded`, or `multipart/form-data`, then it will automatically encode the body 
-- according to the content type.
-- If `opts.query` is a table, a query string will be constructed from it and appended
-- to the request path (assuming none is already present).
-- @name http_client:send
-- @param opts table with options. See https://github.com/pintsized/lua-resty-http
function resty_http_proxy_mt:send(opts)
  local cjson = require "cjson"
  local utils = require "kong.tools.utils"

  opts = opts or {}

  -- build body
  local headers = opts.headers or {}
  local content_type, content_type_name = lookup(headers, "Content-Type")
  content_type = content_type or ""
  local t_body_table = type(opts.body) == "table"
  if string.find(content_type, "application/json") and t_body_table then
    opts.body = cjson.encode(opts.body)
  elseif string.find(content_type, "www-form-urlencoded", nil, true) and t_body_table then
    opts.body = utils.encode_args(opts.body, true) -- true: not % encoded
  elseif string.find(content_type, "multipart/form-data", nil, true) and t_body_table then
    local form = opts.body
    local boundary = "8fd84e9444e3946c"
    local body = ""

    for k, v in pairs(form) do
      body = body.."--"..boundary.."\r\nContent-Disposition: form-data; name=\""..k.."\"\r\n\r\n"..tostring(v).."\r\n"
    end

    if body ~= "" then
      body = body.."--"..boundary.."--\r\n"
    end

    local clength = lookup(headers, "content-length")
    if not clength then
      headers["content-length"] = #body
    end
    
    if not content_type:find("boundary=") then
      headers[content_type_name] = content_type.."; boundary="..boundary
    end
    
    opts.body = body
  end

  -- build querystring (assumes none is currently in 'opts.path')
  if type(opts.query) == "table" then
    local qs = utils.encode_args(opts.query)
    opts.path = opts.path.."?"..qs
    opts.query = nil
  end

  local res, err = self:request(opts)
  if res then
    -- wrap the read_body() so it caches the result and can be called multiple times
    local reader = res.read_body
    res.read_body = function(self)
      if (not self._cached_body) and (not self._cached_error) then
        self._cached_body, self._cached_error = reader(self)
      end
      return self._cached_body, self._cached_error
    end
  end
  
  return res, err
end

function resty_http_proxy_mt:__index(k)
  local f = rawget(resty_http_proxy_mt, k)
  if f then
    return f
  end

  return self.client[k]
end

local function http_client(host, port, timeout)
  timeout = timeout or 10000
  local client = assert(http.new())
  assert(client:connect(host, port))
  client:set_timeout(timeout)
  return setmetatable({
    client = client
  }, resty_http_proxy_mt)
end

local function udp_server(port)
  local threads = require "llthreads2.ex"

  local thread = threads.new({
    function(port)
      local socket = require "socket"
      local server = assert(socket.udp())
      server:settimeout(1)
      server:setoption("reuseaddr", true)
      server:setsockname("127.0.0.1", port)
      local data = server:receive()
      server:close()
      return data
    end
  }, port or 9999)

  thread:start()

  ngx.sleep(0.1)

  return thread
end

--------------------
-- Custom assertions
--------------------
local say = require "say"
local luassert = require "luassert.assert"

local function fail(state, args)
  args[1] = table.concat(args, " ")
  return false
end
say:set("assertion.fail.negative", "%s")
luassert:register("assertion", "fail", fail,
                  "assertion.fail.negative",
                  "assertion.fail.negative")

local function contains(state, args)
  local expected, arr = unpack(args)
  local found
  for i = 1, #arr do
    if arr[i] == expected then
      found = true
      break
    end
  end
  return found
end
say:set("assertion.contains.negative", [[
Expected array to contain element.
Expected to contain:
%s
]])
say:set("assertion.contains.positive", [[
Expected array to not contain element.
Expected to not contain:
%s
]])
luassert:register("assertion", "contains", contains,
                  "assertion.contains.negative",
                  "assertion.contains.positive")

local function res_status(state, args)
  local expected, res = unpack(args)
  if not res then
    table.insert(args, 1, "")
    table.insert(args, 1, "no response")
    table.insert(args, 1, expected)
    return false
  elseif expected ~= res.status then
    local body, err = res:read_body()
    if not body then body = "Error reading body: "..tostring(err) end
    table.insert(args, 1, body)
    table.insert(args, 1, res.status)
    table.insert(args, 1, expected)
    return false
  end
  local body = pl_stringx.strip(res:read_body())
  return true, {body}
end
say:set("assertion.res_status.negative", [[
Invalid response status code.
Status expected:
%s
Status received:
%s
Body:
%s
]])
luassert:register("assertion", "res_status", res_status,
                  "assertion.res_status.negative")

local function jsonbody(state, args)
  local res = unpack(args)
  if (type(res) ~= "table") or (type(res.read_body) ~= "function") then
    table.insert(args, 1, "< input is not a valid response object >")
    return false
  end
  local body = res:read_body()
  local json, err = cjson.decode(body)
  if not json then
    table.insert(args, 1, "Error decoding: "..tostring(err).."\nBody:"..tostring(body))
    return false
  end
  return true, {json}
end
say:set("assertion.jsonbody.negative", [[
Expected response body to contain valid json. Got:
%s
]])
say:set("assertion.jsonbody.positive", [[
Expected response body to not contain valid json. Got:
%s
]])
luassert:register("assertion", "jsonbody", jsonbody,
                  "assertion.jsonbody.negative",
                  "assertion.jsonbody.positive")

---
-- Adds an assertion to look for a named header in a `headers` subtable.
-- Header name comparison is done case-insensitive.
-- Input can be a response object from the client helper, or a parsed json
-- object returned from mockbin.com.
-- @return the value of the header
local function res_header(state, args)
  local header, res = unpack(args)
  if (type(res) ~= "table") or (type(res.headers) ~= "table") then
    table.insert(args, 1, "<< assertion input does not contain a 'headers' subtable >>")
    table.insert(args, 1, header)
    return false
  end
  local value = lookup(res.headers, header)
  if not value then
    table.insert(args, 1, res.headers)
    table.insert(args, 1, header)
    return false
  end
  return true, {value}
end
say:set("assertion.res_header.negative", [[
Expected header: 
%s
But it was not found in: 
%s
]])
say:set("assertion.res_header.positive", [[
Did not expected header: 
%s
But it was found in: 
%s
]])
luassert:register("assertion", "header", res_header,
                  "assertion.res_header.negative",
                  "assertion.res_header.positive")

----------------
-- Shell helpers
----------------
local function exec(...)
  local ok, _, _, stderr = pl_utils.executeex(...)
  return ok, stderr
end

local function kong_exec(args, prefix)
  args = args or ""
  prefix = prefix or conf.prefix

  return exec(BIN_PATH.." "..args.." --prefix "..prefix)
end

----------
-- Exposed
----------
return {
  -- Penlight
  dir = pl_dir,
  path = pl_path,
  file = pl_file,
  execute = pl_utils.executeex,

  -- Kong testing properties
  dao = dao,
  bin_path = BIN_PATH,
  test_conf = conf,
  test_conf_path = TEST_CONF_PATH,
  proxy_port = proxy_port,
  ssl_proxy_port = ssl_proxy_port,
  admin_port = admin_port,

  -- Kong testing helpers
  kong_exec = kong_exec,
  http_client = http_client,
  udp_server = udp_server,

  prepare_prefix = function(prefix)
    prefix = prefix or conf.prefix
    return pl_dir.makepath(prefix)
    --kong_exec("stop", prefix)
  end,
  clean_prefix = function(prefix)
    prefix = prefix or conf.prefix
    if pl_path.exists(prefix) then
      pl_dir.rmtree(prefix)
    end
  end,
  start_kong = function(prefix)
    return kong_exec("start --conf "..TEST_CONF_PATH, prefix)
  end,
  stop_kong = function(prefix)
    return kong_exec("stop ", prefix)
  end
}
