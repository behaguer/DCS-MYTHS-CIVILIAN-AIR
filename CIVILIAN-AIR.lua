-- DCS CIVILIAN AIR  0.1 By Burning Skies MYTH
-- Description: This script allows spawning of civilian air assets based off realtime data.


-- =====================================================================================
-- CONFIG (Editable Section)
-- =====================================================================================

local CONFIG = {
    debug = false,              -- Set to false to disable debug messages
    production_mode = false,    -- Set to true to reduce overhead and debug output

    -- Enable features 
    enable_api = true,        -- Set to false to disable AWACS functionality
    api_poll_frequency = 30,   -- How often to poll for new data from the API (seconds)
    api_timeout = 10,          -- How long to wait for a response from the API before timing out

    -- DCS file read
    api_feed_path = "airline_data.json",
    api_feed_monitor_frequency = 10,    -- How often to monitor the file for changes (seconds)

    -- Spawn limits
    maximum_spawn_limit = 5,

    -- Flight Defaults
    default_spawn_altitude = 5000,       -- Altitude in meters (approximately 16400 feet)
    default_cruise_speed = 150,          -- Speed in m/s (approximately 250 knots)

}

-- =====================================================================================
-- DEBUG FUNCTIONS
-- =====================================================================================

--- Outputs debug messages to both DCS log and player screens.
-- @param message The debug message to display
-- @param force (optional) Force display even in production mode
-- @return void
local function debugMsg(message, force)
    env.info("[CIV-AIR] " .. message)
    if (CONFIG.debug and not CONFIG.production_mode) or force then
        trigger.action.outText(message, 10)
    end
end

--- Internal helper to display messages to specific group.
-- @param parameters Table containing groupID, ptext, pduration, pclear
-- @return void
local function showMessageForGroup(parameters)
	trigger.action.outTextForGroup(parameters.groupID, parameters.ptext, parameters.pduration, parameters.pclear)
end

--- Finds a player's group ID by their player name.
-- @param playerName The name of the player to search for
-- @return number|nil The group ID if found, nil otherwise
local function getPlayerGroupIDByName(playerName)
    if not playerName then
        return nil
    end
    
    local coalitions = {coalition.side.BLUE, coalition.side.RED, coalition.side.NEUTRAL}
    local categories = {Group.Category.AIRPLANE, Group.Category.GROUND, Group.Category.SHIP, Group.Category.HELICOPTER}
    
    for _, side in pairs(coalitions) do
        for _, category in pairs(categories) do
            local groups = coalition.getGroups(side, category)
            if groups then
                for _, group in pairs(groups) do
                    if group and group:isExist() then
                        local units = group:getUnits()
                        if units then
                            for _, unit in pairs(units) do
                                if unit and unit:isExist() then
                                    local unitPlayerName = unit:getPlayerName()
                                    if unitPlayerName == playerName then
                                        return group:getID()
                                    end
                                end
                            end
                        end
                    end
                end
            end
        end
    end
    
    return nil
end

--- Enhanced message function that can target specific players or broadcast to all.
-- @param text The message text to display
-- @param duration (optional) How long to show the message (seconds)
-- @param delaySec (optional) Delay before showing message (seconds)
-- @param clear (optional) Whether to clear existing messages
-- @param groupID (optional) Specific group ID to target
-- @param playerName (optional) Specific player name to target
-- @return void
local function setMsg(text, duration, delaySec, clear, groupID, playerName)
    
    -- If groupID is not provided, try to determine target
    if not groupID then
        if playerName then
            -- Try to find specific player's group
            groupID = getPlayerGroupIDByName(playerName)
        end
        
        -- If still no specific target, send to all players
        if not groupID then
            debugMsg("No specific player target, sending message to all players: " .. text)
            trigger.action.outText(text, duration or 10)
            return
        end
    end
    
	if clear == nil or clear == false then
        clear = false
	else
		clear = true
    end
    
    -- Use minimum delay of 0.1 seconds instead of 0 for timer reliability
    local actualDelay = math.max(delaySec or 0, 0.1)
	timer.scheduleFunction(showMessageForGroup, {groupID = groupID, ptext = text, pduration = duration or 10, pclear = clear}, timer.getTime() + actualDelay)
end

--- Broadcasts a message to all players in the mission.
-- @param text The message text to display
-- @param duration (optional) How long to show the message (seconds)
-- @param delaySec (optional) Delay before showing message (seconds)
-- @param clear (optional) Whether to clear existing messages
-- @return void
local function setMsgToAll(text, duration, delaySec, clear)
    if clear == nil or clear == false then
        clear = false
    else
        clear = true
    end
    
    local actualDelay = math.max(delaySec or 0, 0.1)
    timer.scheduleFunction(function()
        trigger.action.outText(text, duration or 10)
    end, nil, timer.getTime() + actualDelay)
end


-- =====================================================================================
-- STATE MANAGEMENT
-- =====================================================================================

local CIVAIR_STATE = {
    initialized = false,
    groupCounter = 0,
    SPAWNED_PLANES = {},        -- Track Spawned units: [unitName] = { unit, spawnTime, cleanupFlag }
    SPAWNED_HELO = {},          -- Track Spawned units: [unitName] = { unit, spawnTime, cleanupFlag }
}


-- =====================================================================================
-- CIVAIR FUNCTIONS
-- =====================================================================================


--- Counts the current number of active assets of a specific type.
-- @param assetType Type of asset to count ("plane", "helicopter")
-- @return number Current active count of the specified asset type
local function countActiveAssets(assetType)
    local count = 0
    
    if assetType == "plane" then
        for groupName, assetData in pairs(CIVAIR_STATE.SPAWNED_PLANES) do
            if assetData.group and assetData.group:isExist() then
                count = count + 1
            else
                -- Clean up dead groups
                CIVAIR_STATE.SPAWNED_PLANES[groupName] = nil
            end
        end
    else -- helos
        for groupName, assetData in pairs(CIVAIR_STATE.SPAWNED_HELO) do
            if assetData.group and assetData.group:isExist() and assetData.assetType == assetType then
                count = count + 1
            elseif not (assetData.group and assetData.group:isExist()) then
                -- Clean up dead groups
                CIVAIR_STATE.SPAWNED_HELO[groupName] = nil
            end
        end
    end
    
    return count
end


-- TODO: This function spawnCIVAIRAssets needs to be rewritten to read the file and process the data from the file.
-- TODO: Once the data is processed to a format that is usable to dcs then it can be used to spawn the assets.

--- Spawns CIVAIR assets based on API input.
-- @param assetType Type of asset to spawn ("awacs", "tanker-probe", "tanker-basket")
-- @param markerPos Position of the marker
-- @param bearing Bearing from marker to spawn position (degrees)
-- @param distance Distance from marker to spawn position (nautical miles)
-- @param event (optional) DCS event data for marker removal
-- @return boolean Success status of the spawn operation
local function spawnCIVAIRAssets(assetType, markerPos, bearing, distance, event)
    -- Validate asset type and get configuration
    local aircraftType, cmdCost, altitude, speed, task, groupPrefix
    if assetType == "plane" then
        if not CONFIG.enable_awacs then
            debugMsg("ERROR: AWACS functionality is disabled")
            return false
        end
        aircraftType = CONFIG.awacs_type
        cmdCost = 20
        altitude = CONFIG.awacs_spawn_altitude
        speed = CONFIG.awacs_cruise_speed
        task = "AWACS"
        groupPrefix = "CIVAIR_AWACS_"
    elseif assetType == "tanker-probe" then
        if not CONFIG.enable_tanker then
            debugMsg("ERROR: Tanker functionality is disabled")
            return false
        end
        aircraftType = CONFIG.tanker_probe_type
        cmdCost = 10
        altitude = CONFIG.tanker_spawn_altitude
        speed = CONFIG.tanker_cruise_speed
        task = "Refueling"
        groupPrefix = "CIVAIR_TANKER_PROBE_"
    elseif assetType == "tanker-basket" then
        if not CONFIG.enable_tanker then
            debugMsg("ERROR: Tanker functionality is disabled")
            return false
        end
        aircraftType = CONFIG.tanker_basket_type
        cmdCost = 10
        altitude = CONFIG.tanker_spawn_altitude
        speed = CONFIG.tanker_cruise_speed
        task = "Refueling"
        groupPrefix = "CIVAIR_TANKER_BASKET_"
    else
        debugMsg("ERROR: Invalid asset type: " .. tostring(assetType))
        return false
    end
    
    -- Check asset limits before proceeding (before CMD point deduction)
    local currentCount = countActiveAssets(assetType)
    local assetLimit
    local assetName
    
    if assetType == "awacs" then
        assetLimit = CONFIG.awacs_limit
        assetName = "AWACS"
    elseif assetType == "tanker-probe" then
        assetLimit = CONFIG.tanker_probe_limit
        assetName = "Probe Tankers"
    elseif assetType == "tanker-basket" then
        assetLimit = CONFIG.tanker_basket_limit
        assetName = "Basket Tankers"
    end

    if currentCount >= assetLimit then
        local errorMsg = "ERROR: Maximum " .. assetName .. " limit reached (" .. currentCount .. "/" .. assetLimit .. "). Cannot spawn more."
        debugMsg(errorMsg)
        setMsgToAll("Maximum " .. assetName .. " limit reached (" .. currentCount .. "/" .. assetLimit .. ").", 8, 1, true)
        return false
    end

    debugMsg("Asset limit check passed: " .. assetName .. " (" .. currentCount .. "/" .. assetLimit .. ") - spawning allowed")

    -- Create group counter and name
    CIVAIR_STATE.groupCounter = CIVAIR_STATE.groupCounter + 1
    local groupName = groupPrefix .. CIVAIR_STATE.groupCounter

    -- Increment asset-specific counter for unique callsigns
    local assetCounter
    if assetType == "awacs" then
        CIVAIR_STATE.awacsCounter = CIVAIR_STATE.awacsCounter + 1
        assetCounter = CIVAIR_STATE.awacsCounter
    elseif assetType == "tanker-probe" then
        CIVAIR_STATE.tankerProbeCounter = CIVAIR_STATE.tankerProbeCounter + 1
        assetCounter = CIVAIR_STATE.tankerProbeCounter
    elseif assetType == "tanker-basket" then
        CIVAIR_STATE.tankerBasketCounter = CIVAIR_STATE.tankerBasketCounter + 1
        assetCounter = CIVAIR_STATE.tankerBasketCounter
    end
    
    debugMsg("Creating " .. assetType .. " group: " .. groupName)
    
    -- Calculate target position based on bearing and distance (racetrack endpoint)
    local bearingRad = math.rad(bearing)
    local distanceMeters = distance * 1852  -- Convert nautical miles to meters
    
    -- DCS coordinate system: X=East, Z=North but SWAPPED in bearing calculation
    -- For bearing 000°=North: we want Z offset, not X offset
    -- Fix: Swap sin/cos application to correct axes
    local targetX = markerPos.x + math.cos(bearingRad) * distanceMeters  -- cos for X (East/West)
    local targetZ = markerPos.z + math.sin(bearingRad) * distanceMeters  -- sin for Z (North/South)
    
    -- For racetrack: opposite end is same distance in opposite direction from marker
    local oppositeBearingRad = bearingRad + math.pi  -- Add 180 degrees
    local oppositeX = markerPos.x + math.cos(oppositeBearingRad) * distanceMeters  -- cos for X
    local oppositeZ = markerPos.z + math.sin(oppositeBearingRad) * distanceMeters  -- sin for Z
    
    debugMsg("BEARING TEST for " .. bearing .. "°:")
    debugMsg("  cos(" .. bearing .. "°) = " .. string.format("%.3f", math.cos(bearingRad)) .. " (for X/East-West)")
    debugMsg("  sin(" .. bearing .. "°) = " .. string.format("%.3f", math.sin(bearingRad)) .. " (for Z/North-South)")
    debugMsg("  Expected for 000°: cos=1 (no X change), sin=0 -> Z=+distance (North)")
    debugMsg("  Expected for 090°: cos=0 -> X=+distance (East), sin=1 (no Z change)")
    debugMsg("  Opposite: X=" .. string.format("%.0f", oppositeX) .. ", Z=" .. string.format("%.0f", oppositeZ))
    
    -- For racetrack pattern: create initial waypoint 1nm on bearing, then tanker role at target
    local spawnX = markerPos.x
    local spawnZ = markerPos.z
    
    -- Calculate initial waypoint 1nm on bearing for tankers
    local initialWaypointDistance = 1852  -- 1 nautical mile in meters
    local initialX = markerPos.x + math.cos(bearingRad) * initialWaypointDistance
    local initialZ = markerPos.z + math.sin(bearingRad) * initialWaypointDistance
    
    -- Calculate waypoint 2 (tanker activation point) - 2nm on bearing for tankers
    local activationWaypointDistance = 2 * 1852  -- 2 nautical miles in meters
    local activationX = markerPos.x + math.cos(bearingRad) * activationWaypointDistance
    local activationZ = markerPos.z + math.sin(bearingRad) * activationWaypointDistance
    
    -- Calculate heading toward target
    local headingRad = bearingRad
    local heading = math.deg(headingRad)
    
    -- Create group data structure
    local groupData = {
        ["visible"] = false,
        ["tasks"] = {},
        ["uncontrollable"] = false,
        ["task"] = task,
        ["taskSelected"] = task == "Refueling",  -- Only set taskSelected for refueling tankers
        ["radioSet"] = false,  -- Match template
        ["route"] = {
            ["points"] = {
                -- Waypoint 1: Initial waypoint 1nm on bearing (normal turning point)
                [1] = {
                    ["alt"] = altitude,
                    ["type"] = "Turning Point",
                    ["action"] = "Turning Point",
                    ["alt_type"] = "BARO",
                    ["speed"] = speed,
                    ["y"] = initialZ,
                    ["x"] = initialX,
                    ["speed_locked"] = true,
                },
                -- Waypoint 2: Activation point 2nm on bearing - tanker role activates here
                [2] = {
                    ["alt"] = altitude,
                    ["type"] = "Turning Point", 
                    ["action"] = "Turning Point",
                    ["alt_type"] = "BARO",
                    ["speed"] = speed,
                    ["y"] = activationZ,
                    ["x"] = activationX,
                    ["speed_locked"] = true,
                    -- Add tasks for AWACS and tankers (matches template structure)
                    ["task"] = (task == "Refueling" or task == "AWACS") and {
                        ["id"] = "ComboTask",
                        ["params"] = {
                            ["tasks"] = task == "Refueling" and {
                                -- Main tanker task
                                [1] = {
                                    ["enabled"] = true,
                                    ["auto"] = true,
                                    ["id"] = "Tanker", 
                                    ["number"] = 1,
                                    ["params"] = {}
                                },
                                -- TACAN beacon activation
                                [2] = {
                                    ["enabled"] = true,
                                    ["auto"] = true,
                                    ["id"] = "WrappedAction",
                                    ["number"] = 2,
                                    ["params"] = {
                                        ["action"] = {
                                            ["id"] = "ActivateBeacon",
                                            ["params"] = {
                                                ["type"] = 4,  -- TACAN
                                                ["AA"] = false,
                                                ["callsign"] = tacanCallsign or "TKR",
                                                ["modeChannel"] = "Y",
                                                ["channel"] = tacanChannel or 61,
                                                ["system"] = 4,
                                                ["bearing"] = true,
                                                ["frequency"] = (tacanChannel or 61) * 1000000 + 962000000
                                            }
                                        }
                                    }
                                }
                            } or task == "AWACS" and {
                                -- Main AWACS task
                                [1] = {
                                    ["enabled"] = true,
                                    ["auto"] = true,
                                    ["id"] = "AWACS", 
                                    ["number"] = 1,
                                    ["params"] = {}
                                },
                                -- Enable EPLRS datalink
                                [2] = {
                                    ["enabled"] = true,
                                    ["auto"] = true,
                                    ["id"] = "WrappedAction",
                                    ["number"] = 2,
                                    ["params"] = {
                                        ["action"] = {
                                            ["id"] = "EPLRS",
                                            ["params"] = {
                                                ["value"] = true,
                                                ["groupId"] = 1
                                            }
                                        }
                                    }
                                }
                            } or nil
                        }
                    } or nil
                },
                -- Waypoint 3: Full distance target position (furtherest point)
                [3] = {
                    ["alt"] = altitude,
                    ["type"] = "Turning Point",
                    ["action"] = "Turning Point", 
                    ["alt_type"] = "BARO",
                    ["speed"] = speed,
                    ["y"] = targetZ,
                    ["x"] = targetX,
                    ["speed_locked"] = true,
                },
                -- Waypoint 4: Turn around and fly to opposite end (racetrack pattern)
                [4] = {
                    ["alt"] = altitude,
                    ["type"] = "Turning Point",
                    ["action"] = "Turning Point", 
                    ["alt_type"] = "BARO",
                    ["speed"] = speed,
                    ["y"] = oppositeZ,
                    ["x"] = oppositeX,
                    ["speed_locked"] = true,
                },
                -- Waypoint 5: Return to target to complete racetrack pattern
                [5] = {
                    ["alt"] = altitude,
                    ["type"] = "Turning Point",
                    ["action"] = "Turning Point",
                    ["alt_type"] = "BARO", 
                    ["speed"] = speed,
                    ["y"] = targetZ,
                    ["x"] = targetX,
                    ["speed_locked"] = true,
                }
            }
        },
        ["groupId"] = math.random(1000, 9999),
        ["hidden"] = false,
        ["units"] = {},
        ["y"] = spawnZ,
        ["x"] = spawnX,
        ["name"] = groupName,
        ["start_time"] = 0,
        ["communication"] = true,
        ["frequency"] = 251,  -- Standard DCS frequency for tankers (matches template)
        ["modulation"] = 0,   -- AM modulation
    }
    
    -- Create the unit within the group
    local callsignName
    if assetType == "awacs" then
        callsignName = CONFIG.awacs_type_callsign  -- Use configured callsign (Darkstar)
    elseif assetType == "tanker-probe" then
        callsignName = CONFIG.tanker_probe_callsign  -- Use configured callsign (Texaco)
    elseif assetType == "tanker-basket" then
        callsignName = CONFIG.tanker_basket_callsign  -- Use configured callsign (Shell)
    end
    
    -- Calculate radio frequency and TACAN for tankers
    local radioFreq = nil
    local tacanChannel = nil
    local tacanCallsign = nil
    
    if assetType == "tanker-probe" or assetType == "tanker-basket" then
        -- Use standard DCS tanker frequency (251 MHz) and sequential TACAN channels
        radioFreq = 251.0  -- Standard tanker frequency like in template
        tacanChannel = 60 + CIVAIR_STATE.groupCounter  -- TACAN 61, 62, 63, etc.
        tacanCallsign = string.upper(callsignName:sub(1,3)) .. CIVAIR_STATE.groupCounter  -- TEX1, TEX2, SHE1, SHE2, etc.
    end
    
    -- Determine DCS callsign number based on configured callsign name
    local dcsCallsignNumber = getDCSCallsignNumber(callsignName, assetType)
    
    local unit = {
        ["type"] = aircraftType,
        ["unitId"] = math.random(10000, 99999),
        ['callsign'] = {
            [1] = dcsCallsignNumber,
            [2] = assetCounter,  -- Use asset-specific counter for unique flight numbers
            [3] = 1,  -- Aircraft number within flight (always 1 for single aircraft groups)
            ["name"] = callsignName .. assetCounter .. "1"  -- e.g., Texaco11, Texaco21, Shell11, Shell21
        },
        ["skill"] = "High",  -- Match template skill level
        ["livery_id"] = "default",  -- Important for aircraft appearance
        ["onboard_num"] = string.format("%03d", 15 + CIVAIR_STATE.groupCounter),  -- Sequential tail numbers
        ["y"] = spawnZ,
        ["x"] = spawnX,
        ["name"] = callsignName .. "-" .. CIVAIR_STATE.groupCounter .. "-1",  -- Proper DCS callsign format
        ["heading"] = math.rad(heading),
        ["speed"] = speed,
        ["alt"] = altitude,
        ["alt_type"] = "BARO",
        ["payload"] = {
            ["pylons"] = {},
            ["fuel"] = aircraftType == "E-3A Sentry" and 65000 or 90000,  -- Appropriate fuel loads
            ["flare"] = 60,
            ["chaff"] = 120,
            ["gun"] = 100  -- Match template gun value
        }
    }
    
    -- Note: TACAN beacon now configured via waypoint ActivateBeacon task (matches template)
    if assetType == "tanker-probe" or assetType == "tanker-basket" then
        debugMsg("Tanker configured: Freq=" .. radioFreq .. " MHz, TACAN=" .. tacanChannel .. " (" .. tacanCallsign .. ") - via waypoint task")
    elseif assetType == "awacs" then
        debugMsg("AWACS configured: Freq=251 MHz, EPLRS datalink enabled - via waypoint task")
    end
    
    groupData.units[1] = unit
    
    -- Debug: Show all waypoint coordinates  
    debugMsg("WAYPOINT COORDINATES:")
    debugMsg("  WP1 (Initial 1nm): X=" .. initialX .. ", Z=" .. initialZ .. " (1nm on bearing " .. bearing .. "°)")
    debugMsg("  WP2 (Activation 2nm): X=" .. activationX .. ", Z=" .. activationZ .. " (" .. task .. " role activates here)")
    debugMsg("  WP3 (Target " .. distance .. "nm): X=" .. targetX .. ", Z=" .. targetZ .. " (northernmost point)")
    debugMsg("  WP4 (Opposite): X=" .. oppositeX .. ", Z=" .. oppositeZ .. " (racetrack turn)")  
    debugMsg("  WP5 (Return): X=" .. targetX .. ", Z=" .. targetZ .. " (back to target)")
    
    -- Spawn the group
    debugMsg("Spawning " .. aircraftType .. " at marker: x=" .. spawnX .. ", z=" .. spawnZ .. " -> racetrack to: x=" .. targetX .. ", z=" .. targetZ .. ", altitude=" .. altitude)
    local success, result = pcall(coalition.addGroup, country.id.USA, Group.Category.AIRPLANE, groupData)
    
    if success and result then
        debugMsg("✓ " .. assetType .. " spawned successfully: " .. groupName)
        
        -- Store spawned asset in appropriate state table
        if assetType == "awacs" then
            CIVAIR_STATE.AWACS[groupName] = {
                group = result,
                spawnTime = timer.getTime(),
                assetType = assetType,
                markerPos = markerPos,
                targetPos = {x = targetX, z = targetZ},
                oppositePos = {x = oppositeX, z = oppositeZ},
                bearing = bearing,
                distance = distance
            }
        else
            CIVAIR_STATE.TANKERS[groupName] = {
                group = result, 
                spawnTime = timer.getTime(),
                assetType = assetType,
                markerPos = markerPos,
                targetPos = {x = targetX, z = targetZ},
                oppositePos = {x = oppositeX, z = oppositeZ},
                bearing = bearing,
                distance = distance
            }
        end
        
        -- Get updated count after spawning for display
        local newCount = countActiveAssets(assetType)
        local countMsg = " [" .. newCount .. "/" .. assetLimit .. " active]"
        
        -- Create informative message with radio/configuration info and asset count
        local message = assetType:upper() .. " '" .. callsignName .. "-" .. CIVAIR_STATE.groupCounter .. "-1' is airborne! Flying racetrack pattern " .. distance .. "nm at bearing " .. string.format("%03d", bearing) .. "°" .. countMsg
        if assetType == "awacs" then
            message = message .. "\nRadio: 251 MHz | EPLRS Datalink: Active"
        elseif radioFreq and tacanChannel and tacanCallsign then
            message = message .. "\nRadio: " .. string.format("%.2f", radioFreq) .. " MHz | TACAN: " .. tacanChannel .. " (" .. tacanCallsign .. ")"
        end
        setMsgToAll(message, 15, 1, false)

        debugMsg("CIVAIR asset registered in state: " .. groupName .. " -> " .. assetType)

        -- Remove the marker after successful spawn
        if event and event.idx then
            trigger.action.removeMark(event.idx)
            debugMsg("Marker removed after successful " .. assetType .. " spawn")
        end

        return true

    else
        debugMsg("ERROR: Failed to spawn " .. assetType .. ": " .. tostring(result))
        setMsgToAll("Failed to spawn " .. assetType .. " - check log for details", 5, 1, true) 
        return false
    end
end


-- =====================================================================================
-- INITIALIZATION
-- =====================================================================================

--- Initializes the CIVAIR system.
-- @return void
local function initializeCIVAIR()
    if CIVAIR_STATE.initialized then
        return
    end

    debugMsg("Initializing CIVAILIAN AIR system...")
    CIVAIR_STATE.initialized = true
    debugMsg("CIVILAN AIR system initialized successfully!")

    timer.scheduleFunction(function()

        -- TODO: Get the data from the file based off the time set in configuration
        -- TODO: Spawn the aircraft that are missing from the state that are in the file
        -- TODO: Garbage collection

    end, nil, timer.getTime() + CONFIG.api_feed_monitor_frequency)
end

-- Initialize the system
initializeCIVAIR()