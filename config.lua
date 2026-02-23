Config = {}

--[[ 
    TwoPoint Development - Seat Switcher
    Door-based seat entry + anti-auto-shuffle
]]

-- Enable/disable features
Config.EnableDoorBasedEntry = true
Config.EnableAntiAutoShuffle = true
Config.EnableSeatCommands = true
Config.EnableShuffleCommand = true
Config.EnableShuffleKeybind = true

-- If true, pressing F near a vehicle door will attempt to enter the seat attached to that door
Config.EntryControl = 23 -- INPUT_ENTER (default: F)
Config.EntrySearchRadius = 6.0          -- how far to look for a vehicle when pressing F
Config.DoorSelectMaxDistance = 3.25     -- player must be within this distance of a valid door bone
Config.OverrideCooldownMs = 450         -- prevents double-triggering
Config.DisableNativeFNearDoor = true -- recommended: lets the script choose the seat before GTA defaults to driver
Config.EnterTaskTimeoutMs = 10000       -- task timeout passed into TaskEnterVehicle
Config.EnterTaskSpeed = 2.0
Config.EnterTaskFlags = 1               -- 1 = normal enter

-- Optional fallback behavior if target door seat is occupied
Config.FallbackToNearestFreeSeat = false
Config.AllowOverrideWhenSeatOccupied = false -- if false, do nothing (game default may still try driver)

-- Seat shuffle behavior
Config.ShuffleDisableWindowMs = 3000    -- window when /shuffle temporarily disables anti-shuffle flag
Config.AntiShuffleTickMs = 150

-- Chat suggestions (set false if you use a custom chat resource and do not want suggestions)
Config.ChatSuggestions = true

-- Notification style: 'chat', 'feed', or false
Config.NotifyStyle = 'feed'

-- Command aliases
-- /seat supports 1-4 (1=driver, 2=front passenger, 3=rear left, 4=rear right)
-- It also accepts aliases like driver/passenger/rl/rr and raw GTA indexes -1..2
Config.Commands = {
    seat = 'seat',
    shuffle = {'shuff', 'shuffle'}
}

-- Key mapping for shuffle (optional)
Config.ShuffleKeybindCommand = 'tpshuffle'
Config.ShuffleKeybindDefault = 'LSHIFT'

-- Debug
Config.Debug = false
