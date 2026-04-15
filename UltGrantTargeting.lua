UltGrantTargeting = {}

local UGT = UltGrantTargeting

UGT.name = "UltGrantTargeting"
UGT.version = "1.4.0"
UGT.prefix = "|c33CCFF[UGT]|r "

UGT.savedVars = nil

-- Verbose mode: when false (default), chat output is suppressed but
-- everything is still written to SavedVariables for offline analysis.
UGT.verbose = false

-- ---------------------------------------------------------------------------
-- Known ability IDs
-- ---------------------------------------------------------------------------

-- Ult-blocking abilities: prevent the activator from gaining ultimate
-- Magma Armor and morphs (10s)
UGT.MAGMA_ARMOR_IDS = {
    [15957] = "Magma Armor",
    [17874] = "Magma Shell",
    [17878] = "Corrosive Armor",
}
-- Bone Goliath Transformation and morphs (20s)
UGT.BONE_GOLIATH_IDS = {
    [115001] = "Bone Goliath Transformation",
    [118664] = "Pummeling Goliath",
    [118279] = "Ravenous Goliath",
}

-- Set IDs (for reference / future use with LibSets)
-- Arkasis' Genius: 518
-- Colovian Highlands General: 711

-- Arkasis' Genius proc ability IDs (discovered Phase 0)
UGT.ARKASIS_IDS = {
    [142660] = "Arkasis's Genius",
}

-- Colovian Highlands General proc ability IDs (discovered Phase 0)
UGT.COLOVIAN_IDS = {
    [202843] = "Colovian Highlands General",
}

-- Cryptcannon Vestments (Crypt Transfer) ability IDs
UGT.CRYPTCANNON_IDS = {
    [195031] = "Crypt Transfer",
}

-- Combined lookup of all tracked set proc IDs (rebuilt on load)
UGT.TRACKED_SET_IDS = {}

-- ---------------------------------------------------------------------------
-- State tracking
-- ---------------------------------------------------------------------------

-- ultBlockActive[unitTag] = { abilityId = id, name = name, endTime = t }
UGT.ultBlockActive = {}

-- Recent ult energize events for correlation (ring buffer, last N)
UGT.recentEnergizes = {}
UGT.MAX_RECENT = 50

-- Snapshot debounce: group snapshots triggered by energize events are batched
-- within a short window so one set proc (hitting multiple targets) produces
-- one snapshot rather than N.
UGT.lastSnapshotTime = 0
UGT.SNAPSHOT_DEBOUNCE = 0.15 -- seconds

-- Pending summary: index of the proc entry awaiting summary after debounce
UGT.pendingSummaryProcIdx = nil

-- LibGroupCombatStats integration (optional, populated on load)
UGT.lgcs = nil

-- ---------------------------------------------------------------------------
-- SavedVar size limits (overridable via /ugt limit)
-- ---------------------------------------------------------------------------
UGT.MAX_SESSIONS    = 10    -- oldest sessions pruned at startup
UGT.MAX_PROCS       = 500   -- per session, oldest dropped on insert
UGT.MAX_LOG_ENTRIES  = 2000  -- per session, oldest dropped on insert

-- ---------------------------------------------------------------------------
-- Readable name tables
-- ---------------------------------------------------------------------------

UGT.EFFECT_CHANGE_NAMES = {
    [EFFECT_RESULT_GAINED]       = "GAINED",
    [EFFECT_RESULT_FADED]        = "FADED",
    [EFFECT_RESULT_UPDATED]      = "UPDATED",
    [EFFECT_RESULT_FULL_REFRESH] = "REFRESH",
    [EFFECT_RESULT_TRANSFER]     = "TRANSFER",
}

function UGT.GetChangeName(changeType)
    return UGT.EFFECT_CHANGE_NAMES[changeType] or tostring(changeType)
end

-- ---------------------------------------------------------------------------
-- Logging (dual: chat + savedvars)
-- ---------------------------------------------------------------------------

-- Log: always writes to savedvars, only prints to chat if verbose mode is on.
-- Uses a ring buffer to avoid O(n) shifts from table.remove(..., 1).
function UGT.Log(msg)
    if UGT.verbose then
        d(UGT.prefix .. tostring(msg))
    end
    if UGT.savedVars and UGT.savedVars.sessions then
        local session = UGT.savedVars.sessions[#UGT.savedVars.sessions]
        if session then
            local entry = {
                time = GetGameTimeSeconds(),
                msg = tostring(msg),
            }
            session.logIdx = (session.logIdx or 0) + 1
            if session.logIdx <= UGT.MAX_LOG_ENTRIES then
                session.log[session.logIdx] = entry
            else
                -- Wrap around: overwrite oldest entry
                local wrap = ((session.logIdx - 1) % UGT.MAX_LOG_ENTRIES) + 1
                session.log[wrap] = entry
            end
        end
    end
end

-- Linearize the ring buffer log into chronological order.
-- Call before reading log entries (slash commands, session end).
function UGT.LinearizeLog(session)
    if not session or not session.logIdx then return end
    if session.logIdx <= UGT.MAX_LOG_ENTRIES then return end -- not wrapped, already linear
    local size = math.min(session.logIdx, UGT.MAX_LOG_ENTRIES)
    local startSlot = ((session.logIdx) % UGT.MAX_LOG_ENTRIES) + 1 -- oldest entry
    local linear = {}
    for i = 0, size - 1 do
        local slot = ((startSlot - 1 + i) % UGT.MAX_LOG_ENTRIES) + 1
        linear[i + 1] = session.log[slot]
    end
    session.log = linear
    session.logIdx = size -- reset so it's linear again
end

-- Chat: always prints to chat (for load messages, command responses)
function UGT.Chat(msg)
    d(UGT.prefix .. tostring(msg))
end

-- ---------------------------------------------------------------------------
-- SavedVar pruning
-- ---------------------------------------------------------------------------

-- Trim sessions list to MAX_SESSIONS (keeps newest)
function UGT.PruneSessions()
    if not UGT.savedVars or not UGT.savedVars.sessions then return end
    while #UGT.savedVars.sessions > UGT.MAX_SESSIONS do
        table.remove(UGT.savedVars.sessions, 1)
    end
end

-- Trim current session's log and procs tables
function UGT.PruneCurrentSession()
    if not UGT.savedVars or not UGT.savedVars.sessions then return end
    local session = UGT.savedVars.sessions[#UGT.savedVars.sessions]
    if not session then return end
    -- Linearize the ring buffer, then truncate if limit was lowered
    UGT.LinearizeLog(session)
    while #session.log > UGT.MAX_LOG_ENTRIES do
        table.remove(session.log, 1)
    end
    while #session.procs > UGT.MAX_PROCS do
        table.remove(session.procs, 1)
    end
end

-- ---------------------------------------------------------------------------
-- Group state snapshot
-- ---------------------------------------------------------------------------

function UGT.GetGroupSnapshot()
    local snapshot = {}
    local groupSize = GetGroupSize()

    if groupSize <= 0 then
        -- Solo: just capture self
        local current, max, _ = GetUnitPower("player", COMBAT_MECHANIC_FLAGS_ULTIMATE)
        local px, py = GetMapPlayerPosition("player")
        table.insert(snapshot, {
            tag         = "player",
            name        = zo_strformat("<<1>>", GetUnitName("player")),
            ultCurrent  = current,
            ultMax      = max,
            inCombat    = IsUnitInCombat("player"),
            ultBlocked  = UGT.ultBlockActive["player"] and true or false,
            ultBlockId  = UGT.ultBlockActive["player"] and UGT.ultBlockActive["player"].abilityId or 0,
            ultBlockName = UGT.ultBlockActive["player"] and UGT.ultBlockActive["player"].name or nil,
            posX        = px,
            posY        = py,
            distNorm    = 0,
            isPlayer    = true,
            isDead      = IsUnitDead("player"),
            isOnline    = true,
        })
        return snapshot
    end

    local myX, myY = GetMapPlayerPosition("player")

    for i = 1, groupSize do
        local tag = GetGroupUnitTagByIndex(i)
        if tag and DoesUnitExist(tag) then
            local current, max, _ = GetUnitPower(tag, COMBAT_MECHANIC_FLAGS_ULTIMATE)
            local px, py = GetMapPlayerPosition(tag)
            local isMe = AreUnitsEqual(tag, "player")

            -- Use LGCS ult value for non-self members (API returns 0 for them)
            if not isMe and UGT.lgcs then
                local ultData = UGT.lgcs:GetUnitULT(tag)
                if ultData and ultData.ultValue then
                    current = ultData.ultValue
                    max = 500 -- ESO max ult is always 500; GetUnitPower returns 0 for remote players
                end
            end

            -- Compute normalized map distance from the player
            local dx = px - myX
            local dy = py - myY
            local dist = math.sqrt(dx * dx + dy * dy)

            -- Check for ult-blocking ability via our tracked state
            local hasUltBlock = UGT.ultBlockActive[tag] and true or false
            local ultBlockId = hasUltBlock and UGT.ultBlockActive[tag].abilityId or 0
            local ultBlockName = hasUltBlock and UGT.ultBlockActive[tag].name or nil

            table.insert(snapshot, {
                tag         = tag,
                name        = zo_strformat("<<1>>", GetUnitName(tag)) or "?",
                ultCurrent  = current,
                ultMax      = max,
                inCombat    = IsUnitInCombat(tag),
                ultBlocked  = hasUltBlock,
                ultBlockId  = ultBlockId,
                ultBlockName = ultBlockName,
                posX        = px,
                posY        = py,
                distNorm    = dist,
                isPlayer    = isMe,
                isDead      = IsUnitDead(tag),
                isOnline    = IsUnitOnline(tag),
            })
        end
    end

    return snapshot
end

function UGT.PrintGroupSnapshot(snapshot, label, outputFn)
    local out = outputFn or UGT.Log
    out(label .. " (" .. #snapshot .. " members):")
    for _, m in ipairs(snapshot) do
        local ultBlockTag = m.ultBlocked and (" |cFF0000[ULT BLOCKED: " .. (m.ultBlockName or "?") .. "]|r") or ""
        local deadTag = m.isDead and " |c888888[DEAD]|r" or ""
        local meTag = m.isPlayer and " |c00FF00<< YOU >>|r" or ""
        local distStr = m.distNorm and string.format("  dist=%.4f", m.distNorm) or ""
        out(string.format("  %s %s: ult=%d/%d  combat=%s  pos=(%.4f,%.4f)%s%s%s%s",
            m.tag, m.name, m.ultCurrent, m.ultMax,
            tostring(m.inCombat), m.posX, m.posY,
            distStr, ultBlockTag, deadTag, meTag))
    end
end

-- ---------------------------------------------------------------------------
-- Buff scanning helpers
-- ---------------------------------------------------------------------------

function UGT.IsUltBlockingAbility(abilityId)
    return UGT.MAGMA_ARMOR_IDS[abilityId] ~= nil or UGT.BONE_GOLIATH_IDS[abilityId] ~= nil
end

function UGT.DumpAllBuffs(unitTag)
    local numBuffs = GetNumBuffs(unitTag)
    local now = GetGameTimeSeconds()
    UGT.Chat(string.format("Buffs on %s (%s) — %d total:",
        unitTag, GetUnitName(unitTag) or "?", numBuffs))
    for i = 1, numBuffs do
        local buffName, timeStarted, timeEnding, buffSlot, stackCount,
              iconFilename, deprecatedBuffType, effectType, abilityType,
              statusEffectType, abilityId, canClickOff, castByPlayer =
              GetUnitBuffInfo(unitTag, i)

        local remaining = timeEnding > 0 and (timeEnding - now) or -1
        local timeStr = remaining >= 0 and string.format("%.1fs", remaining) or "permanent"
        local ultBlockTag = UGT.IsUltBlockingAbility(abilityId) and " |cFF0000*** ULT BLOCK ***|r" or ""

        UGT.Chat(string.format("  [%d] %s  stacks=%d  type=%s  atype=%s  %s%s",
            abilityId, buffName or "?", stackCount,
            tostring(effectType), tostring(abilityType),
            timeStr, ultBlockTag))
    end
end

-- ---------------------------------------------------------------------------
-- Event: Combat Event — Ultimate POWER_ENERGIZE tracking
-- This is the core event that fires when a player gains ultimate from any
-- source, including set procs like Arkasis and Colovian.
-- ---------------------------------------------------------------------------

function UGT.OnUltEnergize(_, result, isError, abilityName, abilityGraphic,
        abilityActionSlotType, sourceName, sourceType, targetName, targetType,
        hitValue, powerType, damageType, log, sourceUnitId, targetUnitId,
        abilityId, overflow)

    -- powerType == ULTIMATE is guaranteed by REGISTER_FILTER_POWER_TYPE
    local now = GetGameTimeSeconds()
    local isTrackedSet = UGT.TRACKED_SET_IDS[abilityId] or false
    local setName = isTrackedSet or nil

    -- Strip gender/number decorators (^Fx, ^Mx, etc.) from combat event names
    sourceName = sourceName and zo_strformat("<<1>>", sourceName) or "?"
    targetName = targetName and zo_strformat("<<1>>", targetName) or "?"

    -- Store recent energize event
    local entry = {
        time        = now,
        abilityId   = abilityId,
        abilityName = abilityName or "?",
        source      = sourceName,
        sourceType  = sourceType,
        target      = targetName,
        targetType  = targetType,
        hitValue    = hitValue,
        isTrackedSet = isTrackedSet and true or false,
        setName     = setName,
    }

    table.insert(UGT.recentEnergizes, entry)
    if #UGT.recentEnergizes > UGT.MAX_RECENT then
        table.remove(UGT.recentEnergizes, 1)
    end

    -- Color code based on whether this is a tracked set proc
    local color = isTrackedSet and "|c00FF00" or "|cAAAAAAA"
    local setTag = isTrackedSet and (" |cFFFF00[" .. setName .. "]|r") or ""
    local ultBlockTag = ""

    -- Check if the target is a group member under an ult-blocking ability
    local groupSize = GetGroupSize()
    if groupSize > 0 then
        for i = 1, groupSize do
            local tag = GetGroupUnitTagByIndex(i)
            if tag and zo_strformat("<<1>>", GetUnitName(tag)) == targetName then
                if UGT.ultBlockActive[tag] then
                    ultBlockTag = " |cFF0000[TARGET ULT BLOCKED: " .. UGT.ultBlockActive[tag].name .. "]|r"
                end
                break
            end
        end
    end

    UGT.Log(string.format("%sULT ENERGIZE|r: [%d] %s  %s → %s  +%d ult%s%s",
        color, abilityId, abilityName or "?",
        sourceName, targetName,
        hitValue, setTag, ultBlockTag))

    -- Only create structured proc entries (with snapshots) for tracked set procs
    if not isTrackedSet then return end

    -- Trigger group snapshot (debounced so a multi-target proc only takes one)
    if now - UGT.lastSnapshotTime >= UGT.SNAPSHOT_DEBOUNCE then
        UGT.lastSnapshotTime = now
        local snapshot = UGT.GetGroupSnapshot()

        -- Save structured proc event
        if UGT.savedVars and UGT.savedVars.sessions then
            local session = UGT.savedVars.sessions[#UGT.savedVars.sessions]
            if session then
                table.insert(session.procs, {
                    time        = now,
                    trigger     = entry,
                    snapshot    = snapshot,
                })
                if #session.procs > UGT.MAX_PROCS then
                    table.remove(session.procs, 1)
                end

                -- Schedule a human-readable summary after the debounce window
                UGT.pendingSummaryProcIdx = #session.procs
                zo_callLater(function() UGT.EmitProcSummary() end,
                    math.floor(UGT.SNAPSHOT_DEBOUNCE * 1000) + 50)
            end
        end

        UGT.PrintGroupSnapshot(snapshot, "  Group state at proc")
    else
        -- Within debounce window: just append the energize to the most
        -- recent proc entry's extra targets list
        if UGT.savedVars and UGT.savedVars.sessions then
            local session = UGT.savedVars.sessions[#UGT.savedVars.sessions]
            if session and #session.procs > 0 then
                local lastProc = session.procs[#session.procs]
                if not lastProc.additionalTargets then
                    lastProc.additionalTargets = {}
                end
                table.insert(lastProc.additionalTargets, entry)
            end
        end
    end
end

-- ---------------------------------------------------------------------------
-- Human-readable proc summary (fires after debounce window closes)
-- ---------------------------------------------------------------------------

function UGT.EmitProcSummary()
    local idx = UGT.pendingSummaryProcIdx
    UGT.pendingSummaryProcIdx = nil
    if not idx then return end
    if not UGT.savedVars or not UGT.savedVars.sessions then return end
    local session = UGT.savedVars.sessions[#UGT.savedVars.sessions]
    if not session or not session.procs[idx] then return end

    local proc = session.procs[idx]
    local trigger = proc.trigger
    if not trigger or trigger.manual then return end

    local setName = trigger.setName
    if not setName then return end -- only summarize tracked set procs

    -- Build target list: first target from trigger, rest from additionalTargets
    local targets = {}
    local targetNames = {} -- lookup set for cross-referencing snapshot
    table.insert(targets, { name = trigger.target, ult = trigger.hitValue or 0 })
    targetNames[trigger.target] = true
    if proc.additionalTargets then
        for _, t in ipairs(proc.additionalTargets) do
            table.insert(targets, { name = t.target, ult = t.hitValue or 0 })
            targetNames[t.target] = true
        end
    end

    local source = trigger.source or "?"
    local totalUlt = 0
    local nameList = {}
    for _, t in ipairs(targets) do
        totalUlt = totalUlt + t.ult
        table.insert(nameList, string.format("%s (+%d)", t.name, t.ult))
    end

    -- Cross-reference snapshot: find group members who were ult-blocked or dead
    -- and NOT in the target list (i.e., they were skipped or their ult was wasted)
    local blockedList = {}
    local deadList = {}
    if proc.snapshot then
        for _, m in ipairs(proc.snapshot) do
            if not m.isPlayer or m.name ~= source then -- skip the caster
                if not targetNames[m.name] then
                    if m.ultBlocked then
                        table.insert(blockedList, string.format("%s [%s]",
                            m.name, m.ultBlockName or "?"))
                    elseif m.isDead then
                        table.insert(deadList, m.name)
                    end
                end
            end
        end
    end

    local summary
    if setName == "Crypt Transfer" then
        summary = string.format("|cFFFF00%s|r activated |c00FFFF%s|r, distributing |cFFFFFF%d|r ult to %d targets: %s",
            source, setName, totalUlt, #targets, table.concat(nameList, ", "))
    else
        summary = string.format("|cFFFF00%s|r activated |c00FFFF%s|r, granting ult to %d targets: %s",
            source, setName, #targets, table.concat(nameList, ", "))
    end

    if #blockedList > 0 then
        summary = summary .. string.format(" |cFF4400(%d ineligible: %s)|r",
            #blockedList, table.concat(blockedList, ", "))
    end
    if #deadList > 0 then
        summary = summary .. string.format(" |c888888(%d dead: %s)|r",
            #deadList, table.concat(deadList, ", "))
    end

    -- Always print to chat (these are rare, high-value events)
    UGT.Chat(summary)
    -- Also write to savedvars log
    UGT.Log(summary)

    -- Store a clean (no color codes) summary in the proc entry for offline analysis
    proc.summary = summary:gsub("|c%x%x%x%x%x%x", ""):gsub("|r", "")
end

-- Strip ESO color codes from a string for savedvar storage
function UGT.StripColorCodes(str)
    return str:gsub("|c%x%x%x%x%x%x", ""):gsub("|r", "")
end

-- ---------------------------------------------------------------------------
-- Discovery mode: log ALL combat events with POWER_ENERGIZE to find
-- unknown ability IDs. Enabled via /ugt discover
-- ---------------------------------------------------------------------------

UGT.discoveryMode = false

function UGT.OnDiscoveryCombatEvent(_, result, isError, abilityName, abilityGraphic,
        abilityActionSlotType, sourceName, sourceType, targetName, targetType,
        hitValue, powerType, damageType, log, sourceUnitId, targetUnitId,
        abilityId, overflow)

    if result ~= ACTION_RESULT_POWER_ENERGIZE then return end

    local powerLabel = "?"
    if powerType == COMBAT_MECHANIC_FLAGS_ULTIMATE then
        powerLabel = "ULTIMATE"
    elseif powerType == COMBAT_MECHANIC_FLAGS_MAGICKA then
        powerLabel = "MAGICKA"
    elseif powerType == COMBAT_MECHANIC_FLAGS_STAMINA then
        powerLabel = "STAMINA"
    elseif powerType == COMBAT_MECHANIC_FLAGS_HEALTH then
        powerLabel = "HEALTH"
    else
        powerLabel = tostring(powerType)
    end

    sourceName = sourceName and zo_strformat("<<1>>", sourceName) or "?"
    targetName = targetName and zo_strformat("<<1>>", targetName) or "?"

    UGT.Log(string.format("|cFF00FFDISCOVERY|r: [%d] %s  %s → %s  +%d %s  sourceType=%s  targetType=%s",
        abilityId, abilityName or "?",
        sourceName, targetName,
        hitValue, powerLabel,
        tostring(sourceType), tostring(targetType)))
end

-- ---------------------------------------------------------------------------
-- Event: Effect Changed — track ult-blocking ability gain/fade on group members
-- ---------------------------------------------------------------------------

function UGT.OnEffectChanged(_, changeType, effectSlot, effectName, unitTag,
        beginTime, endTime, stackCount, iconName, deprecatedBuffType,
        effectType, abilityType, statusEffectType, unitName, unitId,
        abilityId, sourceType)

    local isUltBlock = UGT.IsUltBlockingAbility(abilityId)

    -- Fallback keyword match (only in discovery mode — all known IDs are hardcoded)
    if not isUltBlock and UGT.discoveryMode and effectName then
        local lower = zo_strlower(effectName)
        if lower:find("magma armor") or lower:find("magma shell") or lower:find("corrosive armor")
            or lower:find("bone goliath") or lower:find("pummeling goliath") or lower:find("ravenous goliath") then
            isUltBlock = true
            -- Learn this ability ID for future reference
            if abilityId and abilityId > 0 then
                if lower:find("magma") or lower:find("corrosive") then
                    UGT.MAGMA_ARMOR_IDS[abilityId] = effectName
                else
                    UGT.BONE_GOLIATH_IDS[abilityId] = effectName
                end
                UGT.Log(string.format("|cFFFF00DISCOVERED|r ult-blocking ability ID: [%d] %s", abilityId, effectName))
            end
        end
    end

    if not isUltBlock then return end

    local changeName = UGT.GetChangeName(changeType)

    if changeType == EFFECT_RESULT_GAINED or changeType == EFFECT_RESULT_FULL_REFRESH then
        UGT.ultBlockActive[unitTag] = {
            abilityId = abilityId,
            name      = effectName,
            endTime   = endTime,
        }
        UGT.Log(string.format("|cFF0000ULT BLOCK %s|r: [%d] %s on %s (%s)  ends=%.1f",
            changeName, abilityId, effectName or "?",
            unitTag, unitName or "?", endTime))

    elseif changeType == EFFECT_RESULT_FADED then
        UGT.ultBlockActive[unitTag] = nil
        UGT.Log(string.format("|c00FF00ULT BLOCK FADED|r: [%d] %s on %s (%s)",
            abilityId, effectName or "?", unitTag, unitName or "?"))
    end
end

-- ---------------------------------------------------------------------------
-- Slash Commands
-- ---------------------------------------------------------------------------

function UGT.SlashCommand(args)
    local input = args and zo_strlower(args) or ""
    local cmd, rest = input:match("^(%S+)%s*(.*)")
    cmd = cmd or ""
    rest = rest or ""

    if cmd == "status" or cmd == "" then
        UGT.Chat("--- UltGrantTargeting Status ---")

        -- Player info
        local current, max = GetUnitPower("player", COMBAT_MECHANIC_FLAGS_ULTIMATE)
        UGT.Chat(string.format("  Ultimate: %d / %d", current, max))
        UGT.Chat("  In combat: " .. tostring(IsUnitInCombat("player")))

        -- Ult-blocking ability state
        local ultBlockCount = 0
        for tag, info in pairs(UGT.ultBlockActive) do
            ultBlockCount = ultBlockCount + 1
            local name = GetUnitName(tag) or "?"
            UGT.Chat(string.format("  |cFF0000Ult blocked|r: %s (%s) — [%d] %s",
                tag, name, info.abilityId, info.name))
        end
        if ultBlockCount == 0 then
            UGT.Chat("  Ult-blocking abilities: |c00FF00none active|r")
        end

        -- Group snapshot
        local snapshot = UGT.GetGroupSnapshot()
        UGT.PrintGroupSnapshot(snapshot, "  Current group state", UGT.Chat)

        -- Session stats
        if UGT.savedVars and UGT.savedVars.sessions then
            local session = UGT.savedVars.sessions[#UGT.savedVars.sessions]
            if session then
                UGT.Chat(string.format("  Session: %d procs, %d log entries",
                    #session.procs, #session.log))
            end
        end

        -- Mode info
        UGT.Chat("  Verbose: " .. (UGT.verbose and "|c00FF00ON|r" or "|c888888OFF|r (data still saved to SavedVars)"))
        UGT.Chat("  Discovery mode: " .. (UGT.discoveryMode and "|cFF00FFON|r" or "|c888888OFF|r"))
        UGT.Chat("  LGCS: " .. (UGT.lgcs and "|c00FF00connected|r" or "|cFF4400not loaded|r"))

    elseif cmd == "snapshot" then
        local snapshot = UGT.GetGroupSnapshot()
        UGT.PrintGroupSnapshot(snapshot, "Manual snapshot", UGT.Chat)

        -- Save to session
        if UGT.savedVars and UGT.savedVars.sessions then
            local session = UGT.savedVars.sessions[#UGT.savedVars.sessions]
            if session then
                table.insert(session.procs, {
                    time        = GetGameTimeSeconds(),
                    trigger     = { manual = true },
                    snapshot    = snapshot,
                })
            end
        end

    elseif cmd == "scan" then
        -- Dump buffs on self (solo) or all group members
        local groupSize = GetGroupSize()
        if groupSize <= 0 then
            UGT.DumpAllBuffs("player")
        else
            for i = 1, groupSize do
                local tag = GetGroupUnitTagByIndex(i)
                if tag and DoesUnitExist(tag) then
                    UGT.DumpAllBuffs(tag)
                end
            end
        end

    elseif cmd == "discover" then
        UGT.discoveryMode = not UGT.discoveryMode
        if UGT.discoveryMode then
            EVENT_MANAGER:RegisterForEvent(UGT.name .. "_Discovery", EVENT_COMBAT_EVENT,
                UGT.OnDiscoveryCombatEvent)
            UGT.Chat("|cFF00FFDiscovery mode ON|r — logging ALL POWER_ENERGIZE events.")
            UGT.Chat("Drink a potion with Arkasis equipped to find the proc ability ID.")
        else
            EVENT_MANAGER:UnregisterForEvent(UGT.name .. "_Discovery", EVENT_COMBAT_EVENT)
            UGT.Chat("Discovery mode OFF.")
        end

    elseif cmd == "verbose" then
        UGT.verbose = not UGT.verbose
        UGT.Chat("Verbose mode: " .. (UGT.verbose and "|c00FF00ON|r — all events shown in chat" or "|c888888OFF|r — data saved silently to SavedVars"))

    elseif cmd == "procs" then
        if not UGT.savedVars or not UGT.savedVars.sessions then
            UGT.Chat("No data.")
            return
        end
        local session = UGT.savedVars.sessions[#UGT.savedVars.sessions]
        if not session or #session.procs == 0 then
            UGT.Chat("No procs recorded this session.")
            return
        end
        UGT.Chat(string.format("--- %d proc events this session ---", #session.procs))
        local start = math.max(1, #session.procs - 9)
        for i = start, #session.procs do
            local p = session.procs[i]
            local triggerStr = "manual"
            if p.trigger and p.trigger.abilityId then
                triggerStr = string.format("[%d] %s → %s +%d",
                    p.trigger.abilityId, p.trigger.abilityName or "?",
                    p.trigger.target or "?", p.trigger.hitValue or 0)
            end
            local extraCount = p.additionalTargets and #p.additionalTargets or 0
            UGT.Chat(string.format("  #%d (t=%.1f): %s  (+%d other targets)  snapshot=%d members",
                i, p.time, triggerStr, extraCount, #p.snapshot))
        end

    elseif cmd == "recent" then
        if #UGT.recentEnergizes == 0 then
            UGT.Chat("No recent energize events.")
            return
        end
        UGT.Chat(string.format("--- Last %d ult energize events ---", math.min(15, #UGT.recentEnergizes)))
        local start = math.max(1, #UGT.recentEnergizes - 14)
        for i = start, #UGT.recentEnergizes do
            local e = UGT.recentEnergizes[i]
            local setTag = e.isTrackedSet and (" [" .. e.setName .. "]") or ""
            UGT.Chat(string.format("  [%d] %s  %s → %s  +%d%s",
                e.abilityId, e.abilityName, e.source, e.target, e.hitValue, setTag))
        end

    elseif cmd == "limit" then
        local what, val = rest:match("^(%S+)%s+(%d+)$")
        if what and val then
            val = tonumber(val)
            if what == "procs" then
                UGT.MAX_PROCS = val
                UGT.PruneCurrentSession()
                UGT.Chat(string.format("Max procs per session set to %d.", val))
            elseif what == "log" then
                UGT.MAX_LOG_ENTRIES = val
                UGT.PruneCurrentSession()
                UGT.Chat(string.format("Max log entries per session set to %d.", val))
            elseif what == "sessions" then
                UGT.MAX_SESSIONS = val
                UGT.PruneSessions()
                UGT.Chat(string.format("Max sessions set to %d.", val))
            else
                UGT.Chat("Unknown limit: " .. what .. ". Use: procs, log, sessions")
            end
        else
            UGT.Chat("Current limits:")
            UGT.Chat(string.format("  sessions = %d  (current: %d)",
                UGT.MAX_SESSIONS, UGT.savedVars and #UGT.savedVars.sessions or 0))
            local session = UGT.savedVars and UGT.savedVars.sessions and UGT.savedVars.sessions[#UGT.savedVars.sessions]
            UGT.Chat(string.format("  procs    = %d  (current session: %d)",
                UGT.MAX_PROCS, session and #session.procs or 0))
            UGT.Chat(string.format("  log      = %d  (current session: %d)",
                UGT.MAX_LOG_ENTRIES, session and #session.log or 0))
            UGT.Chat("  Set with: /ugt limit <procs|log|sessions> <number>")
        end

    elseif cmd == "note" then
        if rest == "" then
            UGT.Chat("Usage: /ugt note <text>  — e.g. /ugt note C1: Magma Armor targeted or skipped?")
            return
        end
        local snapshot = UGT.GetGroupSnapshot()
        local noteEntry = {
            time     = GetGameTimeSeconds(),
            trigger  = { manual = true, note = rest },
            snapshot = snapshot,
        }
        if UGT.savedVars and UGT.savedVars.sessions then
            local session = UGT.savedVars.sessions[#UGT.savedVars.sessions]
            if session then
                table.insert(session.procs, noteEntry)
                if #session.procs > UGT.MAX_PROCS then
                    table.remove(session.procs, 1)
                end
            end
        end
        UGT.Log(string.format("|cFFFF00NOTE|r: %s", rest))
        UGT.Chat(string.format("|cFFFF00NOTE|r: %s  (snapshot saved with %d members)", rest, #snapshot))

    elseif cmd == "clear" then
        if UGT.savedVars then
            UGT.savedVars.sessions = {}
            UGT.StartSession()
        end
        UGT.recentEnergizes = {}
        UGT.ultBlockActive = {}
        UGT.Chat("Log cleared, session reset.")

    elseif cmd == "help" then
        UGT.Chat("Commands: /ugt status | verbose | snapshot | scan | discover | procs | recent | note | limit | clear | help")
        UGT.Chat("  status    — Current ult, group state, ult-block tracking")
        UGT.Chat("  verbose   — Toggle verbose mode (show events in chat)")
        UGT.Chat("  snapshot  — Manual group state snapshot to log")
        UGT.Chat("  scan      — Dump all buffs on self or group (ID discovery)")
        UGT.Chat("  discover  — Toggle discovery mode (logs ALL energize events)")
        UGT.Chat("  procs     — Show recent set proc events with snapshots")
        UGT.Chat("  recent    — Show recent ult energize events")
        UGT.Chat("  note      — Annotate the log: /ugt note <text>")
        UGT.Chat("  limit     — View/set savedvar size limits")
        UGT.Chat("  clear     — Wipe session data")

    else
        UGT.Chat("Unknown command. Use /ugt help")
    end
end

-- ---------------------------------------------------------------------------
-- Session Management
-- ---------------------------------------------------------------------------

function UGT.StartSession()
    if UGT.savedVars and UGT.savedVars.sessions then
        table.insert(UGT.savedVars.sessions, {
            started = GetGameTimeSeconds(),
            date    = GetDateStringFromTimestamp(GetTimeStamp()),
            procs   = {},
            log     = {},
            logIdx  = 0,
        })
        UGT.PruneSessions()
    end
    UGT.ultBlockActive = {}
end

-- ---------------------------------------------------------------------------
-- Rebuild tracked set ID lookup from all known tables
-- ---------------------------------------------------------------------------

function UGT.RebuildTrackedSetIDs()
    UGT.TRACKED_SET_IDS = {}
    for id, name in pairs(UGT.ARKASIS_IDS) do
        UGT.TRACKED_SET_IDS[id] = name
    end
    for id, name in pairs(UGT.COLOVIAN_IDS) do
        UGT.TRACKED_SET_IDS[id] = name
    end
    for id, name in pairs(UGT.CRYPTCANNON_IDS) do
        UGT.TRACKED_SET_IDS[id] = name
    end
end

-- ---------------------------------------------------------------------------
-- Initialization
-- ---------------------------------------------------------------------------

function UGT.OnAddonLoaded(_, addonName)
    if addonName ~= UGT.name then return end
    EVENT_MANAGER:UnregisterForEvent(UGT.name, EVENT_ADD_ON_LOADED)

    UGT.savedVars = ZO_SavedVars:NewAccountWide("UltGrantTargetingLog", 1, nil, { sessions = {} }, GetWorldName())
    UGT.StartSession()
    UGT.RebuildTrackedSetIDs()

    -- -------------------------------------------------------------------
    -- LibGroupCombatStats integration (required dependency)
    -- Provides actual ult values for group members in snapshots
    -- -------------------------------------------------------------------
    if LibGroupCombatStats and LibGroupCombatStats.RegisterAddon then
        UGT.lgcs = LibGroupCombatStats.RegisterAddon(UGT.name, {"ULT"})
        UGT.Log("  LibGroupCombatStats detected — group ult values available.")
    end

    -- -------------------------------------------------------------------
    -- Core event: combat events for POWER_ENERGIZE
    -- Filter to ultimate power type to reduce noise
    -- -------------------------------------------------------------------
    EVENT_MANAGER:RegisterForEvent(UGT.name, EVENT_COMBAT_EVENT, UGT.OnUltEnergize)
    EVENT_MANAGER:AddFilterForEvent(UGT.name, EVENT_COMBAT_EVENT,
        REGISTER_FILTER_COMBAT_RESULT, ACTION_RESULT_POWER_ENERGIZE)
    EVENT_MANAGER:AddFilterForEvent(UGT.name, EVENT_COMBAT_EVENT,
        REGISTER_FILTER_POWER_TYPE, COMBAT_MECHANIC_FLAGS_ULTIMATE)

    -- -------------------------------------------------------------------
    -- Effect changed on group members: track ult-blocking ability gain/fade
    -- We register for ALL group units (group1..group24) plus player
    -- Multiple registrations with different unit tag filters
    -- -------------------------------------------------------------------
    EVENT_MANAGER:RegisterForEvent(UGT.name .. "_EffectPlayer", EVENT_EFFECT_CHANGED, UGT.OnEffectChanged)
    EVENT_MANAGER:AddFilterForEvent(UGT.name .. "_EffectPlayer", EVENT_EFFECT_CHANGED,
        REGISTER_FILTER_UNIT_TAG, "player")

    for i = 1, 24 do
        local tag = "group" .. i
        local eventName = UGT.name .. "_Effect_" .. tag
        EVENT_MANAGER:RegisterForEvent(eventName, EVENT_EFFECT_CHANGED, UGT.OnEffectChanged)
        EVENT_MANAGER:AddFilterForEvent(eventName, EVENT_EFFECT_CHANGED,
            REGISTER_FILTER_UNIT_TAG, tag)
    end

    -- -------------------------------------------------------------------
    -- Slash commands
    -- -------------------------------------------------------------------
    SLASH_COMMANDS["/ugt"] = UGT.SlashCommand

    UGT.Chat("|c33CCFFUltGrantTargeting v" .. UGT.version .. "|r active — collecting data silently to SavedVars. |c888888/ugt help|r")
    UGT.Chat("|cFF4400Remember to remove this addon when testing is complete.|r")

    -- Log detailed info to savedvars only
    UGT.Log("Loaded v" .. UGT.version)
    local trackedCount = 0
    for _ in pairs(UGT.TRACKED_SET_IDS) do trackedCount = trackedCount + 1 end
    if trackedCount > 0 then
        local ids = {}
        for id, name in pairs(UGT.TRACKED_SET_IDS) do
            table.insert(ids, string.format("[%d] %s", id, name))
        end
        UGT.Log("  Tracking set proc IDs: " .. table.concat(ids, ", "))
    else
        UGT.Log("  No set proc IDs configured yet.")
    end
    UGT.Log("  Tracking ult-blocking IDs: 15957, 17874, 17878 (Magma Armor), 115001, 118664, 118279 (Bone Goliath)")
    if UGT.lgcs then
        UGT.Log("  LibGroupCombatStats connected.")
    else
        UGT.Log("  LibGroupCombatStats not found — group ult values will show 0 in snapshots.")
    end
end

EVENT_MANAGER:RegisterForEvent(UGT.name, EVENT_ADD_ON_LOADED, UGT.OnAddonLoaded)
