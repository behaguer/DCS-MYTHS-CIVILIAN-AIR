import json
import os
import sys
import requests

OPENSKY_URL = "https://opensky-network.org/api/states/all"

# Define approximate bounding boxes [min_lat, max_lat, min_lon, max_lon]
DCS_MAPS = {
    "caucasus": {"min_lat": 40.0, "max_lat": 46.0, "min_lon": 36.0, "max_lon": 50.0},
    "syria": {"min_lat": 32.0, "max_lat": 38.0, "min_lon": 33.0, "max_lon": 42.0},
    "marianas": {"min_lat": 13.0, "max_lat": 16.0, "min_lon": 144.0, "max_lon": 146.5}
}

def filter_flights_by_map(states, bounds):
    filtered_states = []
    if not states:
        return filtered_states

    for s in states:
        lon = s[5]
        lat = s[6]

        if lat is not None and lon is not None:
            if (bounds["min_lat"] <= lat <= bounds["max_lat"]) and (bounds["min_lon"] <= lon <= bounds["max_lon"]):
                filtered_states.append(s)
                
    return filtered_states

def main():
    # Check if a map parameter was provided
    if len(sys.argv) < 2:
        print("Warning: map data not found. Please provide a map name as an argument.")
        print(f"Available maps: {', '.join(DCS_MAPS.keys())}")
        sys.exit(1)

    target_map = sys.argv[1].lower()

    # Validate if the map exists in the dictionary
    if target_map not in DCS_MAPS:
        print(f"Warning: map data not found for '{target_map}'.")
        print(f"Available maps: {', '.join(DCS_MAPS.keys())}")
        sys.exit(1)

    bounds = DCS_MAPS[target_map]
    output_file = f"dcs_filtered_flights_{target_map}.json"
    
    print(f"Fetching live flight data to filter for DCS map: {target_map.capitalize()}...")
    
    headers = {"User-Agent": "DCS-CIVILIAN-AIR-MOD-Filter/1.0"}
    try:
        response = requests.get(OPENSKY_URL, headers=headers, timeout=10)
    except requests.exceptions.RequestException as e:
        print(f"Network error occurred: {e}")
        sys.exit(1)
    
    if response.status_code == 200:
        raw_data = response.json()
        states = raw_data.get("states", [])
        
        filtered_states = filter_flights_by_map(states, bounds)
        
        output_payload = {
            "dcs_map": target_map,
            "timestamp": raw_data.get("time"),
            "count": len(filtered_states),
            "states": filtered_states
        }
        
        with open(output_file, "w", encoding="utf-8") as f:
            json.dump(output_payload, f, indent=2)
            
        print(f"Success! Saved {len(filtered_states)} flights over {target_map} to {os.path.abspath(output_file)}")
    else:
        print(f"Failed to fetch data from API. Status code: {response.status_code}")

if __name__ == "__main__":
    main()