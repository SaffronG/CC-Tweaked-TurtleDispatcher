return {
    BASE = "http://<host>:8080",
    sendServerLog = function (turtleId, status)
    local url = BASE .. "/status?turtleId=" .. textutils.urlEncode(tostring(turtleId))
              .. "&status=" .. textutils.urlEncode(status)
    local h, err = http.post(url, "")
    if h then h.close() end
    return h ~= nil, err
end
}