# Creates (or replaces) the Windows scheduled task that refreshes the item data daily.
# Runs as you, only while you are logged in, no admin needed. If the PC was asleep or off
# at the scheduled time, the refresh runs as soon as possible afterwards.
$ErrorActionPreference = 'Stop'
$name = 'Deadlock Item Overlay refresh'
$script = Join-Path $PSScriptRoot 'collect.ps1'
$report = Join-Path $PSScriptRoot 'data\scheduled_task.txt'
New-Item -ItemType Directory -Force -Path (Join-Path $PSScriptRoot 'data') | Out-Null
try {
    $action = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument ('-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File "{0}"' -f $script) -WorkingDirectory $PSScriptRoot
    $trigger = New-ScheduledTaskTrigger -Daily -At '11:40'
    $settings = New-ScheduledTaskSettingsSet -StartWhenAvailable -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -ExecutionTimeLimit (New-TimeSpan -Minutes 15)
    Register-ScheduledTask -TaskName $name -Action $action -Trigger $trigger -Settings $settings -Description 'Daily refresh of Deadlock Street Brawl item stats for the item overlay.' -Force | Out-Null
    $t = Get-ScheduledTask -TaskName $name
    $i = Get-ScheduledTaskInfo -TaskName $name
    $lines = @(
        "OK: scheduled task created $(Get-Date -Format 's')",
        "Name: $($t.TaskName)",
        "State: $($t.State)",
        "Runs: daily at 11:40 AM (catches up after sleep)",
        "Next run: $($i.NextRunTime)",
        "Command: $($t.Actions[0].Execute) $($t.Actions[0].Arguments)",
        "Remove with: schtasks /Delete /TN `"$name`" /F"
    )
} catch {
    $lines = @("FAILED: $($_.Exception.Message)")
}
$lines | Set-Content -Path $report -Encoding UTF8
$lines | ForEach-Object { Write-Host $_ }
