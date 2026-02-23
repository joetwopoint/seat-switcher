--[[
    TwoPoint Development - Seat Switcher (v2.0.0)
    Updated / optimized fork concept inspired by GoatG33k seat-switcher (MIT)
    Features:
      - Prevent front passenger auto-shuffling into driver seat
      - /seat and /shuffle support
      - Door-based seat entry: press F near a door to enter that exact seat
]]

-- localize globals for perf/readability
local CreateThread = CreateThread
local Wait = Wait
local PlayerPedId = PlayerPedId
local GetGameTimer = GetGameTimer
local RegisterCommand = RegisterCommand
local RegisterKeyMapping = RegisterKeyMapping
local TriggerEvent = TriggerEvent
local tonumber = tonumber
local tostring = tostring
local pairs = pairs
local ipairs = ipairs
local math_huge = math.huge

local GetEntityCoords = GetEntityCoords
local GetEntityModel = GetEntityModel
local GetEntityBoneIndexByName = GetEntityBoneIndexByName
local GetWorldPositionOfEntityBone = GetWorldPositionOfEntityBone
local GetVehicleDoorLockStatus = GetVehicleDoorLockStatus
local GetClosestVehicle = GetClosestVehicle
local GetPedInVehicleSeat = GetPedInVehicleSeat
local GetVehiclePedIsIn = GetVehiclePedIsIn
local GetVehiclePedIsTryingToEnter = GetVehiclePedIsTryingToEnter
local IsPedInAnyVehicle = IsPedInAnyVehicle
local IsPedInjured = IsPedInjured
local IsPedOnFoot = IsPedOnFoot
local IsPedRunning = IsPedRunning
local IsPedSprinting = IsPedSprinting
local IsControlJustPressed = IsControlJustPressed
local IsVehicleSeatFree = IsVehicleSeatFree
local SetPedIntoVehicle = SetPedIntoVehicle
local SetPedConfigFlag = SetPedConfigFlag
local TaskEnterVehicle = TaskEnterVehicle
local ClearPedTasks = ClearPedTasks
local Vdist2 = Vdist2

-- UI / notifications
local function notify(msg)
    if not Config.NotifyStyle then return end

    if Config.NotifyStyle == 'chat' then
        TriggerEvent('chat:addMessage', {
            color = {255, 153, 0},
            args = {'TwoPoint SeatSwitcher', msg}
        })
        return
    end

    -- Default feed notification
    BeginTextCommandThefeedPost('STRING')
    AddTextComponentSubstringPlayerName(msg)
    EndTextCommandThefeedPostTicker(false, false)
end

local function debugPrint(...)
    if Config.Debug then
        print('[TwoPoint_SeatSwitcher]', ...)
    end
end

-- State
local temporarilyDisableAntiShuffle = false
local lastDoorOverrideAt = 0

-- GTA seat indexes
local SEAT = {
    DRIVER = -1,
    FRONT_PASSENGER = 0,
    REAR_DRIVER = 1,
    REAR_PASSENGER = 2,
}

-- Door bone -> seat mapping
-- NOTE: this works for most standard 4-door vehicles. 2-door vehicles typically only expose front bones.
local DOOR_SEAT_BONES = {
    { bone = 'door_dside_f', seat = SEAT.DRIVER, label = 'driver' },
    { bone = 'door_pside_f', seat = SEAT.FRONT_PASSENGER, label = 'front passenger' },
    { bone = 'door_dside_r', seat = SEAT.REAR_DRIVER, label = 'rear left' },
    { bone = 'door_pside_r', seat = SEAT.REAR_PASSENGER, label = 'rear right' },
}

local function isVehicleLockedForEntry(vehicle)
    -- 2 = locked, 3 = locked for player? Various scripts also use >1 for locked states
    local status = GetVehicleDoorLockStatus(vehicle)
    return status ~= nil and status >= 2
end

local function getDoorCandidates(vehicle, pedCoords)
    local candidates = {}

    for i = 1, #DOOR_SEAT_BONES do
        local map = DOOR_SEAT_BONES[i]
        local boneIndex = GetEntityBoneIndexByName(vehicle, map.bone)

        if boneIndex and boneIndex ~= -1 then
            local bonePos = GetWorldPositionOfEntityBone(vehicle, boneIndex)
            local dist2 = Vdist2(pedCoords.x, pedCoords.y, pedCoords.z, bonePos.x, bonePos.y, bonePos.z)

            candidates[#candidates + 1] = {
                seat = map.seat,
                label = map.label,
                bone = map.bone,
                dist2 = dist2
            }
        end
    end

    return candidates
end

local function pickNearestDoorSeat(vehicle, pedCoords)
    local candidates = getDoorCandidates(vehicle, pedCoords)
    if #candidates == 0 then return nil end

    local best = nil
    for i = 1, #candidates do
        local c = candidates[i]
        if not best or c.dist2 < best.dist2 then
            best = c
        end
    end

    if not best then return nil end

    local maxDist2 = Config.DoorSelectMaxDistance * Config.DoorSelectMaxDistance
    if best.dist2 > maxDist2 then
        return nil
    end

    return best, candidates
end

local function resolveSeatToEnter(vehicle, preferredSeat, candidates)
    if IsVehicleSeatFree(vehicle, preferredSeat) then
        return preferredSeat
    end

    if not Config.FallbackToNearestFreeSeat then
        return nil
    end

    if not candidates then return nil end

    local bestAlt = nil
    for i = 1, #candidates do
        local c = candidates[i]
        if IsVehicleSeatFree(vehicle, c.seat) then
            if not bestAlt or c.dist2 < bestAlt.dist2 then
                bestAlt = c
            end
        end
    end

    return bestAlt and bestAlt.seat or nil
end

local function findTargetVehicleForEntry(ped)
    -- If GTA already picked a vehicle because player pressed F, prefer that.
    local tryingVeh = GetVehiclePedIsTryingToEnter(ped)
    if tryingVeh and tryingVeh ~= 0 then
        return tryingVeh
    end

    local p = GetEntityCoords(ped)
    local veh = GetClosestVehicle(p.x, p.y, p.z, Config.EntrySearchRadius, 0, 71)
    if veh and veh ~= 0 then
        return veh
    end

    return nil
end

local function shouldHandleDoorEntry(ped)
    if not Config.EnableDoorBasedEntry then return false end
    if IsPedInjured(ped) then return false end
    if not IsPedOnFoot(ped) then return false end
    if IsPedInAnyVehicle(ped, false) then return false end

    local now = GetGameTimer()
    if now - lastDoorOverrideAt < Config.OverrideCooldownMs then
        return false
    end

    return true
end

local function handleDoorBasedEntry()
    local ped = PlayerPedId()

    if not shouldHandleDoorEntry(ped) then return end
    if not IsControlJustPressed(0, Config.EntryControl) then return end

    local vehicle = findTargetVehicleForEntry(ped)
    if not vehicle then return end
    if isVehicleLockedForEntry(vehicle) then
        debugPrint('Vehicle locked, skipping override')
        return
    end

    local pedCoords = GetEntityCoords(ped)
    local nearest, candidates = pickNearestDoorSeat(vehicle, pedCoords)
    if not nearest then
        -- Not standing close enough to a valid door bone; let GTA default behavior happen
        return
    end

    local targetSeat = resolveSeatToEnter(vehicle, nearest.seat, candidates)
    if not targetSeat then
        if Config.AllowOverrideWhenSeatOccupied then
            targetSeat = nearest.seat
        else
            debugPrint('Preferred door seat occupied; no override')
            return
        end
    end

    -- Override GTA's default seat choice (usually driver) with the seat for the door they're near
    lastDoorOverrideAt = GetGameTimer()
    ClearPedTasks(ped)
    TaskEnterVehicle(
        ped,
        vehicle,
        Config.EnterTaskTimeoutMs,
        targetSeat,
        Config.EnterTaskSpeed,
        Config.EnterTaskFlags,
        0
    )

    debugPrint(('Door entry override -> seat %s (%s)'):format(tostring(targetSeat), nearest.label))
end

-- Anti auto-shuffle thread (prevents front passenger from sliding into driver seat)
CreateThread(function()
    while true do
        local sleep = Config.AntiShuffleTickMs
        local ped = PlayerPedId()

        if Config.EnableAntiAutoShuffle and not temporarilyDisableAntiShuffle then
            local restrictSwitching = false

            if IsPedInAnyVehicle(ped, false) then
                local veh = GetVehiclePedIsIn(ped, false)
                if veh and veh ~= 0 then
                    -- Seat 0 = front passenger. This is the seat that auto-shuffles into driver.
                    if GetPedInVehicleSeat(veh, 0) == ped then
                        restrictSwitching = true
                    end
                end
            else
                sleep = 300
            end

            SetPedConfigFlag(ped, 184, restrictSwitching)
        else
            -- Ensure flag is cleared while anti-shuffle is temporarily disabled
            SetPedConfigFlag(ped, 184, false)
            sleep = 100
        end

        Wait(sleep)
    end
end)

-- Door entry override thread
CreateThread(function()
    while true do
        if Config.EnableDoorBasedEntry then
            handleDoorBasedEntry()
            Wait(0)
        else
            Wait(500)
        end
    end
end)

local function withAntiShuffleDisabled(ms)
    CreateThread(function()
        temporarilyDisableAntiShuffle = true
        Wait(ms or Config.ShuffleDisableWindowMs)
        temporarilyDisableAntiShuffle = false
    end)
end

local function seatInputToIndex(value)
    if value == nil then return nil end

    local input = tostring(value):lower():gsub('%s+', '')

    -- Numeric support:
    -- user "0" => driver (-1)
    -- user "1" => front passenger (0)
    -- user "2" => rear left (1)
    -- user "3" => rear right (2)
    local numeric = tonumber(input)
    if numeric ~= nil then
        local mapped = numeric - 1
        if mapped >= -1 and mapped <= 2 then
            return mapped
        end
    end

    -- Aliases
    local aliases = {
        ['d'] = SEAT.DRIVER,
        ['driver'] = SEAT.DRIVER,
        ['0'] = SEAT.DRIVER,

        ['p'] = SEAT.FRONT_PASSENGER,
        ['passenger'] = SEAT.FRONT_PASSENGER,
        ['front'] = SEAT.FRONT_PASSENGER,
        ['fp'] = SEAT.FRONT_PASSENGER,
        ['1'] = SEAT.FRONT_PASSENGER,

        ['rl'] = SEAT.REAR_DRIVER,
        ['rearleft'] = SEAT.REAR_DRIVER,
        ['backleft'] = SEAT.REAR_DRIVER,
        ['2'] = SEAT.REAR_DRIVER,

        ['rr'] = SEAT.REAR_PASSENGER,
        ['rearright'] = SEAT.REAR_PASSENGER,
        ['backright'] = SEAT.REAR_PASSENGER,
        ['3'] = SEAT.REAR_PASSENGER,
    }

    return aliases[input]
end

local function doSeatSwitch(seatIndex)
    local ped = PlayerPedId()
    if not IsPedInAnyVehicle(ped, false) then
        return false, 'You are not in a vehicle.'
    end

    local veh = GetVehiclePedIsIn(ped, false)
    if not veh or veh == 0 then
        return false, 'No vehicle found.'
    end

    if not IsVehicleSeatFree(veh, seatIndex) and GetPedInVehicleSeat(veh, seatIndex) ~= ped then
        return false, 'That seat is occupied.'
    end

    CreateThread(function()
        temporarilyDisableAntiShuffle = true
        SetPedIntoVehicle(PlayerPedId(), veh, seatIndex)
        Wait(100)
        temporarilyDisableAntiShuffle = false
    end)

    return true
end

local function seatCommand(_, args)
    local seatIndex = seatInputToIndex(args and args[1])
    if seatIndex == nil then
        notify('Usage: /' .. Config.Commands.seat .. ' [0-3 | driver | passenger | rl | rr]')
        return
    end

    local ok, err = doSeatSwitch(seatIndex)
    if not ok and err then
        notify(err)
    end
end

local function shuffleCommand()
    if not Config.EnableShuffleCommand and not Config.EnableShuffleKeybind then
        return
    end

    withAntiShuffleDisabled(Config.ShuffleDisableWindowMs)
end

-- Commands
if Config.EnableSeatCommands then
    RegisterCommand(Config.Commands.seat, seatCommand, false)
end

if Config.EnableShuffleCommand and Config.Commands.shuffle then
    for i = 1, #Config.Commands.shuffle do
        RegisterCommand(Config.Commands.shuffle[i], function()
            shuffleCommand()
        end, false)
    end
end

if Config.EnableShuffleKeybind and Config.ShuffleKeybindCommand then
    RegisterCommand(Config.ShuffleKeybindCommand, function()
        shuffleCommand()
    end, false)

    -- This shows in FiveM keybind settings so players can change it
    RegisterKeyMapping(
        Config.ShuffleKeybindCommand,
        'TwoPoint SeatSwitcher: Temporarily allow seat shuffle to driver',
        'keyboard',
        Config.ShuffleKeybindDefault
    )
end

-- Chat suggestions (best effort, only if chat resource is present)
CreateThread(function()
    Wait(1000)

    if Config.ChatSuggestions then
        if Config.EnableSeatCommands then
            TriggerEvent('chat:addSuggestion', '/' .. Config.Commands.seat, 'Switch seats in your current vehicle', {
                { name = 'seat', help = '0=driver, 1=front passenger, 2=rear left, 3=rear right (or names like driver/passenger/rl/rr)' }
            })
        end

        if Config.EnableShuffleCommand and Config.Commands.shuffle then
            for i = 1, #Config.Commands.shuffle do
                TriggerEvent('chat:addSuggestion', '/' .. Config.Commands.shuffle[i], 'Temporarily allow switching to the driver seat')
            end
        end
    end
end)

-- Cleanup ped flag on stop
AddEventHandler('onClientResourceStop', function(resourceName)
    if resourceName ~= GetCurrentResourceName() then return end
    SetPedConfigFlag(PlayerPedId(), 184, false)
end)
