# Changelog

## [1.2.0] - 2026-08-19

### Added
- History window (small H button) - every past session logged by Restart Session, most recent first, auto-labeled with the instance you were in or your most-killed mob. Click a session for its full breakdown in chat, delete individual entries, or clear everything
- Session history is now capped at the most recent 100 entries instead of growing forever

## [1.1.0] - 2026-08-19

### Added
- Toggle mob ordering between most-recently-killed and highest-value (small R/V button)
- Right-click an item icon to filter it out entirely - stops future tracking and hides it from existing history
- Options window (small O button) listing everything currently filtered, with one-click removal
- Optional disenchant value in pricing (off by default) - uses Aux's own real vanilla disenchant-yield data, counted only when higher than vendor/AH

### Fixed
- A won group-loot roll ("You won: [Item]") wasn't being credited to the player - it was being treated as someone else's pickup
- Long mob names could overlap the kill count and value text in the loot window header
- This Session/All Time highlight could show the wrong one selected when first opening the window

## [1.0.0] - 2026-08-19

Initial public release.

### Added
- Always-on kill, loot, and coin tracking - no need to start a session manually, and This Session survives logout/reload
- Live gold/hour rate based on vendor price or Aux auction data, whichever is higher, shown in both the compact readout and the This Session tab
- Persistent per-mob loot history in a resizable, movable Loot Tracker window, styled after RuneLite's OSRS Loot Tracker
- Session and All Time views, with the active view highlighted
- Collapsible compact mode (time / gold-per-hour / kills-per-hour) for a minimal, non-intrusive footprint
- Per-mob collapse to hide a mob's loot grid without losing its history
- Raid-aware loot attribution, including a fallback for delayed loot in groups and raids
- Unclaimed drops (items other players won) shown greyed out instead of discarded
- Right-click reset per mob, plus a confirmed Reset All
- Restart Session to reset the current stretch's clock without touching All Time history
- Optional pfUI skin integration, auto-detected
- Minimap button and `/ll` slash command

### Fixed
- Item icon quality borders now read clearly instead of blending into the background
- Group loot roll announcements (Greed/Need roll lines, winner announcements) were being miscounted as separate item drops, wildly inflating drop counts and occasionally crediting items to the wrong person - only genuine loot receipts are counted now
