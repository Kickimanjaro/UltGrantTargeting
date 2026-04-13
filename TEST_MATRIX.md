# UltGrantTargeting — Test Matrix

## Objective

Determine how the game selects targets for ultimate-granting set procs, and whether players that cannot gain ultimate (e.g., during Magma Armor) are skipped or receive (and waste) the grant.

## Sets Under Test

| Set | Effect | Targets | Stated Range | ICD |
|-----|--------|---------|-------------|-----|
| **Arkasis' Genius** | Drink potion in combat → you + 3 group members gain 42 ult | 3 (+ self) | Unknown | 30s |
| **Colovian Highlands General** | Kill a player → Blood Debt stacks for 0.5s → on expire, you + up to 5 group members gain 15 ult/stack | Up to 5 (+ self) | 28m | N/A |

## Blocking Ability

| Ability | Effect | Duration | IDs |
|---------|--------|----------|-----|
| **Magma Armor** (base) | Cannot gain ultimate | 10s | 15957 |
| **Magma Shell** (morph) | Cannot gain ultimate; shields nearby allies | 10s | 17874 |
| **Corrosive Armor** (morph) | Cannot gain ultimate; ignores resistances | 10s | 17878 |

## Prerequisites

- **PTS** environment with 2–4 accounts (yourself + alt + guildy + guildy alt)
- One character equipped with **Arkasis' Genius** (5-piece) and **tri-stat potions** with 3x Infused jewelry (potion cooldown reduction → 30s cycle)
- One character equipped with **Colovian Highlands General** (1-piece monster set + conditions for kills in Cyrodiil)
- At least one **Dragonknight** with Magma Armor or morph slotted
- A target dummy or PvE mobs to maintain combat state
- UltGrantTargeting addon loaded on all test characters (or at minimum, the set-wearer)

## Phase 0: Discovery — COMPLETE

Proc ability IDs have been discovered and configured:

| Set/Ability | Ability ID | Status |
|-------------|-----------|--------|
| Arkasis's Genius proc | 142660 | Configured |
| Colovian Highlands General proc | 202843 | Configured |
| Magma Armor | 15957 | Confirmed (buff = cast ID) |
| Magma Shell | 17874 | Confirmed (buff = cast ID) |
| Corrosive Armor | 17878 | Confirmed (buff = cast ID) |

---

## Phase A: Arkasis' Genius — Targeting Algorithm

**Players needed: 5 minimum.** Arkasis targets "you and 3 group members" = 4 total recipients. With only 4 in a group, all 3 non-caster members are always chosen — there is no selection to observe. You need 5+ so the set must choose 3 out of 4+ candidates.

**Setup**: Group of 5 players near a target dummy. Arkasis wearer (A) enters combat. B, C, D, E are the 4 candidates — the set must pick 3 and leave 1 out.

| # | Test | Players | Setup | Steps | Expected | Actual |
|---|------|---------|-------|-------|----------|--------|
| A1 | Baseline (equal ult, close) | 5 | All 5 within 5m, all at ~100 ult | Drink potion. Note which 3 of B/C/D/E receive +42. Repeat 5×. | Determines if selection is random, group-index-based, or consistent | |
| A2 | Ult variance | 5 | B: 0 ult, C: 100, D: 300, E: 500. All within 5m. | Drink potion. Repeat 5×. Who is left out each time? | If least-ult: E (highest) consistently left out | |
| A3 | Reversed ult variance | 5 | B: 500, C: 300, D: 100, E: 0. All within 5m. | Drink potion. Repeat 5×. | If least-ult: B consistently left out (confirms it's ult-based, not index-based) | |
| A4 | Distance variance | 5 | B: 5m, C: 10m, D: 20m, E: 40m. All similar ult. | Drink potion. Repeat 5×. Who is left out? | If proximity-based: E (farthest) left out | |
| A5 | Ult vs distance conflict | 5 | B: 500 ult at 5m. E: 0 ult at 40m. C, D mid-range/mid-ult. | Drink potion. Is B (close, high ult) or E (far, low ult) left out? | Determines which factor dominates | |
| A6 | Self always receives | 5 | Arkasis wearer (A) at 500 ult. B/C/D/E at 0. All close. | Drink potion. Does A receive +42 despite being highest? | Self always receives regardless | |

---

## Phase B: Arkasis' Genius — Range

**Players needed: 4.** With 4 players (caster + 3), all 3 non-caster members are candidates. If anyone is out of range, fewer than 3 energize events fire — clear signal.

**Setup**: Arkasis wearer stationary at a landmark. Group members at incremental distances.

| # | Test | Players | Setup | Steps | Expected | Actual |
|---|------|---------|-------|-------|----------|--------|
| B1 | All close | 4 | All 3 members within 10m | Drink potion. Count energize events. | 3 events (all receive) | |
| B2 | One far out | 4 | B: 5m, C: 15m, D: 100m | Drink potion. Does D receive? | If range-limited: only 2 events | |
| B3 | Incremental — find cutoff | 4 | B: 5m (control). C & D start at 20m, move outward 5m each trial. | Drink potion at each distance step. Find the distance where C/D stop receiving. | Identifies the range limit | |
| B4 | At 28m boundary | 4 | B: 5m. C: just under 28m. D: just over 28m. | Drink potion. Does C receive but D does not? | Tests if 28m (same as Colovian's stated range) applies | |
| B5 | No range limit check | 4 | B: 5m, C: 50m, D: 100m | Drink potion. Do all 3 receive? | If yes: Arkasis has no range limit | |

**Distance estimation**: Use `/ugt snapshot` on both the wearer and a target to record normalized map positions. In open zones (e.g., Alik'r), 28m ≈ a known reference distance (e.g., Rapid Maneuver buff radius). Use `IsUnitInGroupSupportRange(tag)` if available as a 28m ground truth.

---

## Phase C: Arkasis' Genius — Magma Armor Interaction

**Players needed: 4 minimum.** With 4 players (caster + 3 candidates), all 3 are always in the target pool. If a Magma Armor user is skipped, only 2 energize events fire (no replacement available). If they're targeted but the ult is wasted, 3 events still fire but the DK's ult doesn't change. This distinguishes the two scenarios.

**5 players** needed for C2/C3 to test whether the set replaces a skipped target with another eligible member.

**At least 1 DK required (2 DKs for C3).**

| # | Test | Players | Setup | Steps | Expected | Actual |
|---|------|---------|-------|-------|----------|--------|
| C1 | Magma Armor — targeted or skipped? | 4 (1 DK) | All within 5m. DK activates Magma Armor, Arkasis wearer drinks potion within 2s. | Count energize events. 3 events = DK was targeted (ult may be wasted). 2 events = DK was skipped. Check DK's actual ult change. | ??? (core question) | |
| C2 | Skip replacement | 5 (1 DK) | All within 5m. DK under Magma Armor. 4 non-caster candidates, set picks 3. | Drink potion. If DK is skipped, do all 3 remaining eligible members receive? Or does only 2 receive (slot wasted)? | If skip + replace: 3 events, none to DK. If skip + waste slot: 2 events. | |
| C3 | Two members under Magma Armor | 5 (2 DKs) | Both DKs activate Magma Armor. 4 candidates, 2 blocked. | Drink potion. How many energize events fire? | If skip + replace: 3 events (all to eligible). If skip + waste: 1 event. If targeted + wasted: 3 events. | |
| C4 | Timing — early in Magma Armor | 4 (1 DK) | DK casts Magma Armor, potion at ~1s into the 10s duration. | Same observation as C1 — count events, check DK ult. | Consistent with C1 | |
| C5 | Timing — late in Magma Armor | 4 (1 DK) | DK casts Magma Armor, potion at ~9s (just before fade). | Same observation as C1. | Consistent with C1 | |
| C6 | Just after Magma Armor fades | 4 (1 DK) | DK's Magma Armor fades. Drink potion within 1s of fade. | DK should receive ult normally now. 3 energize events. | 3 events, DK's ult increases | |
| C7 | Caster under own Magma Armor | 4 | Arkasis wearer is the DK. Cast Magma Armor, drink potion. | Does caster receive +42? Do the 3 group members still receive? Count events targeting caster vs others. | Caster may not gain ult, but group members should | |

---

## Phase D: Colovian Highlands General — Targeting & Interactions

**Location: Cyrodiil.** Colovian targets "you and up to 5 group members within 28 meters." With only 3 non-caster allies (4-person group), all are always within the 5-target cap — no selection to observe. Range and Magma Armor tests still work with 4 since out-of-range or blocked members reduce the energize count below 3.

**Players needed: 4 for most tests. 7+ for D4 (need 6+ non-caster candidates to exceed the 5-target cap). Need 1 enemy-faction character to kill.**

| # | Test | Players | Setup | Steps | Expected | Actual |
|---|------|---------|-------|-------|----------|--------|
| D1 | Baseline | 4 (+1 enemy) | All 3 group members within 28m of killer. Kill enemy player. | Count energize events. All 3 should receive 15 ult/stack. | 3 energize events (all non-caster members) | |
| D2 | 28m range — inside | 4 (+1 enemy) | B: 5m, C: 15m, D: 25m. Kill enemy. | All 3 receive? | All 3 receive (all within 28m) | |
| D3 | 28m range — one outside | 4 (+1 enemy) | B: 5m, C: 15m, D: 35m. Kill enemy. | Does D (beyond 28m) receive? | 2 events if D is out of range | |
| D4 | Magma Armor — targeted or skipped? | 4 (1 DK, +1 enemy) | All within 28m. DK activates Magma Armor. Kill enemy. | Count events. 3 = DK targeted (wasted?). 2 = DK skipped. | ??? | |
| D5 | Magma Armor — skip replacement | 7+ (1 DK, +1 enemy) | 6 non-caster candidates within 28m, 1 DK under Magma Armor. Kill enemy. Set can pick up to 5. | If DK skipped + replaced: 5 events, none to DK. If skipped + wasted: 4 events. If targeted: 5 events including DK. | Determines skip vs waste with overflow candidates | |
| D6 | Multi-stack | 4 (+2 enemies) | Both enemies low HP. Kill both within 0.5s to stack Blood Debt. | Do members receive 15 × (number of stacks)? E.g., 30 for 2 stacks. | 30 ult per target for 2 stacks | |

---

## Phase E: Edge Cases

**Players needed: 2 minimum (E1, E2, E4), 1 for E3**

| # | Test | Players | Setup | Steps | Expected | Actual |
|---|------|---------|-------|-------|----------|--------|
| E1 | Dead group member | 2 | One member dead within range. Arkasis potion. | Does dead member receive ult? | Probably not | |
| E2 | Offline/zoned member | 2 | One member in a different zone. Arkasis potion. | Skipped (out of range)? | Skipped | |
| E3 | Solo (no group) | 1 | Arkasis wearer not in a group. Drink potion in combat. | Self gains +42? No group targets? | Self receives, no errors | |
| E4 | Alliance War ult lock | 2 (+1 enemy) | If player recently died in Cyrodiil and has ult reset to 0 with lock. | Does the lock prevent Arkasis ult gain? | Possibly blocked | |

---

## Data Analysis

After each test phase:

1. `/ugt procs` — review recent proc events in chat
2. `/ugt recent` — check all ult energize events
3. Log out to flush SavedVariables to disk
4. Open `UltGrantTargetingLog.lua` saved variable file
5. For each proc entry, examine:
   - `trigger.target` — who was the first logged target
   - `additionalTargets` — who else received ult in the same proc
   - `snapshot` — group state at time of proc (ult levels, positions, Magma Armor status)
6. Cross-reference target list against snapshot to determine: were closest members chosen? Lowest ult? Random? Did Magma Armor members appear in target list?

## Notes

- Potion cooldown with 3× Infused jewelry = 30s, matching Arkasis ICD. One test per 30s.
- PTS allows easy testing of PvP sets since all participants can port to Cyrodiil.
- `GetMapPlayerPosition` returns normalized (0–1) coordinates. Distance values are relative within a zone; absolute meter calibration requires a known reference (e.g., Rapid Maneuver 28m radius, or counting tiles on a keep floor).
- The addon only sees ult values for the player character. Group members' ult values in snapshots will show 0 unless the group member also has this addon or LibGroupCombatStats broadcasting. **Recommendation**: Have all test participants run the addon and compare their own logs.
