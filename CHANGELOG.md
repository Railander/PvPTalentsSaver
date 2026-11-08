# PvP Talents Saver Changelog

## Unreleased

- PvP talents are now remembered per slot, so each loadout gets its talents back in the slots they were saved in (a slot saved empty is left as it is)
- Switching specialization no longer overwrites the previous loadout's PvP talents
- A loadout's PvP talents are no longer overwritten while they are being put back
- A PvP talent changed right after a loadout switch is no longer discarded by that switch's restore
- A player pick made while a loadout's PvP talents are being put back is kept even when the talent is one the previous loadout used
- Switching loadouts twice in quick succession no longer saves the first loadout's arriving PvP talents into the second
- A restore interrupted by another loadout switch is applied again to the loadout actually active once its writes have settled
- A restore left over from a previous loadout is no longer applied to the newly selected specialization or loadout
- PvP talents that still show the "new" badge are no longer skipped when a loadout is restored
- Using the Starter Build no longer saves its PvP talents into the last selected loadout, so loadouts no longer share PvP talents across specializations through it
- Switching to a loadout whose regular talents are already in place now restores its PvP talents too
- No longer tries to change PvP talents where the game does not allow it (in combat, or once a PvP match or Mythic+ keystone has started)
- PvP talent changes made while the game briefly hides them from addons are now saved as soon as they can be read
- Logging in or reloading no longer changes your PvP talents
- Deleted loadouts are cleaned out of the saved data
- Saved data with a damaged slot is repaired slot by slot instead of losing the whole loadout
- Updated .toc for patch 12.1.5

## v2.0.2 (2026-01-19)

- Updated .toc for Midnight

## v2.0.1 (2025-05-18)

- Rewrite for The War Within expansion
  - Might have breaking changes, if you have issues delete the SavedVariables for the addon

## v1.0.4 (2024-04-08)

- Fix saved variable not being created ([5140c16](https://github.com/guicaulada/PvPTalentsSaver/commit/5140c167246fc6fd478754e54cdcd3d6c1ca4bc0))

## v1.0.3 (2024-04-08)

- Minor change to variable scoping ([e9e741f](https://github.com/guicaulada/PvPTalentsSaver/commit/e9e741f230bb170312e6f154c32d84291da988ed))

## v1.0.2 (2024-04-08)

- Fix conflict with talents not saving/loading correctly ([eb2a850](https://github.com/guicaulada/PvPTalentsSaver/commit/eb2a8504e8f2b504a7c14268b9c443715ec872f0))

## v1.0.1 (2024-04-04)

- Fix "Unable to learn talent" error message ([1d70255](https://github.com/guicaulada/PvPTalentsSaver/commit/1d70255824488e107e8602e9208aa7248772bd62))

## v1.0.0 (2024-04-03)

- First commit ([7ac3302](https://github.com/guicaulada/PvPTalentsSaver/commit/7ac3302aa3b656dab2430294c577b98b55625b1c))
