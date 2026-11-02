# Pick summary for the overlay's stats view (Ctrl+Alt+T): how often you take the top pick and how
# your Street Brawl matches went. Offers and rankings come from data\pick_history.csv (written by the
# overlay). What you bought and whether you won come from your public match history on
# api.deadlock-api.com (new matches can take a while to appear there).
# This file only defines functions; overlay.ps1 loads it.

if ($MyInvocation.InvocationName -ne '.') {
    Write-Host 'The pick summary is now part of the overlay: open overlay.bat and press Ctrl+Alt+T.'
    return
}

function Get-SteamAccountId {
    $steam = $null
    try { $steam = (Get-ItemProperty 'HKCU:\Software\Valve\Steam' -ErrorAction Stop).SteamPath } catch { }
    if (-not $steam) { $steam = 'C:\Program Files (x86)\Steam' }
    $ud = Join-Path ($steam -replace '/', '\') 'userdata'
    if (Test-Path $ud) {
        $d = Get-ChildItem $ud -Directory | Where-Object { $_.Name -match '^\d+$' -and $_.Name -ne '0' } | Sort-Object LastWriteTime -Descending | Select-Object -First 1
        if ($d) { return $d.Name }
    }
    return ''
}

function Get-PickSummary($Snap, [string]$Root, [string]$AccountId = '') {
    $api = 'https://api.deadlock-api.com'
    $historyPath = Join-Path $Root 'data\pick_history.csv'
    $matchDir = Join-Path $Root 'data\matches'
    New-Item -ItemType Directory -Force -Path $matchDir | Out-Null
    if (-not $AccountId) { $AccountId = Get-SteamAccountId }

    $byId = @{}
    foreach ($i in $Snap.items) { $byId[[string]$i.id] = $i }
    $heroName = @{}
    foreach ($h in $Snap.heroes) { $heroName[[string]$h.id] = $h.name }

    $res = [pscustomobject]@{ known = 0; top = 0; avgRank = $null; followed = @(); other = @(); pending = 0; matches = @(); heroesPlayed = @{}; note = '' }
    if (-not (Test-Path $historyPath)) { $res.note = 'No picks logged yet.'; return $res }

    # Offers from the overlay log: one final offer per match, round and choice.
    $offers = @{}
    foreach ($r in @(Import-Csv $historyPath)) {
        if (-not $r.choice -or -not $r.offered_ranked) { continue }
        $items = @()
        foreach ($p in @($r.offered_ranked -split '\s\|\s')) {
            if ($p -match '^\s*(\d+)\.\s+(.+?)\s+([\d.]+)%\s*$') { $items += [pscustomobject]@{ rank = [int]$Matches[1]; name = $Matches[2]; pct = [double]$Matches[3] } }
        }
        if ($items.Count -lt 2) { continue }
        $key = '{0}|{1}|{2}' -f $r.match_start, $r.round, $r.choice
        $o = [pscustomobject]@{ match = $r.match_start; time = [datetime]$r.date; round = $r.round; choice = $r.choice; hero = $r.hero; items = $items; status = $r.status; seen = $r.picked; picked = '' }
        if ($offers.ContainsKey($key) -and -not $o.seen -and $offers[$key].seen) { $o.seen = $offers[$key].seen }
        if (-not $offers.ContainsKey($key) -or $r.status -ne 'rerolled' -or $offers[$key].status -eq 'rerolled') { $offers[$key] = $o }
    }
    $offerList = @($offers.Values | Sort-Object time)

    # Your Street Brawl matches (game mode 4).
    $sb = @()
    if ($AccountId) {
        try { $sb = @(Invoke-RestMethod -Uri "$api/v1/players/$AccountId/match-history" -TimeoutSec 30 -UserAgent 'DeadlockItemOverlay/0.1 (personal use)') | Where-Object { [int]$_.game_mode -eq 4 } } catch { $res.note = 'Match history unavailable right now.' }
    }
    $epoch = [datetime]'1970-01-01Z'

    $known = 0; $top = 0; $rankSum = 0; $rows = @()
    foreach ($mk in @($offerList | ForEach-Object { $_.match } | Select-Object -Unique)) {
        $mo = @($offerList | Where-Object { $_.match -eq $mk })
        $first = ($mo | Sort-Object time | Select-Object -First 1).time.ToUniversalTime()
        $m = $null; $bestD = 1e9
        foreach ($x in $sb) {
            $d = ($first - $epoch.AddSeconds([double]$x.start_time).ToUniversalTime()).TotalMinutes
            if ($d -ge -10 -and $d -le 40 -and [Math]::Abs($d) -lt $bestD) { $bestD = [Math]::Abs($d); $m = $x }
        }
        $bought = $null
        if ($m) {
            $path = Join-Path $matchDir ('{0}.json' -f $m.match_id)
            $meta = $null
            try {
                if (Test-Path $path) { $meta = Get-Content $path -Raw -Encoding UTF8 | ConvertFrom-Json }
                else {
                    $meta = Invoke-RestMethod -Uri ("$api/v1/matches/{0}/metadata" -f $m.match_id) -TimeoutSec 30 -UserAgent 'DeadlockItemOverlay/0.1 (personal use)'
                    ($meta | ConvertTo-Json -Depth 12 -Compress) | Set-Content -Path $path -Encoding UTF8
                }
            } catch { $meta = $null }
            if ($meta) {
                $pl = @($meta.match_info.players | Where-Object { [string]$_.account_id -eq [string]$AccountId }) | Select-Object -First 1
                if ($pl) {
                    $names = @{}
                    foreach ($it in $pl.items) { $xi = $byId[[string]$it.item_id]; if ($xi) { $names[$xi.name] = 1 } }
                    $bought = [pscustomobject]@{ names = $names; won = ([string]$pl.team -eq [string]$meta.match_info.winning_team) }
                }
            }
        }
        $mKnown = 0; $mTop = 0
        foreach ($o in $mo) {
            $hit = @()
            if ($bought) { $hit = @($o.items | Where-Object { $bought.names.ContainsKey($_.name) }) }
            elseif ($o.seen) { $hit = @($o.items | Where-Object { $_.name -eq $o.seen }) }
            if ($hit.Count -eq 1) {
                $o.picked = $hit[0].name
                $mKnown++; $known++; $rankSum += $hit[0].rank
                if ($hit[0].rank -eq 1) { $mTop++; $top++ }
            }
        }
        $hero = (@($mo | Where-Object { $_.hero } | Group-Object hero | Sort-Object Count -Descending | Select-Object -First 1)).Name
        if ($m -and $heroName.ContainsKey([string]$m.hero_id)) { $hero = $heroName[[string]$m.hero_id] }
        if ($hero) { $res.heroesPlayed[$hero] = 1 }
        $result = 'pending'
        if ($bought) { if ($bought.won) { $result = 'win' } else { $result = 'loss' } }
        $rows += [pscustomobject]@{ start = $mk; hero = $hero; result = $result; known = $mKnown; top = $mTop }
    }
    $res.known = $known; $res.top = $top
    if ($known -gt 0) { $res.avgRank = $rankSum / $known }
    $res.matches = $rows
    $res.pending = @($rows | Where-Object { $_.result -eq 'pending' }).Count
    $done = @($rows | Where-Object { $_.result -ne 'pending' -and $_.known -gt 0 })
    $res.followed = @($done | Where-Object { $_.top / $_.known -ge 0.5 })
    $res.other = @($done | Where-Object { $_.top / $_.known -lt 0.5 })
    return $res
}

function Format-WinRate($Set) {
    $s = @($Set)
    if ($s.Count -eq 0) { return 'no results yet' }
    $w = @($s | Where-Object { $_.result -eq 'win' }).Count
    return ('{0:0}%  ({1}-{2})' -f (100.0 * $w / $s.Count), $w, ($s.Count - $w))
}
