# TwoPoint_SeatSwitcher (TwoPoint Development)

Updated / optimized seat switching resource inspired by **GoatG33k/seat-switcher** (MIT licensed).

## What this version adds
- ✅ Prevents auto seat shuffle (front passenger -> driver)
- ✅ `/seat` command (switch seats while inside vehicle)
- ✅ `/shuff` and `/shuffle` commands (temporary shuffle override)
- ✅ **Door-based seat entry**:
  - Walk to any door
  - Press **F**
  - Enters the seat for that door instead of always trying driver seat

## Install
1. Place folder in your server `resources` directory.
2. Add to `server.cfg`:
   ```
   ensure TwoPoint_SeatSwitcher
   ```
3. Restart resource or server.

## Commands
- `/seat 0` = driver
- `/seat 1` = front passenger
- `/seat 2` = rear left
- `/seat 3` = rear right
- `/seat driver`, `/seat passenger`, `/seat rl`, `/seat rr`
- `/shuff` or `/shuffle` = temporarily allow shuffle to driver seat

## Notes
- Works best on standard vehicles with proper door bones.
- Bikes, some special vehicles, and some custom models may not support full door-seat detection.
- If a target seat is occupied, behavior is controlled by `Config.FallbackToNearestFreeSeat`.

## Config
Open `config.lua` and adjust:
- Entry radius / door select distance
- Cooldown timing
- Fallback behavior
- Notifications
- Command aliases / keybind defaults

## License / Credit
- Original concept/source fork target: GoatG33k `seat-switcher` (MIT)
- This package is a TwoPoint Development styled update/customization
