-- clear some globals
-- This will break lua code written for other lua runtimes
local IO = _G.io -- TODO: implement sync File I/O using libuv
_G.io = nil
_G.os = nil
_G.math = nil
_G.string = nil
_G.coroutine = nil
_G.jit = nil
_G.bit = nil
_G.debug = nil
_G.table = nil
_G.loadfile = nil
_G.dofile = nil
_G.print = nil

-- Load libraries used in this file
local Debug = require('debug')

local UV = require('uv')
local Env = require('env')

local Table = require('table')
local Utils = require('utils')
local FS = require('fs')
local TTY = require('tty')
local Emitter = require('emitter')
local Constants = require('constants')
local Path = require('path')

process = Emitter.new()

function process.exit(exit_code)
  process:emit('exit', exit_code)
  exit_process(exit_code or 0)
end

function process:add_handler_type(name)
  local code = Constants[name]
  if code then
    UV.activate_signal_handler(code)
    UV.unref()
  end
end

function process:missing_handler_type(name, ...)
  if name == "error" then
    error(...)
  elseif name == "SIGINT" or name == "SIGTERM" then
    process.exit()
  end
end

process.cwd = getcwd
_G.getcwd = nil
process.argv = argv
_G.argv = nil

local base_path = process.cwd()

-- Hide some stuff behind a metatable
local hidden = {}
setmetatable(_G, {__index=hidden})
local function hide(name)
  hidden[name] = _G[name]
  _G[name] = nil
end
hide("_G")
hide("exit_process")

-- Ignore sigpipe and exit cleanly on SIGINT and SIGTERM
-- These shouldn't hold open the event loop
UV.activate_signal_handler(Constants.SIGPIPE)
UV.unref()
UV.activate_signal_handler(Constants.SIGINT)
UV.unref()
UV.activate_signal_handler(Constants.SIGTERM)
UV.unref()

-- Load the tty as a pair of pipes
-- But don't hold the event loop open for them
process.stdin = TTY.new(0)
UV.unref()
process.stdout = TTY.new(1)
UV.unref()
local stdout = process.stdout

-- Replace print
function print(...)
  local n = select('#', ...)
  local arguments = { ... }

  for i = 1, n do
    arguments[i] = tostring(arguments[i])
  end

  stdout:write(Table.concat(arguments, "\t") .. "\n")
end

-- A nice global data dumper
function p(...)
  local n = select('#', ...)
  local arguments = { ... }

  for i = 1, n do
    arguments[i] = Utils.dump(arguments[i])
  end

  stdout:write(Table.concat(arguments, "\t") .. "\n")
end


-- Add global access to the environment variables using a dynamic table
process.env = setmetatable({}, {
  __pairs = function (table)
    local keys = Env.keys()
    local index = 0
    return function (...)
      index = index + 1
      local name = keys[index]
      if name then
        return name, table[name]
      end
    end
  end,
  __index = function (table, name)
    return Env.get(name)
  end,
  __newindex = function (table, name, value)
    if value then
      Env.set(name, value, 1)
    else
      Env.unset(name)
    end
  end
})

-- This is called by all the event sources from C
-- The user can override it to hook into event sources
function event_source(name, fn, ...)
  local args = {...}
  return assert(xpcall(function ()
    return fn(unpack(args))
  end, Debug.traceback))
end

error_meta = {__tostring=function(table) return table.message end}

local global_meta = {__index=_G}

-- TODO: Implement sync I/O using libuv so we don't use this library
function myloadfile(path)
  local file, error = IO.open(path, "rb")
  if error then return nil, error end
  local code = assert(file:read("*all"))
  assert(file:close())
  local fn = assert(loadstring(code, '@' .. path))
  setfenv(fn, setmetatable({
    __filename = path,
    __dirname = Path.dirname(path)
  }, global_meta))
  return fn
end



-- tries to load a module at a specified absolute path
-- TODO: make these error messages a little prettier
local function load_module(path, verbose)

  local cname = "luaopen_" .. Path.basename(path)

  -- Try the exact match first
  local fn = myloadfile(path)
  if fn then return fn end

  -- Then try with lua appended
  fn = myloadfile(path .. ".lua")
  if fn then return fn end

  local error_message
  -- Then try C addon with luvit appended
  fn, error_message = package.loadlib(path .. ".luvit", cname)
  if fn then return fn end
  -- TODO: find a less fragile way to tell a not found error from other errors
  if not (error_message == path .. ".luvit: cannot open shared object file: No such file or directory") then
    error(error_message)
  end

  -- Then Try a folder with init.lua in it
  fn = myloadfile(path .. "/init.lua")
  if fn then return fn end

  -- Finally try the same for a C addon
  fn, error_message = package.loadlib(path .. "/init.luvit", cname)
  if fn then return fn end
  -- TODO: find a less fragile way to tell a not found error from other errors
  if not (error_message == path .. "/init.luvit: cannot open shared object file: No such file or directory") then
    error(error_message)
  end

  return "\n\tCannot find module " .. path
end

-- Remove the cwd based loaders, we don't want them
package.loaders[2] = nil
package.loaders[3] = nil
package.loaders[4] = nil
package.path = nil
package.cpath = nil
package.searchpath = nil
package.seeall = nil
package.config = nil
_G.module = nil

-- Write our own loader that does proper relative requires of both lua scripts
-- and binary addons
package.loaders[2] = function (path)
  local first = path:sub(1, 1)

  -- Absolute requires
  if first == "/" then
    path = Path.normalize(path)
    return load_module(path)
  end

  -- Relative requires
  if first == "." then
    local source = Debug.getinfo(3, "S").source
    if source:sub(1, 1) == "@" then
      path = Path.join(Path.dirname(source:sub(2)), path)
    else
      path = Path.join(base_path, path)
    end
    return load_module(path)
  end

  -- Bundled module search path
  local errors = {}
  local source = Debug.getinfo(3, "S").source
  local dir
  if source:sub(1, 1) == "@" then
    dir = Path.dirname(source:sub(2)) .. "/@"
  else
    dir = base_path .. '/@'
  end
  repeat
    dir = dir:sub(1, dir:find("/[^/]+$") - 1)
    local ret = load_module(dir .. "/modules/" .. path)
    if type(ret) == "function" then return ret end
    errors[#errors + 1] = ret
  until #dir == 0

  return Table.concat(errors, "")

end

-- Load the file given or start the interactive repl
if process.argv[1] then
  return assert(xpcall(function ()
    assert(myloadfile(Path.resolve(base_path, process.argv[1])))()
  end, Debug.traceback))
else
  require('repl')
end

-- Start the event loop
UV.run()
-- trigger exit handlers and exit cleanly
process.exit(0)

