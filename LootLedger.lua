--[[
LootLedger v1.3.0

A gold/hour and loot tracker for vanilla WoW 1.12. Tracking runs
continuously in the background - kills and loot are valued automatically
(vendor price or Aux auction data, whichever is higher) and rolled into
a live gold/hour rate, alongside a persistent per-mob loot history in a
window styled after RuneLite's OSRS Loot Tracker.

/ll opens the tracker window. /ll help lists every command. See README.md
for full usage and implementation notes.
--]]

-- One-time migration from the addon's old name (FarmTrack). The .toc
-- still lists FarmTrackDB as a SavedVariable too, purely so the client
-- loads the user's existing history under the old global name long
-- enough for this to copy it over - safe to drop both this block and
-- that .toc line in a later release once migration has run once.
if not LootLedgerDB and FarmTrackDB then
    LootLedgerDB = FarmTrackDB
end

LootLedgerDB = LootLedgerDB or { sessions = {} }

-- Tracking is always-on: StartSession(true) runs at file load and again
-- automatically every time StopSession runs, so `session` is essentially
-- always non-nil in practice - it's declared nil here only as the
-- pre-load default.
local session = nil

-- This client (SuperWoW) fires UNIT_HEALTH once per "alias" a unit
-- currently has - a plain token like "target"/"mouseover"/"nameplateN",
-- plus separately its real GUID as arg1. A mob's death is detected via
-- any alias going UnitIsDead()==true; UnitExists(arg1) resolves whichever
-- alias fired to the same real GUID, so dedup happens on that GUID
-- (handledDeaths).
--
-- Ownership (was it actually the player's kill, not some other nearby
-- player's?) is checked via UnitIsTappedByPlayer - the standard vanilla
-- flag that grays out a mob's health bar once someone else has loot
-- rights on it. It's not checked synchronously at the death event though:
-- on a fast kill, that flag can still read nil for a moment after death,
-- since it's a separate data field from health that lags slightly behind.
-- So a death is queued as a *pending* kill and re-checked a moment later
-- (see pendingKills / PENDING_KILL_DELAY below), once the tap flag has
-- had time to arrive.
local handledDeaths = {} -- [guid] = true, once that GUID's death has been queued (prevents re-queueing from duplicate alias events)
local pendingKills = {} -- array of { guid, name, level, deathTime } awaiting tap confirmation
local PENDING_KILL_DELAY = 1.0 -- seconds to wait for UnitIsTappedByPlayer to catch up before deciding

-- When true, print raw diagnostic info on every UNIT_HEALTH event,
-- regardless of whether a session is active. Toggle with /ll debugkill.
local debugKillTracking = false

-- Loot tracker window state, forward-declared here (rather than down by
-- CreateLootWindow) because RecordMobKillForDrops/RecordMobLootItem/
-- RecordMobMoney - defined further up the file, before the window itself
-- exists - need to call RefreshLootWindow as an upvalue when the window is
-- open, for live updates while you farm. RefreshLootWindow is assigned
-- its actual function value down in the window section; nil until then.
local lootWindow -- the main frame, created lazily on first /ll drops
local lootScrollFrame
local lootContent
local lootSummaryText
local lootSummaryText2
local lootModeButtons = {}
local lootViewMode = "alltime" -- "alltime" or "session"
local lootWindowCompact = false -- true = shrunk to just Time/Gold/hr/Kills/hr
local lootSortMode = "recent" -- "recent" or "value" - which order mob sections list in
local RefreshLootWindow
local ToggleOptionsWindow -- assigned down in the Options window section
local RefreshOptionsWindow -- likewise - FilterItem needs to call this if that window happens to already be open
local ToggleHistoryWindow -- assigned down in the History window section
local RefreshHistoryWindow -- likewise - DeleteHistoryEntry needs it if that window happens to already be open

-- ---------------------------------------------------------------------
-- Helpers
-- ---------------------------------------------------------------------

local function Print(msg)
    DEFAULT_CHAT_FRAME:AddMessage("|cffa335eeLootLedger:|r " .. msg)
end

-- Items that should never be tracked at all, by anyone, regardless of who
-- loots them. Matched by name rather than itemID since that's what
-- GetItemInfo reliably resolves. Soul Shard has no resale value and just
-- clutters the list - it's not excluded for lack of a price, it's
-- excluded because a Warlock reagent has nothing to do with gold/hour.
local EXCLUDED_ITEM_NAMES = {
    ["Soul Shard"] = true,
}

-- ---------------------------------------------------------------------
-- Item identity - itemID + random suffix
-- ---------------------------------------------------------------------
--
-- A randomly-enchanted item ("Combat Boots of the Boar") shares an
-- itemID with the base item and every OTHER suffix roll of it
-- ("...of the Bear", "...of the Whale", etc) - GetItemInfo(itemID)
-- alone always resolves to the base, unsuffixed item, and Aux's own AH
-- price history is keyed by itemID+suffix (aux-addon/util/info.lua
-- M.item_key: item_id .. ':' .. suffix_id), not itemID alone, since
-- different rolls are genuinely different auctionable items with very
-- different values (an "of the Whale" and an "of the Boar" of the same
-- base boots are worth nothing alike). Every loot record in this file
-- is keyed by that same "itemID:suffixID" string - an itemKey - instead
-- of a bare itemID, so different rolls get tracked (and priced)
-- separately. suffixID is 0 for the overwhelmingly common case of an
-- item with no random property at all, so most keys look like "6522:0".

-- Vanilla's link field order is item:itemID:enchantID:suffixID:uniqueID
-- [...]. Loose match (no color-code/|H prefix required) rather than
-- anchoring the whole |c...|H...|h pattern - same looseness the
-- original single-itemID extraction already relied on. The bracketed
-- display name is pulled straight from the chat text too, rather than
-- re-resolved via GetItemInfo - it's already the correct suffixed name
-- the client itself generated, and doesn't depend on GetItemInfo having
-- this exact suffix combination cached yet.
local function ParseItemLink(text)
    local _, _, itemID, suffixID = string.find(text, "item:(%d+):%d+:(%d+)")
    if not itemID then return nil end
    local _, _, name = string.find(text, "%[(.-)%]")
    return tonumber(itemID), tonumber(suffixID) or 0, name
end

local function BuildItemKey(itemID, suffixID)
    return tostring(itemID) .. ":" .. tostring(suffixID or 0)
end

-- Pre-migration data (or a stray bare itemID passed in from somewhere)
-- falls back to suffix 0 - see MigrateItemKeys further down for the
-- SavedVariables side of this same fallback.
local function SplitItemKey(itemKey)
    local s = tostring(itemKey)
    local _, _, itemID, suffixID = string.find(s, "^(%d+):(%d+)$")
    if not itemID then return tonumber(s) or 0, 0 end
    return tonumber(itemID), tonumber(suffixID)
end

-- The itemstring GetItemInfo needs to resolve a suffixed item
-- correctly - mirrors aux-addon's own util/info.lua M.item() pattern
-- (enchant/unique zeroed; only itemID+suffixID affect name/stats/
-- price/texture).
local function ItemStringForKey(itemKey)
    local itemID, suffixID = SplitItemKey(itemKey)
    return "item:" .. itemID .. ":0:" .. suffixID .. ":0"
end

-- User-added items (right-click an item icon -> Filter This Item),
-- persisted so they stay filtered across sessions. Same treatment as
-- EXCLUDED_ITEM_NAMES above - never recorded going forward, and hidden
-- retroactively from existing history at render time.
local function IsExcludedItem(itemKey)
    if LootLedgerDB and LootLedgerDB.filteredItems and LootLedgerDB.filteredItems[itemKey] then
        return true
    end
    local name = GetItemInfo(ItemStringForKey(itemKey))
    return name and EXCLUDED_ITEM_NAMES[name]
end

local function FormatGold(copper)
    if not copper then return "unknown" end
    if copper < 0 then copper = 0 end
    local g = math.floor(copper / 10000)
    local remainder1 = copper - (g * 10000)
    local s = math.floor(remainder1 / 100)
    local c = math.floor(remainder1 - (s * 100))
    return string.format("%dg %ds %dc", g, s, c)
end

-- Compact one-denomination version for the small icon-badge label (no
-- room for the full "Xg Ys Zc" there) - shows the largest denomination
-- present so a coin drop is still readable at a glance.
local function FormatGoldShort(copper)
    if not copper or copper <= 0 then return "0c" end
    local g = math.floor(copper / 10000)
    if g > 0 then return g .. "g" end
    local s = math.floor(copper / 100)
    if s > 0 then return s .. "s" end
    return math.floor(copper) .. "c"
end

-- Reads Aux's SavedVariables for the latest known AH price of an item.
-- Returns price in copper, or nil if no data found.
-- Replicates Aux's own "Value" calculation (aux-addon/core/history.lua,
-- M.value/weighted_median) rather than approximating it - a flat average
-- of recent price points reads close to Aux's own number but isn't exact.
-- Each stored price point is weighted by 0.99^(days older than the newest
-- point), then sorted by price - the value where cumulative weight first
-- crosses 50% is the median. Falls back to daily_min_buyout (today's
-- not-yet-pushed low) when there's no history yet, same as Aux does.
--
-- Looks up factionData.history[itemKey] directly - itemKey already
-- matches Aux's own item_key format exactly (see the item-identity
-- section above), so this is a real key match, not a prefix guess. A
-- prefix scan on the bare itemID (the old approach here) would actually
-- match EVERY suffix variant's entry ("6522:0", "6522:867", "6522:900"
-- all start with "6522:"), silently returning whichever one pairs()
-- happened to enumerate first - an exact key is both correct and O(1).
local function GetAuxPrice(itemKey)
    if not aux or not aux.faction then
        return nil
    end
    local realm = GetRealmName()
    local faction = UnitFactionGroup("player")
    local key = realm .. "|" .. faction
    local factionData = aux.faction[key]
    if not factionData or not factionData.history then
        return nil
    end

    local valstr = factionData.history[itemKey]
    if not valstr then
        return nil
    end

    -- format: "next_push#daily_min_buyout#price@ts;price@ts;..."
    local _, _, mainTS, mainPrice, rest = string.find(valstr, "^(%d+)#([%d%.]*)#?(.*)$")
    mainPrice = tonumber(mainPrice)

    local points = {}
    local remaining = rest
    while remaining and remaining ~= "" do
        local _, e, p, t = string.find(remaining, "^([%d%.]+)@(%d+)")
        if not p then break end
        table.insert(points, { price = tonumber(p), ts = tonumber(t) })
        remaining = string.sub(remaining, e + 1)
        if string.sub(remaining, 1, 1) == ";" then
            remaining = string.sub(remaining, 2)
        else
            break
        end
    end

    if table.getn(points) == 0 then
        return mainPrice
    end

    -- Aux inserts new points at index 1, so points[1] is newest -
    -- but our parse order isn't guaranteed to preserve that, so
    -- find the newest timestamp explicitly rather than assume it.
    local newestTS = points[1].ts
    for i = 2, table.getn(points) do
        if points[i].ts > newestTS then
            newestTS = points[i].ts
        end
    end

    local totalWeight = 0
    for i = 1, table.getn(points) do
        local days = math.floor((newestTS - points[i].ts) / 86400 + 0.5)
        points[i].weight = 0.99 ^ days
        totalWeight = totalWeight + points[i].weight
    end
    for i = 1, table.getn(points) do
        points[i].weight = points[i].weight / totalWeight
    end

    table.sort(points, function(a, b) return a.price < b.price end)
    local cum = 0
    for i = 1, table.getn(points) do
        cum = cum + points[i].weight
        if cum >= 0.5 then
            return points[i].price
        end
    end
    return points[table.getn(points)].price
end

-- Extracts a copper total out of a chat message containing amounts like
-- "70 Gold, 2 Silver, 3 Copper" (denominations are omitted when zero, so
-- each is matched independently). Returns nil if no money text found.
local function ParseMoneyFromText(text)
    local copper = nil
    local _, _, g = string.find(text, "(%d+) Gold")
    if g then copper = (copper or 0) + tonumber(g) * 10000 end
    local _, _, s = string.find(text, "(%d+) Silver")
    if s then copper = (copper or 0) + tonumber(s) * 100 end
    local _, _, c = string.find(text, "(%d+) Copper")
    if c then copper = (copper or 0) + tonumber(c) end
    return copper
end

-- Expected disenchant value, using Aux's own real vanilla DE-yield data
-- and pricing (aux-addon/core/disenchant.lua) rather than a hand-built
-- table here - Aux already gets this right for its own tooltip's
-- "Disenchant: X" line, so this reuses the exact same calculation
-- instead of re-deriving it. `require`/`module` are plain globals Aux's
-- own package.lua defines (see libs/package.lua) - any addon loaded
-- after Aux can call them the same way Aux's own files do internally.
-- Only meaningful for armor/weapons above a certain quality, so nil
-- (not zero) for anything else - handled the same as "no price data"
-- by GetBestPrice below.
local function GetDisenchantValue(itemKey)
    if not require then return nil end
    local ok, mod = pcall(require, "aux.core.disenchant")
    if not ok or not mod or not mod.value then return nil end
    -- Mirrors aux-addon's own util/info.lua item() destructure exactly
    -- (name, itemstring, quality, level, class, subclass, max_stack,
    -- slot, texture) - disenchant.value's level/slot arguments need to
    -- line up with however this client's GetItemInfo actually orders its
    -- return values, and Aux's own code is the proven-correct reference
    -- for that, rather than reusing GetBestPrice's own destructuring
    -- below (worked out for a different field - sellPrice - and not
    -- guaranteed to line up the same way for these ones).
    local itemID = SplitItemKey(itemKey)
    local name, itemstring, quality, level, class, subclass, max_stack, slot, texture = GetItemInfo(ItemStringForKey(itemKey))
    if not name then return nil end
    -- DE yield only depends on the base item's slot/quality/level, never
    -- the random suffix, so the plain itemID (not the full itemKey) is
    -- the right 4th argument here - matches what mod.value actually
    -- expects (see aux-addon/core/disenchant.lua).
    local ok2, value = pcall(mod.value, slot, quality, level, itemID)
    if not ok2 then return nil end
    return value
end

-- Returns the best known price (copper) for an item: max(vendor sell, Aux
-- AH, and - if enabled in Options - expected disenchant value). Also
-- returns which source was used, for display purposes.
--
-- GetItemInfo on this client returns 10 values, not vanilla's standard 11
-- - it never returns minLevel, so every field from there onward is
-- shifted one position early. Dropping the minLevel placeholder from the
-- destructuring below realigns everything correctly.
local function GetBestPrice(itemKey)
    local name, link, quality, ilvl, itype, isub, stack, equip, texture, sellPrice = GetItemInfo(ItemStringForKey(itemKey))
    local auxPrice = GetAuxPrice(itemKey)

    sellPrice = sellPrice or 0
    auxPrice = auxPrice or 0

    local best, source = 0, "unknown"
    if sellPrice > best then best, source = sellPrice, "vendor" end
    if auxPrice > best then best, source = auxPrice, "AH" end

    if LootLedgerDB and LootLedgerDB.useDisenchantValue then
        local deValue = GetDisenchantValue(itemKey)
        if deValue and deValue > best then
            best, source = deValue, "DE"
        end
    end

    if best > 0 then
        return best, source
    end
    return nil, "unknown"
end

-- ---------------------------------------------------------------------
-- Session control
-- ---------------------------------------------------------------------

-- silent=true skips the chat message - used for the auto-restart after
-- Restart Session, so tracking is continuous without spamming "session
-- started" every time. startTime uses time() (real-world wall clock), not
-- GetTime() (seconds since this client process launched), since the
-- session persists into LootLedgerDB.currentSession and gets restored
-- across logout/reload (see the bottom of this file) - it needs a clock
-- that keeps counting correctly across a relog instead of resetting to
-- ~0 with a new client.
local function StartSession(silent)
    session = {
        startTime = time(),
        kills = 0,
        unattributedKills = 0, -- death messages with no parseable mob name
        mobKills = {}, -- [name] or [name..":"..level] = { name = ..., level = ..., count = N }
        loot = {}, -- [itemKey ("itemID:suffixID")] = { name = ..., link = ..., count = N }
        moneyLooted = 0, -- copper, from CHAT_MSG_MONEY
        corpseOwner = {}, -- [guid] = mobName (level-agnostic), for attributing loot to the mob that dropped it
        mobLoot = {}, -- [mobName] = { kills, moneyLooted, items = { [itemKey] = { name, count } } } - session-scoped mirror of LootLedgerDB.mobLoot, for the loot tracker window's "this session" view
        lastResolvedCorpse = nil, -- { name, time } - most recent successful target->corpseOwner match, used as a short-lived fallback (see ResolveLootOwner)
        lastKilledMob = nil, -- { name, time } - most recent confirmed kill of any tracked mob, used as a longer-lived raid-loot fallback (see ResolveLootOwner)
    }
    -- session IS LootLedgerDB.currentSession (same table, not a copy) so
    -- every mutation anywhere in this file (session.kills = ..., a new
    -- session.mobLoot[x] entry, etc.) is automatically saved - the client
    -- flushes SavedVariables on logout/reload with no extra work needed.
    LootLedgerDB = LootLedgerDB or { sessions = {} }
    LootLedgerDB.currentSession = session
    if not silent then
        Print("Session reset. Go kill things.")
    end
end

-- ---------------------------------------------------------------------
-- Persistent per-mob drop tracking (LootLedgerDB.mobLoot) - RuneLite loot
-- tracker style: a running history of every mob killed and everything
-- gotten from it, kept by mob NAME only (not level - a Defias Cutpurse's
-- drop table doesn't meaningfully differ by level variant).
-- ---------------------------------------------------------------------

-- Only ever called from RecordMobKillForDrops/RecordMobLootItem/
-- RecordMobMoney (each triggered by real activity on this mob), so
-- bumping lastUpdate here - on every call, not just first creation - is a
-- correct "most recently active" timestamp, used to sort the loot window
-- by recency instead of value (value sorting reads as an arbitrary tie
-- order once several mobs all show 0g because their drops have no vendor
-- or Aux price on record - e.g. Molten Core content with no AH history).
local function EnsureMobLootRecord(mobName)
    LootLedgerDB = LootLedgerDB or { sessions = {} }
    LootLedgerDB.mobLoot = LootLedgerDB.mobLoot or {}
    local rec = LootLedgerDB.mobLoot[mobName]
    if not rec then
        rec = { kills = 0, moneyLooted = 0, items = {} }
        LootLedgerDB.mobLoot[mobName] = rec
    end
    rec.lastUpdate = time()
    return rec
end

-- Same shape as LootLedgerDB.mobLoot[mobName], but scoped to the current
-- session only - lets the loot tracker window show "this session" figures
-- alongside the persistent "all time" ones. Returns nil if no session.
local function EnsureSessionMobLootRecord(mobName)
    if not session then return nil end
    session.mobLoot = session.mobLoot or {}
    local rec = session.mobLoot[mobName]
    if not rec then
        rec = { kills = 0, moneyLooted = 0, items = {} }
        session.mobLoot[mobName] = rec
    end
    rec.lastUpdate = time()
    return rec
end

-- Live-updates the loot tracker window if it's currently open, so figures
-- move while you farm instead of only on next open. RefreshLootWindow is
-- nil until the window section below assigns it (harmless no-op until
-- the window's been opened at least once).
local function MaybeRefreshLootWindow()
    -- Skip the (relatively expensive) full per-mob rebuild while the
    -- window is collapsed to its compact Time/Gold-hr/Kills-hr view -
    -- nothing that view shows depends on it, and it's about to be rebuilt
    -- anyway the moment the window expands again.
    if lootWindow and lootWindow:IsShown() and not lootWindowCompact and RefreshLootWindow then
        RefreshLootWindow()
    end
end

-- Wipes a single mob's tracked loot from BOTH the persistent (All Time)
-- and session-scoped (This Session) stores, since the window shows one
-- name/entry regardless of which tab is active - a partial reset (only
-- one store) would be confusing to look at right after.
local function ResetMobLoot(mobName)
    if LootLedgerDB and LootLedgerDB.mobLoot then
        LootLedgerDB.mobLoot[mobName] = nil
    end
    if session and session.mobLoot then
        session.mobLoot[mobName] = nil
    end
    MaybeRefreshLootWindow()
end

local function ResetAllLoot()
    if LootLedgerDB then
        LootLedgerDB.mobLoot = {}
    end
    -- A full StartSession, not just clearing session.mobLoot - now that
    -- the session persists across logout (see the load-time restore
    -- logic near the bottom of this file), only relying on relogin to
    -- also clear session.kills/moneyLooted/startTime is no longer
    -- correct - Reset All needs to restart the clock itself.
    StartSession(true)
    MaybeRefreshLootWindow()
end

local STICKY_CORPSE_WINDOW = 1.5 -- seconds a resolved corpse stays usable as a fallback for the next loot/money event that can't resolve target itself

-- In a raid, target-matching essentially never succeeds: multi-mob pulls,
-- boss loot with roll/assign delays, and master loot all mean the
-- player's live target has usually moved on by the time a delayed "Your
-- share of the loot"/"You receive loot" message arrives, so the sticky
-- corpse window above rarely gets a chance to help either. Per-mob
-- records are keyed by mob name only (not GUID/level), so exact-corpse
-- precision isn't actually needed for attribution - "whichever tracked
-- mob died most recently" is enough, with a much longer window than the
-- sticky corpse one. Trade-off, accepted on purpose: this can
-- misattribute if a second different tracked mob is killed before an
-- earlier kill's delayed loot arrives, but that's rare enough to be worth
-- trading for fixing the much more common "raid loot attributes to
-- nothing at all" failure.
local RAID_LOOT_WINDOW = 45

-- Figures out which mob a loot/money event should be attributed to, and
-- how (for /ll debugkill visibility into which tier fired). Tiers, most
-- to least precise:
-- 1. "target"       - current target's guid against session.corpseOwner
-- 2. "sticky"        - the last corpse that DID resolve via tier 1, if
--                       within STICKY_CORPSE_WINDOW - covers looting
--                       multiple items off one corpse in quick succession,
--                       since target can clear between loot messages even
--                       on a single kill.
-- 3. "raid-fallback" - the most recently confirmed kill of ANY tracked
--                       mob, within RAID_LOOT_WINDOW - see comment above.
local function ResolveLootOwner()
    if not session then return nil end
    local _, targetGuid = UnitExists("target")
    local ownerName = targetGuid and session.corpseOwner[targetGuid]
    if ownerName then
        session.lastResolvedCorpse = { name = ownerName, time = GetTime() }
        return ownerName, "target"
    end
    local sticky = session.lastResolvedCorpse
    if sticky and (GetTime() - sticky.time) < STICKY_CORPSE_WINDOW then
        return sticky.name, "sticky"
    end
    local lastKill = session.lastKilledMob
    if lastKill and (GetTime() - lastKill.time) < RAID_LOOT_WINDOW then
        return lastKill.name, "raid-fallback"
    end
    return nil
end

local function RecordMobKillForDrops(mobName)
    local rec = EnsureMobLootRecord(mobName)
    rec.kills = rec.kills + 1

    local sessionRec = EnsureSessionMobLootRecord(mobName)
    if sessionRec then
        sessionRec.kills = sessionRec.kills + 1
    end
    -- Feeds ResolveLootOwner's "raid-fallback" tier - see its comment.
    if session then
        session.lastKilledMob = { name = mobName, time = GetTime() }
    end
    MaybeRefreshLootWindow()
end

local function RecordMobLootItem(mobName, itemKey, itemName, qty)
    local rec = EnsureMobLootRecord(mobName)
    if not rec.items[itemKey] then
        rec.items[itemKey] = { name = itemName, count = 0 }
    end
    rec.items[itemKey].count = rec.items[itemKey].count + qty

    local sessionRec = EnsureSessionMobLootRecord(mobName)
    if sessionRec then
        if not sessionRec.items[itemKey] then
            sessionRec.items[itemKey] = { name = itemName, count = 0 }
        end
        sessionRec.items[itemKey].count = sessionRec.items[itemKey].count + qty
    end
    MaybeRefreshLootWindow()
end

-- Items OTHER raid/party members received (the "not the player's own
-- pickup" CHAT_MSG_LOOT messages, previously just discarded entirely) -
-- kept separate from rec.items so they're visible in the window (greyed
-- out, see RefreshLootWindow) but never contribute to itemTotal/value,
-- since the player never actually got them.
local function RecordMobUnclaimedItem(mobName, itemKey, itemName, qty)
    local rec = EnsureMobLootRecord(mobName)
    rec.unclaimed = rec.unclaimed or {}
    if not rec.unclaimed[itemKey] then
        rec.unclaimed[itemKey] = { name = itemName, count = 0 }
    end
    rec.unclaimed[itemKey].count = rec.unclaimed[itemKey].count + qty

    local sessionRec = EnsureSessionMobLootRecord(mobName)
    if sessionRec then
        sessionRec.unclaimed = sessionRec.unclaimed or {}
        if not sessionRec.unclaimed[itemKey] then
            sessionRec.unclaimed[itemKey] = { name = itemName, count = 0 }
        end
        sessionRec.unclaimed[itemKey].count = sessionRec.unclaimed[itemKey].count + qty
    end
    MaybeRefreshLootWindow()
end

local function RecordMobMoney(mobName, copper)
    local rec = EnsureMobLootRecord(mobName)
    rec.moneyLooted = rec.moneyLooted + copper

    local sessionRec = EnsureSessionMobLootRecord(mobName)
    if sessionRec then
        sessionRec.moneyLooted = sessionRec.moneyLooted + copper
    end
    MaybeRefreshLootWindow()
end

-- Records one confirmed kill into the active session's per-mob breakdown,
-- and into the persistent per-mob drop record. guid is remembered on the
-- session (session.corpseOwner) so loot/money looted from that corpse
-- afterward can be attributed back to this mob.
local function RecordKill(guid, name, level)
    if not session then return end
    session.kills = session.kills + 1
    if name then
        local key = level and (name .. ":" .. level) or name
        if not session.mobKills[key] then
            session.mobKills[key] = { name = name, level = level, count = 0 }
        end
        session.mobKills[key].count = session.mobKills[key].count + 1

        if guid then
            session.corpseOwner[guid] = name
        end
        RecordMobKillForDrops(name)
    else
        session.unattributedKills = session.unattributedKills + 1
    end
end

-- Returns a sorted array of {name, level, count}, descending by count.
local function BuildKillBreakdown()
    local rows = {}
    for _, data in pairs(session.mobKills) do
        table.insert(rows, { name = data.name, level = data.level, count = data.count })
    end
    table.sort(rows, function(a, b) return a.count > b.count end)
    return rows
end

local function BuildBreakdown()
    -- returns a sorted array of {itemKey, name, link, count, unitPrice, source, total}
    -- and the grand total, sorted by total value descending
    local rows = {}
    local grandTotal = 0
    local anyUnknown = false

    for itemKey, data in pairs(session.loot) do
        local price, source = GetBestPrice(itemKey)
        local total = 0
        if price then
            total = price * data.count
            grandTotal = grandTotal + total
        else
            anyUnknown = true
        end
        table.insert(rows, {
            itemKey = itemKey,
            name = data.name,
            link = data.link,
            count = data.count,
            unitPrice = price,
            source = source,
            total = total,
        })
    end

    -- simple descending sort by total value
    table.sort(rows, function(a, b) return a.total > b.total end)

    return rows, grandTotal, anyUnknown
end

local function PrintLoot()
    if not session then
        Print("No active session.")
        return
    end
    local rows, grandTotal, anyUnknown = BuildBreakdown()
    if table.getn(rows) == 0 then
        Print("Nothing looted yet.")
        return
    end
    for _, row in ipairs(rows) do
        if row.unitPrice then
            Print(string.format("  %dx %s - %s each (%s) = %s",
                row.count, row.name, FormatGold(row.unitPrice), row.source, FormatGold(row.total)))
        else
            Print(string.format("  %dx %s - no price data", row.count, row.name))
        end
    end
    if session.moneyLooted > 0 then
        Print("Coin looted: " .. FormatGold(session.moneyLooted))
    end
    Print("Running total: " .. FormatGold(grandTotal + session.moneyLooted))
    if anyUnknown then
        Print("(Some items have no vendor or AH price on record.)")
    end
end

local MAX_HISTORY_ENTRIES = 100 -- oldest LootLedgerDB.sessions entries drop off past this

local function StopSession()
    if not session then
        Print("No active session.")
        return
    end

    -- Flush any kills still awaiting tap confirmation (see pendingKills)
    -- so a restart called right after a kill doesn't silently drop it -
    -- RecordKill would otherwise no-op once session is cleared below,
    -- before the OnUpdate resolver gets another chance to run.
    if table.getn(pendingKills) > 0 then
        for _, pk in ipairs(pendingKills) do
            RecordKill(pk.guid, pk.name, pk.level)
        end
        pendingKills = {}
    end

    local elapsedHours = (time() - session.startTime) / 3600
    local rows, grandTotal, anyUnknown = BuildBreakdown()

    Print("---- Session summary ----")
    Print(string.format("Time: %.1f min | Kills (approx): %d | Unique items: %d",
        elapsedHours * 60, session.kills, table.getn(rows)))

    local killRows = BuildKillBreakdown()
    for _, kr in ipairs(killRows) do
        if kr.level then
            Print(string.format("  %dx %s (lvl %d)", kr.count, kr.name, kr.level))
        else
            Print(string.format("  %dx %s", kr.count, kr.name))
        end
    end
    if session.unattributedKills > 0 then
        Print(string.format("  %dx (unnamed kill)", session.unattributedKills))
    end

    for _, row in ipairs(rows) do
        if row.unitPrice then
            Print(string.format("  %dx %s - %s each (%s) = %s",
                row.count, row.name, FormatGold(row.unitPrice), row.source, FormatGold(row.total)))
        else
            Print(string.format("  %dx %s - no price data", row.count, row.name))
        end
    end
    if session.moneyLooted > 0 then
        Print("Coin looted: " .. FormatGold(session.moneyLooted))
    end

    local combinedTotal = grandTotal + session.moneyLooted
    Print("Total session value: " .. FormatGold(combinedTotal))
    if elapsedHours > 0 then
        Print("Rate: ~" .. FormatGold(combinedTotal / elapsedHours) .. " / hour")
        if elapsedHours * 60 < 2 then
            -- a short session extrapolated to an hourly rate is arithmetically
            -- correct but statistically noisy - e.g. a 13-second sample gets
            -- multiplied ~270x, so small timing differences swing it wildly
            Print(string.format("(Session was only %.0fs - rate estimate will settle down over a longer session.)",
                elapsedHours * 3600))
        end
    end
    if anyUnknown then
        Print("(Some items had no vendor or AH price on record - excluded from total.)")
    end

    -- log a lightweight record for history
    -- (re-assert default here defensively - some clients reset SavedVariables
    --  globals after our initial load-time assignment)
    LootLedgerDB = LootLedgerDB or { sessions = {} }
    LootLedgerDB.sessions = LootLedgerDB.sessions or {}

    -- A human-readable label for the History window - the instance name
    -- takes priority over the most-killed mob when in one (e.g. "Scarlet
    -- Monastery" beats "Scarlet Monk" even if that particular mob type
    -- happened to die the most), since that's the more useful "what was
    -- this session" summary for dungeon farming specifically. Outdoors,
    -- there's no equivalent single-zone signal that beats "what did I
    -- actually spend the time killing," so falls back to killRows[1]
    -- (already sorted descending by count).
    local sessionLabel = nil
    if IsInInstance() then
        sessionLabel = GetRealZoneText()
    elseif killRows[1] then
        sessionLabel = killRows[1].name
    end

    local lootLog = {}
    for _, row in ipairs(rows) do
        table.insert(lootLog, { itemKey = row.itemKey, name = row.name, count = row.count, total = row.total })
    end
    local killLog = {}
    for _, kr in ipairs(killRows) do
        table.insert(killLog, { name = kr.name, level = kr.level, count = kr.count })
    end
    table.insert(LootLedgerDB.sessions, {
        label = sessionLabel,
        duration = time() - session.startTime,
        kills = session.kills,
        killsByMob = killLog,
        unattributedKills = session.unattributedKills,
        lootTotal = grandTotal,
        moneyLooted = session.moneyLooted,
        grandTotal = combinedTotal,
        loot = lootLog,
        timestamp = time(),
    })
    -- Unbounded otherwise - every Restart Session adds one more entry
    -- forever. Dropping the oldest once past MAX_HISTORY_ENTRIES keeps
    -- both the SavedVariables file and the History window's list from
    -- growing without end; recent history is what's actually useful to
    -- review anyway.
    while table.getn(LootLedgerDB.sessions) > MAX_HISTORY_ENTRIES do
        table.remove(LootLedgerDB.sessions, 1)
    end

    -- tracking is continuous - immediately start a fresh session instead
    -- of actually stopping, so Restart Session reads as "show me a
    -- summary and reset the clock" rather than "turn tracking off."
    -- Silent since a full summary was just printed above.
    StartSession(true)
end

local function PrintStatus()
    if not session then
        Print("No active session.")
        return
    end
    local elapsedMin = (time() - session.startTime) / 60
    local itemCount = 0
    for _ in pairs(session.loot) do itemCount = itemCount + 1 end
    local mobCount = 0
    for _ in pairs(session.mobKills) do mobCount = mobCount + 1 end
    Print(string.format("%.1f min | ~%d kills (%d species) | %d unique items looted",
        elapsedMin, session.kills, mobCount, itemCount))
end

-- ---------------------------------------------------------------------
-- Loot Tracker window - RuneLite/OSRS-loot-tracker style GUI. Every
-- tracked mob gets a section: name, kill count, total value, and a grid
-- of item icons (icon, quantity badge, hover tooltip) underneath.
-- Toggleable between "This Session" and "All Time" (LootLedgerDB.mobLoot)
-- data. Built entirely from CreateFrame calls, no XML template file.
-- ---------------------------------------------------------------------

local ICON_SIZE = 32
local ICON_PAD = 4
local WINDOW_WIDTH = 280
local WINDOW_HEIGHT = 394
local MIN_WINDOW_WIDTH = 240
local MIN_WINDOW_HEIGHT = 150
local MAX_WINDOW_WIDTH = 600
local MAX_WINDOW_HEIGHT = 700
local COMPACT_WIDTH = 150
local COMPACT_HEIGHT = 84
local HEADER_HEIGHT = 20
local SECTION_GAP = 10

-- Mob sections a user has manually collapsed (left-click a header to
-- toggle) - keyed by mob name, session-only UI state, not persisted.
local collapsedMobs = {}

-- Brand accent - WoW's own Epic-item-quality purple (#A335EE), fitting
-- for a loot tracker. Used for chrome (title, kill-count text, button
-- borders) - NOT for actual gold amounts (stays the conventional gold
-- color) or item-quality borders (stay each item's real rarity color),
-- so the semantic meaning of those colors isn't lost to branding.
local ACCENT_R, ACCENT_G, ACCENT_B = 0.64, 0.21, 0.93
local ACCENT_HEX = "a335ee"

local sectionHeaderPool = {}
local iconButtonPool = {}

-- Right-clicking a mob's header opens this instead of resetting instantly,
-- to avoid wiping data from a stray right-click - a standard vanilla
-- UIDropDownMenu with the mob's name as an unclickable title and a single
-- "Reset" entry you have to click on purpose.
local resetMenuTarget = nil
local resetMenuFrame = nil

local function InitResetMenu()
    local info = UIDropDownMenu_CreateInfo()
    info.text = resetMenuTarget or ""
    info.isTitle = true
    info.notCheckable = true
    UIDropDownMenu_AddButton(info)

    info = UIDropDownMenu_CreateInfo()
    info.text = "Reset"
    info.notCheckable = true
    info.func = function()
        ResetMobLoot(resetMenuTarget)
    end
    UIDropDownMenu_AddButton(info)
end

local function ShowResetMenu(mobName)
    resetMenuTarget = mobName
    if not resetMenuFrame then
        resetMenuFrame = CreateFrame("Frame", "LootLedgerResetMenu", UIParent, "UIDropDownMenuTemplate")
    end
    UIDropDownMenu_Initialize(resetMenuFrame, InitResetMenu, "MENU")
    ToggleDropDownMenu(1, nil, resetMenuFrame, "cursor", 0, 0)
end

local function GetSectionHeader(index)
    local f = sectionHeaderPool[index]
    if f then return f end

    f = CreateFrame("Frame", nil, lootContent)
    f:SetHeight(HEADER_HEIGHT)
    f:SetWidth(WINDOW_WIDTH - 40)
    f:EnableMouse(true)

    -- Interface\BUTTONS\WHITE8X8 is a solid-white 1x1 texture shipped
    -- with the client - tintable via SetBackdropColor/BorderColor for a
    -- plain flat panel look without needing any custom art.
    f:SetBackdrop({
        bgFile = "Interface\\BUTTONS\\WHITE8X8",
        edgeFile = "Interface\\BUTTONS\\WHITE8X8",
        edgeSize = 1,
    })
    f:SetBackdropColor(0, 0, 0, 0.45)
    f:SetBackdropBorderColor(0.35, 0.35, 0.35, 0.8)

    -- HIGHLIGHT-layer regions auto-show/hide on hover for any mouse-enabled
    -- frame (not just Buttons) - no extra OnEnter/OnLeave wiring needed.
    local highlight = f:CreateTexture(nil, "HIGHLIGHT")
    highlight:SetAllPoints(f)
    highlight:SetTexture(ACCENT_R, ACCENT_G, ACCENT_B, 1)
    highlight:SetBlendMode("ADD")
    highlight:SetAlpha(0.15)

    local valueText = f:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    valueText:SetPoint("RIGHT", f, "RIGHT", -4, 0)
    valueText:SetTextColor(1, 0.82, 0)

    local killText = f:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    killText:SetPoint("RIGHT", valueText, "LEFT", -8, 0)
    killText:SetTextColor(ACCENT_R, ACCENT_G, ACCENT_B)

    -- Anchored on BOTH sides (left edge of the header, right edge pinned
    -- to killText) rather than just growing rightward from the left like
    -- killText/valueText do - a long mob name would otherwise push
    -- straight through them instead of stopping short. SetWordWrap isn't
    -- available on this client's FontString objects (errors as a nil
    -- method), so an over-long name wraps to a second line instead of
    -- clipping - the fixed SetHeight below at least keeps that second
    -- line from spilling down into the icon grid.
    local nameText = f:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    nameText:SetPoint("LEFT", f, "LEFT", 4, 0)
    nameText:SetPoint("RIGHT", killText, "LEFT", -6, 0)
    nameText:SetHeight(HEADER_HEIGHT)
    nameText:SetJustifyH("LEFT")

    f.nameText = nameText
    f.killText = killText
    f.valueText = valueText

    -- Left-click collapses/expands this mob's item grid (just the header
    -- stays visible). Right-click opens a small menu with a "Reset" entry
    -- you have to click on purpose - avoids wiping data from a stray/
    -- accidental right-click.
    f:SetScript("OnMouseUp", function()
        if not this.mobName then return end
        if arg1 == "RightButton" then
            ShowResetMenu(this.mobName)
        elseif arg1 == "LeftButton" then
            collapsedMobs[this.mobName] = not collapsedMobs[this.mobName]
            RefreshLootWindow()
        end
    end)
    f:SetScript("OnEnter", function()
        GameTooltip:SetOwner(this, "ANCHOR_RIGHT")
        GameTooltip:SetText("Click to collapse/expand")
        GameTooltip:AddLine("Right-click for reset options", 0.7, 0.7, 0.7)
        GameTooltip:Show()
    end)
    f:SetScript("OnLeave", function()
        GameTooltip:Hide()
    end)

    -- Match pfUI's flat-panel skin when installed (legacy=true applies the
    -- backdrop directly to this frame instead of spawning a child border
    -- frame - the same simple-widget mode pfUI's own SkinButton uses).
    if pfUI and pfUI.api then
        pcall(function() pfUI.api.CreateBackdrop(f, nil, true) end)
    end

    sectionHeaderPool[index] = f
    return f
end

-- Right-clicking an item icon opens this - same "menu instead of instant
-- action" pattern as the mob reset menu above, for the same reason (no
-- accidental filtering from a stray right-click). Filtering hides the
-- item everywhere (see IsExcludedItem) and stops it from being recorded
-- going forward; removing it again is done from the Options window,
-- which lists everything currently filtered.
local itemFilterMenuTarget = nil -- itemKey
local itemFilterMenuFrame = nil

local function FilterItem(itemKey)
    if not itemKey then return end
    LootLedgerDB = LootLedgerDB or { sessions = {} }
    LootLedgerDB.filteredItems = LootLedgerDB.filteredItems or {}
    LootLedgerDB.filteredItems[itemKey] = true
    MaybeRefreshLootWindow()
    if RefreshOptionsWindow then RefreshOptionsWindow() end
end

local function InitItemFilterMenu()
    local itemName = itemFilterMenuTarget and (GetItemInfo(ItemStringForKey(itemFilterMenuTarget)) or ("item " .. itemFilterMenuTarget))
    local info = UIDropDownMenu_CreateInfo()
    info.text = itemName or ""
    info.isTitle = true
    info.notCheckable = true
    UIDropDownMenu_AddButton(info)

    info = UIDropDownMenu_CreateInfo()
    info.text = "Filter This Item"
    info.notCheckable = true
    info.func = function()
        FilterItem(itemFilterMenuTarget)
    end
    UIDropDownMenu_AddButton(info)
end

local function ShowItemFilterMenu(itemKey)
    itemFilterMenuTarget = itemKey
    if not itemFilterMenuFrame then
        itemFilterMenuFrame = CreateFrame("Frame", "LootLedgerItemFilterMenu", UIParent, "UIDropDownMenuTemplate")
    end
    UIDropDownMenu_Initialize(itemFilterMenuFrame, InitItemFilterMenu, "MENU")
    ToggleDropDownMenu(1, nil, itemFilterMenuFrame, "cursor", 0, 0)
end

local function GetIconButton(index)
    local b = iconButtonPool[index]
    if b then return b end

    b = CreateFrame("Button", nil, lootContent)
    b:SetWidth(ICON_SIZE)
    b:SetHeight(ICON_SIZE)

    -- Border lives on the button's own backdrop rather than a separate
    -- overlapping frame - a second frame layered above via SetFrameLevel
    -- turned out unreliable across a whole grid of icons (borders would
    -- randomly go missing on some slots, presumably losing the level
    -- race against a neighboring icon's own frame). A single frame's own
    -- draw layers (BACKGROUND for the backdrop, ARTWORK for the icon) are
    -- strictly ordered with no such ambiguity.
    b:SetBackdrop({
        edgeFile = "Interface\\Buttons\\WHITE8X8",
        edgeSize = 1,
    })
    b:SetBackdropBorderColor(0.5, 0.5, 0.5, 1)
    b.border = b

    -- Inset 1px so the backdrop border (BACKGROUND layer, below the icon)
    -- isn't fully covered by an icon the same size as the button - and
    -- cropped to cut off the faint ~8% empty bezel baked into every
    -- Blizzard icon texture, which otherwise reads as a second, duller
    -- border sitting just inside the real colored one.
    local icon = b:CreateTexture(nil, "ARTWORK")
    icon:SetPoint("TOPLEFT", b, "TOPLEFT", 1, -1)
    icon:SetPoint("BOTTOMRIGHT", b, "BOTTOMRIGHT", -1, 1)
    icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)
    b.icon = icon

    -- Same highlight texture real bag/bank item slots use on hover.
    b:SetHighlightTexture("Interface\\Buttons\\ButtonHilight-Square", "ADD")

    local countText = b:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    countText:SetPoint("TOPLEFT", b, "TOPLEFT", 1, -1)
    countText:SetTextColor(1, 1, 0.4)
    b.countText = countText

    -- reconstructed minimal item link (enchant/gem/unique segments aren't
    -- tracked, so zeroed - only itemID+suffixID matter for a tooltip,
    -- see ItemStringForKey)
    b:SetScript("OnEnter", function()
        if this.moneyTotal then
            GameTooltip:SetOwner(this, "ANCHOR_RIGHT")
            GameTooltip:SetText("Coin: " .. FormatGold(this.moneyTotal))
            GameTooltip:Show()
        elseif this.itemKey then
            GameTooltip:SetOwner(this, "ANCHOR_RIGHT")
            GameTooltip:SetHyperlink(ItemStringForKey(this.itemKey))
            if this.unclaimed then
                GameTooltip:AddLine("Looted by someone else - not counted", 0.7, 0.7, 0.7)
            end
            GameTooltip:AddLine("Right-click to filter this item", 0.7, 0.7, 0.7)
            GameTooltip:Show()
        end
    end)
    -- Right-click opens a small menu to filter this item out entirely
    -- (see FilterItem) - not the coin slot, which has no itemKey.
    b:SetScript("OnMouseUp", function()
        if arg1 == "RightButton" and this.itemKey then
            ShowItemFilterMenu(this.itemKey)
        end
    end)
    b:SetScript("OnLeave", function()
        GameTooltip:Hide()
    end)

    iconButtonPool[index] = b
    return b
end

-- Row frames live in lootContent, which can be much taller than the
-- actual scroll viewport once a session racks up a lot of mobs - every
-- header and icon button has its own SetBackdrop border (see
-- GetSectionHeader/GetIconButton above), and vanilla's renderer pays
-- for every simultaneously-Shown backdrop frame whether or not the
-- ScrollFrame happens to be clipping it out of view right now. With a
-- lot of entries that's hundreds of live bordered frames, and moving or
-- scrolling the window - both of which force a recomposite every single
-- rendered frame - is exactly when that cost shows up as an FPS hit.
-- Below, a row only stays Shown if it's actually within (or near) the
-- visible scroll range; everything else gets Hidden. Positions set by
-- the last full RefreshLootWindow stay correct while hidden, so
-- re-showing a row on scroll-back doesn't need repositioning - only the
-- show/hide state needs to be re-decided, which is why the scroll-tick
-- path below is cheap (no data rebuild, no sorting, no GetItemInfo).
local VISIBILITY_BUFFER = 60
local lastUsedHeaders, lastUsedIcons = 0, 0

local function ApplyRowVisibility(f)
    if not f or not f.rowTop then return end
    local viewTop = lootScrollFrame:GetVerticalScroll()
    local viewBottom = viewTop + lootScrollFrame:GetHeight()
    local rowBottom = f.rowTop + (f.rowHeight or 0)
    if rowBottom >= viewTop - VISIBILITY_BUFFER and f.rowTop <= viewBottom + VISIBILITY_BUFFER then
        f:Show()
    else
        f:Hide()
    end
end

local function UpdateVisibleLootRows()
    if not lootScrollFrame then return end
    local i
    for i = 1, lastUsedHeaders do
        ApplyRowVisibility(sectionHeaderPool[i])
    end
    for i = 1, lastUsedIcons do
        ApplyRowVisibility(iconButtonPool[i])
    end
end

StaticPopupDialogs["LOOTLEDGER_RESET_ALL"] = {
    text = "Reset ALL LootLedger loot history (This Session and All Time)? This cannot be undone.",
    button1 = "Yes",
    button2 = "No",
    OnAccept = function() ResetAllLoot() end,
    timeout = 0,
    whileDead = true,
    hideOnEscape = true,
}

local function CreateLootWindow()
    if lootWindow then return end

    local f = CreateFrame("Frame", "LootLedgerLootWindow", UIParent)
    -- Standard vanilla mechanism for "Escape closes this like any other
    -- window" - the game hides any shown frame whose global name is in
    -- this table when Escape is pressed, no custom key handling needed.
    -- Only registered while expanded, though (see SetEscapeCloses below,
    -- wired into SetLootWindowMode) - compact mode is meant to sit on
    -- screen as a persistent readout, not disappear on a stray Escape
    -- meant for something else entirely.
    local function SetEscapeCloses(enabled)
        local i
        for i = 1, table.getn(UISpecialFrames) do
            if UISpecialFrames[i] == "LootLedgerLootWindow" then
                if not enabled then
                    table.remove(UISpecialFrames, i)
                end
                return
            end
        end
        if enabled then
            tinsert(UISpecialFrames, "LootLedgerLootWindow")
        end
    end
    SetEscapeCloses(true)
    f:SetWidth(WINDOW_WIDTH)
    f:SetHeight(WINDOW_HEIGHT)
    f:SetPoint("CENTER", UIParent, "CENTER", 0, 0)
    f:SetBackdrop({
        bgFile = "Interface\\Tooltips\\UI-Tooltip-Background",
        edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
        tile = true, tileSize = 16, edgeSize = 16,
        insets = { left = 4, right = 4, top = 4, bottom = 4 },
    })
    f:SetBackdropColor(0, 0, 0, 0.9)
    f:SetFrameStrata("DIALOG")
    f:SetMovable(true)
    f:EnableMouse(true)
    f:RegisterForDrag("LeftButton")
    f:SetScript("OnDragStart", function() this:StartMoving() end)
    f:SetScript("OnDragStop", function() this:StopMovingOrSizing() end)
    f:Hide()

    local title = f:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    title:SetPoint("TOP", f, "TOP", 0, -10)
    title:SetText("|cff" .. ACCENT_HEX .. "LootLedger|r")

    -- Compact mode gets its own small "LL" label instead of shrinking the
    -- full title's font - the goal is a genuinely unobtrusive readout, not
    -- just a smaller version of the same header.
    local miniTitle = f:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    miniTitle:SetPoint("TOP", f, "TOP", 0, -6)
    miniTitle:SetText("|cff" .. ACCENT_HEX .. "LL|r")
    miniTitle:Hide()

    local closeBtn = CreateFrame("Button", nil, f, "UIPanelCloseButton")
    closeBtn:SetWidth(18)
    closeBtn:SetHeight(18)
    closeBtn:SetPoint("TOPRIGHT", f, "TOPRIGHT", -2, -2)
    closeBtn:SetScript("OnClick", function() lootWindow:Hide() end)

    -- Opens the Options window (filtered items, disenchant-value toggle).
    -- Tucked next to Reset All/close for the same reason those are tiny -
    -- infrequent enough not to deserve a full row.
    local optionsBtn = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
    optionsBtn:SetWidth(18)
    optionsBtn:SetHeight(18)
    optionsBtn:SetPoint("RIGHT", closeBtn, "LEFT", -2, 0)
    optionsBtn:SetText("O")
    optionsBtn:SetScript("OnClick", function()
        ToggleOptionsWindow()
    end)
    optionsBtn:SetScript("OnEnter", function()
        GameTooltip:SetOwner(this, "ANCHOR_LEFT")
        GameTooltip:SetText("Options")
        GameTooltip:AddLine("Filtered items, disenchant value", 0.7, 0.7, 0.7)
        GameTooltip:Show()
    end)
    optionsBtn:SetScript("OnLeave", function()
        GameTooltip:Hide()
    end)

    -- Wipes ALL loot history (both views). Tiny + red-bordered, tucked up
    -- next to the close button rather than taking a full row - it's rare
    -- enough to need that it doesn't deserve prime real estate, and the
    -- confirmation popup is the actual safety net against misclicks.
    local resetAllBtn = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
    resetAllBtn:SetWidth(18)
    resetAllBtn:SetHeight(18)
    resetAllBtn:SetPoint("RIGHT", optionsBtn, "LEFT", -2, 0)
    resetAllBtn:SetText("|cffff5555R|r")
    resetAllBtn:SetScript("OnClick", function()
        StaticPopup_Show("LOOTLEDGER_RESET_ALL")
    end)
    resetAllBtn:SetScript("OnEnter", function()
        GameTooltip:SetOwner(this, "ANCHOR_LEFT")
        GameTooltip:SetText("|cffff5555Reset All|r")
        GameTooltip:AddLine("Wipes everything - This Session and All Time", 0.7, 0.7, 0.7)
        GameTooltip:Show()
    end)
    resetAllBtn:SetScript("OnLeave", function()
        GameTooltip:Hide()
    end)

    -- Forward-declared so collapseBtn's OnClick (created next) can
    -- reference it as an upvalue before it's assigned a real function
    -- further down, once the widgets it toggles all exist - same pattern
    -- as the module-level RefreshLootWindow forward-declaration.
    local SetLootWindowMode

    local collapseBtn = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
    collapseBtn:SetWidth(18)
    collapseBtn:SetHeight(18)
    collapseBtn:SetPoint("TOPLEFT", f, "TOPLEFT", 4, -4)
    collapseBtn:SetText("-")
    collapseBtn:SetScript("OnClick", function()
        SetLootWindowMode(not lootWindowCompact)
    end)

    -- Toggles mob section ordering between most-recently-killed and
    -- highest-value (see the sort in RefreshLootWindow).
    local sortBtn = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
    sortBtn:SetWidth(18)
    sortBtn:SetHeight(18)
    sortBtn:SetPoint("LEFT", collapseBtn, "RIGHT", 4, 0)
    local function UpdateSortButton()
        sortBtn:SetText(lootSortMode == "value" and "V" or "R")
    end
    sortBtn:SetScript("OnClick", function()
        lootSortMode = (lootSortMode == "value") and "recent" or "value"
        UpdateSortButton()
        RefreshLootWindow()
    end)
    sortBtn:SetScript("OnEnter", function()
        GameTooltip:SetOwner(this, "ANCHOR_RIGHT")
        GameTooltip:SetText(lootSortMode == "value" and "Sorted by Value" or "Sorted by Most Recent")
        GameTooltip:AddLine("Click to change", 0.7, 0.7, 0.7)
        GameTooltip:Show()
    end)
    sortBtn:SetScript("OnLeave", function()
        GameTooltip:Hide()
    end)
    UpdateSortButton()

    -- Opens the History window (past logged sessions - see Restart
    -- Session / StopSession).
    local historyBtn = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
    historyBtn:SetWidth(18)
    historyBtn:SetHeight(18)
    historyBtn:SetPoint("LEFT", sortBtn, "RIGHT", 4, 0)
    historyBtn:SetText("H")
    historyBtn:SetScript("OnClick", function()
        ToggleHistoryWindow()
    end)
    historyBtn:SetScript("OnEnter", function()
        GameTooltip:SetOwner(this, "ANCHOR_RIGHT")
        GameTooltip:SetText("History")
        GameTooltip:AddLine("Past logged sessions", 0.7, 0.7, 0.7)
        GameTooltip:Show()
    end)
    historyBtn:SetScript("OnLeave", function()
        GameTooltip:Hide()
    end)

    -- Forward-declared for the same reason as SetLootWindowMode above -
    -- sessionBtn/allTimeBtn's OnClick (created next) need to call this to
    -- refresh which one looks selected and whether restartBtn applies.
    local UpdateModeButtons

    local sessionBtn = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
    sessionBtn:SetWidth(85)
    sessionBtn:SetHeight(18)
    sessionBtn:SetPoint("TOPLEFT", f, "TOPLEFT", 10, -32)
    sessionBtn:SetText("|cffffffffThis Session|r")
    sessionBtn:SetScript("OnClick", function()
        lootViewMode = "session"
        UpdateModeButtons()
        RefreshLootWindow()
    end)

    local allTimeBtn = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
    allTimeBtn:SetWidth(85)
    allTimeBtn:SetHeight(18)
    allTimeBtn:SetPoint("LEFT", sessionBtn, "RIGHT", 4, 0)
    allTimeBtn:SetText("|cffffffffAll Time|r")
    allTimeBtn:SetScript("OnClick", function()
        lootViewMode = "alltime"
        UpdateModeButtons()
        RefreshLootWindow()
    end)

    lootModeButtons.session = sessionBtn
    lootModeButtons.alltime = allTimeBtn

    -- Restarts the session clock in place - reuses StopSession, which logs
    -- a full summary to chat + LootLedgerDB.sessions history, then starts
    -- a fresh session, so nothing is silently lost.
    -- StartSession creates a brand new session.mobLoot table too, so this
    -- also correctly clears the window's "This Session" tab back to zero -
    -- "All Time" (LootLedgerDB.mobLoot) is untouched. Only makes sense
    -- while viewing "This Session" at all, so UpdateModeButtons shows/
    -- hides it based on lootViewMode rather than leaving it always up.
    local restartBtn = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
    restartBtn:SetWidth(18)
    restartBtn:SetHeight(18)
    restartBtn:SetPoint("LEFT", allTimeBtn, "RIGHT", 4, 0)
    restartBtn:SetText("R")
    restartBtn:SetScript("OnEnter", function()
        GameTooltip:SetOwner(this, "ANCHOR_LEFT")
        GameTooltip:SetText("Restart Session")
        GameTooltip:AddLine("Logs a summary and resets the clock", 0.7, 0.7, 0.7)
        GameTooltip:Show()
    end)
    restartBtn:SetScript("OnLeave", function()
        GameTooltip:Hide()
    end)
    restartBtn:SetScript("OnClick", function()
        StopSession()
        RefreshLootWindow()
    end)

    -- Same action as restartBtn above, just a small icon-sized version
    -- for compact mode instead of the full-width text button - keeps the
    -- tiny readout from having a big label bleeding into it.
    local miniRestartBtn = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
    miniRestartBtn:SetWidth(16)
    miniRestartBtn:SetHeight(16)
    miniRestartBtn:SetPoint("BOTTOMRIGHT", f, "BOTTOMRIGHT", -4, 4)
    miniRestartBtn:SetText("R")
    miniRestartBtn:SetScript("OnClick", function()
        StopSession()
        RefreshLootWindow()
    end)
    miniRestartBtn:SetScript("OnEnter", function()
        GameTooltip:SetOwner(this, "ANCHOR_LEFT")
        GameTooltip:SetText("Restart Session")
        GameTooltip:AddLine("Logs a summary and resets the clock", 0.7, 0.7, 0.7)
        GameTooltip:Show()
    end)
    miniRestartBtn:SetScript("OnLeave", function()
        GameTooltip:Hide()
    end)
    miniRestartBtn:Hide()

    local summary = f:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    summary:SetPoint("TOPLEFT", f, "TOPLEFT", 12, -56)
    summary:SetPoint("TOPRIGHT", f, "TOPRIGHT", -12, -56)
    summary:SetJustifyH("LEFT")
    lootSummaryText = summary

    -- A second line rather than letting the first wrap/truncate on its
    -- own - kills+time and value+gold/hr each comfortably fit their own
    -- line even at MIN_WINDOW_WIDTH, where the old single all-in-one
    -- line got clipped with "...".
    local summary2 = f:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    summary2:SetPoint("TOPLEFT", f, "TOPLEFT", 12, -70)
    summary2:SetPoint("TOPRIGHT", f, "TOPRIGHT", -12, -70)
    summary2:SetJustifyH("LEFT")
    lootSummaryText2 = summary2

    local scroll = CreateFrame("ScrollFrame", "LootLedgerLootScrollFrame", f, "UIPanelScrollFrameTemplate")
    scroll:SetPoint("TOPLEFT", f, "TOPLEFT", 10, -90)
    scroll:SetPoint("BOTTOMRIGHT", f, "BOTTOMRIGHT", -28, 10)

    -- Wraps (not replaces) whatever OnVerticalScroll the template already
    -- wired up, so the scrollbar's own built-in sync keeps working - this
    -- just piggybacks a cheap show/hide pass (see UpdateVisibleLootRows)
    -- on top, so rows scrolled into view actually reappear and rows
    -- scrolled out actually stop costing render time.
    local origOnVerticalScroll = scroll:GetScript("OnVerticalScroll")
    scroll:SetScript("OnVerticalScroll", function()
        if origOnVerticalScroll then origOnVerticalScroll() end
        UpdateVisibleLootRows()
    end)

    -- UIPanelScrollFrameTemplate names its scrollbar child "<name>ScrollBar"
    -- - pfUI.api.SkinScrollbar expects that (a Slider, has GetThumbTexture),
    -- not the ScrollFrame itself.
    local scrollBar = _G["LootLedgerLootScrollFrameScrollBar"]

    local content = CreateFrame("Frame", nil, scroll)
    content:SetWidth(WINDOW_WIDTH - 40)
    content:SetHeight(1) -- grown dynamically in RefreshLootWindow
    scroll:SetScrollChild(content)

    -- Bottom-right resize grip. Drag to freely resize between MIN_/MAX_
    -- WINDOW_WIDTH/HEIGHT - content width and the icon grid's columns
    -- both recompute from the actual frame size on the next refresh (see
    -- RefreshLootWindow), rather than assuming the original fixed size.
    f.expandedWidth, f.expandedHeight = WINDOW_WIDTH, WINDOW_HEIGHT

    local grip = CreateFrame("Button", nil, f)
    grip:SetWidth(18)
    grip:SetHeight(18)
    grip:SetPoint("BOTTOMRIGHT", f, "BOTTOMRIGHT", -3, 3)
    -- Sits in the same corner as the scrollbar's down-arrow button, so it
    -- needs a frame level well above the rest of the window to reliably
    -- receive clicks instead of the scrollbar eating them.
    grip:SetFrameLevel(f:GetFrameLevel() + 10)
    -- A tinted WHITE8X8 square rather than Blizzard's chat-frame resize
    -- texture, which doesn't render on this client.
    grip:SetBackdrop({
        bgFile = "Interface\\Buttons\\WHITE8X8",
    })
    grip:SetBackdropColor(ACCENT_R, ACCENT_G, ACCENT_B, 0.4)
    grip:SetScript("OnEnter", function()
        GameTooltip:SetOwner(this, "ANCHOR_LEFT")
        GameTooltip:SetText("Drag to resize")
        GameTooltip:Show()
    end)
    grip:SetScript("OnLeave", function()
        GameTooltip:Hide()
    end)

    grip:SetScript("OnMouseDown", function()
        this.sizing = true
        this.startX, this.startY = GetCursorPosition()
        this.startW, this.startH = f:GetWidth(), f:GetHeight()
        this.scale = f:GetEffectiveScale()
    end)
    grip:SetScript("OnMouseUp", function()
        this.sizing = nil
    end)
    grip:SetScript("OnUpdate", function()
        if not this.sizing then return end
        local x, y = GetCursorPosition()
        local scale = this.scale or 1
        local newW = this.startW + (x - this.startX) / scale
        local newH = this.startH - (y - this.startY) / scale
        if newW < MIN_WINDOW_WIDTH then newW = MIN_WINDOW_WIDTH end
        if newW > MAX_WINDOW_WIDTH then newW = MAX_WINDOW_WIDTH end
        if newH < MIN_WINDOW_HEIGHT then newH = MIN_WINDOW_HEIGHT end
        if newH > MAX_WINDOW_HEIGHT then newH = MAX_WINDOW_HEIGHT end
        f:SetWidth(newW)
        f:SetHeight(newH)
        content:SetWidth(newW - 40)
        f.expandedWidth, f.expandedHeight = newW, newH
        if RefreshLootWindow then RefreshLootWindow() end
    end)
    f.resizeGrip = grip

    local compactText = f:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    compactText:SetPoint("TOPLEFT", f, "TOPLEFT", 12, -40)
    compactText:SetPoint("TOPRIGHT", f, "TOPRIGHT", -12, -40)
    compactText:SetJustifyH("LEFT")
    compactText:Hide()

    -- Live Time/Gold-per-hour/Kills-per-hour readout for the compact view.
    -- Reuses the exact same math Restart Session and /ll status already use
    -- (BuildBreakdown for item value + session.moneyLooted + session.kills
    -- over elapsed time) so the numbers here never drift from those.
    local function UpdateCompactStats()
        if not session then
            compactText:SetText("No active session.")
            return
        end
        local elapsed = time() - session.startTime
        local elapsedHours = elapsed / 3600
        local mins = math.floor(elapsed / 60)
        local secs = math.floor(elapsed - mins * 60)

        local rows, grandTotal = BuildBreakdown()
        local combinedTotal = grandTotal + session.moneyLooted

        local gph, kph = 0, 0
        if elapsedHours > 0 then
            gph = combinedTotal / elapsedHours
            kph = session.kills / elapsedHours
        end

        compactText:SetText(string.format("Time: %d:%02d\nGold/hr: %s\nKills/hr: %.1f",
            mins, secs, FormatGoldShort(gph), kph))
    end

    -- Shows which view is active (LockHighlight is a base Button method -
    -- under pfUI's skin it recolors the border with the class color, in
    -- the default look it shows the button's own pressed/highlight state
    -- - either way it works without this addon needing to know which
    -- skin is active), and Restart Session only makes sense while
    -- looking at "This Session" at all.
    UpdateModeButtons = function()
        if lootViewMode == "session" then
            sessionBtn:LockHighlight()
            allTimeBtn:UnlockHighlight()
            restartBtn:Show()
        else
            sessionBtn:UnlockHighlight()
            allTimeBtn:LockHighlight()
            restartBtn:Hide()
        end
    end
    UpdateModeButtons()

    SetLootWindowMode = function(compact)
        lootWindowCompact = compact
        if compact then
            sessionBtn:Hide()
            allTimeBtn:Hide()
            resetAllBtn:Hide()
            optionsBtn:Hide()
            sortBtn:Hide()
            historyBtn:Hide()
            restartBtn:Hide()
            summary:Hide()
            summary2:Hide()
            scroll:Hide()
            grip:Hide()
            title:Hide()
            compactText:Show()
            miniTitle:Show()
            miniRestartBtn:Show()
            collapseBtn:SetText("+")
            f:SetWidth(COMPACT_WIDTH)
            f:SetHeight(COMPACT_HEIGHT)
            SetEscapeCloses(false)
            UpdateCompactStats()
        else
            sessionBtn:Show()
            allTimeBtn:Show()
            resetAllBtn:Show()
            optionsBtn:Show()
            sortBtn:Show()
            historyBtn:Show()
            -- Not an unconditional Show() - restartBtn only applies while
            -- viewing "This Session" - UpdateModeButtons() below handles it.
            summary:Show()
            summary2:Show()
            scroll:Show()
            grip:Show()
            title:Show()
            compactText:Hide()
            miniTitle:Hide()
            miniRestartBtn:Hide()
            collapseBtn:SetText("-")
            -- Restore whatever size the user last resized to, not the
            -- fixed default - resizing only ever happens in expanded
            -- mode, so f.expandedWidth/Height always holds it.
            f:SetWidth(f.expandedWidth or WINDOW_WIDTH)
            f:SetHeight(f.expandedHeight or WINDOW_HEIGHT)
            SetEscapeCloses(true)
            UpdateModeButtons()
            RefreshLootWindow()
        end
    end

    local compactUpdateAccum = 0
    f:SetScript("OnUpdate", function()
        if not lootWindowCompact then return end
        compactUpdateAccum = compactUpdateAccum + arg1
        if compactUpdateAccum < 1 then return end
        compactUpdateAccum = 0
        UpdateCompactStats()
    end)

    -- pfUI is a completely separate addon; by the time /ll drops is ever
    -- run, addon load has long since finished, so a straight global
    -- check here is safe - no
    -- ADDON_LOADED race to handle. pfUI.api.CreateBackdrop clears our
    -- Blizzard backdrop internally, so no need to strip it ourselves first.
    -- Wrapped in pcall since pfUI's skin functions are unverified against
    -- this specific client build - a failure here should not break the
    -- window itself, just fall back to the default Blizzard look.
    if pfUI and pfUI.api then
        local ok, err = pcall(function()
            pfUI.api.CreateBackdrop(f)
            pfUI.api.CreateBackdropShadow(f)
            pfUI.api.SkinCloseButton(closeBtn)
            pfUI.api.SkinButton(sessionBtn)
            pfUI.api.SkinButton(allTimeBtn)
            pfUI.api.SkinButton(resetAllBtn)
            pfUI.api.SkinButton(restartBtn)
            pfUI.api.SkinButton(collapseBtn)
            pfUI.api.SkinButton(miniRestartBtn)
            pfUI.api.SkinButton(sortBtn)
            pfUI.api.SkinButton(optionsBtn)
            pfUI.api.SkinButton(historyBtn)
            if scrollBar then
                pfUI.api.SkinScrollbar(scrollBar)
            end

            -- pfUI's own border color/opacity comes from the user's
            -- pfUI settings, which can read faint against a busy
            -- background (e.g. a dungeon backdrop bleeding through a
            -- semi-transparent panel) - force a brighter, on-purpose
            -- border per button on top of the skin so they stay easy to
            -- pick out regardless of the user's pfUI theme settings.
            sessionBtn:SetBackdropBorderColor(ACCENT_R, ACCENT_G, ACCENT_B, 1)
            allTimeBtn:SetBackdropBorderColor(ACCENT_R, ACCENT_G, ACCENT_B, 1)
            restartBtn:SetBackdropBorderColor(ACCENT_R, ACCENT_G, ACCENT_B, 1)
            resetAllBtn:SetBackdropBorderColor(1, 0.15, 0.15, 1)
            collapseBtn:SetBackdropBorderColor(ACCENT_R, ACCENT_G, ACCENT_B, 1)
            miniRestartBtn:SetBackdropBorderColor(ACCENT_R, ACCENT_G, ACCENT_B, 1)
            sortBtn:SetBackdropBorderColor(ACCENT_R, ACCENT_G, ACCENT_B, 1)
            optionsBtn:SetBackdropBorderColor(ACCENT_R, ACCENT_G, ACCENT_B, 1)
            historyBtn:SetBackdropBorderColor(ACCENT_R, ACCENT_G, ACCENT_B, 1)
        end)
        if not ok then
            Print("LootLedger: pfUI skinning failed (" .. tostring(err) .. ") - using default look.")
        end
    end

    -- Re-applied after pfUI skinning (not just once, back when the
    -- buttons were created) - pfUI.api.SkinButton replaces LockHighlight/
    -- UnlockHighlight with its own border-recoloring versions, and the
    -- SetBackdropBorderColor calls just above force both buttons to the
    -- same accent color regardless of which one is actually active. The
    -- first UpdateModeButtons() call locked in the pre-skin visual, which
    -- pfUI's skin pass then overwrote without anything re-asserting it
    -- afterward - default view opened with This Session looking
    -- highlighted even when All Time was actually selected.
    UpdateModeButtons()

    lootWindow = f
    lootScrollFrame = scroll
    lootContent = content
end

-- Assigns the actual function to the forward-declared RefreshLootWindow
-- upvalue (see top of file) - rebuilds the whole section/icon layout from
-- whichever data source (session vs all-time) is currently selected.
RefreshLootWindow = function()
    if not lootWindow then return end

    local store
    if lootViewMode == "session" then
        store = (session and session.mobLoot) or {}
    else
        LootLedgerDB = LootLedgerDB or { sessions = {} }
        store = LootLedgerDB.mobLoot or {}
    end

    local mobRows = {}
    for mobName, rec in pairs(store) do
        local itemTotal = 0
        local itemRows = {}
        for itemKey, data in pairs(rec.items) do
            -- Filters excluded items (e.g. Soul Shard) out of the display
            -- even if they were recorded before the filter existed -
            -- IsExcludedItem() at the CHAT_MSG_LOOT level only stops NEW
            -- pickups from being recorded, it can't retroactively clean
            -- SavedVariables data from earlier sessions.
            if not IsExcludedItem(itemKey) then
                local price, source = GetBestPrice(itemKey)
                local total = (price or 0) * data.count
                itemTotal = itemTotal + total
                table.insert(itemRows, { itemKey = itemKey, count = data.count, total = total })
                if debugKillTracking then
                    Print(string.format("[debug] price: itemKey=%s name=%s count=%d unitPrice=%s source=%s total=%s",
                        tostring(itemKey), tostring(data.name), data.count, price and FormatGold(price) or "nil",
                        tostring(source), FormatGold(total)))
                end
            end
        end
        -- Coin looted counts as a "drop" in this list too, sorted by value
        -- like everything else (not pinned first) - if gold's your biggest
        -- earner off this mob, it lands first naturally.
        if rec.moneyLooted and rec.moneyLooted > 0 then
            table.insert(itemRows, { isMoney = true, total = rec.moneyLooted })
        end
        -- Items other raid/party members won off this mob - shown greyed
        -- out (see icon rendering below) at total=0 so they never affect
        -- itemTotal/value, but still visible as "this dropped here."
        if rec.unclaimed then
            for itemKey, data in pairs(rec.unclaimed) do
                if not IsExcludedItem(itemKey) then
                    table.insert(itemRows, { itemKey = itemKey, count = data.count, total = 0, unclaimed = true })
                end
            end
        end
        table.sort(itemRows, function(a, b) return a.total > b.total end)
        table.insert(mobRows, {
            name = mobName,
            kills = rec.kills,
            value = itemTotal + rec.moneyLooted,
            items = itemRows,
            lastUpdate = rec.lastUpdate or 0,
        })
    end
    -- Sort mode toggled via the R/V button in the header. "recent" reads
    -- as "what did I just kill", useful at a glance while actively
    -- farming; "value" surfaces the mobs actually worth the trip. Records
    -- saved before lastUpdate existed default to 0 (oldest) via the
    -- fallback above, rather than erroring on a missing field.
    if lootSortMode == "value" then
        table.sort(mobRows, function(a, b) return a.value > b.value end)
    else
        table.sort(mobRows, function(a, b) return a.lastUpdate > b.lastUpdate end)
    end

    local totalKills, totalValue = 0, 0
    for _, mr in ipairs(mobRows) do
        totalKills = totalKills + mr.kills
        totalValue = totalValue + mr.value
    end
    -- Two lines rather than one long one - each comfortably fits on its
    -- own even at MIN_WINDOW_WIDTH, where a single all-in-one line used
    -- to get clipped with "...". Time/Gold-per-hour only apply to This
    -- Session - All Time has no single elapsed-time denominator to
    -- divide by, it's a running total across every session ever logged.
    local line1 = string.format("%s | Kills: %d",
        lootViewMode == "session" and "This Session" or "All Time", totalKills)
    local line2 = string.format("Value: |cffffd700%s|r", FormatGold(totalValue))
    if lootViewMode == "session" and session then
        local elapsed = time() - session.startTime
        local mins = math.floor(elapsed / 60)
        local secs = math.floor(elapsed - mins * 60)
        line1 = line1 .. string.format(" | Time: %d:%02d", mins, secs)
        local elapsedHours = elapsed / 3600
        if elapsedHours > 0 then
            line2 = line2 .. string.format(" | Gold/hr: |cffffd700%s|r", FormatGoldShort(totalValue / elapsedHours))
        end
    end
    lootSummaryText:SetText(line1)
    lootSummaryText2:SetText(line2)

    -- Window is resizable now, so both the row width and how many icons
    -- fit per row are computed fresh each refresh instead of using fixed
    -- constants - a wider window fits more icons per row.
    local contentWidth = lootContent:GetWidth()
    local iconsPerRow = math.floor((contentWidth + ICON_PAD) / (ICON_SIZE + ICON_PAD))
    if iconsPerRow < 1 then iconsPerRow = 1 end

    local usedHeaders, usedIcons = 0, 0
    local yOffset = 0

    for _, mr in ipairs(mobRows) do
        usedHeaders = usedHeaders + 1
        local header = GetSectionHeader(usedHeaders)
        header:ClearAllPoints()
        header:SetWidth(contentWidth)
        header:SetPoint("TOPLEFT", lootContent, "TOPLEFT", 0, -yOffset)
        local collapsed = collapsedMobs[mr.name]
        header.nameText:SetText((collapsed and "+ " or "- ") .. mr.name)
        header.killText:SetText("x" .. mr.kills)
        header.valueText:SetText(FormatGold(mr.value))
        header.mobName = mr.name
        header.rowTop = yOffset
        header.rowHeight = HEADER_HEIGHT
        ApplyRowVisibility(header)
        yOffset = yOffset + HEADER_HEIGHT + 4

        if collapsed then
            yOffset = yOffset + SECTION_GAP
        else
        local col = 0
        for _, ir in ipairs(mr.items) do
            usedIcons = usedIcons + 1
            local btn = GetIconButton(usedIcons)
            btn:ClearAllPoints()
            btn:SetPoint("TOPLEFT", lootContent, "TOPLEFT", col * (ICON_SIZE + ICON_PAD), -yOffset)

            if ir.isMoney then
                btn.icon:SetTexture("Interface\\Icons\\INV_Misc_Coin_02")
                btn.icon:SetVertexColor(1, 1, 1)
                btn:SetAlpha(1)
                btn.countText:SetText(FormatGoldShort(ir.total))
                btn.itemKey = nil
                btn.moneyTotal = ir.total
                btn.unclaimed = false
                btn.border:SetBackdropBorderColor(1, 0.82, 0, 1)
            else
                -- Same shifted-fields destructuring as GetBestPrice - see
                -- its comment for why.
                local name, link, quality, ilvl, itype, isub, stack, equip, texture, sellPrice = GetItemInfo(ItemStringForKey(ir.itemKey))
                if debugKillTracking then
                    Print(string.format("[debug] icon: itemKey=%s texture=%s", tostring(ir.itemKey), tostring(texture)))
                end
                if not texture or texture == "" or type(texture) == "number" then
                    texture = "Interface\\Icons\\INV_Misc_QuestionMark"
                end
                btn.icon:SetTexture(texture)
                btn.countText:SetText(tostring(ir.count))
                btn.itemKey = ir.itemKey
                btn.moneyTotal = nil
                btn.unclaimed = ir.unclaimed or false
                if quality and quality >= 0 then
                    local r, g, b = GetItemQualityColor(quality)
                    btn.border:SetBackdropBorderColor(r, g, b, 1)
                else
                    btn.border:SetBackdropBorderColor(0.5, 0.5, 0.5, 1)
                end
                -- Someone else's pickup - shown but visually muted, and
                -- excluded from value (total was baked in as 0 above).
                if ir.unclaimed then
                    btn.icon:SetVertexColor(0.45, 0.45, 0.45)
                    btn:SetAlpha(0.55)
                else
                    btn.icon:SetVertexColor(1, 1, 1)
                    btn:SetAlpha(1)
                end
            end
            btn.rowTop = yOffset
            btn.rowHeight = ICON_SIZE
            ApplyRowVisibility(btn)

            col = col + 1
            if col >= iconsPerRow then
                col = 0
                yOffset = yOffset + ICON_SIZE + ICON_PAD
            end
        end
        if col > 0 then
            yOffset = yOffset + ICON_SIZE + ICON_PAD
        end
        yOffset = yOffset + SECTION_GAP
        end
    end

    local i = usedHeaders + 1
    while sectionHeaderPool[i] do
        sectionHeaderPool[i].rowTop = nil
        sectionHeaderPool[i]:Hide()
        i = i + 1
    end
    i = usedIcons + 1
    while iconButtonPool[i] do
        iconButtonPool[i].rowTop = nil
        iconButtonPool[i]:Hide()
        i = i + 1
    end
    lastUsedHeaders, lastUsedIcons = usedHeaders, usedIcons

    lootContent:SetHeight(yOffset > 0 and yOffset or 1)
end

local function ToggleLootWindow()
    CreateLootWindow()
    if lootWindow:IsShown() then
        lootWindow:Hide()
    else
        RefreshLootWindow()
        lootWindow:Show()
    end
end

-- ---------------------------------------------------------------------
-- Options window - the disenchant-value toggle (see GetDisenchantValue/
-- GetBestPrice), and the list of items filtered out via right-click on
-- an item icon (see FilterItem).
-- ---------------------------------------------------------------------

local OPTIONS_WIDTH = 260
local OPTIONS_HEIGHT = 320
local OPTIONS_ROW_HEIGHT = 22

local optionsWindow
local optionsContent
local optionsRowPool = {}
local deCheckbox

local function UnfilterItem(itemKey)
    if not itemKey or not LootLedgerDB or not LootLedgerDB.filteredItems then return end
    LootLedgerDB.filteredItems[itemKey] = nil
    MaybeRefreshLootWindow()
    if RefreshOptionsWindow then RefreshOptionsWindow() end
end

local function GetOptionsRow(index)
    local row = optionsRowPool[index]
    if row then return row end

    row = CreateFrame("Frame", nil, optionsContent)
    row:SetHeight(OPTIONS_ROW_HEIGHT)
    row:SetWidth(OPTIONS_WIDTH - 40)

    local icon = row:CreateTexture(nil, "ARTWORK")
    icon:SetWidth(18)
    icon:SetHeight(18)
    icon:SetPoint("LEFT", row, "LEFT", 0, 0)
    icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)
    row.icon = icon

    local removeBtn = CreateFrame("Button", nil, row, "UIPanelButtonTemplate")
    removeBtn:SetWidth(16)
    removeBtn:SetHeight(16)
    removeBtn:SetPoint("RIGHT", row, "RIGHT", 0, 0)
    removeBtn:SetText("x")
    removeBtn:SetScript("OnClick", function()
        UnfilterItem(this.itemKey)
    end)
    removeBtn:SetScript("OnEnter", function()
        GameTooltip:SetOwner(this, "ANCHOR_LEFT")
        GameTooltip:SetText("Remove from filter")
        GameTooltip:Show()
    end)
    removeBtn:SetScript("OnLeave", function()
        GameTooltip:Hide()
    end)
    row.removeBtn = removeBtn

    local nameText = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    nameText:SetPoint("LEFT", icon, "RIGHT", 6, 0)
    nameText:SetPoint("RIGHT", removeBtn, "LEFT", -4, 0)
    nameText:SetJustifyH("LEFT")
    row.nameText = nameText

    optionsRowPool[index] = row
    return row
end

local function CreateOptionsWindow()
    if optionsWindow then return end

    local f = CreateFrame("Frame", "LootLedgerOptionsWindow", UIParent)
    tinsert(UISpecialFrames, "LootLedgerOptionsWindow")
    f:SetWidth(OPTIONS_WIDTH)
    f:SetHeight(OPTIONS_HEIGHT)
    f:SetPoint("CENTER", UIParent, "CENTER", 0, 0)
    f:SetBackdrop({
        bgFile = "Interface\\Tooltips\\UI-Tooltip-Background",
        edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
        tile = true, tileSize = 16, edgeSize = 16,
        insets = { left = 4, right = 4, top = 4, bottom = 4 },
    })
    f:SetBackdropColor(0, 0, 0, 0.9)
    f:SetFrameStrata("DIALOG")
    f:SetMovable(true)
    f:EnableMouse(true)
    f:RegisterForDrag("LeftButton")
    f:SetScript("OnDragStart", function() this:StartMoving() end)
    f:SetScript("OnDragStop", function() this:StopMovingOrSizing() end)
    f:Hide()

    local title = f:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    title:SetPoint("TOP", f, "TOP", 0, -10)
    title:SetText("|cff" .. ACCENT_HEX .. "LootLedger Options|r")

    local closeBtn = CreateFrame("Button", nil, f, "UIPanelCloseButton")
    closeBtn:SetWidth(18)
    closeBtn:SetHeight(18)
    closeBtn:SetPoint("TOPRIGHT", f, "TOPRIGHT", -2, -2)
    closeBtn:SetScript("OnClick", function() f:Hide() end)

    deCheckbox = CreateFrame("CheckButton", "LootLedgerDECheckbox", f, "UICheckButtonTemplate")
    deCheckbox:SetWidth(20)
    deCheckbox:SetHeight(20)
    deCheckbox:SetPoint("TOPLEFT", f, "TOPLEFT", 14, -36)
    deCheckbox:SetScript("OnClick", function()
        LootLedgerDB = LootLedgerDB or { sessions = {} }
        LootLedgerDB.useDisenchantValue = (this:GetChecked() == 1)
        MaybeRefreshLootWindow()
    end)
    local deLabel = f:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    deLabel:SetPoint("LEFT", deCheckbox, "RIGHT", 2, 1)
    deLabel:SetPoint("RIGHT", f, "RIGHT", -14, 0)
    deLabel:SetJustifyH("LEFT")
    deLabel:SetText("Include disenchant value (if higher than vendor/AH)")

    local filterLabel = f:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    filterLabel:SetPoint("TOPLEFT", f, "TOPLEFT", 14, -66)
    filterLabel:SetText("|cffffd700Filtered Items|r")

    local emptyText = f:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    emptyText:SetPoint("TOPLEFT", f, "TOPLEFT", 14, -86)
    emptyText:SetPoint("TOPRIGHT", f, "TOPRIGHT", -14, -86)
    emptyText:SetJustifyH("LEFT")
    emptyText:SetText("Right-click an item icon in the Loot Tracker to filter it out.")
    emptyText:SetTextColor(0.6, 0.6, 0.6)
    f.emptyText = emptyText

    local scroll = CreateFrame("ScrollFrame", "LootLedgerOptionsScrollFrame", f, "UIPanelScrollFrameTemplate")
    scroll:SetPoint("TOPLEFT", f, "TOPLEFT", 14, -86)
    scroll:SetPoint("BOTTOMRIGHT", f, "BOTTOMRIGHT", -30, 14)

    local scrollBar = _G["LootLedgerOptionsScrollFrameScrollBar"]

    local content = CreateFrame("Frame", nil, scroll)
    content:SetWidth(OPTIONS_WIDTH - 40)
    content:SetHeight(1)
    scroll:SetScrollChild(content)
    optionsContent = content

    if pfUI and pfUI.api then
        pcall(function()
            pfUI.api.CreateBackdrop(f)
            pfUI.api.CreateBackdropShadow(f)
            pfUI.api.SkinCloseButton(closeBtn)
            pfUI.api.SkinCheckbox(deCheckbox)
            if scrollBar then
                pfUI.api.SkinScrollbar(scrollBar)
            end
        end)
    end

    optionsWindow = f
end

RefreshOptionsWindow = function()
    if not optionsWindow then return end

    deCheckbox:SetChecked(LootLedgerDB and LootLedgerDB.useDisenchantValue)

    local filtered = (LootLedgerDB and LootLedgerDB.filteredItems) or {}
    local itemKeys = {}
    for itemKey in pairs(filtered) do
        table.insert(itemKeys, itemKey)
    end
    table.sort(itemKeys, function(a, b) return a < b end)

    if table.getn(itemKeys) == 0 then
        optionsWindow.emptyText:Show()
    else
        optionsWindow.emptyText:Hide()
    end

    local yOffset = 0
    local used = 0
    for _, itemKey in ipairs(itemKeys) do
        used = used + 1
        local row = GetOptionsRow(used)
        row:ClearAllPoints()
        row:SetPoint("TOPLEFT", optionsContent, "TOPLEFT", 0, -yOffset)
        local name, link, quality, ilvl, itype, isub, stack, equip, texture = GetItemInfo(ItemStringForKey(itemKey))
        row.nameText:SetText(name or ("item " .. itemKey))
        if texture and texture ~= "" and type(texture) ~= "number" then
            row.icon:SetTexture(texture)
        else
            row.icon:SetTexture("Interface\\Icons\\INV_Misc_QuestionMark")
        end
        row.removeBtn.itemKey = itemKey
        row:Show()
        yOffset = yOffset + OPTIONS_ROW_HEIGHT
    end

    local i = used + 1
    while optionsRowPool[i] do
        optionsRowPool[i]:Hide()
        i = i + 1
    end

    optionsContent:SetHeight(yOffset > 0 and yOffset or 1)
end

ToggleOptionsWindow = function()
    CreateOptionsWindow()
    if optionsWindow:IsShown() then
        optionsWindow:Hide()
    else
        RefreshOptionsWindow()
        optionsWindow:Show()
    end
end

-- ---------------------------------------------------------------------
-- History window - past sessions logged by Restart Session (see
-- StopSession's LootLedgerDB.sessions entry), most recent first.
-- ---------------------------------------------------------------------

local HISTORY_WIDTH = 320
local HISTORY_HEIGHT = 360
local HISTORY_ROW_HEIGHT = 36

local historyWindow
local historyContent
local historyRowPool = {}

-- Same shape as StopSession's live chat summary, just reading a saved
-- entry's already-computed fields instead of recomputing from a live
-- session - lets you pull up the full item-by-item breakdown of any past
-- session without it having to still be "This Session".
local function PrintHistoryEntry(entry)
    Print("---- Session from " .. date("%m/%d %I:%M%p", entry.timestamp) .. " ----")
    Print(string.format("Time: %.1f min | Kills: %d | Unique items: %d",
        entry.duration / 60, entry.kills, table.getn(entry.loot)))
    for _, kr in ipairs(entry.killsByMob) do
        if kr.level then
            Print(string.format("  %dx %s (lvl %d)", kr.count, kr.name, kr.level))
        else
            Print(string.format("  %dx %s", kr.count, kr.name))
        end
    end
    if entry.unattributedKills and entry.unattributedKills > 0 then
        Print(string.format("  %dx (unnamed kill)", entry.unattributedKills))
    end
    for _, row in ipairs(entry.loot) do
        Print(string.format("  %dx %s = %s", row.count, row.name, FormatGold(row.total)))
    end
    if entry.moneyLooted and entry.moneyLooted > 0 then
        Print("Coin looted: " .. FormatGold(entry.moneyLooted))
    end
    Print("Total session value: " .. FormatGold(entry.grandTotal))
    if entry.duration > 0 then
        Print("Rate: ~" .. FormatGold(entry.grandTotal / (entry.duration / 3600)) .. " / hour")
    end
end

local function DeleteHistoryEntry(sessionIndex)
    if not sessionIndex or not LootLedgerDB or not LootLedgerDB.sessions then return end
    table.remove(LootLedgerDB.sessions, sessionIndex)
    if RefreshHistoryWindow then RefreshHistoryWindow() end
end

local function ClearHistory()
    if LootLedgerDB then
        LootLedgerDB.sessions = {}
    end
    if RefreshHistoryWindow then RefreshHistoryWindow() end
end

StaticPopupDialogs["LOOTLEDGER_CLEAR_HISTORY"] = {
    text = "Clear all logged session history? This cannot be undone.",
    button1 = "Yes",
    button2 = "No",
    OnAccept = function() ClearHistory() end,
    timeout = 0,
    whileDead = true,
    hideOnEscape = true,
}

local function GetHistoryRow(index)
    local row = historyRowPool[index]
    if row then return row end

    row = CreateFrame("Button", nil, historyContent)
    row:SetHeight(HISTORY_ROW_HEIGHT)
    row:SetWidth(HISTORY_WIDTH - 40)
    row:SetHighlightTexture("Interface\\Buttons\\ButtonHilight-Square", "ADD")
    row:SetScript("OnClick", function()
        if this.entry then PrintHistoryEntry(this.entry) end
    end)
    row:SetScript("OnEnter", function()
        GameTooltip:SetOwner(this, "ANCHOR_RIGHT")
        GameTooltip:SetText("Click for full breakdown in chat")
        GameTooltip:Show()
    end)
    row:SetScript("OnLeave", function()
        GameTooltip:Hide()
    end)

    local removeBtn = CreateFrame("Button", nil, row, "UIPanelButtonTemplate")
    removeBtn:SetWidth(16)
    removeBtn:SetHeight(16)
    removeBtn:SetPoint("TOPRIGHT", row, "TOPRIGHT", 0, 0)
    removeBtn:SetText("x")
    removeBtn:SetScript("OnClick", function()
        DeleteHistoryEntry(row.sessionIndex)
    end)
    removeBtn:SetScript("OnEnter", function()
        GameTooltip:SetOwner(this, "ANCHOR_LEFT")
        GameTooltip:SetText("Delete this entry")
        GameTooltip:Show()
    end)
    removeBtn:SetScript("OnLeave", function()
        GameTooltip:Hide()
    end)
    row.removeBtn = removeBtn

    local labelText = row:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    labelText:SetPoint("TOPLEFT", row, "TOPLEFT", 0, 0)
    labelText:SetPoint("RIGHT", removeBtn, "LEFT", -4, 0)
    labelText:SetJustifyH("LEFT")
    row.labelText = labelText

    local detailText = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    detailText:SetPoint("TOPLEFT", row, "TOPLEFT", 0, -16)
    detailText:SetPoint("RIGHT", row, "RIGHT", 0, 0)
    detailText:SetJustifyH("LEFT")
    row.detailText = detailText

    historyRowPool[index] = row
    return row
end

local function CreateHistoryWindow()
    if historyWindow then return end

    local f = CreateFrame("Frame", "LootLedgerHistoryWindow", UIParent)
    tinsert(UISpecialFrames, "LootLedgerHistoryWindow")
    f:SetWidth(HISTORY_WIDTH)
    f:SetHeight(HISTORY_HEIGHT)
    f:SetPoint("CENTER", UIParent, "CENTER", 0, 0)
    f:SetBackdrop({
        bgFile = "Interface\\Tooltips\\UI-Tooltip-Background",
        edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
        tile = true, tileSize = 16, edgeSize = 16,
        insets = { left = 4, right = 4, top = 4, bottom = 4 },
    })
    f:SetBackdropColor(0, 0, 0, 0.9)
    f:SetFrameStrata("DIALOG")
    f:SetMovable(true)
    f:EnableMouse(true)
    f:RegisterForDrag("LeftButton")
    f:SetScript("OnDragStart", function() this:StartMoving() end)
    f:SetScript("OnDragStop", function() this:StopMovingOrSizing() end)
    f:Hide()

    local title = f:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    title:SetPoint("TOP", f, "TOP", 0, -10)
    title:SetText("|cff" .. ACCENT_HEX .. "LootLedger History|r")

    local closeBtn = CreateFrame("Button", nil, f, "UIPanelCloseButton")
    closeBtn:SetWidth(18)
    closeBtn:SetHeight(18)
    closeBtn:SetPoint("TOPRIGHT", f, "TOPRIGHT", -2, -2)
    closeBtn:SetScript("OnClick", function() f:Hide() end)

    local clearBtn = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
    clearBtn:SetWidth(18)
    clearBtn:SetHeight(18)
    clearBtn:SetPoint("RIGHT", closeBtn, "LEFT", -2, 0)
    clearBtn:SetText("|cffff5555R|r")
    clearBtn:SetScript("OnClick", function()
        StaticPopup_Show("LOOTLEDGER_CLEAR_HISTORY")
    end)
    clearBtn:SetScript("OnEnter", function()
        GameTooltip:SetOwner(this, "ANCHOR_LEFT")
        GameTooltip:SetText("|cffff5555Clear History|r")
        GameTooltip:Show()
    end)
    clearBtn:SetScript("OnLeave", function()
        GameTooltip:Hide()
    end)

    local hintText = f:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    hintText:SetPoint("TOPLEFT", f, "TOPLEFT", 14, -34)
    hintText:SetPoint("TOPRIGHT", f, "TOPRIGHT", -14, -34)
    hintText:SetJustifyH("LEFT")
    hintText:SetText("Click a session for its full breakdown in chat.")
    hintText:SetTextColor(0.6, 0.6, 0.6)

    local emptyText = f:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    emptyText:SetPoint("TOPLEFT", f, "TOPLEFT", 14, -54)
    emptyText:SetPoint("TOPRIGHT", f, "TOPRIGHT", -14, -54)
    emptyText:SetJustifyH("LEFT")
    emptyText:SetText("No sessions logged yet - use Restart Session to log one.")
    emptyText:SetTextColor(0.6, 0.6, 0.6)
    f.emptyText = emptyText

    local scroll = CreateFrame("ScrollFrame", "LootLedgerHistoryScrollFrame", f, "UIPanelScrollFrameTemplate")
    scroll:SetPoint("TOPLEFT", f, "TOPLEFT", 14, -54)
    scroll:SetPoint("BOTTOMRIGHT", f, "BOTTOMRIGHT", -30, 14)

    local scrollBar = _G["LootLedgerHistoryScrollFrameScrollBar"]

    local content = CreateFrame("Frame", nil, scroll)
    content:SetWidth(HISTORY_WIDTH - 40)
    content:SetHeight(1)
    scroll:SetScrollChild(content)
    historyContent = content

    if pfUI and pfUI.api then
        pcall(function()
            pfUI.api.CreateBackdrop(f)
            pfUI.api.CreateBackdropShadow(f)
            pfUI.api.SkinCloseButton(closeBtn)
            pfUI.api.SkinButton(clearBtn)
            clearBtn:SetBackdropBorderColor(1, 0.15, 0.15, 1)
            if scrollBar then
                pfUI.api.SkinScrollbar(scrollBar)
            end
        end)
    end

    historyWindow = f
end

RefreshHistoryWindow = function()
    if not historyWindow then return end

    local sessions = (LootLedgerDB and LootLedgerDB.sessions) or {}
    local total = table.getn(sessions)

    if total == 0 then
        historyWindow.emptyText:Show()
    else
        historyWindow.emptyText:Hide()
    end

    local yOffset = 0
    local used = 0
    local i
    for i = total, 1, -1 do
        used = used + 1
        local entry = sessions[i]
        local row = GetHistoryRow(used)
        row:ClearAllPoints()
        row:SetPoint("TOPLEFT", historyContent, "TOPLEFT", 0, -yOffset)
        row.entry = entry
        row.sessionIndex = i

        local label = entry.label or "Session"
        row.labelText:SetText(string.format("|cffffd700%s|r - %s", label, date("%m/%d %I:%M%p", entry.timestamp)))

        local hours = math.floor(entry.duration / 3600)
        local mins = math.floor((entry.duration - hours * 3600) / 60)
        local durationText = hours > 0 and string.format("%dh %dm", hours, mins) or string.format("%dm", mins)

        local gph = 0
        if entry.duration > 0 then
            gph = entry.grandTotal / (entry.duration / 3600)
        end
        row.detailText:SetText(string.format("%s | %d kills | |cffffd700%s|r | %s/hr",
            durationText, entry.kills, FormatGold(entry.grandTotal), FormatGoldShort(gph)))

        row:Show()
        yOffset = yOffset + HISTORY_ROW_HEIGHT
    end

    local j = used + 1
    while historyRowPool[j] do
        historyRowPool[j]:Hide()
        j = j + 1
    end

    historyContent:SetHeight(yOffset > 0 and yOffset or 1)
end

ToggleHistoryWindow = function()
    CreateHistoryWindow()
    if historyWindow:IsShown() then
        historyWindow:Hide()
    else
        RefreshHistoryWindow()
        historyWindow:Show()
    end
end

-- ---------------------------------------------------------------------
-- Minimap button - gold coin icon, draggable around the ring, click
-- toggles the Loot Tracker window. Position persists across sessions.
-- ---------------------------------------------------------------------

local function CreateMinimapButton()
    local btn = CreateFrame("Button", "LootLedgerMinimapButton", Minimap)
    btn:SetWidth(31)
    btn:SetHeight(31)
    btn:SetFrameStrata("MEDIUM")
    btn:SetFrameLevel(8)
    btn:RegisterForClicks("LeftButtonUp")
    btn:RegisterForDrag("LeftButton")
    btn:SetMovable(true)

    local overlay = btn:CreateTexture(nil, "OVERLAY")
    overlay:SetWidth(53)
    overlay:SetHeight(53)
    overlay:SetTexture("Interface\\Minimap\\MiniMap-TrackingBorder")
    overlay:SetPoint("TOPLEFT", 0, 0)

    local icon = btn:CreateTexture(nil, "BACKGROUND")
    icon:SetWidth(20)
    icon:SetHeight(20)
    icon:SetTexture("Interface\\Icons\\INV_Misc_Coin_02")
    icon:SetPoint("TOPLEFT", 7, -6)
    icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)

    -- Same plain square highlight the item icons use elsewhere in this
    -- addon, not Blizzard's zoom-button glow (a circular halo meant for
    -- the minimap +/- buttons specifically).
    local highlight = btn:CreateTexture(nil, "HIGHLIGHT")
    highlight:SetWidth(20)
    highlight:SetHeight(20)
    highlight:SetPoint("TOPLEFT", 7, -6)
    highlight:SetTexture("Interface\\Buttons\\ButtonHilight-Square")
    highlight:SetBlendMode("ADD")

    local function UpdatePosition(angle)
        btn:ClearAllPoints()
        btn:SetPoint("CENTER", Minimap, "CENTER", math.cos(angle) * 80, math.sin(angle) * 80)
    end

    UpdatePosition(LootLedgerDB.minimapAngle or 3.93) -- ~225 deg, bottom-left

    btn:SetScript("OnDragStart", function()
        this:SetScript("OnUpdate", function()
            local mx, my = Minimap:GetCenter()
            local px, py = GetCursorPosition()
            local scale = Minimap:GetEffectiveScale()
            px, py = px / scale, py / scale
            local angle = math.atan2(py - my, px - mx)
            LootLedgerDB.minimapAngle = angle
            UpdatePosition(angle)
        end)
    end)
    btn:SetScript("OnDragStop", function()
        this:SetScript("OnUpdate", nil)
    end)

    btn:SetScript("OnClick", function()
        ToggleLootWindow()
    end)

    btn:SetScript("OnEnter", function()
        GameTooltip:SetOwner(this, "ANCHOR_LEFT")
        GameTooltip:SetText("|cff" .. ACCENT_HEX .. "LootLedger|r")
        GameTooltip:AddLine("Click to open the Loot Tracker", 1, 1, 1)
        GameTooltip:AddLine("Drag to move this button", 0.7, 0.7, 0.7)
        GameTooltip:Show()
    end)
    btn:SetScript("OnLeave", function()
        GameTooltip:Hide()
    end)

    return btn
end

CreateMinimapButton()

-- ---------------------------------------------------------------------
-- Event handling
-- ---------------------------------------------------------------------

local frame = CreateFrame("Frame")
frame:RegisterEvent("CHAT_MSG_LOOT")
frame:RegisterEvent("CHAT_MSG_MONEY")
frame:RegisterEvent("UNIT_HEALTH")

frame:SetScript("OnEvent", function()
    if event == "UNIT_HEALTH" then
        -- A death is detected via any alias going UnitIsDead()==true -
        -- nameplateN aliases fire this directly even for mobs never
        -- individually targeted, at the same moment as the raw-GUID
        -- alias. UnitExists(arg1) resolves whichever alias fired to the
        -- same real GUID, so deduping on that GUID (handledDeaths)
        -- collapses the multiple alias-events per kill into one.
        --
        -- Ownership isn't decided here - see the pendingKills comment near
        -- the top of this file for why tap-checking is deferred. The
        -- debug print below fires unconditionally (not just while a
        -- session is active) so /ll debugkill shows something regardless
        -- of session state; only the pendingKills/handledDeaths
        -- bookkeeping is gated on session.
        if arg1 then
            local exists, guid = UnitExists(arg1)
            if exists and guid and UnitIsDead(arg1) and not UnitIsPlayer(arg1)
                and UnitCanAttack("player", arg1) then
                -- Scoped to actual deaths only, not every health tick, so
                -- it doesn't bury the CHAT_MSG_LOOT/CHAT_MSG_MONEY debug
                -- lines under UNIT_HEALTH spam.
                if debugKillTracking then
                    Print(string.format("[debug] death: arg1=%s guid=%s alreadyQueued=%s",
                        tostring(arg1), tostring(guid), tostring(handledDeaths[guid] ~= nil)))
                end
                if session and not handledDeaths[guid] then
                    handledDeaths[guid] = true
                    table.insert(pendingKills, {
                        guid = guid,
                        name = UnitName(arg1),
                        level = UnitLevel(arg1),
                        deathTime = GetTime(),
                    })
                end
            end
        end
        return
    end

    if event == "CHAT_MSG_MONEY" and debugKillTracking then
        Print("[debug] CHAT_MSG_MONEY raw text: \"" .. tostring(arg1) .. "\"")
    end

    if not session then return end

    if event == "CHAT_MSG_LOOT" then
        -- vanilla loot messages contain a real item link, e.g.
        -- "You receive loot: |cffffffff|Hitem:6522:0:0:0:0:0:0:0|h[Deviate Fish]|h|rx2."
        -- In a group/raid, CHAT_MSG_LOOT also carries other players'
        -- pickups as third-person broadcasts - "PlayerName receives loot:
        -- [Item]." - and on this server, roll results too: a "Greed Roll -
        -- N for [Item] by Name" line per person who rolled, then a
        -- "Name won: [Item]" line for the winner, all as their own
        -- CHAT_MSG_LOOT events, none of which are an actual loot receipt.
        -- A loose "starts with You" / "contains an item link" check
        -- can't tell those apart from the real thing - it counted every
        -- single roll line as its own drop (a 5-person roll on one item
        -- read as "5 of that item dropped"), and counted the player's own
        -- "You have selected Greed for: [Item]" roll-participation line
        -- as if they'd actually received it. Requiring the exact
        -- "receive(s) loot:" phrasing (or " won: " for the winner
        -- announcement) instead of just a "You" prefix filters that
        -- process noise out, leaving only genuine pickups.
        --
        -- A won roll never generates a separate "You receive loot:" line
        -- on this server - "You won: [Item]." is the only notification,
        -- so it has to count as an own pickup too, not just anyone else's
        -- win ("PlayerName won: [Item].", still only matched below).
        local isOwnPickup = (string.find(arg1, "^You receive loot:") or string.find(arg1, "^You won:")) ~= nil
        local isOtherPickup = (not isOwnPickup)
            and (string.find(arg1, "receives loot:") or string.find(arg1, " won: "))

        if isOwnPickup then
            local itemID, suffixID, parsedName = ParseItemLink(arg1)
            if itemID then
                local itemKey = BuildItemKey(itemID, suffixID)
                if IsExcludedItem(itemKey) then
                    if debugKillTracking then
                        Print("[debug] CHAT_MSG_LOOT ignored (excluded item, e.g. Soul Shard): \"" .. tostring(arg1) .. "\"")
                    end
                    return
                end
                local qty = 1
                local _, _, qtyStr = string.find(arg1, "%]x(%d+)")
                if qtyStr then qty = tonumber(qtyStr) end

                if not session.loot[itemKey] then
                    session.loot[itemKey] = {
                        name = parsedName or ("item " .. itemKey),
                        link = ItemStringForKey(itemKey),
                        count = 0,
                    }
                end
                session.loot[itemKey].count = session.loot[itemKey].count + qty

                -- attribute this loot to whichever mob's corpse it came
                -- from, if the corpse being looted is one we tracked a
                -- kill for (see ResolveLootOwner for the tiered fallback -
                -- target match, sticky corpse, then raid-recency).
                -- Unmatched loot still counts in the plain session total
                -- above, just without per-mob attribution.
                local ownerName, method = ResolveLootOwner()
                if debugKillTracking then
                    Print(string.format("[debug] CHAT_MSG_LOOT: item=%s corpseOwner=%s (%s)",
                        tostring(session.loot[itemKey].name), tostring(ownerName), tostring(method)))
                end
                if ownerName then
                    RecordMobLootItem(ownerName, itemKey, session.loot[itemKey].name, qty)
                end
            end
        elseif isOtherPickup then
            -- Someone else's pickup ("PlayerName receives loot: [Item]." or
            -- the roll winner announcement "Name won: [Item]"), still
            -- worth showing in the window so a mob's full drop table is
            -- visible even for items you didn't win - recorded separately
            -- via RecordMobUnclaimedItem, which never touches
            -- itemTotal/value (see RefreshLootWindow).
            local itemID, suffixID, parsedName = ParseItemLink(arg1)
            if itemID then
                local itemKey = BuildItemKey(itemID, suffixID)
                if IsExcludedItem(itemKey) then
                    if debugKillTracking then
                        Print("[debug] CHAT_MSG_LOOT ignored (excluded item, e.g. Soul Shard): \"" .. tostring(arg1) .. "\"")
                    end
                    return
                end
                local qty = 1
                local _, _, qtyStr = string.find(arg1, "%]x(%d+)")
                if qtyStr then qty = tonumber(qtyStr) end
                local itemName = parsedName or ("item " .. itemKey)

                local ownerName, method = ResolveLootOwner()
                if debugKillTracking then
                    Print(string.format("[debug] CHAT_MSG_LOOT (other player's pickup): item=%s corpseOwner=%s (%s) - \"%s\"",
                        tostring(itemName), tostring(ownerName), tostring(method), tostring(arg1)))
                end
                if ownerName then
                    RecordMobUnclaimedItem(ownerName, itemKey, itemName, qty)
                end
            elseif debugKillTracking then
                Print("[debug] CHAT_MSG_LOOT ignored (no item link, not the player's own pickup): \"" .. tostring(arg1) .. "\"")
            end
        elseif debugKillTracking then
            -- Roll-in-progress noise (e.g. "Greed Roll - N for [Item] by
            -- Name") - not a loot event at all, just the bidding process,
            -- one line per person who rolled on the same single item.
            Print("[debug] CHAT_MSG_LOOT ignored (not a loot receipt): \"" .. tostring(arg1) .. "\"")
        end

    elseif event == "CHAT_MSG_MONEY" then
        -- e.g. "You loot 1 Gold, 3 Copper." or "Your share is 2 Silver."
        local copper = ParseMoneyFromText(arg1)
        if copper then
            session.moneyLooted = session.moneyLooted + copper

            local ownerName, method = ResolveLootOwner()
            if debugKillTracking then
                Print(string.format("[debug] CHAT_MSG_MONEY: copper=%d corpseOwner=%s (%s)",
                    copper, tostring(ownerName), tostring(method)))
            end
            if ownerName then
                RecordMobMoney(ownerName, copper)
            end
        end
    end
end)

-- Resolves pendingKills: once PENDING_KILL_DELAY has given the tap flag
-- time to sync, check UnitIsTappedByPlayer and either count the kill or
-- drop it (someone else's kill - a nearby mob that died, but not to the
-- player). Throttled via updateAccum since OnUpdate fires every rendered
-- frame and pendingKills is normally empty.
local updateAccum = 0
frame:SetScript("OnUpdate", function()
    if table.getn(pendingKills) == 0 then return end

    updateAccum = updateAccum + arg1
    if updateAccum < 0.1 then return end
    updateAccum = 0

    local now = GetTime()
    local stillPending = {}
    for _, pk in ipairs(pendingKills) do
        local tapped = UnitExists(pk.guid) and UnitIsTappedByPlayer(pk.guid)
        local expired = (now - pk.deathTime) >= PENDING_KILL_DELAY
        if tapped then
            RecordKill(pk.guid, pk.name, pk.level)
            if debugKillTracking then
                Print(string.format("[debug] pending kill CONFIRMED: %s (waited %.1fs)",
                    tostring(pk.name), now - pk.deathTime))
            end
        elseif expired then
            if debugKillTracking then
                Print(string.format("[debug] pending kill DROPPED (never tapped by player): %s",
                    tostring(pk.name)))
            end
        else
            table.insert(stillPending, pk)
        end
    end
    pendingKills = stillPending
end)

-- ---------------------------------------------------------------------
-- Slash command
-- ---------------------------------------------------------------------

SLASH_LOOTLEDGER1 = "/ll"
SlashCmdList["LOOTLEDGER"] = function(msg)
    local _, _, cmd, rest = string.find(msg, "^(%S*)%s*(.-)%s*$")
    cmd = string.lower(cmd or "")
    rest = rest or ""

    if cmd == "" or cmd == "drops" then
        -- Bare /ll is the main entry point - opens/closes the Loot
        -- Tracker window, the thing you reach for most. /ll drops still
        -- works too (same action) so nothing that used to work breaks.
        ToggleLootWindow()

    elseif cmd == "status" then
        PrintStatus()

    elseif cmd == "loot" then
        PrintLoot()

    elseif cmd == "debug" then
        if aux then
            Print("aux global: FOUND")
            local realm = GetRealmName()
            local faction = UnitFactionGroup("player")
            local key = realm .. "|" .. faction
            Print("Your realm|faction key: " .. key)
            if aux.faction and aux.faction[key] then
                Print("Found data for that key.")
                if aux.faction[key].history then
                    local n = 0
                    for _ in pairs(aux.faction[key].history) do n = n + 1 end
                    Print("History entries: " .. n)
                else
                    Print("No 'history' table under that key.")
                end
            else
                Print("No aux.faction data for that key.")
            end
            -- List every realm|faction key Aux actually has data under, so we
            -- can confirm GetAuxPrice() is only ever reading the current
            -- realm's key and not accidentally blending in another one.
            if aux.faction then
                Print("All realm|faction keys present in Aux's saved data:")
                for k, v in pairs(aux.faction) do
                    local n = 0
                    if v.history then
                        for _ in pairs(v.history) do n = n + 1 end
                    end
                    local marker = (k == key) and "  <-- yours" or ""
                    Print("  " .. k .. " (" .. n .. " entries)" .. marker)
                end
            end
        else
            Print("aux global: NOT FOUND.")
        end

    elseif cmd == "debugkill" then
        debugKillTracking = not debugKillTracking
        if debugKillTracking then
            Print("Kill/money diagnostic ON. Target something and kill it - watch for")
            Print("[debug] lines showing raw event data. /ll debugkill again to turn off.")
        else
            Print("Kill/money diagnostic OFF.")
        end

    elseif cmd == "debugprice" then
        local _, _, idPart, suffixPart = string.find(rest or "", "^(%d+)%s*(%d*)$")
        local itemID = idPart and tonumber(idPart)
        local suffixID = (suffixPart and suffixPart ~= "" and tonumber(suffixPart)) or 0
        if not itemID then
            Print("Usage: /ll debugprice <itemID> [suffixID] (e.g. /ll debugprice 7611, or /ll debugprice 8345 867 for a suffixed roll)")
        elseif not aux or not aux.faction then
            Print("aux global not found.")
        else
            local realm = GetRealmName()
            local faction = UnitFactionGroup("player")
            local key = realm .. "|" .. faction
            local factionData = aux.faction[key]
            if not factionData or not factionData.history then
                Print("No history data under your key (" .. key .. ").")
            else
                local itemKey = BuildItemKey(itemID, suffixID)
                local valstr = factionData.history[itemKey]
                if not valstr then
                    Print("No history entry found for itemKey " .. itemKey .. " under key " .. key)
                else
                    Print(string.format("  raw: %s = %s", itemKey, tostring(valstr)))
                    local _, _, mainTS, mainPrice, rest2 = string.find(valstr, "^(%d+)#([%d%.]*)#?(.*)$")
                    mainPrice = tonumber(mainPrice)

                    local points = {}
                    local remaining = rest2
                    while remaining and remaining ~= "" do
                        local _, e, p, t = string.find(remaining, "^([%d%.]+)@(%d+)")
                        if not p then break end
                        table.insert(points, { price = tonumber(p), ts = tonumber(t) })
                        remaining = string.sub(remaining, e + 1)
                        if string.sub(remaining, 1, 1) == ";" then
                            remaining = string.sub(remaining, 2)
                        else
                            break
                        end
                    end

                    if table.getn(points) == 0 then
                        Print(string.format("No data_points yet - falling back to daily_min_buyout: %s",
                            mainPrice and FormatGold(mainPrice) or "nil"))
                    else
                        local newestTS = points[1].ts
                        for i = 2, table.getn(points) do
                            if points[i].ts > newestTS then newestTS = points[i].ts end
                        end
                        local totalWeight = 0
                        for i = 1, table.getn(points) do
                            local days = math.floor((newestTS - points[i].ts) / 86400 + 0.5)
                            points[i].weight = 0.99 ^ days
                            totalWeight = totalWeight + points[i].weight
                        end
                        for i = 1, table.getn(points) do
                            points[i].weight = points[i].weight / totalWeight
                        end
                        local byTime = {}
                        for i = 1, table.getn(points) do byTime[i] = points[i] end
                        table.sort(byTime, function(a, b) return a.ts > b.ts end)
                        Print(string.format("%d data_points (newest first):", table.getn(byTime)))
                        for i = 1, table.getn(byTime) do
                            Print(string.format("  %s  ts=%s  weight=%.3f", FormatGold(byTime[i].price), tostring(byTime[i].ts), byTime[i].weight))
                        end

                        local byPrice = {}
                        for i = 1, table.getn(points) do byPrice[i] = points[i] end
                        table.sort(byPrice, function(a, b) return a.price < b.price end)
                        local cum = 0
                        local result = byPrice[table.getn(byPrice)].price
                        for i = 1, table.getn(byPrice) do
                            cum = cum + byPrice[i].weight
                            if cum >= 0.5 then
                                result = byPrice[i].price
                                break
                            end
                        end
                        Print(string.format("GetAuxPrice() weighted median would return: %s", FormatGold(result)))
                    end
                end
            end
        end

    elseif cmd == "testdata" then
        -- Seeds a few fake mobs/items/coin via the same Record* functions
        -- real kills use, so the data shape is guaranteed correct - purely
        -- for eyeballing the Loot Tracker window's layout/icons/reset menu
        -- without having to actually farm. Real itemIDs so icons/tooltips
        -- render for real.
        local fakes = {
            { name = "Test Wolf", kills = 5, money = 12345,
              items = { { id = 2589, name = "Linen Cloth", qty = 3 }, { id = 3927, name = "Light Leather", qty = 2 } } },
            { name = "Test Bandit", kills = 3, money = 45678,
              items = { { id = 2592, name = "Wool Cloth", qty = 4 }, { id = 6948, name = "Hearthstone", qty = 1 } } },
            { name = "Test Golem", kills = 1, money = 987654,
              items = { { id = 7909, name = "Moss Agate", qty = 1 } } },
        }
        for _, mob in ipairs(fakes) do
            for i = 1, mob.kills do
                RecordMobKillForDrops(mob.name)
            end
            RecordMobMoney(mob.name, mob.money)
            for _, item in ipairs(mob.items) do
                RecordMobLootItem(mob.name, BuildItemKey(item.id, 0), item.name, item.qty)
            end
        end
        Print("Test data loaded - /ll to view it. /ll testdata again adds more (does not replace).")

    elseif cmd == "help" then
        Print("Commands: /ll (opens the Loot Tracker), /ll status, /ll loot, /ll debug, /ll debugkill, /ll debugprice, /ll testdata")

    else
        Print("Unknown command. /ll opens the Loot Tracker - /ll help for the full command list.")
    end
end

-- One-time per-login migration: pre-1.3.0 saves keyed loot entries by a
-- bare numeric itemID (see the item-identity section near the top of
-- this file). Reinterpreted as suffix 0 - the overwhelmingly common
-- case, and the only option available, since old data never captured
-- which suffix actually dropped - so existing history survives under
-- the new "itemID:suffixID" keys instead of silently going invisible
-- (every lookup against it would miss until the exact same item
-- happened to drop again under its new key).
local function MigrateItemKeys(t)
    if not t then return end
    local toMove = {}
    local k
    for k in pairs(t) do
        if type(k) == "number" then
            table.insert(toMove, k)
        end
    end
    local i
    for i = 1, table.getn(toMove) do
        local oldKey = toMove[i]
        local newKey = BuildItemKey(oldKey, 0)
        if t[newKey] == nil then
            t[newKey] = t[oldKey]
        end
        t[oldKey] = nil
    end
end

local function MigrateAllItemKeys()
    MigrateItemKeys(LootLedgerDB.filteredItems)
    if LootLedgerDB.mobLoot then
        local mobName, rec
        for mobName, rec in pairs(LootLedgerDB.mobLoot) do
            MigrateItemKeys(rec.items)
            MigrateItemKeys(rec.unclaimed)
        end
    end
    if session then
        MigrateItemKeys(session.loot)
        if session.mobLoot then
            local mobName, rec
            for mobName, rec in pairs(session.mobLoot) do
                MigrateItemKeys(rec.items)
                MigrateItemKeys(rec.unclaimed)
            end
        end
    end
end

-- Tracking is always-on: give `session` a real value immediately so
-- nothing null-derefs before login finishes - genuine restoration (below)
-- happens once PLAYER_ENTERING_WORLD fires, so this placeholder only
-- matters for the brief loading-screen window where no gameplay events
-- can fire anyway.
StartSession(true)

-- This client doesn't reliably have the real LootLedgerDB (loaded from
-- the WTF SavedVariables file) in place by the time this file's own
-- top-level code runs, unlike stock Blizzard clients where that's
-- synchronous - the placeholder StartSession(true) above can end up
-- linked to a stand-in table instead of the real saved one.
-- LootLedgerDB.mobLoot (the "All Time" store) never runs into this
-- because it's only ever read lazily from inside functions that fire
-- later, well after login, by which point the real table is in place.
-- Deferring this same restore-or-adopt check to PLAYER_ENTERING_WORLD
-- fixes it the same way.
local loginFrame = CreateFrame("Frame")
loginFrame:RegisterEvent("PLAYER_ENTERING_WORLD")
loginFrame:SetScript("OnEvent", function()
    loginFrame:UnregisterEvent("PLAYER_ENTERING_WORLD")
    if LootLedgerDB and LootLedgerDB.currentSession and LootLedgerDB.currentSession ~= session then
        -- A real saved session from before this login, distinct from the
        -- placeholder above - adopt it. corpseOwner/lastResolvedCorpse/
        -- lastKilledMob are always cleared even when restoring - they
        -- reference target/corpse state from the previous client process
        -- that no longer exists, and would otherwise misattribute the
        -- first loot of the new login. The other session.* fields are
        -- defensively defaulted so a session saved by an older version of
        -- the addon (missing a field added since) still loads instead of
        -- erroring.
        session = LootLedgerDB.currentSession
        session.corpseOwner = {}
        session.lastResolvedCorpse = nil
        session.lastKilledMob = nil
        session.startTime = session.startTime or time()
        session.kills = session.kills or 0
        session.unattributedKills = session.unattributedKills or 0
        session.mobKills = session.mobKills or {}
        session.loot = session.loot or {}
        session.moneyLooted = session.moneyLooted or 0
        session.mobLoot = session.mobLoot or {}
        Print(string.format("Restored session from before login (%d kills).", session.kills))
    else
        -- No real saved session (or the placeholder is already correctly
        -- linked in) - just make sure the NOW-current LootLedgerDB (which
        -- may be a different table object than whatever existed when the
        -- placeholder was created) actually points at it.
        LootLedgerDB = LootLedgerDB or { sessions = {} }
        LootLedgerDB.currentSession = session
    end

    -- aux is listed as an OptionalDep because it's genuinely optional in
    -- the .toc-mechanics sense (LootLedger won't error without it, and
    -- vendor sell price is still a real, if lower, fallback) - but
    -- "reports your gold/hour" is the addon's whole pitch, and vendor
    -- price alone systematically undervalues anything actually worth
    -- farming. Worth an explicit heads-up rather than silently reporting
    -- numbers that read as correct but are missing their biggest
    -- component - checked here (not at top-level file load) for the
    -- same load-order-safety reason as MigrateAllItemKeys below.
    if not aux or not aux.faction then
        Print("aux-addon not detected - gold/hour will only reflect vendor sell prices, not AH value. Install aux for accurate farming totals.")
    end

    -- Only safe here, not at top-level file load - see MigrateItemKeys'
    -- comment and the LootLedgerDB.mobLoot timing note above.
    MigrateAllItemKeys()
    MaybeRefreshLootWindow()
end)

-- session and LootLedgerDB.currentSession are meant to be the exact same
-- table so every mutation during play is already saved with no extra
-- work - this is a defensive re-sync of the reference itself right
-- before the client writes SavedVariables to disk, in case anything
-- (including the same load-order quirk worked around above) ever leaves
-- them pointing at different tables.
local logoutFrame = CreateFrame("Frame")
logoutFrame:RegisterEvent("PLAYER_LOGOUT")
logoutFrame:SetScript("OnEvent", function()
    LootLedgerDB.currentSession = session
end)

Print("Loaded v1.3.0. Always tracking - /ll for the loot tracker.")
