--
-- MobDebug 0.2
-- Copyright Paul Kulchenko 2011
-- Based on RemDebug 1.0 (http://www.keplerproject.org/remdebug)
--

(function()

module("mobdebug", package.seeall)

_COPYRIGHT = "Paul Kulchenko"
_DESCRIPTION = "Mobile Remote Debugger for the Lua programming language"
_VERSION = "0.2"

-- this is a socket class that implements socket.lua interface
local function socketLua() 
  local self = {}
  self.connect = function(host, port)
    local socket = require "socket"
    local connection = socket.connect(host, port)
    return connection and (function ()
      local self = {}
      self.send = function(self, msg) 
        return connection:send(msg) 
      end
      self.receive = function(self, len) 
        local line, status = connection:receive(len) 
        return line
      end
      self.close = function(self) 
        return connection:close() 
      end
      return self
    end)()
  end

  return self
end

-- this is a socket class that implements maConnect interface
local function socketMobileLua() 
  local self = {}
  self.connect = function(host, port)
    local connection = maConnect("socket://" .. host .. ":" .. port)
    return connection and (function ()
      local self = {}
      local outBuffer = SysAlloc(1000)
      local inBuffer = SysAlloc(1000)
      local event = SysEventCreate()
      function stringToBuffer(s, buffer)
        local i = 0
        for c in s:gmatch(".") do
          i = i + 1
          local b = s:byte(i)
          SysBufferSetByte(buffer, i - 1, b)
        end
        return i
      end
      function bufferToString(buffer, len)
        local s = ""
        for i = 0, len - 1 do
          local c = SysBufferGetByte(buffer, i)
          s = s .. string.char(c)
        end
        return s
      end
      self.send = function(self, msg) 
        local numberOfBytes = stringToBuffer(msg, outBuffer)
        maConnWrite(connection, outBuffer, numberOfBytes)
      end
      self.receive = function(self, len) 
        local line = ""
        while (len and string.len(line) < len)     -- either we need len bytes
           or (not len and not line:find("\n")) do -- or one line (if no len specified)
          maConnRead(connection, inBuffer, 1000)
          while true do
            maWait(0)
            maGetEvent(event)
            local eventType = SysEventGetType(event)
            if (EVENT_TYPE_CLOSE == eventType) then maExit(0) end
            if (EVENT_TYPE_CONN == eventType and
                SysEventGetConnHandle(event) == connection and
                SysEventGetConnOpType(event) == CONNOP_READ) then
              local result = SysEventGetConnResult(event);
              if result > 0 then line = line .. bufferToString(inBuffer, result) end
              break; -- got the event we wanted; now check if we have all we need
            end
          end  
        end
        return line
      end
      self.close = function(self) 
        SysFree(inBuffer)
        SysFree(outBuffer)
        SysFree(event)
        maConnClose(connection)
      end
      return self
    end)()
  end

  return self
end

local socket = maConnect and socketMobileLua() or socketLua()

--
-- RemDebug 1.0 Beta
-- Copyright Kepler Project 2005 (http://www.keplerproject.org/remdebug)
--

local debug = require "debug"
local coro_debugger
local events = { BREAK = 1, WATCH = 2 }
local breakpoints = {}
local watches = {}
local abort = false
local step_into = false
local step_over = false
local step_level = 0
local stack_level = 0
local server
local debugee = function () 
  local a = 1
  print("Dummy script for debugging")
  return "ok"
end

local function set_breakpoint(file, line)
  if not breakpoints[file] then
    breakpoints[file] = {}
  end
  breakpoints[file][line] = true  
end

local function remove_breakpoint(file, line)
  if breakpoints[file] then
    breakpoints[file][line] = nil
  end
end

local function has_breakpoint(file, line)
  return breakpoints[file] and breakpoints[file][line]
end

local function restore_vars(vars)
  if type(vars) ~= 'table' then return end
  local func = debug.getinfo(3, "f").func
  local i = 1
  local written_vars = {}
  while true do
    local name = debug.getlocal(3, i)
    if not name then break end
    debug.setlocal(3, i, vars[name])
    written_vars[name] = true
    i = i + 1
  end
  i = 1
  while true do
    local name = debug.getupvalue(func, i)
    if not name then break end
    if not written_vars[name] then
      debug.setupvalue(func, i, vars[name])
      written_vars[name] = true
    end
    i = i + 1
  end
end

local function capture_vars()
  local vars = {}
  local func = debug.getinfo(3, "f").func
  local i = 1
  while true do
    local name, value = debug.getupvalue(func, i)
    if not name then break end
    vars[name] = value
    i = i + 1
  end
  i = 1
  while true do
    local name, value = debug.getlocal(3, i)
    if not name then break end
    vars[name] = value
    i = i + 1
  end
  setmetatable(vars, { __index = getfenv(func), __newindex = getfenv(func) })
  return vars
end

local function break_dir(path) 
  local paths = {}
  path = string.gsub(path, "\\", "/")
  for w in string.gfind(path, "[^\/]+") do
    table.insert(paths, w)
  end
  return paths
end

local function merge_paths(path1, path2)
  local paths1 = break_dir(path1)
  local paths2 = break_dir(path2)
  for i, path in ipairs(paths2) do
    if path == ".." then
      table.remove(paths1, #paths1)
    elseif path ~= "." then
      table.insert(paths1, path)
    end
  end
  return table.concat(paths1, "/")
end

local function debug_hook(event, line)
  if abort then error("aborted") end -- abort execution for RE/LOAD
  if event == "call" then
    stack_level = stack_level + 1
  elseif event == "return" then
    stack_level = stack_level - 1
  else
    local file = debug.getinfo(2, "S").source
    if string.find(file, "@") == 1 then
      file = string.sub(file, 2)
    end
    file = merge_paths(".", file) -- lfs.currentdir()
    local vars = capture_vars()
    for index, value in pairs(watches) do
      setfenv(value, vars)
      local status, res = pcall(value)
      if status and res then
        coroutine.resume(coro_debugger, events.WATCH, vars, file, line, index)
        restore_vars(vars)
      end
    end
    if step_into or (step_over and stack_level <= step_level) or has_breakpoint(file, line) then
      step_into = false
      step_over = false
      coroutine.resume(coro_debugger, events.BREAK, vars, file, line)
      restore_vars(vars)
    end
  end
end

local function debugger_loop()
  local command
  local eval_env = {}
  local function emptyWatch () return false end

  while true do
    local line = server:receive()
    command = string.sub(line, string.find(line, "^[A-Z]+"))
    if command == "SETB" then
      local _, _, _, filename, line = string.find(line, "^([A-Z]+)%s+([%w%p]+)%s+(%d+)$")
      if filename and line then
        set_breakpoint(filename, tonumber(line))
        server:send("200 OK\n")
      else
        server:send("400 Bad Request\n")
      end
    elseif command == "DELB" then
      local _, _, _, filename, line = string.find(line, "^([A-Z]+)%s+([%w%p]+)%s+(%d+)$")
      if filename and line then
        remove_breakpoint(filename, tonumber(line))
        server:send("200 OK\n")
      else
        server:send("400 Bad Request\n")
      end
    elseif command == "EXEC" then
      local _, _, chunk = string.find(line, "^[A-Z]+%s+(.+)$")
      if chunk then 
        local func = loadstring(chunk)
        local status, res
        if func then
          setfenv(func, eval_env)
          status, res = xpcall(func, debug.traceback)
        end
        res = tostring(res)
        if status then
          server:send("200 OK " .. string.len(res) .. "\n") 
          server:send(res)
        else
          server:send("401 Error in Expression " .. string.len(res) .. "\n")
          server:send(res)
        end
      else
        server:send("400 Bad Request\n")
      end
    elseif command == "LOAD" then
      local _, _, size = string.find(line, "^[A-Z]+%s+(%d+)$")
      size = 0+size
      if size == 0 then -- RELOAD the current script being debugged
        server:send("200 OK 0\n") 
        abort = true
        coroutine.yield() -- this should not return as the hook will abort
      end 

      local chunk = server:receive(size)
      if chunk then -- LOAD a new script for debugging
        local func, res = loadstring(chunk)
        if func then
          server:send("200 OK 0\n") 
          debugee = func
          abort = true
          coroutine.yield() -- this should not return as the hook will abort
        else
          server:send("401 Error in Expression " .. string.len(res) .. "\n")
          server:send(res)
        end
      else
        server:send("400 Bad Request\n")
      end
    elseif command == "SETW" then
      local _, _, exp = string.find(line, "^[A-Z]+%s+(.+)$")
      if exp then 
        local func = loadstring("return(" .. exp .. ")")
        if func then
          local newidx = #watches + 1
          watches[newidx] = func
          server:send("200 OK " .. newidx .. "\n") 
        else
          server:send("400 Bad Request\n")
        end
      else
        server:send("400 Bad Request\n")
      end
    elseif command == "DELW" then
      local _, _, index = string.find(line, "^[A-Z]+%s+(%d+)$")
      index = 0+index
      if index > 0 and index <= #watches then
        watches[index] = emptyWatch
        server:send("200 OK\n") 
      else
        server:send("400 Bad Request\n")
      end
    elseif command == "RUN" then
      server:send("200 OK\n")
      local ev, vars, file, line, idx_watch = coroutine.yield()
      file = "(interpreter)"
      eval_env = vars
      if ev == events.BREAK then
        server:send("202 Paused " .. file .. " " .. line .. "\n")
      elseif ev == events.WATCH then
        server:send("203 Paused " .. file .. " " .. line .. " " .. idx_watch .. "\n")
      else
        server:send("401 Error in Execution " .. string.len(file) .. "\n")
        server:send(file)
      end
    elseif command == "STEP" then
      server:send("200 OK\n")
      step_into = true
      local ev, vars, file, line, idx_watch = coroutine.yield()
      file = "(interpreter)"
      eval_env = vars
      if ev == events.BREAK then
        server:send("202 Paused " .. file .. " " .. line .. "\n")
      elseif ev == events.WATCH then
        server:send("203 Paused " .. file .. " " .. line .. " " .. idx_watch .. "\n")
      else
        server:send("401 Error in Execution " .. string.len(file) .. "\n")
        server:send(file)
      end
    elseif command == "OVER" then
      server:send("200 OK\n")
      step_over = true
      step_level = stack_level
      local ev, vars, file, line, idx_watch = coroutine.yield()
      file = "(interpreter)"
      eval_env = vars
      if ev == events.BREAK then
        server:send("202 Paused " .. file .. " " .. line .. "\n")
      elseif ev == events.WATCH then
        server:send("203 Paused " .. file .. " " .. line .. " " .. idx_watch .. "\n")
      else
        server:send("401 Error in Execution " .. string.len(file) .. "\n")
        server:send(file)
      end
    else
      server:send("400 Bad Request\n")
    end
  end
end

function connect(controller_host, controller_port)
  return socket.connect(controller_host, controller_port)
end

-- Tries to start the debug session by connecting with a controller
function start(controller_host, controller_port)
  server = socket.connect(controller_host, controller_port)
  if server then
    print("Connected to " .. controller_host .. ":" .. controller_port)
    debug.sethook(debug_hook, "lcr")
    coro_debugger = coroutine.create(debugger_loop)
    return coroutine.resume(coro_debugger)
  end
end

function loop(controller_host, controller_port)
  server = socket.connect(controller_host, controller_port)
  if server then
    print("Connected to " .. controller_host .. ":" .. controller_port)

    while true do 
      step_into = true
      abort = false
      coro_debugger = coroutine.create(debugger_loop)

      local coro_debugee = coroutine.create(debugee)
      debug.sethook(coro_debugee, debug_hook, "lcr")
      coroutine.resume(coro_debugee)

      if not abort then break end
    end
  end
end

local client
local basedir = ""

-- Handles server debugging commands 
function handle(line)
  local _, _, command = string.find(line, "^([a-z]+)")
  if command == "run" or command == "step" or command == "over" then
    client:send(string.upper(command) .. "\n")
    client:receive()
    local breakpoint = client:receive()
    if not breakpoint then
      print("Program finished")
      os.exit()
    end
    local _, _, status = string.find(breakpoint, "^(%d+)")
    if status == "202" then
      local _, _, file, line = string.find(breakpoint, "^202 Paused%s+([%w%p]+)%s+(%d+)$")
      if file and line then 
        print("Paused at file " .. file .. " line " .. line)
      end
    elseif status == "203" then
      local _, _, file, line, watch_idx = string.find(breakpoint, "^203 Paused%s+([%w%p]+)%s+(%d+)%s+(%d+)$")
      if file and line and watch_idx then
        print("Paused at file " .. file .. " line " .. line .. " (watch expression " .. watch_idx .. ": [" .. watches[watch_idx] .. "])")
      end
    elseif status == "401" then 
      local _, _, size = string.find(breakpoint, "^401 Error in Execution (%d+)$")
      if size then
        print("Error in remote application: ")
        print(client:receive(tonumber(size)))
        os.exit()
      end
    else
      print("Unknown error")
      os.exit()
    end
  elseif command == "exit" then
    client:close()
    os.exit()
  elseif command == "setb" then
    local _, _, _, filename, line = string.find(line, "^([a-z]+)%s+([%w%p]+)%s+(%d+)$")
    if filename and line then
      filename = basedir .. filename
      if not breakpoints[filename] then breakpoints[filename] = {} end
      client:send("SETB " .. filename .. " " .. line .. "\n")
      if client:receive() == "200 OK" then 
        breakpoints[filename][line] = true
      else
        print("Error: breakpoint not inserted")
      end
    else
      print("Invalid command")
    end
  elseif command == "setw" then
    local _, _, exp = string.find(line, "^[a-z]+%s+(.+)$")
    if exp then
      client:send("SETW " .. exp .. "\n")
      local answer = client:receive()
      local _, _, watch_idx = string.find(answer, "^200 OK (%d+)$")
      if watch_idx then
        watches[watch_idx] = exp
        print("Inserted watch exp no. " .. watch_idx)
      else
        print("Error: Watch expression not inserted")
      end
    else
      print("Invalid command")
    end
  elseif command == "delb" then
    local _, _, _, filename, line = string.find(line, "^([a-z]+)%s+([%w%p]+)%s+(%d+)$")
    if filename and line then
      filename = basedir .. filename
      if not breakpoints[filename] then breakpoints[filename] = {} end
      client:send("DELB " .. filename .. " " .. line .. "\n")
      if client:receive() == "200 OK" then 
        breakpoints[filename][line] = nil
      else
        print("Error: breakpoint not removed")
      end
    else
      print("Invalid command")
    end
  elseif command == "delallb" then
    for filename, breaks in pairs(breakpoints) do
      for line, _ in pairs(breaks) do
        client:send("DELB " .. filename .. " " .. line .. "\n")
        if client:receive() == "200 OK" then 
          breakpoints[filename][line] = nil
        else
          print("Error: breakpoint at file " .. filename .. " line " .. line .. " not removed")
        end
      end
    end
  elseif command == "delw" then
    local _, _, index = string.find(line, "^[a-z]+%s+(%d+)$")
    if index then
      client:send("DELW " .. index .. "\n")
      if client:receive() == "200 OK" then 
        watches[index] = nil
      else
        print("Error: watch expression not removed")
      end
    else
      print("Invalid command")
    end
  elseif command == "delallw" then
    for index, exp in pairs(watches) do
      client:send("DELW " .. index .. "\n")
      if client:receive() == "200 OK" then 
      watches[index] = nil
      else
        print("Error: watch expression at index " .. index .. " [" .. exp .. "] not removed")
      end
    end    
  elseif command == "eval" or command == "exec" 
      or command == "load" or command == "reload" then
    local _, _, exp = string.find(line, "^[a-z]+%s+(.+)$")
    if exp or (command == "reload") then 
      if command == "eval" then
        client:send("EXEC return (" .. exp .. ")\n")
      elseif command == "exec" then
        client:send("EXEC " .. exp .. "\n")
      elseif command == "reload" then
        client:send("LOAD 0\n")
      else
        local file = io.open(exp, "r")
        if not file then print("Cannot open file " .. exp); return end
        local lines = file:read("*all")
        file:close()
        client:send("LOAD " .. string.len(lines) .. "\n")
        client:send(lines)
      end
      local line = client:receive()
      local _, _, status, len = string.find(line, "^(%d+)[%s%w]+(%d+)$")
      if status == "200" then
        len = tonumber(len)
        if len > 0 then 
          local res = client:receive(len)
          print(res)
        end
      elseif status == "401" then
        len = tonumber(len)
        local res = client:receive(len)
        print("Error in expression:")
        print(res)
      else
        print("Unknown error")
      end
    else
      print("Invalid command")
    end
  elseif command == "listb" then
    for k, v in pairs(breakpoints) do
      io.write(k .. ": ")
      for k, v in pairs(v) do
        io.write(k .. " ")
      end
      io.write("\n")
    end
  elseif command == "listw" then
    for i, v in pairs(watches) do
      print("Watch exp. " .. i .. ": " .. v)
    end    
  elseif command == "basedir" then
    local _, _, dir = string.find(line, "^[a-z]+%s+(.+)$")
    if dir then
      if not string.find(dir, "/$") then dir = dir .. "/" end
      basedir = dir
      print("New base directory is " .. basedir)
    else
      print(basedir)
    end
  elseif command == "help" then
    print("setb <file> <line>    -- sets a breakpoint")
    print("delb <file> <line>    -- removes a breakpoint")
    print("delallb               -- removes all breakpoints")
    print("setw <exp>            -- adds a new watch expression")
    print("delw <index>          -- removes the watch expression at index")
    print("delallw               -- removes all watch expressions")
    print("run                   -- run until next breakpoint")
    print("step                  -- run until next line, stepping into function calls")
    print("over                  -- run until next line, stepping over function calls")
    print("listb                 -- lists breakpoints")
    print("listw                 -- lists watch expressions")
    print("eval <exp>            -- evaluates expression on the current context and returns its value")
    print("exec <stmt>           -- executes statement on the current context")
    print("load <file>           -- loads a local file for debugging")
    print("reload                -- restarts the current debugging session")
    print("basedir [<path>]      -- sets the base path of the remote application, or shows the current one")
    print("exit                  -- exits debugger")
  else
    local _, _, spaces = string.find(line, "^(%s*)$")
    if not spaces then
      print("Invalid command")
    end
  end
end

-- Starts debugging server
function listen(host, port)

  local socket = require "socket"

  print("Lua Remote Debugger")
  print("Run the program you wish to debug")

  local server = socket.bind(host, port)
  client = server:accept()

  client:send("STEP\n")
  client:receive()

  local breakpoint = client:receive()
  local _, _, file, line = string.find(breakpoint, "^202 Paused%s+([%w%p]+)%s+(%d+)$")
  if file and line then
    print("Paused at file " .. file )
    print("Type 'help' for commands")
  else
    local _, _, size = string.find(breakpoint, "^401 Error in Execution (%d+)$")
    if size then
      print("Error in remote application: ")
      print(client:receive(size))
    end
  end

  while true do
    io.write("> ")
    local line = io.read("*line")
    handle(line)
  end
end

end)()