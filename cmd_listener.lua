local args = { ... }
if #args == 0 then
    print("Usage: cmd_listener <turtleId>")
    return
end

local tid = args[1]
local fmtSource = "[Client #"..tid.."]"
local logging = require('logging')

http.websocketAsync(logging.WebServerBaseAddr, { ["turtle_id"] = tid });

print(fmtSource.." Connection request sent for Turtle "..tid..", Awaiting response.")

while true do
   local event, resUrl, handleOrError = os.pullEvent()

   if (event == "websocket_success" or event == "websocket_failure") and resUl = url then
        if event == "websocketAsync" then
            local ws = handleOrError
            print(fmtSource.." Connected successfully!")

            

            ws.close();
        else
            logging.sendLog(fmtSource," Connection failed: "..handleOrError)
        end
    end
end