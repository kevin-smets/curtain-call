#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0' }

BeforeAll {
    $script:ScriptFile = Join-Path $PSScriptRoot '..\curtain-call.ps1'
    . $script:ScriptFile   # dot-sourced: loads the functions, changes nothing

    # Brussels; reference times from timeanddate.com, in UTC
    $script:BxlLat = 50.85
    $script:BxlLon = 4.35
    function Utc([string]$s) { [datetime]::SpecifyKind([datetime]$s, 'Utc') }
    function MinutesApart([datetime]$a, [datetime]$b) { [math]::Abs(($a.ToUniversalTime() - $b.ToUniversalTime()).TotalMinutes) }
}

Describe 'Get-SunTimes' {
    It 'matches Brussels on <Date> within 3 minutes' -ForEach @(
        @{ Date = '2026-06-21'; Sunrise = '2026-06-21 03:29'; Sunset = '2026-06-21 20:00' }
        @{ Date = '2026-12-21'; Sunrise = '2026-12-21 07:44'; Sunset = '2026-12-21 15:39' }
    ) {
        $t = Get-SunTimes ([datetime]$Date) $BxlLat $BxlLon
        MinutesApart $t.Sunrise (Utc $Sunrise) | Should -BeLessOrEqual 3
        MinutesApart $t.Sunset  (Utc $Sunset)  | Should -BeLessOrEqual 3
    }

    It 'returns valid times during polar night and polar day' {
        foreach ($d in '2026-12-21', '2026-06-21') {
            $t = Get-SunTimes ([datetime]$d) 78.2 15.6   # Svalbard
            [double]::IsNaN($t.Sunrise.Ticks) | Should -BeFalse
            $t.Sunset | Should -BeGreaterOrEqual $t.Sunrise
        }
    }
}

Describe 'Get-ThemeState' {
    It 'is dark before sunrise and schedules sunrise' {
        $s = Get-ThemeState (Utc '2026-12-21 06:00') $BxlLat $BxlLon
        $s.Light | Should -BeFalse
        MinutesApart $s.NextRun (Utc '2026-12-21 07:45') | Should -BeLessOrEqual 3
    }

    It 'is light during the day and schedules sunset' {
        $s = Get-ThemeState (Utc '2026-12-21 12:00') $BxlLat $BxlLon
        $s.Light | Should -BeTrue
        MinutesApart $s.NextRun (Utc '2026-12-21 15:40') | Should -BeLessOrEqual 3
    }

    It 'is dark after sunset and schedules tomorrow''s sunrise' {
        $s = Get-ThemeState (Utc '2026-12-21 20:00') $BxlLat $BxlLon
        $s.Light | Should -BeFalse
        MinutesApart $s.NextRun (Utc '2026-12-22 07:45') | Should -BeLessOrEqual 3
    }

    It 'schedules the next run just after the transition, not on it' {
        $s = Get-ThemeState (Utc '2026-12-21 12:00') $BxlLat $BxlLon
        $sunset = (Get-SunTimes ([datetime]'2026-12-21') $BxlLat $BxlLon).Sunset
        ($s.NextRun.ToUniversalTime() - $sunset).TotalMinutes | Should -BeGreaterThan 0
    }

    It 'gives dark when the task catches up late after sleep (unlock at 18:59 on 2026-11-23)' {
        # The sunset run at 16:48 was missed while the PC slept; the unlock run must still pick dark
        $s = Get-ThemeState (Utc '2026-11-23 17:59') 50.84 4.59
        $s.Light | Should -BeFalse
        $s.NextRun.ToUniversalTime().Date | Should -Be (Utc '2026-11-24')
    }
}

Describe 'Set-Theme' {
    BeforeEach {
        Mock Set-ItemProperty {}
        Mock Send-ColorSetChange {}
    }

    It 'does nothing when the theme is already right' {
        Mock Get-ItemProperty { [pscustomobject]@{ AppsUseLightTheme = 0; SystemUsesLightTheme = 0 } }
        Set-Theme $false | Should -BeFalse
        Should -Invoke Set-ItemProperty -Times 0 -Exactly
        Should -Invoke Send-ColorSetChange -Times 0 -Exactly
    }

    It 'writes both values and notifies apps when the theme changes' {
        Mock Get-ItemProperty { [pscustomobject]@{ AppsUseLightTheme = 1; SystemUsesLightTheme = 1 } }
        Set-Theme $false | Should -BeTrue
        Should -Invoke Set-ItemProperty -Times 1 -Exactly -ParameterFilter { $Name -eq 'AppsUseLightTheme' -and $Value -eq 0 }
        Should -Invoke Set-ItemProperty -Times 1 -Exactly -ParameterFilter { $Name -eq 'SystemUsesLightTheme' -and $Value -eq 0 }
        Should -Invoke Send-ColorSetChange -Times 1 -Exactly
    }

    It 'also fixes a half-applied theme (apps light, system dark)' {
        Mock Get-ItemProperty { [pscustomobject]@{ AppsUseLightTheme = 1; SystemUsesLightTheme = 0 } }
        Set-Theme $false | Should -BeTrue
    }
}

Describe 'Get-TaskTriggers' {
    BeforeAll {
        $script:next = (Get-Date).AddHours(3)
        $script:triggers = Get-TaskTriggers $next
        $script:types = $triggers | ForEach-Object { $_.CimClass.CimClassName }
    }

    It 'runs at logon' {
        $types | Should -Contain 'MSFT_TaskLogonTrigger'
    }

    It 'runs at session unlock for the current user (catch-up after sleep)' {
        $unlock = $triggers | Where-Object { $_.CimClass.CimClassName -eq 'MSFT_TaskSessionStateChangeTrigger' }
        $unlock | Should -HaveCount 1
        $unlock.StateChange | Should -Be 8   # TASK_SESSION_UNLOCK
        $unlock.UserId | Should -Be $env:USERNAME
    }

    It 'runs daily at midnight as a safety net' {
        $daily = $triggers | Where-Object { $_.CimClass.CimClassName -eq 'MSFT_TaskDailyTrigger' }
        ([datetime]$daily.StartBoundary).TimeOfDay | Should -Be ([timespan]::Zero)
    }

    It 'runs once at the next transition' {
        $once = $triggers | Where-Object { $_.CimClass.CimClassName -eq 'MSFT_TaskTimeTrigger' }
        MinutesApart ([datetime]$once.StartBoundary) $next | Should -BeLessThan 1
    }
}

Describe 'Get-TaskAction' {
    It 'runs the copy in %LOCALAPPDATA%, not the repo' {
        $a = Get-TaskAction 50.84 4.59
        $a.Arguments | Should -BeLike "*`"$env:LOCALAPPDATA\CurtainCall\curtain-call.ps1`"*"
    }

    It 'runs headless through conhost' {
        $a = Get-TaskAction 50.84 4.59
        $a.Execute | Should -Be 'conhost.exe'
        $a.Arguments | Should -BeLike '--headless *'
    }

    It 'writes coordinates with a dot, also under a comma-decimal culture' {
        $old = [Threading.Thread]::CurrentThread.CurrentCulture
        try {
            [Threading.Thread]::CurrentThread.CurrentCulture = 'nl-BE'
            (Get-TaskAction 50.84 -4.59).Arguments | Should -BeLike '*-Lat 50.84 -Lon -4.59'
        } finally {
            [Threading.Thread]::CurrentThread.CurrentCulture = $old
        }
    }
}

Describe 'Script file' {
    It 'parses without errors in this PowerShell' {
        $errors = $null
        [void][Management.Automation.Language.Parser]::ParseFile((Resolve-Path $ScriptFile), [ref]$null, [ref]$errors)
        $errors | Should -BeNullOrEmpty
    }

    It 'is checked out with CRLF line endings (.gitattributes)' {
        $attr = git -C $PSScriptRoot check-attr eol -- ../curtain-call.ps1
        $attr | Should -BeLike '*: eol: crlf'
    }
}
