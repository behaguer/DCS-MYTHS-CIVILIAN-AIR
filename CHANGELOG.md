# DCS CIVILIAN AIR v0.1 Changelog

---

## v0.1.1 - Feed Sources, Live Correction & GC

### Added
- `fetch_flights_adsblol.py`: alternative feed generator using the **adsb.lol** API (no API key required).
  - Filtered by geographic radius, outputs the same OpenSky-compatible state-vector format
    so `CIVILIAN-AIR.lua` works unchanged.
  - Field conversions: `alt_baro`/`alt_geom` (ft→m), `gs` (kts→m/s), `baro_rate` (ft/min→m/s),
    `hex`→icao24, `flight`→callsign, `track`→heading. `alt_baro == "ground"` maps to `on_ground = true`.
- **Live correction** for already-spawned aircraft: each monitor cycle the script compares
  the in-game position, heading and altitude against the feed and re-tasks off-track / drifting /
  descending planes back onto the real flight path and altitude.
- New configurable thresholds: `update_position_threshold_m`, `update_heading_threshold_deg`,
  `update_altitude_threshold_m`.

### Changed
- `CIVILIAN-AIR.lua`: feed timestamp from the JSON is now stored in `CIVAIR_STATE.feedTimestamp`
  and per-plane (`lastFeedTimestamp`).
- Replaced the non-functional `loadstring`-based JSON decoder with a self-contained
  recursive-descent JSON parser (works without `loadstring` in the DCS sandbox).
- Fixed OpenSky state-vector indices (0-indexed API → 1-indexed Lua) so `on_ground` and other
  fields are read correctly.
- Fixed `countTableKeys` being referenced before definition (Lua upvalue ordering).
- Fixed undefined `i` in the spawn group's callsign `number` field.
- Re-tuned live-correction thresholds so off-track / descending planes are corrected on
  **every** monitor cycle until they hold the feed's position, heading and altitude.

### Fixed
- Aircraft were incorrectly skipped / despawned because the `on_ground` field was read from
  the wrong index.
- Planes descending away from the feed altitude now get corrected to hold altitude.

---

## v0.1 - CIVILIAN AIR System
**Initial Release**

### Core Features
- Air Spawner from API Feed (work in progress)

### Features
- Configuration options to enable/disable spawning of assets based on the feed data.
- Configurable maximum limits for each asset type to prevent over-spawning.
- Python Script with real time generation of flight data

---
