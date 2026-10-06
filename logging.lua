local HTTP_BASE = "http://localhost:8081"

return {
    BASE = "ws://localhost:8080",
    HTTP_BASE = HTTP_BASE,
    sendServerLog = function(turtleId, status)
        local url = HTTP_BASE .. "/status?turtleId=" .. textutils.urlEncode(tostring(turtleId))
                  .. "&status=" .. textutils.urlEncode(tostring(status))
        local h, err, errH = http.post(url, "")
       if h then
            local body = h.readAll()
            h.close()
            return true, body
        end 
        if errH then
            err = err .. ": " .. (errH.readAll() or "")
            errH.close()
        end
        return false, err
    end
}