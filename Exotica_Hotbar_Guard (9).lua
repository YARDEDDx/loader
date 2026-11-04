-- Exotica Hotbar Guard (standalone). Run it by itself, or together with Exotica_Hotbar_Diagnostic.lua.
-- Stops the game's anti-spam from switching your hotbar off and force-unequipping your tools.
local Players = game:GetService("Players")
local p = Players.LocalPlayer

-- ==========================================
-- HOTBAR GUARD (Baddies)
-- Cause found in the game's BackpackController: six Tool additions to your character with under 0.7s
-- between them trips an anti-spam that turns the Satchel hotbar off, force-unequips your tools and
-- waits 3 seconds. Fast macros trip it.
-- Fix 1: that anti-spam trigger is neutralised at the source (_disableSpam).
-- Fix 2: Satchel:SetBackpackEnabled(false) is blocked unless the game has a real reason (driving, duel,
--        arrested, frozen, dress room...), and a watchdog turns the hotbar back on if it is still off.
-- Logger: while DEBUG is true, everything that hides the hotbar is printed and saved to
--        Exotica_Hotbar_Debug.txt (with who called it), so it can be sent for diagnosis.
-- ==========================================
task.spawn(function()
    local GUARD_ENABLED = true
    local DEBUG = true

    -- only the newest copy of this guard stays active (running it twice used to make two keepers fight)
    local env = (getgenv and getgenv()) or _G
    env.__ExoticaGuardGen = (env.__ExoticaGuardGen or 0) + 1
    local myGen = env.__ExoticaGuardGen

    local RS = game:GetService("ReplicatedStorage")
    local t0 = os.clock()
    local logLines, flushQueued = {}, false
    local function dlog(...)
        if not DEBUG then return end
        local parts = { string.format("[%7.2f]", os.clock() - t0) }
        for _, v in ipairs({ ... }) do parts[#parts + 1] = tostring(v) end
        local line = table.concat(parts, " ")
        print("[Exotica HotbarGuard]", line)
        logLines[#logLines + 1] = line
        if #logLines > 400 then table.remove(logLines, 1) end
        if writefile and not flushQueued then
            flushQueued = true
            task.delay(1.5, function()
                flushQueued = false
                pcall(writefile, "Exotica_Hotbar_Debug.txt", table.concat(logLines, "\n"))
            end)
        end
    end

    local LEGIT_BLOCKS = {
        "Freezed", "BeingDogLeashed", "BeingTombstoneTrapped", "BeingArrested", "USER_DRIVING",
        "USER_VEHICLE_SITTING", "IN_DRESS_ROOM", "CARRYING_EGG", "UNDERGROUND_FIGHTING", "IsOnDuel",
        "BeingSchoolLockerTrapped", "IsJuggernautOfRunEvent", "GravityGunEffect", "ChampionRingQueue",
    }
    local function activeBlocks()
        local on = {}
        for _, a in ipairs(LEGIT_BLOCKS) do
            if p:GetAttribute(a) then on[#on + 1] = a end
        end
        return on
    end

    -- sets t[k] = v even if the table is read-only (frozen), when the executor allows it; logs if it can't
    local function patch(t, k, v)
        if pcall(function() t[k] = v end) then return true end
        pcall(function() if setreadonly then setreadonly(t, false) end end)
        local ok2, err = pcall(function() t[k] = v end)
        if ok2 then return true end
        dlog("could not patch", k, "|", tostring(err))
        return false
    end

    local Satchel, Ctrl
    pcall(function()
        local mods = RS:WaitForChild("Modules", 15)
        Satchel = require(mods:WaitForChild("Satchel", 15))
    end)
    pcall(function()
        local scripts = p:WaitForChild("PlayerScripts", 15)
        local controllers = scripts:WaitForChild("Controllers", 30)
        Ctrl = require(controllers:WaitForChild("BackpackController", 30))
    end)
    dlog("Satchel:", Satchel and "found" or "MISSING", "| BackpackController:", type(Ctrl) == "table" and "found" or "MISSING")

    -- Fix 1: the anti-spam shutdown never runs (no hotbar off, no forced unequip)
    if type(Ctrl) == "table" then
        local origSpam = Ctrl._disableSpam
        patch(Ctrl, "_disableSpam", function(self, ...)
            if not GUARD_ENABLED then return origSpam(self, ...) end
            dlog("BLOCKED the game's anti-spam hotbar shutdown")
        end)
    end

    -- Fix 2: Satchel can't be switched off without a real reason; every attempt is logged with its caller
    if Satchel then
        local origSet = Satchel.SetBackpackEnabled
        patch(Satchel, "SetBackpackEnabled", function(self, value, ...)
            if value == false then
                local why = activeBlocks()
                dlog("SetBackpackEnabled(false) | game reasons:", #why > 0 and table.concat(why, ",") or "NONE")
                dlog((debug.traceback("caller", 2):gsub("\n", " <- ")))
                if GUARD_ENABLED and #why == 0 then
                    dlog("-> ignored")
                    return
                end
            end
            return origSet(self, value, ...)
        end)
    end

    -- logger: tool add / remove timing on your character (shows the burst that trips the game)
    local function watchChar(char)
        if not char then return end
        char.ChildAdded:Connect(function(c) if c:IsA("Tool") then dlog("equipped", c.Name) end end)
        char.ChildRemoved:Connect(function(c) if c:IsA("Tool") then dlog("unequipped", c.Name) end end)
    end
    watchChar(p.Character)
    p.CharacterAdded:Connect(watchChar)

    -- ==== TOOL KEEPER ====
    -- If a tool is pulled out of your hands right after you equipped it, and nothing on your side asked for that
    -- (not the hotbar, not your macros) and the game has no real reason (stunned, ragdolled, arrested, in a duel...),
    -- the tool is put back in your hand. Works whether the client or the server did it.
    local KEEP_TOOLS = false -- off by default: pacing (below) prevents the pull-outs, and re-equipping can add noise. Set true to bring it back.
    -- Why it waits: the game punishes a burst of equips. If the tool goes straight back into your hand, that
    -- is one more equip in the burst, and it gets pulled out again (the loop in the log). Waiting until the
    -- burst window (0.7s) has passed lets the counters reset, so the tool stays. Set to 0 for instant.
    local KEEPER_WAIT = 0.75
    local lastToolAdd = -10

    -- ==== EQUIP PACING ====
    -- The log shows that once the game decides you are spamming, EVERY tool you equip is pulled out again about
    -- 60-80ms later, even after waiting 1.4s. So the best fix is not to trip it at all: the game trips on the
    -- 6th equip in a row with under 0.7s between them. This holds the 6th equip back until a 0.7s quiet gap has
    -- reset its counter, then equips it. (Costs ~0.7s on that one equip, instead of losing the weapon.)
    local PACE_EQUIPS = false -- off by default: the recorder showed the anti-spam block alone stops the shutdown and forced unequip. Set true only if the weapon still gets pulled out.
    local PACE_MAX = 5      -- quick equips allowed in a row. If it still trips, try 4 or 3.
    local PACE_GAP = 0.72   -- the game resets its counter after a 0.7s gap
    local burst = 0
    local paceBypass = false
    local paceToken = 0
    local lastEquipped = nil
    local lastUnequipAsk = -10 -- last time anything on your client called Humanoid:UnequipTools
    pcall(function()
        if hookmetamethod and getnamecallmethod then
            local oldNC
            oldNC = hookmetamethod(game, "__namecall", (newcclosure or function(f) return f end)(function(self, ...)
                local m = getnamecallmethod()
                if m == "UnequipTools" then
                    lastUnequipAsk = os.clock()
                elseif m == "EquipTool" and PACE_EQUIPS and GUARD_ENABLED and not paceBypass then
                    local tool = ...
                    local now = os.clock()
                    local okOwn = pcall(function() return self.Parent == p.Character end)
                    if okOwn and self.Parent == p.Character and burst >= PACE_MAX and now - lastToolAdd < 0.7 then
                        -- this would be the 6th quick equip: hold it back until the counter has reset
                        paceToken = paceToken + 1
                        local myToken = paceToken
                        local hum = self
                        local delay = (lastToolAdd + PACE_GAP) - now
                        task.delay(delay, function()
                            if myToken ~= paceToken then return end -- a newer equip replaced this one
                            paceBypass = true
                            pcall(function() hum:EquipTool(tool) end)
                            paceBypass = false
                        end)
                        dlog("PACED an equip of", tostring(tool), "by", math.floor(delay * 1000), "ms (it would have been equip #" .. (burst + 1) .. " in a row)")
                        return
                    end
                end
                return oldNC(self, ...)
            end))
        else
            dlog("no hookmetamethod: the keeper can't tell your own unequips apart, it only reacts within 0.6s of an equip")
        end
    end)

    local equippedAt = setmetatable({}, { __mode = "k" })
    local restoreLog = setmetatable({}, { __mode = "k" })
    local keepState = setmetatable({}, { __mode = "k" }) -- per tool: how many quick put-backs got pulled out again

    local function safeToRestore(char)
        local hum = char and char:FindFirstChildOfClass("Humanoid")
        if not hum or hum.Health <= 0 then return false, nil end
        for _, n in ipairs({ "RagdollTrigger", "Dead", "BeingCarried", "stunned" }) do
            if char:FindFirstChild(n) then return false, nil end
        end
        if hum:GetAttribute("Ragdoll") or p:GetAttribute("InDanceBombEffect") or p:GetAttribute("InPotionBubble") then
            return false, nil
        end
        if #activeBlocks() > 0 then return false, nil end
        return true, hum
    end

    local function handHasTool(char)
        for _, c in ipairs(char:GetChildren()) do
            if c:IsA("Tool") then return true end
        end
        return false
    end

    local function watchKeeper(char)
        if not char then return end
        char.ChildAdded:Connect(function(c)
            if c:IsA("Tool") then
                local nowA = os.clock()
                if nowA - lastToolAdd >= 0.7 then burst = 0 end -- same rule the game uses
                burst = burst + 1
                equippedAt[c] = nowA
                lastToolAdd = nowA
                lastEquipped = c
            end
        end)
        char.ChildRemoved:Connect(function(c)
            if not (KEEP_TOOLS and GUARD_ENABLED) or not c:IsA("Tool") then return end
            local t = equippedAt[c]
            if not t then return end
            local now = os.clock()
            if now - t > 0.6 then return end                -- only a tool that was JUST equipped
            if lastUnequipAsk > t + 0.002 then return end   -- unequipped on purpose by you / the hotbar / your macro
            -- first try is quick. If the tool gets pulled out AGAIN right after a put-back, the quick way is not
            -- working, so each further try waits longer (0.06s, then KEEPER_WAIT, then twice that).
            local st = keepState[c] or { n = 0, at = -10 }
            keepState[c] = st
            if now - st.at < 0.4 then st.n = st.n + 1 else st.n = 0 end
            local ladder = { 0.06, KEEPER_WAIT, KEEPER_WAIT * 2 }
            local want = ladder[math.min(st.n + 1, #ladder)]
            local waitFor = math.max(0.06, (lastToolAdd + want) - now)
            task.delay(waitFor, function()
                local ok, hum = safeToRestore(char)
                if not ok then return end
                if handHasTool(char) then return end        -- you already picked something else
                if lastEquipped ~= c then return end        -- you equipped a different tool since; do not bring this one back
                local bp = p:FindFirstChildOfClass("Backpack")
                if not bp or c.Parent ~= bp then return end
                -- no fighting: at most 3 puts-back per tool every 2 seconds
                local log2 = restoreLog[c] or {}
                for i = #log2, 1, -1 do
                    if os.clock() - log2[i] > 2 then table.remove(log2, i) end
                end
                if #log2 >= 3 then return end
                log2[#log2 + 1] = os.clock()
                restoreLog[c] = log2
                paceBypass = true
                pcall(function() hum:EquipTool(c) end)
                paceBypass = false
                st.at = os.clock()
                dlog("KEEPER put", c.Name, "back in your hand after waiting", math.floor(waitFor * 1000), "ms (it was pulled out", math.floor((now - t) * 1000), "ms after you equipped it)")
            end)
        end)
    end
    watchKeeper(p.Character)
    p.CharacterAdded:Connect(watchKeeper)

    -- watchdog: if the hotbar is off with no game reason, turn it back on
    local lastState
    while true do
        task.wait(0.1)
        if env.__ExoticaGuardGen ~= myGen then
            GUARD_ENABLED = false -- a newer copy took over; this one goes inert
            return
        end
        if Satchel then
            local ok, enabled = pcall(function() return Satchel:GetBackpackEnabled() end)
            if ok and enabled ~= lastState then
                lastState = enabled
                dlog("hotbar enabled =", tostring(enabled))
            end
            if GUARD_ENABLED and ok and enabled == false and #activeBlocks() == 0 then
                local hum = p.Character and p.Character:FindFirstChildOfClass("Humanoid")
                if hum and hum.Health > 0 then
                    pcall(function()
                        Satchel:SetBackpackEnabled(true)
                    end)
                    if type(Ctrl) == "table" then Ctrl._enabled = true Ctrl._spamDelay = false end
                    dlog("watchdog turned the hotbar back on")
                end
            end
        end
    end
end)
