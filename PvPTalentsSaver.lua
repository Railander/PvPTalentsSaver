-- PvP Talents Saver
-- Remembers the PvP talents chosen on each talent loadout and puts them back
-- whenever that loadout becomes active again (loadout swap, spec swap).
--
-- Model: one tracked loadout (the spec's last selected saved loadout). PvP
-- talent changes save into it; a change of the selected loadout (or spec)
-- restores the new loadout's saved set instead. Login and /reload change no
-- talents, so they take the live set as the current loadout's. The two are
-- kept apart: a PvP update that arrives while the selection has moved is the
-- switch itself (spec swaps change PvP talents server-side), never a save,
-- and the updates caused by our own restore are not saved either -- otherwise
-- a half-applied restore would overwrite the loadout it was restoring. A
-- player change during that window shows up as a slot holding something our
-- writes cannot explain: it ends the restore and saves the player's set.
--
-- Sets are stored per slot ({slot1, slot2, ...}, 0 = empty) and keyed by the
-- loadout's configID in one account-wide table (as in v2), so a configID must
-- identify the loadout across characters; deleted loadouts are dropped. The
-- starter build (the game's shared starter loadout) and "no loadout
-- selected" are not tracked: the game already remembers PvP talents per spec
-- for those.
--
-- Writes: a restore is a single attempt, made only where the addon can tell
-- the game accepts talent changes -- not in combat, and not once a PvP match
-- (rated or unrated) or a Mythic+ run has started; prep phases and raids are
-- fine -- and in pcall, so a refusal can never break the event handler.
-- Nothing is queued for a later opportunity: talents that cannot be changed
-- stay as they are, and the loadout keeps its saved set for the next time it
-- becomes active. Two things do wait. A save whose slots could not be read
-- (nil slot info under restrictions -- never saved) is retried on the next
-- wake-up (combat end, restriction change, zoning). And the writes of a
-- restore abandoned by a loadout switch are still answered: the addon
-- remembers which set they came from, so their answers are not saved into
-- the newly tracked loadout, and once they have settled it re-applies that
-- loadout's set if they left it wrong (only while it is still the selected
-- one -- a later switch's pass owns the new selection).
--
-- A slot saved as empty is not cleared: clearing has no documented call, so
-- a restore leaves whatever is in that slot alone.
--
-- Everything is event driven: events are coalesced into one deferred pass on
-- the next frame (talent APIs report the new state only after the event), no
-- polling, no per-frame code. No slash commands, no chat output.

local PTS_ADDON = "PvPTalentsSaver";
local PTS_DB_NAME = "PvPTalentsSaverDB"; -- kept from v1/v2 so existing saves carry over
local PTS_MAX_SLOTS = 8; -- scan cap; the real count is wherever slot info ends
local PTS_VERIFY_DELAY = 2; -- seconds for the server to answer a restore

local PTS_db; -- alias for the PvPTalentsSaverDB SavedVariables table, set on ADDON_LOADED

-- Session state. Declared HERE, above every function that reads or writes it.
local PTS_loadout; -- configID whose PvP talents are being tracked (nil = none)
local PTS_started = false; -- the first pass with a known spec has run
local PTS_inWorld = false; -- the player has entered the world since this load
local PTS_restoring; -- saved set being restored while its writes are in flight
local PTS_restoringFrom; -- live slots when the restore started (divergence base)
local PTS_pendingSave; -- loadout whose change could not be read yet; saved on wake-ups
local PTS_pvpChanged = false; -- a PvP update arrived since the last pass
local PTS_passQueued = false;
local PTS_verifyTimer;

local PTS_frame = CreateFrame("Frame");

-- Returns the tracked loadout (nil = none) and whether the spec is known yet.
-- The starter build is active config while the game still reports the last
-- saved loadout, so it is checked first.
local function PTS_SelectedLoadout()
	local specID = PlayerUtil.GetCurrentSpecID();
	if not specID then
		return nil, false;
	end
	if C_ClassTalents.GetStarterBuildActive() then
		return nil, true;
	end
	local configID = C_ClassTalents.GetLastSelectedSavedConfigID(specID);
	if type(configID) ~= "number" or configID <= 0 then
		return nil, true;
	end
	return configID, true;
end

-- Live slot state, or nil when it cannot be read (low level, not loaded yet).
-- Returns the selected talent per slot plus the slot infos themselves.
local function PTS_ReadSlots()
	local talents, infos = {}, {};
	for slot = 1, PTS_MAX_SLOTS do
		local info = C_SpecializationInfo.GetPvpTalentSlotInfo(slot);
		if not info then
			break;
		end
		talents[slot] = info.selectedTalentID or 0;
		infos[slot] = info;
	end
	if #talents == 0 then
		return nil;
	end
	return talents, infos;
end

local function PTS_Matches(talents, saved)
	for slot = 1, #talents do
		local want = saved[slot] or 0;
		if want ~= 0 and talents[slot] ~= want then
			return false;
		end
	end
	return true;
end

-- Restores abandoned by a selection move: their learns are still in flight,
-- so their answers can arrive while another loadout is tracked. Keeping their
-- target sets lets the addon tell those answers from a player's pick.
local PTS_abandoned = {};
local PTS_ABANDONED_MAX = 4;
local PTS_abandonTimer;

-- True when `id` in `slot` is a value our own writes could have produced:
-- 0 (a move emptied the slot), the target set's value, the value the restore
-- started from (`before`), or an abandoned target's value.
local function PTS_SlotExplained(slot, id, saved, before)
	if id == 0 then
		return true;
	end
	if saved and (saved[slot] or 0) == id then
		return true;
	end
	if before and (before[slot] or 0) == id then
		return true;
	end
	for i = 1, #PTS_abandoned do
		if (PTS_abandoned[i][slot] or 0) == id then
			return true;
		end
	end
	return false;
end

-- True when a talent appeared that our own writes cannot explain. Our learns
-- only place a target's talent in its slot or empty the slot a moved talent
-- left; anything else (including a target talent put in a different slot) is
-- the player's pick.
local function PTS_HasForeign(talents, saved, before)
	for slot = 1, #talents do
		if not PTS_SlotExplained(slot, talents[slot], saved, before) then
			return true;
		end
	end
	return false;
end

local function PTS_ClearAbandoned()
	if PTS_abandonTimer then
		PTS_abandonTimer:Cancel();
		PTS_abandonTimer = nil;
	end
	for i = #PTS_abandoned, 1, -1 do
		PTS_abandoned[i] = nil;
	end
end

-- The answer window elapsed; nothing is being restored any more.
local function PTS_EndRestore()
	PTS_verifyTimer = nil;
	PTS_restoring = nil;
	PTS_restoringFrom = nil;
end

-- Ends an in-flight restore and drops its timer (selection moves, abort).
local function PTS_AbortRestore()
	PTS_restoring = nil;
	PTS_restoringFrom = nil;
	if PTS_verifyTimer then
		PTS_verifyTimer:Cancel();
		PTS_verifyTimer = nil;
	end
end

-- Saves the live set into configID, or leaves the save pending when the
-- slots cannot be read right now.
local function PTS_Save(configID, talents)
	talents = talents or PTS_ReadSlots();
	if talents then
		PTS_db[configID] = talents;
		PTS_pendingSave = nil;
	else
		PTS_pendingSave = configID;
	end
end

local function PTS_CanLearn(info, talentID)
	if not info.enabled then
		return false;
	end
	local offered = false;
	for _, id in ipairs(info.availableTalentIDs) do
		if id == talentID then
			offered = true;
			break;
		end
	end
	if not offered then
		return false;
	end
	-- GetPvpTalentInfo.unlocked is the availability gate the client uses
	-- (Blizzard_PvPTalentListTemplates.lua:24). IsPvpTalentLocked is the
	-- "new talent" badge, not an availability check; it is only a fallback
	-- for clients where the per-talent info cannot be read.
	local talentInfo = C_SpecializationInfo.GetPvpTalentInfo(talentID);
	if talentInfo then
		return talentInfo.unlocked == true;
	end
	return not C_SpecializationInfo.IsPvpTalentLocked(talentID);
end

-- True while the game would refuse a talent change (see the header).
local function PTS_WritesBlocked()
	return UnitAffectingCombat("player")
		or C_PvP.GetActiveMatchState() == Enum.PvPMatchState.Engaged
		or C_ChallengeMode.IsChallengeModeActive();
end

-- Restores the saved set of configID (writes only the slots that differ).
local function PTS_Restore(configID)
	local saved = PTS_db[configID];
	if not saved then
		return;
	end
	local talents, infos = PTS_ReadSlots();
	if not talents or PTS_WritesBlocked() then
		return;
	end
	local learns = {};
	for slot = 1, #talents do
		local want = saved[slot] or 0;
		if want ~= 0 and talents[slot] ~= want and PTS_CanLearn(infos[slot], want) then
			learns[#learns + 1] = slot;
		end
	end
	if #learns == 0 then
		return;
	end
	PTS_AbortRestore();
	PTS_restoring = saved;
	PTS_restoringFrom = talents;
	for _, slot in ipairs(learns) do
		pcall(LearnPvpTalent, saved[slot], slot);
	end
	PTS_verifyTimer = C_Timer.NewTimer(PTS_VERIFY_DELAY, PTS_EndRestore);
end

-- The abandoned writes have had their time: the tracked loadout's set is
-- applied again if their answers left it wrong -- but only while that loadout
-- is still the selected one. A spec or loadout change in the same frame
-- queues the pass for the new selection; this timer must not write the old
-- loadout's set into the new selection's slots before it runs.
local function PTS_Settle()
	PTS_abandonTimer = nil;
	for i = #PTS_abandoned, 1, -1 do
		PTS_abandoned[i] = nil;
	end
	local saved = PTS_loadout and PTS_db[PTS_loadout];
	if not saved then
		return;
	end
	local configID = PTS_SelectedLoadout();
	if configID ~= PTS_loadout then
		return;
	end
	local talents = PTS_ReadSlots();
	if talents and not PTS_restoring and not PTS_Matches(talents, saved) then
		PTS_Restore(PTS_loadout);
	end
end

local function PTS_AbandonRestore(saved)
	PTS_abandoned[#PTS_abandoned + 1] = saved;
	while #PTS_abandoned > PTS_ABANDONED_MAX do
		table.remove(PTS_abandoned, 1);
	end
	if PTS_abandonTimer then
		PTS_abandonTimer:Cancel();
	end
	PTS_abandonTimer = C_Timer.NewTimer(PTS_VERIFY_DELAY, PTS_Settle);
end

local function PTS_Pass()
	PTS_passQueued = false;
	if not PTS_inWorld then
		-- the loading screen's selection can still be stale; the first pass
		-- waits for PLAYER_ENTERING_WORLD so login adopts, never restores
		return;
	end
	local pvpChanged = PTS_pvpChanged;
	PTS_pvpChanged = false;

	local configID, specKnown = PTS_SelectedLoadout();
	if not specKnown then
		return;
	end
	if configID ~= PTS_loadout or not PTS_started then
		-- the selection moved: restore the new loadout. Login, or a loadout
		-- seen for the first time, adopts the live set instead.
		local moved = PTS_started;
		PTS_started = true;
		PTS_loadout = configID;
		if PTS_restoring then
			-- the writes are already sent: remember their target so their
			-- answers are not mistaken for the new loadout's set
			PTS_AbandonRestore(PTS_restoring);
		end
		PTS_AbortRestore();
		PTS_pendingSave = nil;
		if configID then
			if moved and PTS_db[configID] then
				PTS_Restore(configID);
			else
				PTS_Save(configID);
			end
		end
		return;
	end
	if not configID then
		return;
	end

	if PTS_restoring then
		-- our own writes answering; finish early once the set is in place
		local talents = PTS_ReadSlots();
		if talents then
			if PTS_Matches(talents, PTS_restoring) then
				PTS_AbortRestore();
			elseif PTS_HasForeign(talents, PTS_restoring, PTS_restoringFrom) then
				-- the player picked a talent outside the saved set: their set
				-- is the loadout's now, and the restore must not continue
				PTS_AbortRestore();
				PTS_Save(configID, talents);
				PTS_ClearAbandoned();
			end
		end
	elseif pvpChanged or PTS_pendingSave == configID then
		-- the player picked talents: that is the loadout's set now
		local talents = PTS_ReadSlots();
		-- an abandoned restore answering is not this loadout's set (the
		-- settle pass applies this loadout's set again), so only anything
		-- our own writes cannot explain becomes the loadout's set
		local ours = talents and #PTS_abandoned > 0
			and not PTS_HasForeign(talents, PTS_db[configID], nil);
		if not ours then
			PTS_Save(configID, talents);
			if talents then
				PTS_ClearAbandoned();
			end
		end
	end
end

local function PTS_QueuePass()
	if not PTS_passQueued then
		PTS_passQueued = true;
		C_Timer.After(0, PTS_Pass);
	end
end

local function PTS_ValidSlot(slot, id)
	return type(slot) == "number" and slot >= 1 and slot <= PTS_MAX_SLOTS and slot % 1 == 0
		and type(id) == "number" and id >= 0 and id % 1 == 0;
end

-- Drops malformed entries and heals ragged/bad slots in place. A set with one
-- bad slot keeps every good slot instead of losing the whole loadout.
local function PTS_Sanitize()
	for key, set in pairs(PTS_db) do
		local keep = type(key) == "number" and key > 0 and key % 1 == 0
			and type(set) == "table";
		if keep then
			for slot, id in pairs(set) do
				if not PTS_ValidSlot(slot, id) then
					set[slot] = nil;
				end
			end
		else
			PTS_db[key] = nil;
		end
	end
end

local PTS_WAKE_EVENTS = {
	"PLAYER_ENTERING_WORLD",
	"PLAYER_TALENT_UPDATE",
	"ACTIVE_TALENT_GROUP_CHANGED",
	"SELECTED_LOADOUT_CHANGED",
	"TRAIT_CONFIG_UPDATED",
	"PLAYER_REGEN_ENABLED",
	"ADDON_RESTRICTION_STATE_CHANGED",
};

PTS_frame:SetScript("OnEvent", function(self, event, arg1)
	if event == "ADDON_LOADED" then
		if arg1 ~= PTS_ADDON then
			return;
		end
		self:UnregisterEvent("ADDON_LOADED");
		if type(_G[PTS_DB_NAME]) ~= "table" then
			_G[PTS_DB_NAME] = {}; -- first session: publish it so it gets saved
		end
		PTS_db = _G[PTS_DB_NAME];
		PTS_Sanitize();
		if IsLoggedIn() then
			PTS_inWorld = true; -- loaded mid-session (already in the world)
		end
		for _, wake in ipairs(PTS_WAKE_EVENTS) do
			self:RegisterEvent(wake);
		end
		self:RegisterEvent("PLAYER_PVP_TALENT_UPDATE");
		self:RegisterEvent("TRAIT_CONFIG_DELETED");
		PTS_QueuePass();
	elseif event == "TRAIT_CONFIG_DELETED" then
		if type(arg1) == "number" then
			PTS_db[arg1] = nil;
		end
		PTS_QueuePass();
	else
		if event == "PLAYER_ENTERING_WORLD" then
			PTS_inWorld = true;
		elseif event == "PLAYER_PVP_TALENT_UPDATE" then
			PTS_pvpChanged = true;
		end
		PTS_QueuePass();
	end
end);
PTS_frame:RegisterEvent("ADDON_LOADED");
