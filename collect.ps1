# Daily data refresh for the Street Brawl item ranker.
# Pulls Street Brawl hero and item stats and item names from api.deadlock-api.com,
# saves a dated snapshot under data\, writes data\latest.json, and compares against the previous day.
# Windows PowerShell 5.1 compatible.

param([int]$MaxDays = 30)

$ErrorActionPreference = 'Stop'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
$ProgressPreference = 'SilentlyContinue'

$Root    = $PSScriptRoot
$DataDir = Join-Path $Root 'data'
$Api     = 'https://api.deadlock-api.com'
$Today   = Get-Date -Format 'yyyy-MM-dd'
$DayDir  = Join-Path $DataDir $Today
New-Item -ItemType Directory -Force -Path $DayDir | Out-Null
$LogFile = Join-Path $DataDir 'collect.log'
$Modes   = @('street_brawl')

function Write-Log([string]$Message) {
    $line = '{0} {1}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Message
    Write-Host $line
    Add-Content -Path $LogFile -Value $line -Encoding UTF8
}

function Get-Api([string]$Path) {
    $url = $Api + $Path
    for ($try = 1; $try -le 4; $try++) {
        try {
            $res = Invoke-RestMethod -Uri $url -TimeoutSec 180 -UserAgent 'DeadlockItemOverlay/0.1 (personal use)'
            return $res
        } catch {
            $code = 0
            if ($_.Exception.Response) { $code = [int]$_.Exception.Response.StatusCode }
            Write-Log ('  request failed (HTTP {0}), try {1}: {2}' -f $code, $try, $Path)
            if ($code -eq 429) { Start-Sleep -Seconds (20 * $try) } else { Start-Sleep -Seconds (3 * $try) }
        }
    }
    throw "Giving up on $Path"
}

try {
    Write-Log "Refresh started"

    # Time window: since the latest big patch, but no more than $MaxDays days back.
    $now = [DateTimeOffset]::UtcNow
    $since = $now.AddDays(-$MaxDays)
    $patchNote = ''
    try {
        $big = @(Get-Api '/v1/patches/big-days')
        if ($big.Count -gt 0) {
            $last = [DateTimeOffset]::Parse([string]$big[0], [Globalization.CultureInfo]::InvariantCulture)
            foreach ($b in $big) {
                $d = [DateTimeOffset]::Parse([string]$b, [Globalization.CultureInfo]::InvariantCulture)
                if ($d -gt $last) { $last = $d }
            }
            $patchNote = $last.ToString('yyyy-MM-dd')
            if ($last -gt $since) { $since = $last }
        }
    } catch { Write-Log '  could not read patch dates, using the day window only' }
    $sinceUnix = $since.ToUnixTimeSeconds()

    # Newest game build (ClientVersion) known to the API.
    $build = ''
    try {
        $vers = @(Get-Api '/v1/assets/client-versions')
        if ($vers.Count -gt 0) { $build = [string](($vers | ForEach-Object { [int]$_ } | Measure-Object -Maximum).Maximum) }
    } catch { Write-Log '  could not read the game build number' }
    Write-Log "  game build: $build"
    Write-Log ('  window: since {0} (last big patch {1})' -f $since.ToString('yyyy-MM-dd'), $patchNote)

    # Names, tiers, costs (items) and heroes with the game's per-hero draft tags.
    Write-Log '  downloading item list'
    $itemsRaw = @(Get-Api '/v1/assets/items')
    $items = @()
    foreach ($i in $itemsRaw) {
        if ($i.type -ne 'upgrade') { continue }
        $items += [ordered]@{
            id = [string]$i.id; name = $i.name; class_name = $i.class_name
            tier = $i.item_tier; cost = $i.cost; slot = $i.item_slot_type
            shopable = [bool]$i.shopable; disabled = [bool]$i.disabled
        }
    }
    $abilityImg = @{}
    $shopImg = @{}
    foreach ($i in $itemsRaw) {
        if ($i.type -eq 'ability' -and $i.image) { $abilityImg[[string]$i.class_name] = [string]$i.image }
        if ($i.type -eq 'upgrade' -and $i.shopable -and $i.shop_image) { $shopImg[[string]$i.id] = [string]$i.shop_image }
    }
    $itemsRaw = $null
    Write-Log ('  items: {0} upgrades' -f $items.Count)

    Write-Log '  downloading hero list'
    $heroesRaw = @(Get-Api '/v1/assets/heroes')
    $heroes = @()
    foreach ($h in $heroesRaw) {
        $buckets = [ordered]@{}
        if ($h.item_draft_bucketing) {
            foreach ($p in $h.item_draft_bucketing.PSObject.Properties) {
                $buckets[$p.Name] = [ordered]@{ b = $p.Value.bucket; w = $p.Value.weight }
            }
        }
        $heroes += [ordered]@{
            id = [string]$h.id; name = $h.name
            selectable = ([bool]$h.player_selectable -and -not [bool]$h.disabled)
            buckets = $buckets
        }
    }
    # Ability icons (for hero detection on screen). Re-download only when an icon URL changes.
    $iconDir = Join-Path $DataDir 'icons'
    New-Item -ItemType Directory -Force -Path $iconDir | Out-Null
    $manifestPath = Join-Path $iconDir 'icons.json'
    $manifest = @{}
    if (Test-Path $manifestPath) {
        $mj = Get-Content $manifestPath -Raw -Encoding UTF8 | ConvertFrom-Json
        foreach ($p in $mj.PSObject.Properties) { $manifest[$p.Name] = [string]$p.Value }
    }
    $iconNew = 0; $iconFail = 0
    foreach ($h in $heroesRaw) {
        if (-not ([bool]$h.player_selectable -and -not [bool]$h.disabled)) { continue }
        for ($k = 1; $k -le 4; $k++) {
            $cls = [string]$h.items."signature$k"
            if (-not $cls -or -not $abilityImg.ContainsKey($cls)) { continue }
            $url = $abilityImg[$cls]
            $file = '{0}_{1}.png' -f $h.id, $k
            $path = Join-Path $iconDir $file
            if ((Test-Path $path) -and $manifest[$file] -eq $url) { continue }
            try {
                Invoke-WebRequest -Uri $url -OutFile $path -UseBasicParsing -TimeoutSec 60 -UserAgent 'DeadlockItemOverlay/0.1 (personal use)'
                $manifest[$file] = $url; $iconNew++
            } catch { $iconFail++ }
        }
    }
    $manifest | ConvertTo-Json | Set-Content -Path $manifestPath -Encoding UTF8
    Write-Log ('  ability icons: {0} downloaded, {1} failed' -f $iconNew, $iconFail)

    # Item shop icons (shown inside the overlay circles). Re-download only when an icon URL changes.
    $itemIconDir = Join-Path $DataDir 'item_icons'
    New-Item -ItemType Directory -Force -Path $itemIconDir | Out-Null
    $imPath = Join-Path $itemIconDir 'icons.json'
    $im = @{}
    if (Test-Path $imPath) {
        $imj = Get-Content $imPath -Raw -Encoding UTF8 | ConvertFrom-Json
        foreach ($p in $imj.PSObject.Properties) { $im[$p.Name] = [string]$p.Value }
    }
    $itNew = 0; $itFail = 0
    foreach ($id in $shopImg.Keys) {
        $url = $shopImg[$id]
        $path = Join-Path $itemIconDir ($id + '.png')
        if ((Test-Path $path) -and $im[$id] -eq $url) { continue }
        try {
            Invoke-WebRequest -Uri $url -OutFile $path -UseBasicParsing -TimeoutSec 60 -UserAgent 'DeadlockItemOverlay/0.1 (personal use)'
            $im[$id] = $url; $itNew++
        } catch { $itFail++ }
    }
    $im | ConvertTo-Json | Set-Content -Path $imPath -Encoding UTF8
    Write-Log ('  item icons: {0} downloaded, {1} failed' -f $itNew, $itFail)

    $heroesRaw = $null
    $playable = @($heroes | Where-Object { $_.selectable })
    Write-Log ('  heroes: {0} playable' -f $playable.Count)

    $heroStats = [ordered]@{}
    $itemStats = [ordered]@{}
    foreach ($mode in $Modes) {
        $hsMap = [ordered]@{}
        foreach ($r in @(Get-Api "/v1/analytics/hero-stats?game_mode=$mode&min_unix_timestamp=$sinceUnix")) {
            $hsMap[[string]$r.hero_id] = [ordered]@{ wins = [long]$r.wins; matches = [long]$r.matches }
        }
        $heroStats[$mode] = $hsMap

        $isMap = [ordered]@{}
        foreach ($h in $playable) {
            Start-Sleep -Milliseconds 350
            $rows = @(Get-Api "/v1/analytics/item-stats?game_mode=$mode&hero_ids=$($h.id)&min_unix_timestamp=$sinceUnix")
            $slim = @()
            foreach ($r in $rows) {
                $slim += [ordered]@{ id = [string]$r.item_id; w = [long]$r.wins; m = [long]$r.matches; t = [Math]::Round([double]$r.avg_buy_time_s, 0) }
            }
            $isMap[$h.id] = $slim
        }
        $itemStats[$mode] = $isMap
        Write-Log ('  {0}: stats for {1} heroes' -f $mode, $isMap.Count)
    }

    # Enhanced vs regular copies of each item (Street Brawl), from the public data lake.
    # In match data, upgrade_info = 3<<16 marks an Enhanced copy (normal mode only ever has 1<<16).
    $enhanced = $null; $enhancedHero = $null; $enhSince = ''
    $idList = (@($items | ForEach-Object { $_.id }) -join ',')
    $tries = @([DateTime]::UtcNow.AddDays(-7), [DateTime]::UtcNow.AddDays(-3), [DateTime]::UtcNow.AddDays(-1))
    foreach ($t in $tries) {
        $ts = $t.ToString('yyyy-MM-dd HH:mm:ss')
        $q = "SELECT hero_id h, i, u, count(*) n, sum(CASE WHEN team = winning_team THEN 1 ELSE 0 END) w FROM (SELECT hero_id, team, winning_team, unnest(""items.item_id"") i, unnest(""items.upgrade_info"") u FROM match_player WHERE game_mode='StreetBrawl' AND start_time > TIMESTAMP '$ts+00') WHERE i IN ($idList) GROUP BY 1,2,3"
        try {
            $rowsE = @(Invoke-RestMethod -Uri ($Api + '/v1/sql?query=' + [uri]::EscapeDataString($q)) -TimeoutSec 120 -UserAgent 'DeadlockItemOverlay/0.1 (personal use)')
            if ($rowsE.Count -gt 0 -and $null -ne $rowsE[0].i) {
                $enhanced = [ordered]@{}
                $enhancedHero = [ordered]@{}
                foreach ($r in $rowsE) {
                    $id = [string]$r.i
                    $hk = [string]$r.h
                    if (-not $enhanced.Contains($id)) { $enhanced[$id] = [ordered]@{ rn = 0; rw = 0; en = 0; ew = 0 } }
                    if (-not $enhancedHero.Contains($hk)) { $enhancedHero[$hk] = [ordered]@{} }
                    if (-not $enhancedHero[$hk].Contains($id)) { $enhancedHero[$hk][$id] = [ordered]@{ rn = 0; rw = 0; en = 0; ew = 0 } }
                    $hrow = $enhancedHero[$hk][$id]
                    if ([long]$r.u -eq 65536) { $enhanced[$id].rn += [long]$r.n; $enhanced[$id].rw += [long]$r.w; $hrow.rn += [long]$r.n; $hrow.rw += [long]$r.w }
                    else { $enhanced[$id].en += [long]$r.n; $enhanced[$id].ew += [long]$r.w; $hrow.en += [long]$r.n; $hrow.ew += [long]$r.w }
                }
                $enhSince = $t.ToString('yyyy-MM-dd')
                break
            }
        } catch { Write-Log ('  enhanced query failed for window from {0}: {1}' -f $t.ToString('yyyy-MM-dd'), $_.Exception.Message) }
        Start-Sleep -Seconds 35   # the query endpoint allows 2 requests per minute
    }
    if ($null -eq $enhanced) {
        $prevLatest = Join-Path $DataDir 'latest.json'
        if (Test-Path $prevLatest) {
            try {
                $pl = Get-Content $prevLatest -Raw -Encoding UTF8 | ConvertFrom-Json
                if ($pl.enhanced) { $enhanced = $pl.enhanced; $enhancedHero = $pl.enhanced_hero; $enhSince = [string]$pl.enhanced_since; Write-Log '  kept enhanced stats from the previous refresh' }
            } catch { }
        }
    } else { Write-Log ('  enhanced stats: {0} items (since {1})' -f $enhanced.Count, $enhSince) }

    $snap = [ordered]@{
        date = $Today; collected_at = (Get-Date).ToString('s'); build = $build; since = $since.ToString('yyyy-MM-dd'); last_patch = $patchNote
        source = $Api; enhanced = $enhanced; enhanced_hero = $enhancedHero; enhanced_since = $enhSince; items = $items; heroes = $heroes; hero_stats = $heroStats; item_stats = $itemStats
    }
    $json = $snap | ConvertTo-Json -Depth 10 -Compress
    $snapPath = Join-Path $DayDir 'snapshot.json'
    [IO.File]::WriteAllText($snapPath, $json, (New-Object Text.UTF8Encoding $false))
    Copy-Item $snapPath (Join-Path $DataDir 'latest.json') -Force
    Write-Log "  saved $snapPath"

    # ---- Compare with the previous snapshot ----
    $changes = New-Object System.Collections.Generic.List[string]
    $changes.Add("Changes for $Today (data since $($since.ToString('yyyy-MM-dd')))")
    $knownIds = @{}
    foreach ($i in $items) { $knownIds[$i.id] = $i.name }
    $unknown = @{}
    foreach ($mode in $Modes) {
        foreach ($hid in $itemStats[$mode].Keys) {
            foreach ($r in $itemStats[$mode][$hid]) { if (-not $knownIds.ContainsKey($r.id)) { $unknown[$r.id] = 1 } }
        }
    }
    if ($unknown.Count -gt 0) { $changes.Add('UNKNOWN item IDs in stats (no name, likely a patch): ' + (($unknown.Keys | Sort-Object) -join ', ')) }

    $prevDir = Get-ChildItem -Path $DataDir -Directory | Where-Object { $_.Name -match '^\d{4}-\d{2}-\d{2}$' -and $_.Name -lt $Today -and (Test-Path (Join-Path $_.FullName 'snapshot.json')) } | Sort-Object Name -Descending | Select-Object -First 1
    if ($prevDir) {
        $prev = Get-Content (Join-Path $prevDir.FullName 'snapshot.json') -Raw -Encoding UTF8 | ConvertFrom-Json
        $changes.Add("Compared with $($prevDir.Name)")
        $prevItems = @{}
        foreach ($i in $prev.items) { $prevItems[[string]$i.id] = $i }
        foreach ($i in $items) {
            if (-not $prevItems.ContainsKey($i.id)) { $changes.Add("NEW item: $($i.name)") }
            else {
                $p = $prevItems[$i.id]
                if ($p.name -ne $i.name) { $changes.Add("RENAMED: $($p.name) -> $($i.name)") }
                if ($p.cost -ne $i.cost) { $changes.Add("COST: $($i.name) $($p.cost) -> $($i.cost)") }
                if ([bool]$p.shopable -ne [bool]$i.shopable -or [bool]$p.disabled -ne [bool]$i.disabled) { $changes.Add("SHOP STATUS changed: $($i.name)") }
            }
        }
        foreach ($k in $prevItems.Keys) { if (-not $knownIds.ContainsKey($k)) { $changes.Add("REMOVED item: $($prevItems[$k].name)") } }
        $prevHeroes = @{}
        foreach ($h in $prev.heroes) { $prevHeroes[[string]$h.id] = $h }
        foreach ($h in $playable) { if (-not $prevHeroes.ContainsKey($h.id) -or -not $prevHeroes[$h.id].selectable) { $changes.Add("NEW playable hero: $($h.name)") } }
        if ([string]$prev.last_patch -ne $patchNote) { $changes.Add("NEW big patch detected: $patchNote (stats window reset)") }
        if ($prev.build -and [string]$prev.build -ne $build) { $changes.Add("NEW game build: $($prev.build) -> $build") }
    } else {
        $changes.Add('No earlier snapshot to compare with (first run).')
    }
    if ($prevDir -and $changes.Count -le 2) { $changes.Add('No item, hero or patch changes.') }
    $changes | Set-Content -Path (Join-Path $DayDir 'changes.txt') -Encoding UTF8
    $changes | Set-Content -Path (Join-Path $DataDir 'latest_changes.txt') -Encoding UTF8
    foreach ($c in $changes) { Write-Log "  $c" }

    # Keep 30 days of snapshots.
    $cutoff = (Get-Date).AddDays(-30).ToString('yyyy-MM-dd')
    Get-ChildItem -Path $DataDir -Directory | Where-Object { $_.Name -match '^\d{4}-\d{2}-\d{2}$' -and $_.Name -lt $cutoff } | Remove-Item -Recurse -Force

    Write-Log 'Refresh finished OK'
    exit 0
} catch {
    Write-Log ('Refresh FAILED: ' + $_.Exception.Message)
    exit 1
}
