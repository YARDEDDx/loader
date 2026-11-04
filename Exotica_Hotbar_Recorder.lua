-- Exotica Hotbar Recorder (passive: it only listens, it changes nothing)
--
-- HOW TO USE
--   1. Run ONLY this script. Do not run the guard or your macro script at the same time.
--   2. Do about 10-15 seconds of the fast switching that makes the weapon get pulled out.
--   3. Stop and wait ~6 seconds. A summary prints in the console AND is copied to your clipboard
--      (paste it straight into the chat). RightShift also prints it at any time.
--   4. The full timeline is saved to Exotica_Hotbar_Recorder.txt in your executor's workspace folder.
--
-- WHAT IT RECORDS
--   - every tool equip / unequip on your character, and whether YOUR client asked for it
--   - an unequip that nothing on your client asked for is marked FORCED
--   - for every FORCED unequip: which remote events the server sent you, and which you sent it,
--     in the 0.3 seconds before it (this is how we find out whether the server did it)
--   - the game's anti-spam firing, hotbar on/off flips, and the game's own "reasons" (attributes)

local Players = game:GetService("Players")
local RS = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local UIS = game:GetService("UserInputService")
local p = Players.LocalPlayer

local FILE = "Exotica_Hotbar_Recorder.txt"
local clock = os.clock
local t0 = clock()
local function now() return clock() - t0 end

------------------------------------------------------------
-- storage
------------------------------------------------------------
local events = {}          -- timeline: { t, kind, text }
local remotes = {}         -- recent remote traffic: { t, dir, name }
local totals = { ["in"] = {}, out = {} }
local forcedList = {}      -- one entry per FORCED unequip
local stats = { equips = 0, unequips = 0, requested = 0, forced = 0, spam = 0, hotbarOff = 0 }

local lastEvent = -10       -- last tool event time (drives the auto summary)
local eventsSinceSummary = 0
local lastClientRemoval = -10 -- last time YOUR client called UnequipTools or moved a tool out by .Parent
local lastSpam = -10
local equippedAt = setmetatable({}, { __mode = "k" })

local function ev(kind, text)
    events[#events + 1] = { t = now(), kind = kind, text = text }
    if #events > 5000 then
        table.move(events, 501, #events, 1)
        for i = #events - 499, #events do events[i] = nil end
    end
end

local function addRemote(dir, name)
    remotes[#remotes + 1] = { t = now(), dir = dir, name = name }
    totals[dir][name] = (totals[dir][name] or 0) + 1
    if #remotes > 3000 then
        table.move(remotes, 1001, #remotes, 1)
        for i = #remotes - 999, #remotes do remotes[i] = nil end
    end
end

local function short(s)
    s = tostring(s):gsub("\n", " < ")
    if #s > 230 then s = s:sub(1, 230) .. "..." end
    return s
end

local function step(name, fn)
    local ok, err = pcall(fn)
    if not ok then ev("ERROR", "step failed: " .. name .. " | " .. tostring(err)) print("[Recorder] step failed:", name, err) end
end

local function patch(t, k, v)
    if pcall(function() t[k] = v end) then return true end
    pcall(function() if setreadonly then setreadonly(t, false) end end)
    return pcall(function() t[k] = v end)
end

------------------------------------------------------------
-- the game's own reasons for hiding / unequipping
------------------------------------------------------------
local REASONS = {
    "Freezed", "BeingDogLeashed", "BeingTombstoneTrapped", "BeingArrested", "USER_DRIVING",
    "USER_VEHICLE_SITTING", "IN_DRESS_ROOM", "CARRYING_EGG", "UNDERGROUND_FIGHTING", "IsOnDuel",
    "BeingSchoolLockerTrapped", "IsJuggernautOfRunEvent", "GravityGunEffect", "ChampionRingQueue",
    "InDanceBombEffect", "InPotionBubble",
}
local function reasonsOn()
    local on = {}
    for _, a in ipairs(REASONS) do
        if p:GetAttribute(a) then on[#on + 1] = a end
    end
    local c = p.Character
    if c then
        for _, n in ipairs({ "RagdollTrigger", "Dead", "BeingCarried", "stunned" }) do
            if c:FindFirstChild(n) then on[#on + 1] = "char:" .. n end
        end
        local h = c:FindFirstChildOfClass("Humanoid")
        if h and h:GetAttribute("Ragdoll") then on[#on + 1] = "Humanoid.Ragdoll" end
    end
    return #on > 0 and table.concat(on, ",") or "none"
end

------------------------------------------------------------
-- 1) the game's hotbar modules (observe only, originals always run)
------------------------------------------------------------
local Satchel, Ctrl
pcall(function() Satchel = require(RS:WaitForChild("Modules", 15):WaitForChild("Satchel", 15)) end)
pcall(function()
    Ctrl = require(p:WaitForChild("PlayerScripts", 15):WaitForChild("Controllers", 30):WaitForChild("BackpackController", 30))
end)
ev("INFO", "Satchel " .. (Satchel and "found" or "MISSING") .. " | BackpackController " .. (type(Ctrl) == "table" and "found" or "MISSING"))

step("watch anti-spam", function()
    if type(Ctrl) ~= "table" then error("BackpackController missing") end
    for _, name in ipairs({ "_disableSpam", "_toggleBackpackTo" }) do
        local orig = Ctrl[name]
        if type(orig) == "function" then
            patch(Ctrl, name, function(self, a, ...)
                if name == "_disableSpam" then
                    lastSpam = now()
                    stats.spam = stats.spam + 1
                    ev("ANTISPAM", "the game's anti-spam fired (too many equips in a row)")
                else
                    ev("HOTBAR", "_toggleBackpackTo(" .. tostring(a) .. ")")
                end
                return orig(self, a, ...)
            end)
        end
    end
end)

------------------------------------------------------------
-- 2) engine calls: UnequipTools, EquipTool, FireServer, InvokeServer, tool.Parent writes
------------------------------------------------------------
step("engine hooks", function()
    if not (hookmetamethod and getnamecallmethod) then error("executor has no hookmetamethod") end
    local who = function() return (checkcaller and checkcaller()) and "EXECUTOR" or "game" end
    local wrap = newcclosure or function(f) return f end

    local oldNC
    oldNC = hookmetamethod(game, "__namecall", wrap(function(self, ...)
        local m = getnamecallmethod()
        if m == "UnequipTools" or m == "EquipTool" then
            local a1 = ... -- the tool, for EquipTool
            local by = who()
            local t = now()
            if m == "UnequipTools" then lastClientRemoval = t end
            pcall(function()
                ev("CALL", m .. (a1 and (" " .. tostring(a1)) or "") .. " by " .. by .. " | " .. short(debug.traceback("", 2)))
            end)
        elseif m == "FireServer" or m == "InvokeServer" then
            pcall(function() addRemote("out", self.Name) end)
        end
        return oldNC(self, ...)
    end))

    local oldNI
    oldNI = hookmetamethod(game, "__newindex", wrap(function(self, k, v)
        if k == "Parent" and typeof(self) == "Instance" then
            local ok, cn = pcall(function() return self.ClassName end)
            if ok and cn == "Tool" then
                local by = who()
                if v ~= p.Character then lastClientRemoval = now() end
                pcall(function()
                    ev("PARENT", self.Name .. ".Parent = " .. tostring(v) .. " by " .. by .. " | " .. short(debug.traceback("", 2)))
                end)
            end
        end
        return oldNI(self, k, v)
    end))
end)

------------------------------------------------------------
-- 3) incoming remote events (did the server just tell us something?)
------------------------------------------------------------
local hookedRemotes = setmetatable({}, { __mode = "k" })
local remoteCount = 0
local function hookRemote(r)
    if hookedRemotes[r] or remoteCount >= 900 then return end
    local ok, isEvent = pcall(function() return r:IsA("RemoteEvent") end)
    if not (ok and isEvent) then return end
    hookedRemotes[r] = true
    remoteCount = remoteCount + 1
    local name = r.Name
    pcall(function()
        r.OnClientEvent:Connect(function()
            addRemote("in", name)
        end)
    end)
end

step("listen to remotes", function()
    for _, d in ipairs(RS:GetDescendants()) do hookRemote(d) end
    RS.DescendantAdded:Connect(hookRemote)
    ev("INFO", "listening to " .. remoteCount .. " remote events")
end)

------------------------------------------------------------
-- 4) your tools
------------------------------------------------------------
local function contextNames(dir, from, to)
    local counts, order = {}, {}
    for i = #remotes, 1, -1 do
        local r = remotes[i]
        if r.t < from then break end
        if r.dir == dir and r.t <= to then
            if not counts[r.name] then counts[r.name] = 0 order[#order + 1] = r.name end
            counts[r.name] = counts[r.name] + 1
        end
    end
    local parts = {}
    for _, n in ipairs(order) do parts[#parts + 1] = n .. (counts[n] > 1 and ("x" .. counts[n]) or "") end
    return counts, (#parts > 0 and table.concat(parts, ", ") or "none")
end

local function onAdded(tool)
    local t = now()
    stats.equips = stats.equips + 1
    equippedAt[tool] = t
    lastEvent = t
    eventsSinceSummary = eventsSinceSummary + 1
    ev("EQUIP", tool.Name)
end

local function onRemoved(tool, char)
    local t = now()
    stats.unequips = stats.unequips + 1
    lastEvent = t
    eventsSinceSummary = eventsSinceSummary + 1
    local eq = equippedAt[tool]
    local hum = char and char:FindFirstChildOfClass("Humanoid")
    if not char or not char.Parent or (hum and hum.Health <= 0) then
        ev("UNEQUIP", tool.Name .. " (character died or was removed)")
        return
    end
    if not eq then ev("UNEQUIP", tool.Name) return end
    local asked = lastClientRemoval > eq + 0.002
    if asked then
        stats.requested = stats.requested + 1
        ev("UNEQUIP", tool.Name .. " (your client asked for it, " .. math.floor((t - eq) * 1000) .. "ms after equip)")
        return
    end
    -- nothing on your client asked for this one
    stats.forced = stats.forced + 1
    local age = math.floor((t - eq) * 1000)
    local sinceSpam = (t - lastSpam < 5) and math.floor((t - lastSpam) * 1000) or nil
    local inCounts, inText = contextNames("in", t - 0.30, t)
    local outCounts, outText = contextNames("out", t - 0.30, t)
    forcedList[#forcedList + 1] = { age = age, spam = sinceSpam, inCounts = inCounts, outCounts = outCounts }
    local line = string.format("FORCED unequip of %s | %dms after equip | %s | game reasons: %s | remotes received 300ms before: %s | remotes sent 300ms before: %s",
        tool.Name, age, sinceSpam and (sinceSpam .. "ms after the anti-spam") or "no anti-spam nearby", reasonsOn(), inText, outText)
    ev("FORCED", line)
    print("[Recorder] " .. line)
end

local function watchChar(char)
    if not char then return end
    char.ChildAdded:Connect(function(c)
        if c:IsA("Tool") then onAdded(c) end
    end)
    char.ChildRemoved:Connect(function(c)
        if c:IsA("Tool") then onRemoved(c, char) end
    end)
    for _, n in ipairs({ "RagdollTrigger", "Dead", "BeingCarried", "stunned" }) do
        local f = char:FindFirstChild(n)
        if f then ev("STATE", "character already has " .. n) end
    end
    char.ChildAdded:Connect(function(c)
        local n = c.Name
        if n == "RagdollTrigger" or n == "Dead" or n == "BeingCarried" or n == "stunned" then ev("STATE", "character gained " .. n) end
    end)
end
step("watch character", function()
    watchChar(p.Character)
    p.CharacterAdded:Connect(function(c) ev("INFO", "character respawned") watchChar(c) end)
end)

step("watch attributes", function()
    p.AttributeChanged:Connect(function(name)
        ev("ATTR", name .. " = " .. tostring(p:GetAttribute(name)))
    end)
end)

step("watch hotbar", function()
    if not Satchel then error("Satchel missing") end
    local last
    RunService.Heartbeat:Connect(function()
        local ok, v = pcall(function() return Satchel:GetBackpackEnabled() end)
        if ok and v ~= last then
            last = v
            if v == false then stats.hotbarOff = stats.hotbarOff + 1 end
            ev("HOTBAR", "hotbar enabled = " .. tostring(v))
        end
    end)
end)

------------------------------------------------------------
-- 5) summary
------------------------------------------------------------
local function topNames(hitCounts, total, n)
    local arr = {}
    for name, c in pairs(hitCounts) do arr[#arr + 1] = { name = name, c = c } end
    table.sort(arr, function(a, b) return a.c > b.c end)
    local out = {}
    for i = 1, math.min(n, #arr) do
        local e = arr[i]
        out[#out + 1] = string.format("%s (before %d of %d, fired %d times in total)", e.name, e.c, #forcedList, total[e.name] or 0)
    end
    return out
end

local function summary()
    local L = {}
    local function add(s) L[#L + 1] = s end
    add("=== EXOTICA HOTBAR RECORDER SUMMARY ===")
    add(string.format("recorded %.0fs | equips %d | unequips %d | asked for by your client %d | FORCED (nothing on your client asked) %d",
        now(), stats.equips, stats.unequips, stats.requested, stats.forced))
    add(string.format("game anti-spam fired %d times | hotbar turned off %d times", stats.spam, stats.hotbarOff))
    if #forcedList > 0 then
        local ages = {}
        local nearSpam = 0
        for _, f in ipairs(forcedList) do
            ages[#ages + 1] = f.age
            if f.spam and f.spam < 1500 then nearSpam = nearSpam + 1 end
        end
        table.sort(ages)
        add(string.format("forced unequips came %d / %d / %d ms after the equip (min / median / max)", ages[1], ages[math.ceil(#ages / 2)], ages[#ages]))
        add(string.format("%d of %d forced unequips happened within 1.5s after the anti-spam fired", nearSpam, #forcedList))
        local hitsIn, hitsOut = {}, {}
        for _, f in ipairs(forcedList) do
            for n in pairs(f.inCounts) do hitsIn[n] = (hitsIn[n] or 0) + 1 end
            for n in pairs(f.outCounts) do hitsOut[n] = (hitsOut[n] or 0) + 1 end
        end
        local ti = topNames(hitsIn, totals["in"], 6)
        local to = topNames(hitsOut, totals.out, 6)
        add("remotes the SERVER sent just before forced unequips: " .. (#ti > 0 and "" or "none"))
        for _, s in ipairs(ti) do add("   " .. s) end
        add("remotes YOU sent just before forced unequips: " .. (#to > 0 and "" or "none"))
        for _, s in ipairs(to) do add("   " .. s) end
        -- the last few forced events, in full
        add("last forced unequips:")
        local shown = 0
        for i = #events, 1, -1 do
            if events[i].kind == "FORCED" then
                add(string.format("   [%.2f] %s", events[i].t, events[i].text))
                shown = shown + 1
                if shown >= 4 then break end
            end
        end
    else
        add("no forced unequips were recorded in this session")
    end
    return table.concat(L, "\n")
end

local function save(reason)
    local s = summary()
    local out = { s, "", "=== TIMELINE (newest last) ===" }
    local from = math.max(1, #events - 1800)
    for i = from, #events do
        local e = events[i]
        out[#out + 1] = string.format("%8.3f %-9s %s", e.t, e.kind, e.text)
    end
    local text = table.concat(out, "\n")
    if writefile then pcall(writefile, FILE, text) end
    return s
end

local function report(reason)
    local s = save(reason)
    eventsSinceSummary = 0
    for line in (s .. "\n"):gmatch("(.-)\n") do print("[Recorder] " .. line) end
    local copied = false
    if setclipboard then copied = pcall(setclipboard, s) end
    print("[Recorder] summary " .. (copied and "copied to your clipboard, paste it in the chat" or "printed above") .. " | full timeline saved to " .. FILE)
end

-- RightShift prints it any time
UIS.InputBegan:Connect(function(input)
    if input.KeyCode == Enum.KeyCode.RightShift then report("manual") end
end)

-- automatic: after the tool activity stops for ~6 seconds, print / copy / save the summary once
task.spawn(function()
    while true do
        task.wait(1)
        if eventsSinceSummary >= 8 and now() - lastEvent > 6 then
            report("auto")
        end
    end
end)

if getgenv then getgenv().ExoticaRecorderReport = report end
print("[Recorder] listening. Do your fast switching, then stop for ~6 seconds. The summary prints and is copied automatically.")
