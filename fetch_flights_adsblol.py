import json
import os
import sys
import requests

# adsb.lol geographic feed. Returns all tracked aircraft within `dist` nautical
# miles of a center point. (API caps dist at 250 NM, no API key required.)
ADSB_LOL_URL = "https://api.adsb.lol/v2/lat/{lat}/lon/{lon}/dist/{dist}"

# Define each DCS map by a center point and a search radius in nautical miles.
DCS_MAPS = {
    "caucasus": {"lat": 43.0, "lon": 43.0, "dist": 250},
    "syria": {"lat": 35.0, "lon": 37.5, "dist": 250},
    "marianas": {"lat": 14.5, "lon": 145.25, "dist": 250}
}

# Conversion helpers (OpenSky reports SI units; adsb.lol reports imperial).

def ft_to_m(v):
    try:
        return round(float(v) * 0.3048, 2)
    except (TypeError, ValueError):
        return 0.0


def kt_to_ms(v):
    try:
        return round(float(v) * 0.514444, 2)
    except (TypeError, ValueError):
        return 0.0


def ftmin_to_ms(v):
    try:
        return round(float(v) * 0.00508, 2)
    except (TypeError, ValueError):
        return 0.0


def to_opensky_state(a, ctime):
    """Converts one adsb.lol aircraft dict into an OpenSky state-vector array.

    The DCS Lua parser (CIVILIAN-AIR.lua) expects the OpenSky 'states' format,
    so we emit the same 17-field, 0-indexed arrays here. That keeps the Lua
    script working unchanged.
    """
    hex_id = a.get("hex")
    callsign = a.get("flight")

    # adsb.lol reports baro altitude as the string "ground" when on the ground
    alt_baro_raw = a.get("alt_baro")
    on_ground = alt_baro_raw == "ground" or alt_baro_raw is None

    # Position age: seen_pos/seen are "seconds ago", so derive absolute epochs
    time_position = None
    last_contact = None
    if ctime is not None:
        seen_pos = a.get("seen_pos")
        seen = a.get("seen")
        if isinstance(seen_pos, (int, float)):
            time_position = round(ctime - seen_pos)
        if isinstance(seen, (int, float)):
            last_contact = round(ctime - seen)

    return [
        hex_id,                            # 0  icao24
        callsign,                          # 1  callsign
        "",                                # 2  origin_country (not provided)
        time_position,                     # 3  time_position
        last_contact,                      # 4  last_contact
        a.get("lon"),                      # 5  longitude
        a.get("lat"),                      # 6  latitude
        ft_to_m(alt_baro_raw),             # 7  baro_altitude (m)
        on_ground,                         # 8  on_ground
        kt_to_ms(a.get("gs")),             # 9  velocity (m/s)
        a.get("track"),                    # 10 true_track (deg)
        ftmin_to_ms(a.get("baro_rate")),   # 11 vertical_rate (m/s)
        None,                              # 12 sensors
        ft_to_m(a.get("alt_geom")),        # 13 geo_altitude (m)
        a.get("squawk"),                   # 14 squawk
        None,                              # 15 spi
        None,                              # 16 position_source
    ]


def main():
    if len(sys.argv) < 2:
        print("Warning: map data not found. Please provide a map name as an argument.")
        print(f"Available maps: {', '.join(DCS_MAPS.keys())}")
        sys.exit(1)

    target_map = sys.argv[1].lower()

    if target_map not in DCS_MAPS:
        print(f"Warning: map data not found for '{target_map}'.")
        print(f"Available maps: {', '.join(DCS_MAPS.keys())}")
        sys.exit(1)

    center = DCS_MAPS[target_map]
    output_file = f"dcs_filtered_flights_{target_map}.json"

    print(f"Fetching live flight data from adsb.lol for DCS map: {target_map.capitalize()}...")

    url = ADSB_LOL_URL.format(lat=center["lat"], lon=center["lon"], dist=center["dist"])
    headers = {"User-Agent": "DCS-CIVILIAN-AIR-MOD-Filter/1.0"}

    try:
        response = requests.get(url, headers=headers, timeout=10)
    except requests.exceptions.RequestException as e:
        print(f"Network error occurred: {e}")
        sys.exit(1)

    if response.status_code == 200:
        raw_data = response.json()
        # adsb.lol returns aircraft under the "ac" key; older key "aircraft"
        aircraft = raw_data.get("ac") or raw_data.get("aircraft") or []
        ctime = raw_data.get("ctime") or raw_data.get("now")

        states = [to_opensky_state(a, ctime) for a in aircraft]

        output_payload = {
            "dcs_map": target_map,
            "timestamp": ctime,
            "count": len(states),
            "states": states
        }

        with open(output_file, "w", encoding="utf-8") as f:
            json.dump(output_payload, f, indent=2)

        print(f"Success! Saved {len(states)} flights over {target_map} to {os.path.abspath(output_file)}")
    else:
        print(f"Failed to fetch data from API. Status code: {response.status_code}")


if __name__ == "__main__":
    main()
