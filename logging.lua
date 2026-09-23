return {
    sendLog = function(source, target, action)
        return print("[" .. source .. "] Sent " .. action.type .. ":action to " .. target .. " from " .. source)
    end,
    recieveLog = function(source, target, action)
        return print("[" .. source .. "] Recieved " .. action.type .. ":action to " .. target .. " from " .. source)
    end,
    saveLogs = function(turtles)
        return 0
    end,
    action = function(type, params)
        return {
            type = type,
            params = params
        }
    end,
    -- Base address for hosted server client
    WebServerBaseAddr = "http://localhost:8080",
    -- Wrapper functions for CC:Tweaked OS Functions
    updateServerState = function(path, payload)
        return http.post(WebServerBaseAddr..path, payload)
    end,
    getServerState = function(path, payload)
        return http.get(WebServerBaseAddr..path)
    end,
    checkServerState = function(path)
        return http.checkURL(WebServerBaseAddr..path)
    end,
}