# UltGrantTargeting — Test Matrix

## Objective

Determine how the game selects targets for ultimate-granting set procs, and whether players that cannot gain ultimate (e.g., during Magma Armor) are skipped or receive (and waste) the ultimate grant.

## Sets Under Test

| Set | Set Description | Targets | Range | ICD |
|-----|----------------|---------|-------------|-----|
| **Arkasis' Genius** | Drink potion in combat → you + 3 group members gain 44 ult | 3 (+ self) | Unknown | 30s |
| **Colovian Highlands General** | Kill a player → Blood Debt stacks for 0.5s → on expire, you + up to 5 group members gain 15 ult/stack | Up to 5 (+ self) | 28m | N/A |
| **Cryptcannon Vestments** | Replaces ult with Crypt Transfer: consume all ult, distribute to nearby group members | Group (nearby) | Unknown | 5s |

## Ult Blocking Ability
The following two abilities are known to prevent the activator from gaining ult for their duration.
- **Magma Armor** (and morphs Magma Shell, Corrosive Armor) for 10s
- **Bone Goliath Transformation** (and morphs Pummeling Goliath, Ravenous Goliath)  for 20s

## Prerequisites

- **PTS** environment
- A target dummy or PvE mobs to maintain combat state
- UltGrantTargeting addon loaded on the tester; all participants should have LibGroupBroadcast + LibGroupCombatStats installed so the addon can read everyone's ult values in snapshots

---

## Arkasis' Genius

### Targeting

**Players needed: 5 minimum.** Arkasis targets "you and 3 group members" = 4 total recipients. With only 4 in a group, all 3 non-caster members are always chosen — there is no selection to observe. You need 5+ so the set must choose 3 out of 4+ candidates.

**Setup**: Group of 5 players near a target dummy. Arkasis wearer (A) enters combat. B, C, D, E are the 4 candidates — the set must pick 3 and leave 1 out.

| # | Test | Players | Setup | Steps | Expected | Actual |
|---|------|---------|-------|-------|----------|--------|
| A1 | Baseline (equal ult, close) | 5 | All 5 within 5m, all at ~100 ult | Drink potion. Note which 3 of B/C/D/E receive +44. Repeat 5×. | Determines if selection is random, group-index-based, or consistent | |
| A2 | Ult variance | 5 | B: 0 ult, C: 100, D: 300, E: 500. All within 5m. | Drink potion. Repeat 5×. Who is left out each time? | If least-ult: E (highest) consistently left out | |
| A3 | Reversed ult variance | 5 | B: 500, C: 300, D: 100, E: 0. All within 5m. | Drink potion. Repeat 5×. | If least-ult: B consistently left out (confirms it's ult-based, not index-based) | |
| A4 | Distance variance | 5 | B: 5m, C: 10m, D: 20m, E: 40m. All similar ult. | Drink potion. Repeat 5×. Who is left out? | If proximity-based: E (farthest) left out | |
| A5 | Ult vs distance conflict | 5 | B: 500 ult at 5m. E: 0 ult at 40m. C, D mid-range/mid-ult. | Drink potion. Is B (close, high ult) or E (far, low ult) left out? | Determines which factor dominates | |
| A6 | Self always receives | 5 | Arkasis wearer (A) at 500 ult. B/C/D/E at 0. All close. | Drink potion. Does A receive +44 despite being highest? | Self always receives regardless | |

### Range

**Players needed: 4.** With 4 players (caster + 3), all 3 non-caster members are candidates. If anyone is out of range, fewer than 3 energize events fire — clear signal.

**Setup**: Arkasis wearer stationary at a landmark. Group members at incremental distances.

| # | Test | Players | Setup | Steps | Expected | Actual |
|---|------|---------|-------|-------|----------|--------|
| B1 | All close | 4 | All 3 members within 10m | Drink potion. Count energize events. | 3 events (all receive) | |
| B2 | One far out | 4 | B: 5m, C: 15m, D: 100m | Drink potion. Does D receive? | If range-limited: only 2 events | |
| B3 | Incremental — find cutoff | 4 | B: 5m (control). C & D start at 20m, move outward 5m each trial. | Drink potion at each distance step. Find the distance where C/D stop receiving. | Identifies the range limit | |
| B4 | At 28m boundary | 4 | B: 5m. C: just under 28m. D: just over 28m. | Drink potion. Does C receive but D does not? | Tests if 28m (same as Colovian's stated range) applies | |
| B5 | No range limit check | 4 | B: 5m, C: 50m, D: 100m | Drink potion. Do all 3 receive? | If yes: Arkasis has no range limit | |

**Distance estimation**: Use `/ugt snapshot` to record normalized map positions. In open zones, 28m ≈ Rapid Maneuver buff radius.

### Interaction with Ult Blocking Abilities

**Players needed: 4 minimum.** With 4 players (caster + 3 candidates), all 3 are always in the target pool. If a Magma Armor user is skipped, only 2 energize events fire (no replacement available). If they're targeted but the ult is wasted, 3 events still fire but the blocked player's ult doesn't change. This distinguishes the two scenarios.

**5 players** needed for C2/C3 to test whether the set replaces a skipped target with another eligible member.

| # | Test | Players | Setup | Steps | Expected | Actual |
|---|------|---------|-------|-------|----------|--------|
| C1 | Magma Armor — targeted or skipped? | 4 | All within 5m. One player activates Magma Armor, Arkasis wearer drinks potion within 2s. **Ensure no one is at max ult** (see Notes). | Count energize events. 3 events = targeted (ult may be wasted). 2 events = skipped. Check blocked player's actual ult change. | ??? (core question) | |
| C2 | Skip replacement | 5 | All within 5m. One player under Magma Armor. 4 non-caster candidates, set picks 3. | Drink potion. If blocked player is skipped, do all 3 remaining eligible members receive? Or only 2 (slot wasted)? | If skip + replace: 3 events, none to blocked. If skip + waste slot: 2 events. | |
| C3 | Two members under Magma Armor | 5 | Two players activate Magma Armor. 4 candidates, 2 blocked. | Drink potion. How many energize events fire? | If skip + replace: 3 events (all to eligible). If skip + waste: 1 event. If targeted + wasted: 3 events. | |
| C4 | Timing — early in Magma Armor | 4 | Player casts Magma Armor, potion at ~1s into the 10s duration. | Same observation as C1 — count events, check ult. | Consistent with C1 | |
| C5 | Timing — late in Magma Armor | 4 | Player casts Magma Armor, potion at ~9s (just before fade). | Same observation as C1. | Consistent with C1 | |
| C6 | Just after Magma Armor fades | 4 | Player's Magma Armor fades. Drink potion within 1s of fade. | Player should receive ult normally. 3 energize events. | 3 events, ult increases | |
| C7 | Caster under own Magma Armor | 4 | Arkasis wearer activates own Magma Armor, drinks potion. | Does caster receive +44? Do the 3 group members still receive? | Caster may not gain ult, but group members should | |

---

## Colovian Highlands General

### Targeting

**Location: Cyrodiil.** Colovian targets "you and up to 5 group members within 28 meters." With only 3 non-caster allies (4-person group), all are always within the 5-target cap — no selection to observe. Range tests still work with 4 since out-of-range members reduce the energize count below 3.

**Players needed: 4 for most tests. 7+ for D3 (need 6+ non-caster candidates to exceed the 5-target cap). Need 1 enemy-faction character to kill.**

| # | Test | Players | Setup | Steps | Expected | Actual |
|---|------|---------|-------|-------|----------|--------|
| D1 | Baseline | 4 (+1 enemy) | All 3 group members within 28m of killer. Kill enemy player. | Count energize events. All 3 should receive 15 ult/stack. | 3 energize events | |
| D2 | 28m range — one outside | 4 (+1 enemy) | B: 5m, C: 15m, D: 35m. Kill enemy. | Does D (beyond 28m) receive? | 2 events if D is out of range | |
| D3 | Multi-stack | 4 (+2 enemies) | Both enemies low HP. Kill both within 0.5s to stack Blood Debt. | Do members receive 15 × (number of stacks)? E.g., 30 for 2 stacks. | 30 ult per target for 2 stacks | |

### Interaction with Ult Blocking Abilities

**Players needed: 4 for most tests. 7+ for D5.**

| # | Test | Players | Setup | Steps | Expected | Actual |
|---|------|---------|-------|-------|----------|--------|
| D4 | Magma Armor — targeted or skipped? | 4 (+1 enemy) | All within 28m. One player under Magma Armor. Kill enemy. | Count events. 3 = targeted (wasted?). 2 = skipped. | ??? | |
| D5 | Magma Armor — skip replacement | 7+ (+1 enemy) | 6 non-caster candidates within 28m, 1 under Magma Armor. Kill enemy. Set can pick up to 5. | If skipped + replaced: 5 events, none to blocked. If skipped + wasted: 4 events. If targeted: 5 events including blocked. | Determines skip vs waste with overflow candidates | |

---

## Cryptcannon Vestments

### Targeting

**Cryptcannon Vestments** replaces your ultimate with **Crypt Transfer** (ability ID 195031): activating it consumes all your ultimate and distributes it to nearby group members. Unlike Arkasis/Colovian, the ult transfer amount is variable (depends on how much ult you had). The key questions: how are targets selected, what's the range, and is total ult conserved?

**Players needed: 4 for most tests. 5+ for E3.**

| # | Test | Players | Setup | Steps | Expected | Actual |
|---|------|---------|-------|-------|----------|--------|
| E1 | Baseline — distribution pattern | 4 | All within 5m. Caster at 500 ult. | Activate Crypt Transfer. How much ult does each member receive? Is it split evenly (500/3 ≈ 166 each)? | Even split among eligible members | |
| E2 | Partial ult | 4 | All within 5m. Caster at 200 ult. | Activate Crypt Transfer. How much does each receive? (200/3 ≈ 66?) | Proportional to consumed ult | |
| E3 | Target cap | 5+ | All within 5m. Caster at 500 ult. 4+ candidates. | Activate Crypt Transfer. Does everyone receive, or is there a target cap? | Determines if there's a max target count | |
| E4 | Range test | 4 | B: 5m, C: 30m, D: 60m. Caster at 500 ult. | Activate Crypt Transfer. Who receives? | Find range cutoff | |

### Interaction with Ult Blocking Abilities

**Players needed: 4.**

| # | Test | Players | Setup | Steps | Expected | Actual |
|---|------|---------|-------|-------|----------|--------|
| E5 | Magma Armor — targeted or skipped? | 4 | All within 5m. One member under Magma Armor. Caster at 500 ult. | Activate Crypt Transfer. Count recipients. Does blocked member receive (wasted) or get skipped? | ??? | |
| E6 | Magma Armor — redistribution | 4 | All within 5m. One member under Magma Armor. Caster at 500 ult. | If blocked member is skipped, is their share redistributed (250 each to 2) or lost (166 each to 2)? | Determines if total ult is conserved | |
| E7 | Self under Magma Armor | 4 | Caster is under own Magma Armor with 500 ult. | Attempt to activate Crypt Transfer. | May be blocked entirely since Magma Armor replaces ult bar | |

---

## Edge Cases

### Interactions with Dead Players

Dead players cannot gain ultimate, but the question is whether the game counts them as eligible targets — potentially wasting a target slot — or skips them entirely.

**Players needed: 5 for F1. 4 for F2.**

| # | Test | Players | Setup | Steps | Expected | Actual |
|---|------|---------|-------|-------|----------|--------|
| F1 | Dead member — Arkasis (slot wasted?) | 5 | All within 5m. One of the 4 candidates is dead. Arkasis wearer drinks potion. | Count energize events to living players. 3 events = dead player skipped (all living candidates received). 2 events = dead player consumed a slot. | ??? | |
| F2 | Dead member — Cryptcannon (share lost?) | 4 | All within 5m. One member dead. Caster at 500 ult. Activate Crypt Transfer. | How much ult do the 2 living members receive? 250 each = dead skipped, ult redistributed. ~166 each = dead player counted, share lost. | ??? | |

---

## Data Analysis

After each test:

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

- **Max-ult suppression**: When a player is already at max ultimate, the game does not fire an energize event at all — it doesn't send a "wasted" event with 0 gain. This means event counting is unreliable if any candidate is at ult cap: they'll look like they were skipped even if they were targeted. **Ensure test participants are not at max ult** when running any event-counting test (Magma Armor, dead player, etc.).
- `GetMapPlayerPosition` returns normalized (0–1) coordinates. Distance values are relative within a zone; absolute meter calibration requires a known reference (e.g., Rapid Maneuver 28m radius).
- The addon integrates with LibGroupCombatStats (via LibGroupBroadcast) to read group members' actual ult values in snapshots. All participants should have LGB+LGCS installed for this to work.
