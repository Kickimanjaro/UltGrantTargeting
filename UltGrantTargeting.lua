UltGrantTargeting = {}

local UGT = UltGrantTargeting

UGT.name = "UltGrantTargeting"
UGT.version = "1.1.0"
UGT.prefix = "|c33CCFF[UGT]|r "

UGT.savedVars = nil

-- ---------------------------------------------------------------------------
-- Known ability IDs
-- ---------------------------------------------------------------------------

-- Magma Armor and morphs (prevent ultimate gain for their duration, 10s)
UGT.MAGMA_ARMOR_IDS = {
    [15957] = "Magma Armor",
    [17874] = "Magma Shell",
    [17878] = "Corrosive Armor",
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

-- magmaArmorActive[unitTag] = { abilityId = id, name = name, endTime = t }
UGT.magmaArmorActive = {}

-- Recent ult energize events for correlation (ring buffer, last N)
UGT.recentEnergizes = {}
UGT.MAX_RECENT = 50

-- Snapshot debounce: group snapshots triggered by energize events are batched
-- within a short window so one set proc (hitting multiple targets) produces
-- one snapshot rather than N.
UGT.lastSnapshotTime = 0
UGT.SNAPSHOT_DEBOUNCE = 0.15 -- seconds

-- LibGroupCombatStats integration (optional, populated on load)
UGT.lgcs = nil

-- ---------------------------------------------------------------------------
-- Readable name tables
-- ---------------------------------------------------------------------------

UGT.ACTION_RESULT_NAMES = {
    [ACTION_RESULT_DAMAGE]              = "DAMAGE",
    [ACTION_RESULT_CRITICAL_DAMAGE]     = "CRIT_DMG",
    [ACTION_RESULT_DOT_TICK]            = "DOT",
    [ACTION_RESULT_DOT_TICK_CRITICAL]   = "DOT_CRIT",
    [ACTION_RESULT_HEAL]                = "HEAL",
    [ACTION_RESULT_CRITICAL_HEAL]       = "CRIT_HEAL",
    [ACTION_RESULT_HOT_TICK]            = "HOT",
    [ACTION_RESULT_HOT_TICK_CRITICAL]   = "HOT_CRIT",
    [ACTION_RESULT_POWER_ENERGIZE]      = "POWER_ENERGIZE",
    [ACTION_RESULT_POWER_DRAIN]         = "POWER_DRAIN",
    [ACTION_RESULT_IMMUNE]              = "IMMUNE",
    [ACTION_RESULT_BLOCKED]             = "BLOCKED",
    [ACTION_RESULT_MISS]                = "MISS",
    [ACTION_RESULT_RESIST]              = "RESIST",
    [ACTION_RESULT_EFFECT_GAINED]       = "EFFECT_GAINED",
    [ACTION_RESULT_EFFECT_FADED]        = "EFFECT_FADED",
}

UGT.EFFECT_CHANGE_NAMES = {
    [EFFECT_RESULT_GAINED]       = "GAINED",
    [EFFECT_RESULT_FADED]        = "FADED",
    [EFFECT_RESULT_UPDATED]      = "UPDATED",
    [EFFECT_RESULT_FULL_REFRESH] = "REFRESH",
    [EFFECT_RESULT_TRANSFER]     = "TRANSFER",
}

function UGT.GetResultName(result)
    return UGT.ACTION_RESULT_NAMES[result] or tostring(result)
end

function UGT.GetChangeName(changeType)
    return UGT.EFFECT_CHANGE_NAMES[changeType] or tostring(changeType)
end

-- ---------------------------------------------------------------------------
-- Logging (dual: chat + savedvars)
-- ---------------------------------------------------------------------------

function UGT.Log(msg)
    local text = UGT.prefix .. tostring(msg)
    d(text)
    if UGT.savedVars and UGT.savedVars.sessions then
        local session = UGT.savedVars.sessions[#UGT.savedVars.sessions]
        if session then
            table.insert(session.log, {
                time = GetGameTimeSeconds(),
                msg = tostring(msg),
            })
        end
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
        local current, max, effectiveMax = GetUnitPower("player", COMBAT_MECHANIC_FLAGS_ULTIMATE)
        local px, py = GetMapPlayerPosition("player")
        table.insert(snapshot, {
            tag         = "player",
            name        = GetUnitName("player"),
            ultCurrent  = current,
            ultMax      = max,
            inCombat    = IsUnitInCombat("player"),
            magmaArmor  = UGT.magmaArmorActive["player"] and true or false,
            magmaId     = UGT.magmaArmorActive["player"] and UGT.magmaArmorActive["player"].abilityId or 0,
            posX        = px,
            posY        = py,
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
            local current, max, effectiveMax = GetUnitPower(tag, COMBAT_MECHANIC_FLAGS_ULTIMATE)
            local px, py = GetMapPlayerPosition(tag)
            local isMe = AreUnitsEqual(tag, "player")

            -- Use LGCS ult value for non-self members (API returns 0 for them)
            if not isMe and UGT.lgcs then
                local ultData = UGT.lgcs:GetUnitULT(tag)
                if ultData and ultData.ultValue then
                    current = ultData.ultValue
                end
            end

            -- Compute normalized map distance from the player
            local dx = px - myX
            local dy = py - myY
            local dist = math.sqrt(dx * dx + dy * dy)

            -- Check for Magma Armor via our tracked state
            local hasMagma = UGT.magmaArmorActive[tag] and true or false
            local magmaId = hasMagma and UGT.magmaArmorActive[tag].abilityId or 0

            table.insert(snapshot, {
                tag         = tag,
                name        = GetUnitName(tag) or "?",
                ultCurrent  = current,
                ultMax      = max,
                inCombat    = IsUnitInCombat(tag),
                magmaArmor  = hasMagma,
                magmaId     = magmaId,
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

function UGT.PrintGroupSnapshot(snapshot, label)
    UGT.Log(label .. " (" .. #snapshot .. " members):")
    for _, m in ipairs(snapshot) do
        local magmaTag = m.magmaArmor and " |cFF0000[MAGMA ARMOR]|r" or ""
        local deadTag = m.isDead and " |c888888[DEAD]|r" or ""
        local meTag = m.isPlayer and " |c00FF00<< YOU >>|r" or ""
        local distStr = m.distNorm and string.format("  dist=%.4f", m.distNorm) or ""
        UGT.Log(string.format("  %s %s: ult=%d/%d  combat=%s  pos=(%.4f,%.4f)%s%s%s%s",
            m.tag, m.name, m.ultCurrent, m.ultMax,
            tostring(m.inCombat), m.posX, m.posY,
            distStr, magmaTag, deadTag, meTag))
    end
end

-- ---------------------------------------------------------------------------
-- Buff scanning helpers
-- ---------------------------------------------------------------------------

function UGT.IsMagmaArmorAbility(abilityId)
    return UGT.MAGMA_ARMOR_IDS[abilityId] ~= nil
end

function UGT.ScanForMagmaArmor(unitTag)
    local numBuffs = GetNumBuffs(unitTag)
    for i = 1, numBuffs do
        local buffName, timeStarted, timeEnding, buffSlot, stackCount,
              iconFilename, deprecatedBuffType, effectType, abilityType,
              statusEffectType, abilityId, canClickOff, castByPlayer =
              GetUnitBuffInfo(unitTag, i)

        if UGT.IsMagmaArmorAbility(abilityId) then
            return true, abilityId, buffName, timeEnding
        end

        -- Fallback: keyword match for names we might not have IDs for
        if buffName then
            local lower = zo_strlower(buffName)
            if lower:find("magma armor") or lower:find("magma shell") or lower:find("corrosive armor") then
                return true, abilityId, buffName, timeEnding
            end
        end
    end
    return false, nil, nil, nil
end

function UGT.DumpAllBuffs(unitTag)
    local numBuffs = GetNumBuffs(unitTag)
    local now = GetGameTimeSeconds()
    UGT.Log(string.format("Buffs on %s (%s) — %d total:",
        unitTag, GetUnitName(unitTag) or "?", numBuffs))
    for i = 1, numBuffs do
        local buffName, timeStarted, timeEnding, buffSlot, stackCount,
              iconFilename, deprecatedBuffType, effectType, abilityType,
              statusEffectType, abilityId, canClickOff, castByPlayer =
              GetUnitBuffInfo(unitTag, i)

        local remaining = timeEnding > 0 and (timeEnding - now) or -1
        local timeStr = remaining >= 0 and string.format("%.1fs", remaining) or "permanent"
        local magmaTag = UGT.IsMagmaArmorAbility(abilityId) and " |cFF0000*** MAGMA ***|r" or ""

        UGT.Log(string.format("  [%d] %s  stacks=%d  type=%s  atype=%s  %s%s",
            abilityId, buffName or "?", stackCount,
            tostring(effectType), tostring(abilityType),
            timeStr, magmaTag))
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

    -- Only care about ultimate energizes
    if powerType ~= COMBAT_MECHANIC_FLAGS_ULTIMATE then return end

    local now = GetGameTimeSeconds()
    local isTrackedSet = UGT.TRACKED_SET_IDS[abilityId] or false
    local setName = isTrackedSet or nil

    -- Store recent energize event
    local entry = {
        time        = now,
        abilityId   = abilityId,
        abilityName = abilityName or "?",
        source      = sourceName or "?",
        sourceType  = sourceType,
        target      = targetName or "?",
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
    local magmaTag = ""

    -- Check if the target is a group member under Magma Armor
    local groupSize = GetGroupSize()
    if groupSize > 0 then
        for i = 1, groupSize do
            local tag = GetGroupUnitTagByIndex(i)
            if tag and GetUnitName(tag) == targetName then
                if UGT.magmaArmorActive[tag] then
                    magmaTag = " |cFF0000[TARGET HAS MAGMA ARMOR]|r"
                end
                break
            end
        end
    end

    UGT.Log(string.format("%sULT ENERGIZE|r: [%d] %s  %s → %s  +%d ult%s%s",
        color, abilityId, abilityName or "?",
        sourceName or "?", targetName or "?",
        hitValue, setTag, magmaTag))

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

    UGT.Log(string.format("|cFF00FFDISCOVERY|r: [%d] %s  %s → %s  +%d %s  sourceType=%s  targetType=%s",
        abilityId, abilityName or "?",
        sourceName or "?", targetName or "?",
        hitValue, powerLabel,
        tostring(sourceType), tostring(targetType)))
end

-- ---------------------------------------------------------------------------
-- Event: Effect Changed — track Magma Armor gain/fade on group members
-- ---------------------------------------------------------------------------

function UGT.OnEffectChanged(_, changeType, effectSlot, effectName, unitTag,
        beginTime, endTime, stackCount, iconName, deprecatedBuffType,
        effectType, abilityType, statusEffectType, unitName, unitId,
        abilityId, sourceType)

    local isMagma = UGT.IsMagmaArmorAbility(abilityId)

    -- Fallback keyword match
    if not isMagma and effectName then
        local lower = zo_strlower(effectName)
        if lower:find("magma armor") or lower:find("magma shell") or lower:find("corrosive armor") then
            isMagma = true
            -- Learn this ability ID for future reference
            if abilityId and abilityId > 0 then
                UGT.MAGMA_ARMOR_IDS[abilityId] = effectName
                UGT.Log(string.format("|cFFFF00DISCOVERED|r Magma Armor buff ID: [%d] %s", abilityId, effectName))
            end
        end
    end

    if not isMagma then return end

    local changeName = UGT.GetChangeName(changeType)

    if changeType == EFFECT_RESULT_GAINED or changeType == EFFECT_RESULT_FULL_REFRESH then
        UGT.magmaArmorActive[unitTag] = {
            abilityId = abilityId,
            name      = effectName,
            endTime   = endTime,
        }
        UGT.Log(string.format("|cFF0000MAGMA ARMOR %s|r: [%d] %s on %s (%s)  ends=%.1f",
            changeName, abilityId, effectName or "?",
            unitTag, unitName or "?", endTime))

    elseif changeType == EFFECT_RESULT_FADED then
        UGT.magmaArmorActive[unitTag] = nil
        UGT.Log(string.format("|c00FF00MAGMA ARMOR FADED|r: [%d] %s on %s (%s)",
            abilityId, effectName or "?", unitTag, unitName or "?"))
    end
end

-- ---------------------------------------------------------------------------
-- Event: Power Update — track ultimate value changes on player
-- (Group members' ult is only visible on self unless using lib broadcast)
-- ---------------------------------------------------------------------------

function UGT.OnPowerUpdate(_, unitTag, powerIndex, powerType, powerValue, powerMax, powerEffectiveMax)
    if powerType ~= COMBAT_MECHANIC_FLAGS_ULTIMATE then return end
    if unitTag ~= "player" then return end

    -- We don't log every tick to avoid spam; this is used for
    -- confirming whether the player actually received the ult after a proc.
    -- The data is captured in snapshots instead.
end

-- ---------------------------------------------------------------------------
-- Slash Commands
-- ---------------------------------------------------------------------------

function UGT.SlashCommand(args)
    local cmd = args and zo_strlower(args) or ""

    if cmd == "status" or cmd == "" then
        UGT.Log("--- UltGrantTargeting Status ---")

        -- Player info
        local current, max = GetUnitPower("player", COMBAT_MECHANIC_FLAGS_ULTIMATE)
        UGT.Log(string.format("  Ultimate: %d / %d", current, max))
        UGT.Log("  In combat: " .. tostring(IsUnitInCombat("player")))

        -- Magma Armor state
        local magmaCount = 0
        for tag, info in pairs(UGT.magmaArmorActive) do
            magmaCount = magmaCount + 1
            local name = GetUnitName(tag) or "?"
            UGT.Log(string.format("  |cFF0000Magma Armor active|r: %s (%s) — [%d] %s",
                tag, name, info.abilityId, info.name))
        end
        if magmaCount == 0 then
            UGT.Log("  Magma Armor: |c00FF00none active|r")
        end

        -- Group snapshot
        local snapshot = UGT.GetGroupSnapshot()
        UGT.PrintGroupSnapshot(snapshot, "  Current group state")

        -- Session stats
        if UGT.savedVars and UGT.savedVars.sessions then
            local session = UGT.savedVars.sessions[#UGT.savedVars.sessions]
            if session then
                UGT.Log(string.format("  Session: %d procs, %d log entries",
                    #session.procs, #session.log))
            end
        end

        -- Discovery mode
        UGT.Log("  Discovery mode: " .. (UGT.discoveryMode and "|cFF00FFON|r" or "|c888888OFF|r"))
        UGT.Log("  LGCS: " .. (UGT.lgcs and "|c00FF00connected|r" or "|cFF4400not loaded|r"))

    elseif cmd == "snapshot" then
        local snapshot = UGT.GetGroupSnapshot()
        UGT.PrintGroupSnapshot(snapshot, "Manual snapshot")

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
        -- Dump all buffs on player to discover Magma Armor buff IDs
        UGT.DumpAllBuffs("player")

    elseif cmd == "scangroup" then
        -- Dump buffs on all group members
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
            UGT.Log("|cFF00FFDiscovery mode ON|r — logging ALL POWER_ENERGIZE events.")
            UGT.Log("Drink a potion with Arkasis equipped to find the proc ability ID.")
        else
            EVENT_MANAGER:UnregisterForEvent(UGT.name .. "_Discovery", EVENT_COMBAT_EVENT)
            UGT.Log("Discovery mode OFF.")
        end

    elseif cmd == "procs" then
        if not UGT.savedVars or not UGT.savedVars.sessions then
            UGT.Log("No data.")
            return
        end
        local session = UGT.savedVars.sessions[#UGT.savedVars.sessions]
        if not session or #session.procs == 0 then
            UGT.Log("No procs recorded this session.")
            return
        end
        UGT.Log(string.format("--- %d proc events this session ---", #session.procs))
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
            UGT.Log(string.format("  #%d (t=%.1f): %s  (+%d other targets)  snapshot=%d members",
                i, p.time, triggerStr, extraCount, #p.snapshot))
        end

    elseif cmd == "recent" then
        if #UGT.recentEnergizes == 0 then
            UGT.Log("No recent energize events.")
            return
        end
        UGT.Log(string.format("--- Last %d ult energize events ---", math.min(15, #UGT.recentEnergizes)))
        local start = math.max(1, #UGT.recentEnergizes - 14)
        for i = start, #UGT.recentEnergizes do
            local e = UGT.recentEnergizes[i]
            local setTag = e.isTrackedSet and (" [" .. e.setName .. "]") or ""
            UGT.Log(string.format("  [%d] %s  %s → %s  +%d%s",
                e.abilityId, e.abilityName, e.source, e.target, e.hitValue, setTag))
        end

    elseif cmd == "clear" then
        if UGT.savedVars then
            UGT.savedVars.sessions = {}
            UGT.StartSession()
        end
        UGT.recentEnergizes = {}
        UGT.magmaArmorActive = {}
        UGT.Log("Log cleared, session reset.")

    elseif cmd == "help" then
        UGT.Log("Commands: /ugt status | snapshot | scan | scangroup | discover | procs | recent | clear | help")
        UGT.Log("  status    — Current ult, group state, Magma Armor tracking")
        UGT.Log("  snapshot  — Manual group state snapshot to log")
        UGT.Log("  scan      — Dump all buffs on self (ID discovery)")
        UGT.Log("  scangroup — Dump all buffs on all group members")
        UGT.Log("  discover  — Toggle discovery mode (logs ALL energize events)")
        UGT.Log("  procs     — Show recent set proc events with snapshots")
        UGT.Log("  recent    — Show recent ult energize events")
        UGT.Log("  clear     — Wipe session data")

    else
        UGT.Log("Unknown command. Use /ugt help")
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
        })
    end
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

    UGT.savedVars = UltGrantTargetingLog or { sessions = {} }
    UltGrantTargetingLog = UGT.savedVars
    if not UGT.savedVars.sessions then
        UGT.savedVars.sessions = {}
    end
    UGT.StartSession()
    UGT.RebuildTrackedSetIDs()

    -- -------------------------------------------------------------------
    -- LibGroupCombatStats integration (optional)
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

    -- -------------------------------------------------------------------
    -- Effect changed on group members: track Magma Armor gain/fade
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
        UGT.Log("  |cFFFF00No set proc IDs configured yet.|r Use |c33CCFF/ugt discover|r to find them.")
    end
    UGT.Log("  Tracking Magma Armor IDs: 15957, 17874, 17878")
    if not UGT.lgcs then
        UGT.Log("  |cFFFF00LibGroupCombatStats not found|r — group ult values will show 0 in snapshots.")
    end
    UGT.Log("  Use |c33CCFF/ugt help|r for commands")
end

EVENT_MANAGER:RegisterForEvent(UGT.name, EVENT_ADD_ON_LOADED, UGT.OnAddonLoaded)
