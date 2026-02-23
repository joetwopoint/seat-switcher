--[[
    TwoPoint Development - Seat Switcher (v2.1.1)
    Inspired by GoatG33k seat-switcher (MIT) and expanded for door-based entry.

    Fixes in this version:
      - More reliable door/seat detection (uses door + seat bones)
      - Blocks native F only when near a valid door so custom seat entry can win
      - /seat and /shuff commands now provide feedback + active behavior
      - Safer keymapping registration guards
]]

local CreateThread = CreateThread
local Wait = Wait
local PlayerPedId = PlayerPedId
local RegisterCommand = RegisterCommand
local TriggerEvent = TriggerEvent
local GetGameTimer = GetGameTimer
local tonumber = tonumber
local tostring = tostring
local type = type

-- Natives
local GetEntityCoords = GetEntityCoords
local GetClosestVehicle = GetClosestVehicle
local GetEntityBoneIndexByName = GetEntityBoneIndexByName
local GetWorldPositionOfEntityBone = GetWorldPositionOfEntityBone
local GetVehicleDoorLockStatus = GetVehicleDoorLockStatus
local GetVehiclePedIsTryingToEnter = GetVehiclePedIsTryingToEnter
local GetVehiclePedIsIn = GetVehiclePedIsIn
local GetPedInVehicleSeat = GetPedInVehicleSeat
local IsPedInAnyVehicle = IsPedInAnyVehicle
local IsPedOnFoot = IsPedOnFoot
local IsPedInjured = IsPedInjured
local IsControlJustPressed = IsControlJustPressed
local IsDisabledControlJustPressed = IsDisabledControlJustPressed
local DisableControlAction = DisableControlAction
local IsVehicleSeatFree = IsVehicleSeatFree
local TaskEnterVehicle = TaskEnterVehicle
local TaskShuffleToNextVehicleSeat = TaskShuffleToNextVehicleSeat
local SetPedConfigFlag = SetPedConfigFlag
local SetPedIntoVehicle = SetPedIntoVehicle
local ClearPedTasks = ClearPedTasks
local Vdist2 = Vdist2
local DoesEntityExist = DoesEntityExist
local GetCurrentResourceName = GetCurrentResourceName

local function notify(msg)
    if not Config or not Config.NotifyStyle then return end

    if Config.NotifyStyle == 'chat' then
        TriggerEvent('chat:addMessage', {
            color = {255, 153, 0},
            args = {'TwoPoint SeatSwitcher', msg}
        })
        return
    end

    BeginTextCommandThefeedPost('STRING')
    AddTextComponentSubstringPlayerName(msg)
    EndTextCommandThefeedPostTicker(false, false)
end

local function debugPrint(...)
    if Config and Config.Debug then
        print('[TwoPoint_SeatSwitcher]', ...)
    end
end

local SEAT = {
    DRIVER = -1,
    FRONT_PASSENGER = 0,
    REAR_LEFT = 1,
    REAR_RIGHT = 2,
}

-- We probe multiple bones per seat because some vehicles expose seat bones better than door bones.
local DOOR_SEAT_POINTS = {
    { seat = SEAT.DRIVER,          label = 'driver',           bones = {'door_dside_f', 'seat_dside_f'} },
    { seat = SEAT.FRONT_PASSENGER, label = 'front passenger',  bones = {'door_pside_f', 'seat_pside_f'} },
    { seat = SEAT.REAR_LEFT,       label = 'rear left',        bones = {'door_dside_r', 'seat_dside_r'} },
    { seat = SEAT.REAR_RIGHT,      label = 'rear right',       bones = {'door_pside_r', 'seat_pside_r'} },
}

local temporarilyDisableAntiShuffle = false
local lastDoorEntryAt = 0

local function isVehicleLockedForEntry(vehicle)
    if not vehicle or vehicle == 0 then return true end
    local status = GetVehicleDoorLockStatus(vehicle)
    -- 2+ commonly means locked/locked for player
    return status and status >= 2 or false
end

local function canHandleDoorBasedEntry(ped)
    if not Config.EnableDoorBasedEntry then return false end
    if IsPedInjured(ped) then return false end
    if not IsPedOnFoot(ped) then return false end
    if IsPedInAnyVehicle(ped, false) then return false end

    local now = GetGameTimer()
    if (now - lastDoorEntryAt) < (Config.OverrideCooldownMs or 350) then
        return false
    end

    return true
end

local function getEntryCandidateVehicle(ped)
    local trying = GetVehiclePedIsTryingToEnter(ped)
    if trying and trying ~= 0 and DoesEntityExist(trying) then
        return trying
    end

    local p = GetEntityCoords(ped)
    local veh = GetClosestVehicle(p.x, p.y, p.z, Config.EntrySearchRadius or 5.0, 0, 71)
    if veh and veh ~= 0 and DoesEntityExist(veh) then
        return veh
    end

    return nil
end

local function collectSeatDoorCandidates(vehicle, pedCoords)
    local out = {}
    local maxDist2 = (Config.DoorSelectMaxDistance or 3.25)
    maxDist2 = maxDist2 * maxDist2

    for i = 1, #DOOR_SEAT_POINTS do
        local entry = DOOR_SEAT_POINTS[i]
        local bestDist2 = nil

        for b = 1, #entry.bones do
            local boneName = entry.bones[b]
            local boneIndex = GetEntityBoneIndexByName(vehicle, boneName)
            if boneIndex and boneIndex ~= -1 then
                local pos = GetWorldPositionOfEntityBone(vehicle, boneIndex)
                local dist2 = Vdist2(pedCoords.x, pedCoords.y, pedCoords.z, pos.x, pos.y, pos.z)
                if not bestDist2 or dist2 < bestDist2 then
                    bestDist2 = dist2
                end
            end
        end

        if bestDist2 and bestDist2 <= maxDist2 then
            out[#out + 1] = {
                seat = entry.seat,
                label = entry.label,
                dist2 = bestDist2,
            }
        end
    end

    return out
end

local function pickNearestDoorSeat(vehicle, pedCoords)
    local list = collectSeatDoorCandidates(vehicle, pedCoords)
    if #list == 0 then return nil, nil end

    local best = list[1]
    for i = 2, #list do
        if list[i].dist2 < best.dist2 then
            best = list[i]
        end
    end

    return best, list
end

local function resolveSeatForEntry(vehicle, preferredSeat, candidates)
    if IsVehicleSeatFree(vehicle, preferredSeat) then
        return preferredSeat
    end

    -- If player is already trying to enter this exact seat somehow, let task still be sent if configured
    if Config.AllowOverrideWhenSeatOccupied then
        return preferredSeat
    end

    if not Config.FallbackToNearestFreeSeat then
        return nil
    end

    local alt = nil
    for i = 1, #candidates do
        local c = candidates[i]
        if IsVehicleSeatFree(vehicle, c.seat) then
            if not alt or c.dist2 < alt.dist2 then
                alt = c
            end
        end
    end

    return alt and alt.seat or nil
end

local function attemptDoorEntry()
    local ped = PlayerPedId()
    if not canHandleDoorBasedEntry(ped) then return end

    local vehicle = getEntryCandidateVehicle(ped)
    if not vehicle then return end
    if isVehicleLockedForEntry(vehicle) then return end

    local pedCoords = GetEntityCoords(ped)
    local nearest, candidates = pickNearestDoorSeat(vehicle, pedCoords)
    if not nearest then return end

    -- Disable vanilla F while near a detectable door so our chosen seat is used.
    -- IMPORTANT: when a control is disabled in FiveM, IsControlJustPressed may not fire.
    -- We must also listen to IsDisabledControlJustPressed or F gets fully blocked near doors.
    local pressed = false
    if Config.DisableNativeFNearDoor ~= false then
        DisableControlAction(0, Config.EntryControl, true)
        pressed = IsDisabledControlJustPressed(0, Config.EntryControl) or IsControlJustPressed(0, Config.EntryControl)
    else
        pressed = IsControlJustPressed(0, Config.EntryControl)
    end

    if not pressed then return end

    local targetSeat = resolveSeatForEntry(vehicle, nearest.seat, candidates)
    if targetSeat == nil then
        notify('That seat is occupied.')
        return
    end

    lastDoorEntryAt = GetGameTimer()
    ClearPedTasks(ped)
    TaskEnterVehicle(
        ped,
        vehicle,
        Config.EnterTaskTimeoutMs or 10000,
        targetSeat,
        Config.EnterTaskSpeed or 2.0,
        Config.EnterTaskFlags or 1,
        0
    )

    debugPrint(('Door-based entry -> seat %s (%s)'):format(tostring(targetSeat), nearest.label))
end

-- Anti-auto-shuffle: stops passenger seat from auto sliding to driver unless temporarily disabled
CreateThread(function()
    while true do
        local ped = PlayerPedId()
        local sleep = Config.AntiShuffleTickMs or 150

        if Config.EnableAntiAutoShuffle and not temporarilyDisableAntiShuffle then
            local prevent = false
            if IsPedInAnyVehicle(ped, false) then
                local veh = GetVehiclePedIsIn(ped, false)
                if veh and veh ~= 0 and GetPedInVehicleSeat(veh, 0) == ped then
                    prevent = true
                end
            else
                sleep = 300
            end
            SetPedConfigFlag(ped, 184, prevent)
        else
            SetPedConfigFlag(ped, 184, false)
            sleep = 120
        end

        Wait(sleep)
    end
end)

-- Door-based entry thread
CreateThread(function()
    while true do
        if Config.EnableDoorBasedEntry then
            attemptDoorEntry()
            Wait(0)
        else
            Wait(500)
        end
    end
end)

local function withAntiShuffleDisabled(ms)
    CreateThread(function()
        temporarilyDisableAntiShuffle = true
        Wait(ms or Config.ShuffleDisableWindowMs or 3000)
        temporarilyDisableAntiShuffle = false
    end)
end

local function seatInputToIndex(value)
    if value == nil then return nil end

    local input = tostring(value):lower():gsub('%s+', '')

    local aliases = {
        -- Preferred user-facing numbering (matches many seat scripts):
        ['1'] = SEAT.DRIVER,
        ['2'] = SEAT.FRONT_PASSENGER,
        ['3'] = SEAT.REAR_LEFT,
        ['4'] = SEAT.REAR_RIGHT,

        -- Backwards compatibility with v2.0 docs / zero-based indexing:
        ['0'] = SEAT.DRIVER,

        ['d'] = SEAT.DRIVER,
        ['driver'] = SEAT.DRIVER,
        ['p'] = SEAT.FRONT_PASSENGER,
        ['passenger'] = SEAT.FRONT_PASSENGER,
        ['front'] = SEAT.FRONT_PASSENGER,
        ['fp'] = SEAT.FRONT_PASSENGER,
        ['rl'] = SEAT.REAR_LEFT,
        ['rearleft'] = SEAT.REAR_LEFT,
        ['backleft'] = SEAT.REAR_LEFT,
        ['rr'] = SEAT.REAR_RIGHT,
        ['rearright'] = SEAT.REAR_RIGHT,
        ['backright'] = SEAT.REAR_RIGHT,
    }

    if aliases[input] ~= nil then
        return aliases[input]
    end

    local n = tonumber(input)
    if n == nil then return nil end

    -- Also support raw GTA seat indexes if users pass -1..2
    if n >= -1 and n <= 2 then
        return n
    end

    return nil
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

    local currentSeatIsTarget = (GetPedInVehicleSeat(veh, seatIndex) == ped)
    if currentSeatIsTarget then
        return true, 'Already in that seat.'
    end

    if not IsVehicleSeatFree(veh, seatIndex) then
        return false, 'That seat is occupied.'
    end

    CreateThread(function()
        temporarilyDisableAntiShuffle = true
        SetPedIntoVehicle(PlayerPedId(), veh, seatIndex)
        Wait(75)
        temporarilyDisableAntiShuffle = false
    end)

    return true, 'Switched seats.'
end

local function seatCommand(_, args)
    local seatIndex = seatInputToIndex(args and args[1])
    if seatIndex == nil then
        notify('Usage: /' .. Config.Commands.seat .. ' [1-4 | driver | passenger | rl | rr]')
        return
    end

    local ok, msg = doSeatSwitch(seatIndex)
    if msg then notify(msg) end
    if not ok then
        debugPrint('Seat command failed:', msg or 'unknown')
    end
end

local function shuffleCommand()
    local ped = PlayerPedId()
    if not IsPedInAnyVehicle(ped, false) then
        notify('You are not in a vehicle.')
        return
    end

    local veh = GetVehiclePedIsIn(ped, false)
    withAntiShuffleDisabled(Config.ShuffleDisableWindowMs or 3000)

    -- Actively request a shuffle if possible (helps users confirm the command works)
    TaskShuffleToNextVehicleSeat(ped, veh)
    notify('Seat shuffle enabled briefly.')
end

if Config.EnableSeatCommands then
    RegisterCommand(Config.Commands.seat, seatCommand, false)
end

if Config.EnableShuffleCommand and Config.Commands and type(Config.Commands.shuffle) == 'table' then
    for i = 1, #Config.Commands.shuffle do
        local cmd = Config.Commands.shuffle[i]
        RegisterCommand(cmd, function()
            shuffleCommand()
        end, false)
    end
end

if Config.EnableShuffleKeybind and Config.ShuffleKeybindCommand then
    RegisterCommand(Config.ShuffleKeybindCommand, function()
        shuffleCommand()
    end, false)

    -- Guard for older artifacts that may not expose RegisterKeyMapping
    if RegisterKeyMapping then
        RegisterKeyMapping(
            Config.ShuffleKeybindCommand,
            'TwoPoint SeatSwitcher: Shuffle to next seat',
            'keyboard',
            Config.ShuffleKeybindDefault or 'LSHIFT'
        )
    end
end

CreateThread(function()
    Wait(1000)
    if not Config.ChatSuggestions then return end

    if Config.EnableSeatCommands then
        TriggerEvent('chat:addSuggestion', '/' .. Config.Commands.seat, 'Switch seats in your current vehicle', {
            { name = 'seat', help = '1=driver, 2=front passenger, 3=rear left, 4=rear right (aliases also supported)' }
        })
    end

    if Config.EnableShuffleCommand and Config.Commands and type(Config.Commands.shuffle) == 'table' then
        for i = 1, #Config.Commands.shuffle do
            TriggerEvent('chat:addSuggestion', '/' .. Config.Commands.shuffle[i], 'Temporarily allow and request seat shuffle')
        end
    end
end)

AddEventHandler('onClientResourceStop', function(resourceName)
    if resourceName ~= GetCurrentResourceName() then return end
    SetPedConfigFlag(PlayerPedId(), 184, false)
end)
