# curtain-call

Switches Windows to light mode at sunrise and dark mode at sunset. A single PowerShell script calculates sunrise and sunset locally (NOAA formula, no internet needed) and runs from Task Scheduler. It runs at logon, daily at midnight, and at each sunrise/sunset, and reschedules itself every time it runs. Nothing keeps running in the background.

## Requirements

- Windows 11 (uses `conhost --headless` to run without a visible window)
- Windows PowerShell 5.1 (built in)
- No admin rights needed

## Commands

Install the scheduled task and apply the right theme now. Your location is read from Windows location services (Settings > Privacy & security > Location, including desktop apps) and stored in the task:

```
powershell -NoProfile -ExecutionPolicy Bypass -File .\curtain-call.ps1 -Install
```

Same, but with your own coordinates (east = positive longitude), if location services are off:

```
powershell -NoProfile -ExecutionPolicy Bypass -File .\curtain-call.ps1 -Lat 50.85 -Lon 4.35 -Install
```

Show today's sunrise, sunset and next switch without changing anything:

```
powershell -NoProfile -ExecutionPolicy Bypass -File .\curtain-call.ps1 -Show
```

Remove the scheduled task:

```
powershell -NoProfile -ExecutionPolicy Bypass -File .\curtain-call.ps1 -Uninstall
```

The task points to the script's location. If you move the folder, run `-Install` again from the new location.
