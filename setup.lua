Logging = require("logging")
QuarrySupervisor = ""
QSFilename = "quarry_sv.lua"
ServerName = "CentralSupervisor"
Processes = {}

-- Local ovverrides for CC:Tweaked termincal commands for testing purposes
shell = {
    run  = function(cmd, args)
        return print(cmd, args)
    end,
    openTab = function(proc_name, args)
        Processes.proc_name = math.random(1,10000)
        return print("[Server] Launched " .. proc_name .. " in background tab ID: " .. Processes.proc_name)
    end,
}

shell.run("rm", QSFilename)
shell.run("echo", "pastebin get " .. QuarrySupervisor .. " " .. QSFilename)
shell.run("clear", "")
shell.openTab(QSFilename, "-L=Verbose")
Logging.sendLog(ServerName, "Miner01", Logging.action("Quarry", "x:3;y:3;z:10"))
Logging.sendLog(ServerName, "Miner01", Logging.action("Refuel", "x:0;y:0;z:30"))