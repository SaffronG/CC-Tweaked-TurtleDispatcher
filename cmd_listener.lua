local args = { ... }
if #args == 0 then
    print("Usage: cmd_listener <turtleId>")
    return
end

local tid = args[1]
local fmtSource = "[Client #" .. tid .. "]"
local logging = require("logging")

local function log(msg)
    local ok, err = logging.sendServerLog(tid, msg)
    if not ok then
        printError(fmtSource .. " Log POST failed: " .. tostring(err))
    end
end

http.websocketAsync(logging.BASE, { ["turtle_id"] = tid })
print(fmtSource .. " Connection request sent for Turtle " .. tid .. ", awaiting response.")

while true do
    local event, resUrl, handleOrError = os.pullEvent()

    if (event == "websocket_success" or event == "websocket_failure") and resUrl == logging.BASE then
        if event == "websocket_success" then
            local ws = handleOrError
            print(fmtSource .. " Connected successfully!")
            log("Connected")
            -- ws stays open here; use ws.receive() / ws.send() in your loop
        else
            printError(fmtSource .. " Websocket failed: " .. tostring(handleOrError))
            log("Connection Failed: " .. tostring(handleOrError))
            return
        end
    end
end