<#
  curtain-call.ps1 - switch Windows to light mode at sunrise and dark mode at sunset.

  Sun times are calculated locally (NOAA formula, no internet needed).
  Each run sets the correct theme and reschedules the task for the next transition,
  so nothing keeps running in the background.

  -Install    copy the script to %LOCALAPPDATA%\CurtainCall and register the scheduled task (at logon + at unlock + daily at midnight + at next sunrise/sunset)
  -Uninstall  remove the scheduled task
  -Show       only print today's times and the mode that would be set

  -Lat/-Lon   your coordinates (east = positive). When omitted, they are read from
              Windows location services; -Install stores them in the task.
#>
param(
    [Nullable[double]]$Lat,
    [Nullable[double]]$Lon,
    [switch]$Install,
    [switch]$Uninstall,
    [switch]$Show
)

$TaskName = 'CurtainCall'
$InstallDir = Join-Path $env:LOCALAPPDATA 'CurtainCall'   # copy lives here so the task survives the repo drive unmounting
$InstalledScript = Join-Path $InstallDir 'curtain-call.ps1'
$RegPath  ='HKCU:\Software\Microsoft\Windows\CurrentVersion\Themes\Personalize'

function Get-SunTimes([datetime]$Date) {
    $rad = [math]::PI / 180
    $g = 2 * [math]::PI / 365 * ($Date.DayOfYear - 1)
    $eqTime = 229.18 * (0.000075 + 0.001868 * [math]::Cos($g) - 0.032077 * [math]::Sin($g) `
              - 0.014615 * [math]::Cos(2 * $g) - 0.040849 * [math]::Sin(2 * $g))
    $decl = 0.006918 - 0.399912 * [math]::Cos($g) + 0.070257 * [math]::Sin($g) `
            - 0.006758 * [math]::Cos(2 * $g) + 0.000907 * [math]::Sin(2 * $g) `
            - 0.002697 * [math]::Cos(3 * $g) + 0.00148 * [math]::Sin(3 * $g)
    $cosHa = [math]::Cos(90.833 * $rad) / ([math]::Cos($Lat * $rad) * [math]::Cos($decl)) `
             - [math]::Tan($Lat * $rad) * [math]::Tan($decl)
    $cosHa = [math]::Max([double]-1, [math]::Min([double]1, $cosHa))   # polar day/night guard
    $ha = [math]::Acos($cosHa) / $rad

    $utcMidnight = [datetime]::SpecifyKind($Date.Date, 'Utc')
    [pscustomobject]@{
        Sunrise = $utcMidnight.AddMinutes(720 - 4 * ($Lon + $ha) - $eqTime).ToLocalTime()
        Sunset  = $utcMidnight.AddMinutes(720 - 4 * ($Lon - $ha) - $eqTime).ToLocalTime()
    }
}

function Set-Theme([bool]$Light) {
    $v = [int]$Light
    $cur = Get-ItemProperty -Path $RegPath -ErrorAction SilentlyContinue
    if ($cur.AppsUseLightTheme -eq $v -and $cur.SystemUsesLightTheme -eq $v) { return }
    Set-ItemProperty -Path $RegPath -Name AppsUseLightTheme    -Value $v -Type DWord
    Set-ItemProperty -Path $RegPath -Name SystemUsesLightTheme -Value $v -Type DWord

    # Tell running apps the color setting changed
    Add-Type -Namespace Win32 -Name Msg -MemberDefinition @'
[DllImport("user32.dll", CharSet = CharSet.Unicode)]
public static extern System.IntPtr SendMessageTimeout(System.IntPtr hWnd, uint Msg, System.UIntPtr wParam,
    string lParam, uint fuFlags, uint uTimeout, out System.UIntPtr lpdwResult);
'@
    $r = [UIntPtr]::Zero
    [void][Win32.Msg]::SendMessageTimeout([IntPtr]0xffff, 0x1A, [UIntPtr]::Zero, 'ImmersiveColorSet', 2, 5000, [ref]$r)
}

function Get-WindowsLocation([int]$TimeoutSeconds = 15) {
    Add-Type -AssemblyName System.Device
    $w = New-Object System.Device.Location.GeoCoordinateWatcher
    try {
        if (-not $w.TryStart($true, [TimeSpan]::FromSeconds($TimeoutSeconds))) { return $null }
        $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
        while ($w.Position.Location.IsUnknown -and (Get-Date) -lt $deadline) { Start-Sleep -Milliseconds 250 }
        if ($w.Position.Location.IsUnknown) { return $null }
        $w.Position.Location
    } finally {
        $w.Stop(); $w.Dispose()
    }
}

function Get-TaskAction {
    $cmd = "--headless powershell.exe -NoProfile -ExecutionPolicy Bypass -File `"$InstalledScript`" -Lat $Lat -Lon $Lon"
    New-ScheduledTaskAction -Execute 'conhost.exe' -Argument $cmd
}

if ($Uninstall) {
    Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false -ErrorAction SilentlyContinue
    Remove-Item -Path $InstallDir -Recurse -Force -ErrorAction SilentlyContinue
    Write-Host "Task '$TaskName' and $InstallDir removed."
    return
}

if ($null -eq $Lat -or $null -eq $Lon) {
    $loc = Get-WindowsLocation
    if (-not $loc) {
        Write-Error ("Could not get your location from Windows. Enable it in Settings > Privacy & security > " +
                     "Location (including 'Let desktop apps access your location'), or pass -Lat and -Lon.")
        exit 1
    }
    $Lat = [math]::Round($loc.Latitude, 2)
    $Lon = [math]::Round($loc.Longitude, 2)
    Write-Host "Location from Windows: $Lat, $Lon"
}

$now   = Get-Date
$today = Get-SunTimes $now
$light = $now -ge $today.Sunrise -and $now -lt $today.Sunset

if     ($now -lt $today.Sunrise) { $next = $today.Sunrise }
elseif ($now -lt $today.Sunset)  { $next = $today.Sunset }
else                             { $next = (Get-SunTimes $now.AddDays(1)).Sunrise }
$nextRun = $next.AddMinutes(1)   # small margin so the run lands after the transition

if ($Show) {
    "Sunrise : {0:HH:mm}" -f $today.Sunrise
    "Sunset  : {0:HH:mm}" -f $today.Sunset
    "Now     : {0}" -f ($(if ($light) { 'light' } else { 'dark' }))
    "Next    : {0:ddd HH:mm}" -f $nextRun
    return
}

Set-Theme $light

# Unlock trigger: catches up after sleep/Modern Standby, where missed time triggers aren't reliably rerun
$unlock = New-CimInstance -ClientOnly -CimClass (Get-CimClass -Namespace 'ROOT\Microsoft\Windows\TaskScheduler' `
          -ClassName MSFT_TaskSessionStateChangeTrigger) -Property @{ StateChange = 8; UserId = $env:USERNAME; Enabled = $true }

$triggers = @(
    New-ScheduledTaskTrigger -AtLogOn -User $env:USERNAME
    $unlock
    New-ScheduledTaskTrigger -Daily -At '00:00'           # safety net: restarts the chain daily
    New-ScheduledTaskTrigger -Once -At $nextRun
)

if ($Install) {
    New-Item -ItemType Directory -Path $InstallDir -Force | Out-Null
    if ($PSCommandPath -ne $InstalledScript) { Copy-Item -Path $PSCommandPath -Destination $InstalledScript -Force }
    $settings = New-ScheduledTaskSettingsSet -StartWhenAvailable -AllowStartIfOnBatteries `
                -DontStopIfGoingOnBatteries -ExecutionTimeLimit (New-TimeSpan -Minutes 5)
    $principal = New-ScheduledTaskPrincipal -UserId $env:USERNAME -LogonType Interactive -RunLevel Limited
    Register-ScheduledTask -TaskName $TaskName -Action (Get-TaskAction) -Trigger $triggers `
        -Settings $settings -Principal $principal -Force | Out-Null
    Write-Host ("Installed. Theme now {0}, next switch {1:ddd HH:mm}." -f $(if ($light) { 'light' } else { 'dark' }), $nextRun)
} else {
    Set-ScheduledTask -TaskName $TaskName -Trigger $triggers -ErrorAction SilentlyContinue | Out-Null
}
