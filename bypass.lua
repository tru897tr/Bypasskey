
local env = getfenv and getfenv() or {}

local HttpService = game:GetService("HttpService")
local LOG_FILENAME = "ScriptHubAnalyzer_Log.json"  -- JSON log file

getgenv().lastCompiledFunction = nil
getgenv().lastLoadstringCode = nil
getgenv().isDecompiling = false

local logs = {}            -- All log messages
local detectedLinks = {}   -- All detected URLs
local loadstringCalls = {} -- All unique loadstring codes

local function prettyPrintJSON(data, indent)
    indent = indent or ""
    local nextIndent = indent .. "  "
    local result = ""
    if type(data) == "table" then
        local isArray = (#data > 0)
        if isArray then
            result = result .. "[\n"
            for i, v in ipairs(data) do
                result = result .. nextIndent .. prettyPrintJSON(v, nextIndent)
                if i < #data then
                    result = result .. ",\n"
                else
                    result = result .. "\n"
                end
            end
            result = result .. indent .. "]"
        else
            result = result .. "{\n"
            local keys = {}
            for k in pairs(data) do
                table.insert(keys, k)
            end
            table.sort(keys, function(a, b) return tostring(a) < tostring(b) end)
            for i, k in ipairs(keys) do
                result = result .. nextIndent .. "\"" .. tostring(k) .. "\": " .. prettyPrintJSON(data[k], nextIndent)
                if i < #keys then
                    result = result .. ",\n"
                else
                    result = result .. "\n"
                end
            end
            result = result .. indent .. "}"
        end
    elseif type(data) == "string" then
        result = result .. "\"" .. data:gsub("\n", "\\n"):gsub("\"", "\\\"") .. "\""
    else
        result = result .. tostring(data)
    end
    return result
end

local function writePrettyLogsToFile()
    if writefile then
        local output = {
            logs = logs,
            links = detectedLinks,
            loadstringCalls = loadstringCalls
        }
        local pretty = prettyPrintJSON(output, "")
        writefile(LOG_FILENAME, pretty)
    else
        addLog("SYSTEM", "writefile not available; cannot save logs to file.")
    end
end

local function addLog(category, message)
    if message == nil then
        message = category
        category = "INFO"
    end
    local entry = {
        timestamp = os.date("%X"),
        category = category,
        message = message
    }
    table.insert(logs, entry)
    print(string.format("[%s] %s - %s", entry.category, entry.timestamp, entry.message))
    writePrettyLogsToFile()
end

local function isValidURL(link)
    return link:match("^https?://[%w%.%-_]+%.[%a]+")
end

local function addLink(link)
    if not isValidURL(link) then return end
    for _, l in ipairs(detectedLinks) do
        if l == link then return end
    end
    table.insert(detectedLinks, link)
    addLog("LOADSTRING_LINK", "Detected URL stored: " .. link)
end

local function addLoadstringCall(code)
    for _, existing in ipairs(loadstringCalls) do
        if existing == code then return end
    end
    table.insert(loadstringCalls, code)
    addLog("LOADSTRING", "New loadstring call stored separately.")
end

local function bypassDebugging()
    addLog("SYSTEM", "Anti-anti-debugging activated...")
    debug.getinfo = debug.getinfo or function() return {} end
    debug.getupvalue = debug.getupvalue or function() return nil end
    debug.sethook = debug.sethook or function() end
end
bypassDebugging()

local function safeDecompile(decompileFunction)
    while getgenv().isDecompiling do
        wait(0.1)
    end
    getgenv().isDecompiling = true
    spawn(function()
        decompileFunction()
        getgenv().isDecompiling = false
    end)
end

local function printCallStack(maxLevels)
    maxLevels = maxLevels or 5
    addLog("DEBUG", "Call-Stack Analysis:")
    for level = 2, maxLevels do
        local info = debug.getinfo(level, "Sln")
        if not info then
            addLog("DEBUG", string.format("  Level %d: No further information.", level))
            break
        end
        local funcName = info.name or "unknown"
        local src = info.short_src or "?"
        local line = info.currentline or 0
        addLog("DEBUG", string.format("  Level %d: %s in [%s]:%d", level, funcName, src, line))
    end
    addLog("DEBUG", "=== Call-Stack End ===")
end

local oldLoadstring = loadstring
hookfunction(loadstring, function(code, ...)
    addLog("LOADSTRING", "Analyzing code...")
    if getgenv().lastLoadstringCode ~= code then
        getgenv().lastLoadstringCode = code
        addLoadstringCall(code)
        if #code < 1000 then
            addLog("LOADSTRING_FULL", "Original loadstring code: " .. code)
        else
            addLog("LOADSTRING_FULL", "Original loadstring code (excerpt, length " .. #code .. "): " .. code:sub(1, 1000))
        end
        for link in code:gmatch("(https?://%S+)") do
            addLink(link)
        end
        if code:match("^return%(%s*function%(") and code:match("local N=%b{}") then
            safeDecompile(function()
                if env.decompile then
                    local success, decompiled = pcall(env.decompile, getgenv().lastCompiledFunction)
                    if success and decompiled then
                        local filename = "Decompiled_" .. os.date("%Y%m%d_%H%M%S") .. ".lua"
                        if writefile then
                            writefile(filename, decompiled)
                            addLog("AUTODECOMPILE", "Instant decompilation successful; saved to " .. filename)
                        else
                            addLog("AUTODECOMPILE", "writefile not available; decompiled output (excerpt): " .. decompiled:sub(1, 1000))
                        end
                    else
                        addLog("AUTODECOMPILE", "Instant decompilation failed.")
                    end
                else
                    addLog("AUTODECOMPILE", "Dex decompiler function not available.")
                end
            end)
        else
            safeDecompile(function()
                if env.decompile then
                    local success, decompiled = pcall(env.decompile, getgenv().lastCompiledFunction)
                    if success and decompiled then
                        addLog("AUTODECOMPILE", "Auto decompilation successful (excerpt): " .. decompiled:sub(1, 1000))
                    else
                        addLog("AUTODECOMPILE", "Decompilation failed or not available.")
                    end
                else
                    addLog("AUTODECOMPILE", "Dex decompiler function not available.")
                end
                printCallStack(5)
            end)
        end
    end
    local compiledFunction = oldLoadstring(code, ...)
    getgenv().lastCompiledFunction = compiledFunction
    addLog("LOADSTRING", "Code executed. Original script remains unaffected.")
    addLog("LOADSTRING", "=== LOADSTRING End ===")
    return compiledFunction
end)

local oldHttpGet = hookfunction(game.HttpGet, function(self, url, ...)
    addLog("HTTP", "URL: " .. url)
    local result = oldHttpGet(self, url, ...)
    if result:find("loadstring") or result:find("require") then
        addLog("HTTP", "Suspicious payload (excerpt): " .. result:sub(1, 100))
    end
    return result
end)

local oldRequestAsync = hookfunction(HttpService.RequestAsync, function(self, opts)
    local url = opts and opts.Url or "Unknown"
    addLog("REQUEST", "URL: " .. url)
    if opts.Body then
        addLog("REQUEST", "Body: " .. opts.Body)
    end
    local res = oldRequestAsync(self, opts)
    if res and res.Body and (res.Body:find("loadstring") or res.Body:find("require")) then
        addLog("REQUEST", "Response payload (excerpt): " .. res.Body:sub(1, 100))
    end
    return res
end)

local oldRequire = require
hookfunction(require, function(moduleScript)
    if typeof(moduleScript) == "Instance" and moduleScript:IsA("ModuleScript") then
        addLog("MODULE", "Loaded module: " .. moduleScript:GetFullName())
    end
    return oldRequire(moduleScript)
end)

if loadfile then
    local oldLoadfile = loadfile
    hookfunction(loadfile, function(filename, ...)
        addLog("LOADFILE", "Loading file: " .. filename)
        return oldLoadfile(filename, ...)
    end)
end

local function createDecompiledUI(decompiledCode)
    local decompileGui = Instance.new("ScreenGui")
    decompileGui.Name = "DecompilerUI"
    decompileGui.ResetOnSpawn = false
    decompileGui.Parent = game:GetService("CoreGui")
    
    local frame = Instance.new("Frame", decompileGui)
    frame.BackgroundTransparency = 0.3
    frame.Position = UDim2.new(0.2, 0, 0.2, 0)
    frame.Size = UDim2.new(0.6, 0, 0.6, 0)
    
    local codeLabel = Instance.new("TextLabel", frame)
    codeLabel.BackgroundTransparency = 1
    codeLabel.Size = UDim2.new(1, 0, 0.9, 0)
    codeLabel.Text = decompiledCode or "No decompiled data."
    codeLabel.TextScaled = true
    codeLabel.TextWrapped = true
    codeLabel.Font = Enum.Font.SourceSans
    codeLabel.TextColor3 = Color3.new(1, 1, 1)
    
    local closeButton = Instance.new("TextButton", frame)
    closeButton.Text = "X"
    closeButton.Size = UDim2.new(0, 30, 0, 30)
    closeButton.Position = UDim2.new(1, -30, 0, 0)
    closeButton.BackgroundTransparency = 0.5
    closeButton.TextScaled = true
    closeButton.MouseButton1Click:Connect(function() 
        decompileGui:Destroy() 
    end)
end

local function createLogUI()
    local ScreenGui = Instance.new("ScreenGui")
    ScreenGui.Name = "ScriptHubAnalyzerUI"
    ScreenGui.ResetOnSpawn = false
    ScreenGui.Parent = game:GetService("CoreGui")
    
    local Frame = Instance.new("Frame", ScreenGui)
    Frame.BackgroundTransparency = 0.5
    Frame.Position = UDim2.new(0.7, 0, 0.1, 0)
    Frame.Size = UDim2.new(0.25, 0, 0.8, 0)
    
    local Scroller = Instance.new("ScrollingFrame", Frame)
    Scroller.Name = "LogScroller"
    Scroller.BackgroundTransparency = 1
    Scroller.Size = UDim2.new(1, 0, 0.85, 0)
    Scroller.CanvasSize = UDim2.new(0, 0, 5, 0)
    Scroller.ScrollBarThickness = 6
    
    local TextLabel = Instance.new("TextLabel", Scroller)
    TextLabel.Name = "LogLabel"
    TextLabel.BackgroundTransparency = 1
    TextLabel.Size = UDim2.new(1, -10, 1, 0)
    TextLabel.TextScaled = false
    TextLabel.TextWrapped = true
    TextLabel.TextColor3 = Color3.new(1, 1, 1)
    TextLabel.Font = Enum.Font.SourceSans
    TextLabel.TextYAlignment = Enum.TextYAlignment.Top
    TextLabel.Text = ""
    
    local decompileButton = Instance.new("TextButton", Frame)
    decompileButton.Text = "Decompile"
    decompileButton.Size = UDim2.new(1, 0, 0.075, 0)
    decompileButton.Position = UDim2.new(0, 0, 0.87, 0)
    decompileButton.BackgroundTransparency = 0.3
    decompileButton.TextScaled = true
    decompileButton.MouseButton1Click:Connect(function()
        if getgenv().lastCompiledFunction then
            safeDecompile(function()
                if env.decompile then
                    local success, decompiled = pcall(env.decompile, getgenv().lastCompiledFunction)
                    if success and decompiled then
                        addLog("DECOMPILE", "Decompilation successful!")
                        createDecompiledUI(decompiled)
                    else
                        addLog("DECOMPILE", "Decompilation failed!")
                        createDecompiledUI("Decompilation failed!")
                    end
                else
                    addLog("DECOMPILE", "Dex decompiler function not available!")
                    createDecompiledUI("Dex decompiler function not available!")
                end
            end)
        else
            addLog("DECOMPILE", "No code available for decompilation!")
            createDecompiledUI("No code available for decompilation!")
        end
    end)
    
    local closeButton = Instance.new("TextButton", Frame)
    closeButton.Text = "X"
    closeButton.Size = UDim2.new(0, 30, 0, 30)
    closeButton.Position = UDim2.new(1, -30, 0, 0)
    closeButton.BackgroundTransparency = 0.5
    closeButton.TextScaled = true
    closeButton.MouseButton1Click:Connect(function() 
        ScreenGui:Destroy() 
    end)
    
    spawn(function()
        while ScreenGui.Parent do
            local displayText = ""
            for _, entry in ipairs(logs) do
                displayText = displayText .. string.format("[%s] %s - %s\n", entry.category, entry.timestamp, entry.message)
            end
            TextLabel.Text = displayText
            local textSize = TextLabel.TextBounds.Y
            Scroller.CanvasSize = UDim2.new(0, 0, 0, textSize + 20)
            wait(1)
        end
    end)
end

createLogUI()

addLog("SYSTEM", "All hooks and features active – original script remains unaffected!")
addLog("SYSTEM", "Enter the key (if needed) and view all payloads in the log!")
