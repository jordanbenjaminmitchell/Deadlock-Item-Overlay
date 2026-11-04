# Shared functions for the Deadlock Street Brawl item ranker.
# Windows PowerShell 5.1 compatible (no downloads needed).

$script:PriorMatches = 1000      # shrinkage strength: small samples are pulled toward the hero average
$script:EnhPrior     = 2000      # enhanced lift: pulled toward the tier's typical lift (as if 2,000 typical games)
$script:EnhHeroPrior = 1000      # per-hero enhanced lift: pulled toward the all-heroes lift (as if 1,000 games)
$script:ThinSample   = 1000      # flag items with fewer matches than this
$script:CloseCall    = 1.0       # top two within this many points = close call

function Get-Root { return $PSScriptRoot }

function Read-JsonFile([string]$Path) {
    if (-not (Test-Path $Path)) { return $null }
    $raw = Get-Content -Path $Path -Raw -Encoding UTF8
    return ($raw | ConvertFrom-Json)
}

function Get-Snapshot {
    $p = Join-Path (Get-Root) 'data\latest.json'
    $snap = Read-JsonFile $p
    if ($null -eq $snap) { throw "No data yet. Run collect.bat first." }
    return $snap
}

function Get-Notes {
    $p = Join-Path (Get-Root) 'notes.json'
    return (Read-JsonFile $p)
}

function ConvertTo-Key([string]$s) {
    if ($null -eq $s) { return '' }
    return (($s.ToLowerInvariant()) -replace '[^a-z0-9]', '')
}

function Get-EditDistance([string]$a, [string]$b) {
    $n = $a.Length; $m = $b.Length
    if ($n -eq 0) { return $m }
    if ($m -eq 0) { return $n }
    $prev = New-Object 'int[]' ($m + 1)
    $cur  = New-Object 'int[]' ($m + 1)
    for ($j = 0; $j -le $m; $j++) { $prev[$j] = $j }
    for ($i = 1; $i -le $n; $i++) {
        $cur[0] = $i
        for ($j = 1; $j -le $m; $j++) {
            $cost = 1
            if ($a[$i - 1] -ceq $b[$j - 1]) { $cost = 0 }
            $best = $prev[$j] + 1
            if ($cur[$j - 1] + 1 -lt $best) { $best = $cur[$j - 1] + 1 }
            if ($prev[$j - 1] + $cost -lt $best) { $best = $prev[$j - 1] + $cost }
            $cur[$j] = $best
        }
        $tmp = $prev; $prev = $cur; $cur = $tmp
    }
    return $prev[$m]
}

# Fuzzy name lookup. $Candidates = objects with a .name property.
# Returns the matched object, or $null. Used for typed names now and OCR text later.
function Find-ByName([string]$Query, $Candidates) {
    $q = ConvertTo-Key $Query
    if ($q -eq '') { return $null }
    foreach ($c in $Candidates) { if ((ConvertTo-Key $c.name) -eq $q) { return $c } }
    $starts = @($Candidates | Where-Object { (ConvertTo-Key $_.name).StartsWith($q) })
    if ($starts.Count -eq 1) { return $starts[0] }
    $contains = @($Candidates | Where-Object { (ConvertTo-Key $_.name).Contains($q) })
    if ($contains.Count -eq 1) { return $contains[0] }
    $best = $null; $bestD = 999
    foreach ($c in $Candidates) {
        $d = Get-EditDistance $q (ConvertTo-Key $c.name)
        if ($d -lt $bestD) { $bestD = $d; $best = $c }
    }
    $limit = [Math]::Max(2, [Math]::Floor($q.Length / 4))
    if ($bestD -le $limit) { return $best }
    return $null
}

function Get-Suggestions([string]$Query, $Candidates, [int]$Count = 3) {
    $q = ConvertTo-Key $Query
    $scored = foreach ($c in $Candidates) {
        [pscustomobject]@{ name = $c.name; d = (Get-EditDistance $q (ConvertTo-Key $c.name)) }
    }
    return @($scored | Sort-Object d | Select-Object -First $Count | ForEach-Object { $_.name })
}

function Format-Time([double]$Seconds) {
    if ($Seconds -le 0) { return '?' }
    $t = [TimeSpan]::FromSeconds([Math]::Round($Seconds))
    return ('{0}:{1:00}' -f [int][Math]::Floor($t.TotalMinutes), $t.Seconds)
}

function Get-ShopItems($Snap) {
    return @($Snap.items | Where-Object { $_.shopable -and -not $_.disabled })
}

function Get-PlayableHeroes($Snap) {
    return @($Snap.heroes | Where-Object { $_.selectable })
}

function Find-StatRow($Rows, $ItemId) {
    foreach ($r in $Rows) { if ([string]$r.id -eq [string]$ItemId) { return $r } }
    return $null
}

# Core ranking. Returns ranked objects (best first) with numbers and a one-line reason.
# Typical (median) Enhanced lift per item tier, from items with enough games. Cached per snapshot.
$script:EnhCache = @{ date = ''; byTier = @{}; all = 0.0 }
function Get-Median($Values) {
    $sorted = @($Values | Sort-Object)
    if ($sorted.Count -eq 0) { return 0.0 }
    return [double]$sorted[[int][Math]::Floor($sorted.Count / 2)]
}
function Get-EnhancedPrior($Snap, $Tier) {
    if ($script:EnhCache.date -ne [string]$Snap.collected_at) {
        $tierOf = @{}
        foreach ($i in $Snap.items) { $tierOf[[string]$i.id] = [int]$i.tier }
        $byTier = @{}; $all = @()
        if ($Snap.enhanced) {
            foreach ($p in $Snap.enhanced.PSObject.Properties) {
                $e = $p.Value
                if ($e.rn -lt 500 -or $e.en -lt 500) { continue }
                $l = 100.0 * ($e.ew / $e.en - $e.rw / $e.rn)
                $all += $l
                $t = $tierOf[[string]$p.Name]
                if (-not $byTier.ContainsKey($t)) { $byTier[$t] = @() }
                $byTier[$t] += $l
            }
        }
        $med = @{}
        foreach ($t in $byTier.Keys) { if ($byTier[$t].Count -ge 3) { $med[$t] = Get-Median $byTier[$t] } }
        $script:EnhCache = @{ date = [string]$Snap.collected_at; byTier = $med; all = (Get-Median $all) }
    }
    $prior = $script:EnhCache.all
    if ($script:EnhCache.byTier.ContainsKey([int]$Tier)) { $prior = $script:EnhCache.byTier[[int]$Tier] }
    return [Math]::Max(0.0, $prior)
}

# How much more an Enhanced copy of this item wins than a regular copy (points).
# Pulled toward the tier's typical boost, and never below 0: an Enhanced copy has strictly better
# numbers, so a negative reading reflects who picks it, not the item.
# Per hero when there is hero data: the hero's own Enhanced vs regular gap, pulled toward the item's
# all-heroes boost (which is itself pulled toward the tier's typical boost). Never below 0.
function Get-EnhancedLift($Snap, $Item, $HeroId) {
    $prior = Get-EnhancedPrior $Snap $Item.tier
    $e = $null
    if ($Snap.enhanced) { $e = $Snap.enhanced.([string]$Item.id) }
    $itemLift = $prior; $raw = $null; $n = 0
    if ($e -and $e.en -gt 0 -and $e.rn -gt 0) {
        $raw = 100.0 * ($e.ew / $e.en - $e.rw / $e.rn)
        $itemLift = ($e.en * $raw + $script:EnhPrior * $prior) / ($e.en + $script:EnhPrior)
        $n = [int]$e.en
    }
    $lift = $itemLift; $heroRaw = $null; $heroN = 0
    $he = $null
    if ($Snap.enhanced_hero -and $HeroId) {
        $hh = $Snap.enhanced_hero.([string]$HeroId)
        if ($hh) { $he = $hh.([string]$Item.id) }
    }
    if ($he -and $he.en -gt 0 -and $he.rn -gt 0) {
        $heroRaw = 100.0 * ($he.ew / $he.en - $he.rw / $he.rn)
        $heroN = [int]$he.en
        $lift = ($heroN * $heroRaw + $script:EnhHeroPrior * $itemLift) / ($heroN + $script:EnhHeroPrior)
    }
    return [pscustomobject]@{ lift = [Math]::Max(0.0, $lift); raw = $raw; n = $n; prior = $prior; heroRaw = $heroRaw; heroN = $heroN }
}

# Counter tags for one item: enemy heroes on the screen that this item does extra well against
# (from the daily refresh; tier 1-4 only, significant after correction). Best first.
function Get-CounterTags($Snap, [string]$ItemId, $EnemyIds) {
    $out = @()
    if (-not $Snap.counters -or -not $ItemId) { return $out }
    foreach ($e in @($EnemyIds)) {
        if (-not $e) { continue }
        $c = $Snap.counters.([string]$e)
        if (-not $c) { continue }
        $v = $c.$ItemId
        if ($v) { $out += [pscustomobject]@{ hero = [string]$e; pp = [double]$v.pp } }
    }
    return @($out | Sort-Object pp -Descending)
}

function Get-ItemRanking($Snap, $Hero, $Items, $Enhanced = @(), [bool]$UseEnhancedBoost = $true) {
    $hid = [string]$Hero.id
    $hs = $Snap.hero_stats.street_brawl.$hid
    if ($null -eq $hs -or $hs.matches -eq 0) { throw "No Street Brawl data for $($Hero.name)." }
    $base = $hs.wins / $hs.matches
    $rows = @($Snap.item_stats.street_brawl.$hid)
    # Each tier's average win rate for this hero: late tiers sit well above or below the hero's
    # overall average, so items are compared with others of the same tier.
    $tierOf = @{}
    foreach ($i in $Snap.items) { $tierOf[[string]$i.id] = [int]$i.tier }
    $tw = @{}; $tm = @{}
    foreach ($r in $rows) {
        $t = $tierOf[[string]$r.id]
        if ($null -eq $t) { continue }
        $tw[$t] = [double]$tw[$t] + $r.w; $tm[$t] = [double]$tm[$t] + $r.m
    }
    $notes = Get-Notes
    $heroNotes = $null
    if ($notes -and $notes.heroes) { $heroNotes = $notes.heroes.($Hero.name) }

    $out = foreach ($it in $Items) {
        $r = Find-StatRow $rows $it.id
        $o = [ordered]@{
            id = [string]$it.id; name = $it.name; tier = $it.tier; slot = $it.slot; tierAvg = $null
            matches = 0; winrate = $null; delta = $null; score = -999; buyrate = $null; expected = $null; enhLift = $null
            good = $false; note = $null; reason = ''; verdict = ''; thin = $true
            enhanced = (@($Enhanced) -contains $it.name)
        }
        $bucket = $null
        if ($Hero.buckets) { $bucket = $Hero.buckets.($it.class_name) }
        if ($bucket -and $bucket.b -eq 'Good') { $o.good = $true }
        if ($heroNotes) { $o.note = $heroNotes.($it.name) }

        $tb = $base
        $tk = [int]$it.tier
        if ($tm[$tk] -gt 0) { $tb = $tw[$tk] / $tm[$tk] }
        $o.tierAvg = 100.0 * $tb
        if ($r -and $r.m -gt 0) {
            $adj = ($r.w + $script:PriorMatches * $tb) / ($r.m + $script:PriorMatches)
            $o.matches = [int]$r.m
            $o.winrate = 100.0 * $r.w / $r.m
            $o.delta = 100.0 * ($adj - $tb)
            $o.score = $o.delta
            if ($o.enhanced) {
                $el = Get-EnhancedLift $Snap $it $Hero.id
                $o.enhLift = $el
                if ($UseEnhancedBoost) { $o.score += $el.lift }
            }
            $o.expected = 100.0 * $tb + $o.score
            $o.buyrate = 100.0 * $r.m / $hs.matches
            $o.thin = ($r.m -lt $script:ThinSample)
        }
        [pscustomobject]$o
    }
    $ranked = @($out | Sort-Object -Property @{ Expression = 'score'; Descending = $true })

    for ($i = 0; $i -lt $ranked.Count; $i++) {
        $x = $ranked[$i]
        $parts = @()
        if ($null -eq $x.delta) {
            $parts += "No Street Brawl data for $($Hero.name) with this item."
        } else {
            $d = $x.score
            if ($d -ge 2) { $parts += ('Strong for {0}: {1:+0.0;-0.0;0.0} pts vs its tier average.' -f $Hero.name, $d) }
            elseif ($d -ge 0.5) { $parts += ('Above {0}''s tier average ({1:+0.0;-0.0;0.0} pts).' -f $Hero.name, $d) }
            elseif ($d -gt -0.5) { $parts += ('About tier average for {0} ({1:+0.0;-0.0;0.0} pts).' -f $Hero.name, $d) }
            elseif ($d -gt -2) { $parts += ('Below {0}''s tier average ({1:+0.0;-0.0;0.0} pts).' -f $Hero.name, $d) }
            else { $parts += ('Weak for {0}: {1:+0.0;-0.0;0.0} pts vs its tier average.' -f $Hero.name, $d) }
        }
        $x.verdict = $parts[$parts.Count - 1]
        if ($x.enhanced -and $x.enhLift -and $UseEnhancedBoost) {
            if ($null -ne $x.enhLift.raw) {
                $parts += ('Enhanced copies won {0:+0.0;-0.0;0.0} pts vs regular ({1:N0} games, all heroes); counted as {2:+0.0;-0.0;0.0} (tier typical {3:+0.0;-0.0;0.0}, never below 0).' -f $x.enhLift.raw, $x.enhLift.n, $x.enhLift.lift, $x.enhLift.prior)
            } else {
                $parts += ('No Enhanced data for this item; counted as the tier typical {0:+0.0;-0.0;0.0}.' -f $x.enhLift.lift)
            }
            $x.verdict += ' ' + $parts[$parts.Count - 1]
        }
        if ($x.good) { $parts += "Game tags it Good for $($Hero.name)." }
        if ($x.matches -gt 0 -and $x.thin) { $parts += ('Thin sample ({0} matches), treat as a guess.' -f $x.matches) }
        if ($x.note) { $parts += $x.note }
        $x.reason = ($parts -join ' ')
    }
    $result = [pscustomobject]@{
        hero = $Hero.name; date = $Snap.date
        baseline = 100.0 * $base; heroMatches = [int]$hs.matches
        closeCall = $false; ranked = $ranked
    }
    if ($ranked.Count -ge 2 -and $null -ne $ranked[0].delta -and $null -ne $ranked[1].delta) {
        if (($ranked[0].score - $ranked[1].score) -lt $script:CloseCall) { $result.closeCall = $true }
    }
    return $result
}

# Best N items per tier (only well-sampled items), tier 1 first. Comparing within a tier avoids
# late, expensive items looking great just because teams that buy them are already ahead.
function Select-BestByTier($Ranked, [int]$PerTier = 2) {
    $ok = @($Ranked | Where-Object { $_.matches -ge $script:ThinSample })
    $tiers = @($ok | ForEach-Object { [int]$_.tier } | Sort-Object -Unique)
    foreach ($t in $tiers) {
        $ok | Where-Object { [int]$_.tier -eq $t } | Sort-Object -Property @{ Expression = 'score'; Descending = $true } | Select-Object -First $PerTier
    }
}

# Street Brawl standing of every hero (win rate, play share), best first. Heroes under 1,000 games are left out.
function Get-HeroTable($Snap) {
    $rows = @()
    $tot = 0
    foreach ($p in $Snap.hero_stats.street_brawl.PSObject.Properties) { $tot += [double]$p.Value.matches }
    $games = $tot / 8.0
    foreach ($h in (Get-PlayableHeroes $Snap)) {
        $hs = $Snap.hero_stats.street_brawl.([string]$h.id)
        if (-not $hs -or $hs.matches -lt 1000) { continue }
        $pick = 0.0
        if ($games -gt 0) { $pick = 100.0 * $hs.matches / $games }
        $rows += [pscustomobject]@{ id = [string]$h.id; name = $h.name; winrate = 100.0 * $hs.wins / $hs.matches; matches = [long]$hs.matches; pickrate = $pick }
    }
    $rows = @($rows | Sort-Object winrate -Descending)
    for ($i = 0; $i -lt $rows.Count; $i++) { $rows[$i] | Add-Member -NotePropertyName rank -NotePropertyValue ($i + 1) -Force }
    return $rows
}
function Get-HeroTier([double]$WinRate) {
    if ($WinRate -ge 55) { return 'S' } elseif ($WinRate -ge 51) { return 'A' } elseif ($WinRate -ge 47) { return 'B' } elseif ($WinRate -ge 44) { return 'C' } else { return 'D' }
}
