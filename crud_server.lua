local pegasus = require('pegasus')
local json = require('dkjson')

ServerName = "PegasusDisplaySupervisor"
local server = pegasus:new({ port = '8080' })

local statusLog = {}
local workers = {}    -- turtleId -> ip
local commands = {}   -- turtleId -> { action1, action2, ... } (pending, not yet fetched)

---------------------------------------------------------------------------
-- Persistence
---------------------------------------------------------------------------
local LOG_FILE = "status.log"
local WORKERS_FILE = "workers.json"
local COMMANDS_FILE = "commands.json"
local MAX_ENTRIES = 1000   -- in-memory cap; set to nil for unlimited

local function readAll(path)
    local f = io.open(path, "r")
    if not f then return nil end
    local data = f:read("*a")
    f:close()
    return data
end

local function writeAll(path, data)
    local f = io.open(path, "w")
    if not f then return false end
    f:write(data)
    f:close()
    return true
end

local function saveLog()
    local lines = {}
    for _, entry in ipairs(statusLog) do
        lines[#lines + 1] = json.encode(entry)
    end
    return writeAll(LOG_FILE, #lines > 0 and (table.concat(lines, "\n") .. "\n") or "")
end

local function loadLog()
    local f = io.open(LOG_FILE, "r")
    if not f then return 0 end
    for line in f:lines() do
        local ok, entry = pcall(json.decode, line)
        if ok and type(entry) == "table" then
            table.insert(statusLog, entry)
        end
    end
    f:close()
    if MAX_ENTRIES and #statusLog > MAX_ENTRIES then
        while #statusLog > MAX_ENTRIES do table.remove(statusLog, 1) end
        saveLog()
    end
    return #statusLog
end

local function log(source, message)
    local entry = { time = os.date(), source = source, message = message }
    table.insert(statusLog, entry)

    local f = io.open(LOG_FILE, "a")
    if f then
        f:write(json.encode(entry), "\n")
        f:close()
    end

    if MAX_ENTRIES and #statusLog > MAX_ENTRIES + 100 then
        while #statusLog > MAX_ENTRIES do table.remove(statusLog, 1) end
        saveLog()
    end
end

local function saveTable(path, t)
    -- An empty Lua table encodes as [], so force an object for consistency
    if next(t) == nil then return writeAll(path, "{}") end
    return writeAll(path, json.encode(t))
end

local function loadTable(path, into)
    local data = readAll(path)
    if not data or data == "" then return end
    local ok, decoded = pcall(json.decode, data)
    if ok and type(decoded) == "table" then
        for k, v in pairs(decoded) do into[k] = v end
    end
end

local function saveWorkers() return saveTable(WORKERS_FILE, workers) end
local function saveCommands() return saveTable(COMMANDS_FILE, commands) end

loadLog()
loadTable(WORKERS_FILE, workers)
loadTable(COMMANDS_FILE, commands)

---------------------------------------------------------------------------
-- Helpers
---------------------------------------------------------------------------
local function reply(response, code, body, contentType)
    response:statusCode(code)
    response:addHeader('Content-Type', contentType or 'text/plain')
    response:write(body)
    return response:close()
end

local function replyJson(response, code, t)
    return reply(response, code, json.encode(t, { indent = true }), 'application/json')
end

local function tag(msg)
    return "[" .. ServerName .. "] " .. msg
end

local function queueCommand(id, action)
    commands[id] = commands[id] or {}
    table.insert(commands[id], action)
end

local function restartSelf()
    -- Relaunch after a short delay so this process can exit and free the port first
    local interpreter = (arg and arg[-1]) or "lua"
    local script = (arg and arg[0]) or "crud_server.lua"
    os.execute(string.format("(sleep 1 && %q %q) >/dev/null 2>&1 &", interpreter, script))
    os.exit(0)
end

---------------------------------------------------------------------------
-- API map (keep in sync when adding routes)
---------------------------------------------------------------------------
local API_MAP = {
    { method = "GET",  path = "/",                     description = "This API map" },
    { method = "GET",  path = "/workers",              params = "turtleId (optional)", description = "All workers, or one worker's info and logs" },
    { method = "POST", path = "/workers",              params = "turtleId", description = "Register a turtle as a worker" },
    { method = "GET",  path = "/status",               params = "source (optional)", description = "Status log, optionally filtered by source" },
    { method = "POST", path = "/status",               params = "turtleId, status", description = "Add a status update" },
    { method = "GET",  path = "/commands",             params = "turtleId (optional)", description = "Pending commands. Turtles (JSON) fetch and clear their queue; the browser view only shows it" },
    { method = "POST", path = "/commands",             params = "turtleId (or 'all'), action", description = "Queue a command" },
    { method = "POST", path = "/admin/clear-logs",     description = "Clear the status log" },
    { method = "POST", path = "/admin/deregister-all", description = "Queue Base.Return for every turtle, then deregister all" },
    { method = "POST", path = "/admin/reboot",         description = "Restart the server" },
}

---------------------------------------------------------------------------
-- HTML rendering
---------------------------------------------------------------------------
local function esc(s)
    return (tostring(s == nil and "" or s):gsub("[&<>\"']", {
        ["&"] = "&amp;", ["<"] = "&lt;", [">"] = "&gt;", ['"'] = "&quot;", ["'"] = "&#39;",
    }))
end

-- Percent-encode a value for use in a URL query string
local function urlenc(s)
    return (tostring(s):gsub("[^%w%-_%.~]", function(c) return string.format("%%%02X", string.byte(c)) end))
end

local function countKeys(t)
    local n = 0
    for _ in pairs(t) do n = n + 1 end
    return n
end

-- Sorted list of keys; numeric-looking ids sort numerically
local function sortedKeys(t)
    local keys = {}
    for k in pairs(t) do keys[#keys + 1] = k end
    table.sort(keys, function(a, b)
        local na, nb = tonumber(a), tonumber(b)
        if na and nb then return na < nb end
        return tostring(a) < tostring(b)
    end)
    return keys
end

local function lastLogFor(source)
    for i = #statusLog, 1, -1 do
        if statusLog[i].source == source then return statusLog[i] end
    end
    return nil
end

local function turtleLink(id)
    return '<a href="/workers?turtleId=' .. urlenc(id) .. '">' .. esc(id) .. '</a>'
end

local function code(s) return '<code>' .. esc(s) .. '</code>' end

-- headers: list of column names; rows: list of lists of already-escaped HTML cells
local function htmlTable(headers, rows, emptyText)
    if #rows == 0 then
        return '<div class="card empty">' .. esc(emptyText or "Nothing here yet.") .. '</div>'
    end
    local out = { '<div class="card"><table><thead><tr>' }
    for _, h in ipairs(headers) do out[#out + 1] = '<th>' .. esc(h) .. '</th>' end
    out[#out + 1] = '</tr></thead><tbody>'
    for _, row in ipairs(rows) do
        out[#out + 1] = '<tr><td>' .. table.concat(row, '</td><td>') .. '</td></tr>'
    end
    out[#out + 1] = '</tbody></table></div>'
    return table.concat(out, "\n")
end

local function section(title, body)
    return '<h2>' .. esc(title) .. '</h2>\n' .. body
end

local NAV = {
    { "/", "API map" }, { "/workers", "Workers" }, { "/status", "Status log" }, { "/commands", "Commands" },
}

local STYLE = [[
  :root { --bg:#f6f7f9; --card:#fff; --fg:#1d2330; --muted:#6b7280; --line:#e5e7eb; --accent:#2563eb;
          --get:#0f766e; --get-bg:#ccfbf1; --post:#9a3412; --post-bg:#ffedd5; }
  @media (prefers-color-scheme: dark) {
    :root { --bg:#111418; --card:#1a1f26; --fg:#e5e7eb; --muted:#9ca3af; --line:#2a313b; --accent:#60a5fa;
            --get:#5eead4; --get-bg:#134e4a; --post:#fdba74; --post-bg:#7c2d12; }
  }
  body { margin:0; padding:0 16px 32px; background:var(--bg); color:var(--fg);
         font:15px/1.5 system-ui, -apple-system, Segoe UI, sans-serif; }
  main { max-width:960px; margin:0 auto; }
  nav { max-width:960px; margin:0 auto; display:flex; flex-wrap:wrap; gap:4px 18px; padding:14px 0;
        border-bottom:1px solid var(--line); margin-bottom:20px; }
  nav a { color:var(--muted); text-decoration:none; font-weight:500; }
  nav a.on, nav a:hover { color:var(--fg); }
  nav .brand { color:var(--fg); font-weight:700; margin-right:auto; }
  h1 { font-size:22px; margin:0 0 4px; }
  h2 { font-size:15px; margin:26px 0 10px; }
  p.sub { color:var(--muted); margin:0 0 18px; }
  .card { background:var(--card); border:1px solid var(--line); border-radius:10px; overflow-x:auto; }
  .card.empty { padding:16px; color:var(--muted); }
  table { width:100%; border-collapse:collapse; }
  th, td { text-align:left; padding:9px 14px; border-bottom:1px solid var(--line); vertical-align:top; }
  th { font-size:12px; text-transform:uppercase; letter-spacing:.04em; color:var(--muted); white-space:nowrap; }
  tr:last-child td { border-bottom:none; }
  td.nowrap, td:first-child { white-space:nowrap; }
  code { font:13px ui-monospace, SFMono-Regular, Menlo, monospace; }
  a { color:var(--accent); }
  .m { display:inline-block; min-width:44px; text-align:center; font:600 12px ui-monospace, monospace;
       padding:2px 6px; border-radius:4px; }
  .m.get { color:var(--get); background:var(--get-bg); }
  .m.post { color:var(--post); background:var(--post-bg); }
  .stats { display:flex; flex-wrap:wrap; gap:10px; margin:0 0 6px; }
  .stat { background:var(--card); border:1px solid var(--line); border-radius:10px; padding:10px 14px; min-width:120px; }
  .stat b { display:block; font-size:20px; }
  .stat span { color:var(--muted); font-size:13px; }
  .pill { display:inline-block; background:var(--line); border-radius:999px; padding:0 8px; font-size:13px; margin:1px 2px 1px 0; }
  .muted { color:var(--muted); }
  footer { color:var(--muted); font-size:13px; margin-top:18px; }
]]

-- Wraps page content in the shared layout. opts.refresh = seconds for auto-refresh.
local function page(current, title, subtitle, body, opts)
    opts = opts or {}
    local nav = { '<nav><span class="brand">' .. esc(ServerName) .. '</span>' }
    for _, item in ipairs(NAV) do
        nav[#nav + 1] = string.format('<a href="%s"%s>%s</a>', item[1],
            item[1] == current and ' class="on"' or '', esc(item[2]))
    end
    nav[#nav + 1] = '</nav>'

    local refresh = ""
    if opts.refresh then
        refresh = '<meta http-equiv="refresh" content="' .. tonumber(opts.refresh) .. '">'
    end

    return table.concat({
        '<!DOCTYPE html><html lang="en"><head><meta charset="utf-8">',
        '<meta name="viewport" content="width=device-width, initial-scale=1">', refresh,
        '<title>', esc(title), ' · ', esc(ServerName), '</title><style>', STYLE, '</style></head><body>',
        table.concat(nav),
        '<main><h1>', esc(title), '</h1>',
        subtitle and ('<p class="sub">' .. subtitle .. '</p>') or '',
        body,
        '<footer>Generated ', esc(os.date()),
        opts.jsonHref and (' &middot; <a href="' .. opts.jsonHref .. '">View as JSON</a>') or '',
        opts.refresh and (' &middot; auto-refreshes every ' .. tonumber(opts.refresh) .. 's') or '',
        '</footer></main></body></html>',
    })
end

-- Browsers send Accept: text/html; curl and CC:Tweaked's http.get don't, so they keep getting JSON.
-- ?format=json or ?format=html overrides.
local function wantsHtml(request, q)
    if q.format == 'json' then return false end
    if q.format == 'html' then return true end
    local ok, headers = pcall(function() return request:headers() end)
    if not ok or type(headers) ~= "table" then return false end
    local accept = headers['accept'] or headers['Accept'] or ""
    return accept:find("text/html", 1, true) ~= nil
end

local function jsonLink(path, q)
    local parts = { "format=json" }
    for k, v in pairs(q) do
        if k ~= "format" and k ~= "refresh" then parts[#parts + 1] = urlenc(k) .. "=" .. urlenc(v) end
    end
    return esc(path .. "?" .. table.concat(parts, "&"))
end

local function refreshOpt(q)
    local n = tonumber(q.refresh)
    if n and n >= 1 then return math.floor(n) end
    return nil
end

local function statsBar(items)
    local out = { '<div class="stats">' }
    for _, it in ipairs(items) do
        out[#out + 1] = '<div class="stat"><b>' .. esc(it[1]) .. '</b><span>' .. esc(it[2]) .. '</span></div>'
    end
    out[#out + 1] = '</div>'
    return table.concat(out)
end

local function pendingCount()
    local n = 0
    for _, list in pairs(commands) do n = n + #list end
    return n
end

local function logRows(entries, showSource)
    local rows = {}
    for i = #entries, 1, -1 do   -- newest first
        local e = entries[i]
        local row = { '<span class="muted">' .. esc(e.time) .. '</span>' }
        if showSource then
            local src = e.source
            row[#row + 1] = workers[src] and turtleLink(src)
                or ('<a href="/status?source=' .. urlenc(src) .. '">' .. esc(src) .. '</a>')
        end
        row[#row + 1] = esc(e.message)
        rows[#rows + 1] = row
    end
    return rows
end

local function actionPills(list)
    if not list or #list == 0 then return '<span class="muted">none</span>' end
    local out = {}
    for _, a in ipairs(list) do out[#out + 1] = '<span class="pill">' .. esc(a) .. '</span>' end
    return table.concat(out)
end

-- Page renderers ----------------------------------------------------------

local function renderApiMap(q)
    local rows = {}
    for _, r in ipairs(API_MAP) do
        rows[#rows + 1] = {
            '<span class="m ' .. esc(r.method:lower()) .. '">' .. esc(r.method) .. '</span>',
            r.method == "GET" and ('<a href="' .. esc(r.path) .. '"><code>' .. esc(r.path) .. '</code></a>') or code(r.path),
            r.params and code(r.params) or '<span class="muted">-</span>',
            esc(r.description),
        }
    end
    local body = statsBar({
        { countKeys(workers), "registered turtles" },
        { #statusLog, "log entries" },
        { pendingCount(), "pending commands" },
    }) .. section("Endpoints", htmlTable({ "Method", "Path", "Params", "Description" }, rows))
    return page("/", "API map", "Params go in the query string, e.g. <code>/workers?turtleId=1</code>.",
        body, { jsonHref = jsonLink("/", q) })
end

local function renderWorkers(q)
    local rows = {}
    for _, id in ipairs(sortedKeys(workers)) do
        local last = lastLogFor(id)
        rows[#rows + 1] = {
            turtleLink(id),
            code(workers[id]),
            last and esc(last.message) or '<span class="muted">-</span>',
            last and ('<span class="muted">' .. esc(last.time) .. '</span>') or '<span class="muted">-</span>',
            actionPills(commands[id]),
        }
    end
    return page("/workers", "Workers", countKeys(workers) .. " registered turtle(s). Click an id for details.",
        htmlTable({ "Turtle", "IP", "Last status", "Updated", "Pending" }, rows, "No turtles registered."),
        { jsonHref = jsonLink("/workers", q), refresh = refreshOpt(q) })
end

local function renderWorker(id, q)
    local entries = {}
    for _, e in ipairs(statusLog) do
        if e.source == id then entries[#entries + 1] = e end
    end
    local body = statsBar({
        { workers[id], "IP address" },
        { #entries, "log entries" },
        { commands[id] and #commands[id] or 0, "pending commands" },
    })
    body = body .. section("Pending commands", '<div class="card empty" style="color:inherit">' .. actionPills(commands[id]) .. '</div>')
    body = body .. section("Log", htmlTable({ "Time", "Message" }, logRows(entries, false), "No log entries for this turtle."))
    return page("/workers", "Turtle " .. id, '<a href="/workers">&larr; All workers</a>', body,
        { jsonHref = jsonLink("/workers", q), refresh = refreshOpt(q) })
end

local function renderStatus(q)
    local entries, subtitle = statusLog, #statusLog .. " entries, newest first."
    if q.source then
        entries = {}
        for _, e in ipairs(statusLog) do
            if e.source == q.source then entries[#entries + 1] = e end
        end
        subtitle = #entries .. " entries from " .. code(q.source) .. ' &middot; <a href="/status">show all</a>'
    end
    return page("/status", "Status log", subtitle,
        htmlTable({ "Time", "Source", "Message" }, logRows(entries, true), "The log is empty."),
        { jsonHref = jsonLink("/status", q), refresh = refreshOpt(q) })
end

local function renderCommands(q)
    local rows = {}
    local ids = sortedKeys(commands)
    for _, id in ipairs(ids) do
        if not q.turtleId or q.turtleId == id then
            rows[#rows + 1] = {
                workers[id] and turtleLink(id) or (esc(id) .. ' <span class="muted">(deregistered)</span>'),
                tostring(#commands[id]),
                actionPills(commands[id]),
            }
        end
    end
    local subtitle = pendingCount() .. " command(s) waiting to be fetched. Viewing this page doesn't clear them."
    if q.turtleId then
        subtitle = "Pending for turtle " .. code(q.turtleId) .. ' &middot; <a href="/commands">show all</a>'
    end
    return page("/commands", "Pending commands", subtitle,
        htmlTable({ "Turtle", "Count", "Actions" }, rows, "No pending commands."),
        { jsonHref = jsonLink("/commands", q), refresh = refreshOpt(q) })
end

local function renderError(code_, title, message)
    return page("", title, nil, '<div class="card empty" style="color:inherit">' .. esc(message) .. '</div>'
        .. '<p><a href="/">&larr; Back to the API map</a></p>')
end

local function replyHtml(response, code_, html)
    return reply(response, code_, html, 'text/html; charset=utf-8')
end

---------------------------------------------------------------------------
-- Routes
---------------------------------------------------------------------------
server:start(function(request, response)
    local method = request:method()
    local path = request:path()
    local q = request.querystring or {}
    local ip = request.ip or "unknown"
    local html = method == 'GET' and wantsHtml(request, q)

    -- GET /  -> API map
    if method == 'GET' and (path == '/' or path == '') then
        if not html then
            return replyJson(response, 200, { server = ServerName, routes = API_MAP })
        end
        return replyHtml(response, 200, renderApiMap(q))

    -- GET /workers[?turtleId=X]  -> all workers, or one worker's info + logs
    elseif method == 'GET' and path == '/workers' then
        local id = q.turtleId
        if id == nil then
            if html then return replyHtml(response, 200, renderWorkers(q)) end
            local list = {}
            for _, wid in ipairs(sortedKeys(workers)) do
                list[#list + 1] = { turtleId = wid, ip = workers[wid] }
            end
            return replyJson(response, 200, { workers = setmetatable(list, { __jsontype = 'array' }) })
        end
        if workers[id] == nil then
            log(ip, "Lookup for unknown turtle " .. id)
            if html then return replyHtml(response, 404, renderError(404, "Not found", "Turtle " .. id .. " is not registered.")) end
            return reply(response, 404, tag("Turtle " .. id .. " not found"))
        end
        if html then return replyHtml(response, 200, renderWorker(id, q)) end
        local entries = {}
        for _, entry in ipairs(statusLog) do
            if entry.source == id then table.insert(entries, entry) end
        end
        return replyJson(response, 200, { turtleId = id, ip = workers[id], logs = entries })

    -- POST /workers?turtleId=X  -> register worker
    elseif method == 'POST' and path == '/workers' then
        local id = q.turtleId
        if id == nil then
            log(ip, "Invalid request: POST /workers missing turtleId")
            return reply(response, 400, tag("Invalid request, must provide turtleId"))
        end
        workers[id] = ip
        saveWorkers()
        local message = tag("Successfully registered turtle " .. id .. " as a worker")
        log(id, message)
        return reply(response, 200, message)

    -- POST /status?turtleId=X&status=Y  -> add status update
    elseif method == 'POST' and path == '/status' then
        local id, update = q.turtleId, q.status
        if id == nil or update == nil then
            log(ip, "Invalid request: POST /status missing turtleId or status")
            return reply(response, 400, tag("Invalid request, must provide turtleId and status"))
        end
        log(id, update)
        return reply(response, 200, tag("Added status update for Turtle " .. id .. ": " .. update))

    -- GET /status[?source=X]  -> status log
    elseif method == 'GET' and path == '/status' then
        if html then return replyHtml(response, 200, renderStatus(q)) end
        if q.source then
            local entries = {}
            for _, e in ipairs(statusLog) do
                if e.source == q.source then entries[#entries + 1] = e end
            end
            return replyJson(response, 200, setmetatable(entries, { __jsontype = 'array' }))
        end
        return replyJson(response, 200, statusLog)

    -- POST /commands?turtleId=X&action=Y  -> queue a command (turtleId=all for every worker)
    elseif method == 'POST' and path == '/commands' then
        local id, action = q.turtleId, q.action
        if id == nil or action == nil then
            log(ip, "Invalid request: POST /commands missing turtleId or action")
            return reply(response, 400, tag("Invalid request, must provide turtleId and action"))
        end
        if id == "all" then
            local count = 0
            for wid in pairs(workers) do
                queueCommand(wid, action)
                count = count + 1
            end
            saveCommands()
            log(ip, "Queued '" .. action .. "' for all " .. count .. " workers")
            return reply(response, 200, tag("Queued '" .. action .. "' for " .. count .. " turtles"))
        end
        if workers[id] == nil then
            return reply(response, 404, tag("Turtle " .. id .. " not found"))
        end
        queueCommand(id, action)
        saveCommands()
        log(ip, "Queued '" .. action .. "' for turtle " .. id)
        return reply(response, 200, tag("Queued '" .. action .. "' for turtle " .. id))

    -- GET /commands?turtleId=X  -> turtle polls for its pending actions (clears them)
    -- In a browser this only shows the queue and never clears it.
    elseif method == 'GET' and path == '/commands' then
        if html then return replyHtml(response, 200, renderCommands(q)) end
        local id = q.turtleId
        if id == nil then
            return reply(response, 400, tag("Invalid request, must provide turtleId"))
        end
        local actions = commands[id] or {}
        if #actions > 0 then
            commands[id] = nil
            saveCommands()
            log(id, "Fetched " .. #actions .. " command(s)")
        end
        return replyJson(response, 200, { turtleId = id, actions = setmetatable(actions, { __jsontype = 'array' }) })

    -- POST /admin/clear-logs  -> wipe the status log (memory + file)
    elseif method == 'POST' and path == '/admin/clear-logs' then
        local count = #statusLog
        statusLog = {}
        saveLog()
        log(ip, "Cleared " .. count .. " log entries")
        return reply(response, 200, tag("Cleared " .. count .. " log entries"))

    -- POST /admin/deregister-all  -> send Base.Return to every turtle, then forget them
    elseif method == 'POST' and path == '/admin/deregister-all' then
        local count = 0
        for wid in pairs(workers) do
            queueCommand(wid, "Base.Return")
            count = count + 1
        end
        workers = {}
        saveWorkers()
        saveCommands()
        log(ip, "Deregistered " .. count .. " turtles (Base.Return queued)")
        return reply(response, 200, tag("Deregistered " .. count .. " turtles, Base.Return queued for each"))

    -- POST /admin/reboot  -> restart the server process
    elseif method == 'POST' and path == '/admin/reboot' then
        log(ip, "Server reboot requested")
        reply(response, 200, tag("Rebooting..."))
        restartSelf()
    end

    if html then
        return replyHtml(response, 404, renderError(404, "Not found", "No route for " .. method .. " " .. path))
    end
    return reply(response, 404, tag("No route for " .. method .. " " .. path))
end)