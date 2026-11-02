# Pick summary: how often you take the overlay's top pick, and how your Street Brawl matches went.
# Offers and rankings come from data\pick_history.csv (written by the overlay).
# What you actually bought and whether you won come from your public match history on
# api.deadlock-api.com (new matches can take a while to appear there).
# Writes data\summary.html and opens it. Windows PowerShell 5.1, no downloads.

param([string]$AccountId = '')

$ErrorActionPreference = 'Stop'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
$ProgressPreference = 'SilentlyContinue'
. (Join-Path $PSScriptRoot 'lib.ps1')

$Api = 'https://api.deadlock-api.com'
$DataDir = Join-Path $PSScriptRoot 'data'
$HistoryPath = Join-Path $DataDir 'pick_history.csv'
$MatchDir = Join-Path $DataDir 'matches'
$OutPath = Join-Path $DataDir 'summary.html'
New-Item -ItemType Directory -Force -Path $MatchDir | Out-Null

function Get-Json([string]$Url) { return Invoke-RestMethod -Uri $Url -TimeoutSec 60 -UserAgent 'DeadlockItemOverlay/0.1 (personal use)' }
function Enc([string]$s) { return [System.Net.WebUtility]::HtmlEncode($s) }

# Your Steam account (Deadlock account id) from the most recently used Steam profile folder.
if (-not $AccountId) {
    $steam = $null
    try { $steam = (Get-ItemProperty 'HKCU:\Software\Valve\Steam' -ErrorAction Stop).SteamPath } catch { }
    if (-not $steam) { $steam = 'C:\Program Files (x86)\Steam' }
    $ud = Join-Path ($steam -replace '/', '\') 'userdata'
    if (Test-Path $ud) {
        $d = Get-ChildItem $ud -Directory | Where-Object { $_.Name -match '^\d+$' -and $_.Name -ne '0' } | Sort-Object LastWriteTime -Descending | Select-Object -First 1
        if ($d) { $AccountId = $d.Name }
    }
}
if (-not $AccountId) { throw 'Could not find your Steam account. Run: summary.bat -AccountId <your id>' }

$snap = Get-Snapshot
$byId = @{}; $byName = @{}
foreach ($i in $snap.items) { $byId[[string]$i.id] = $i; $byName[$i.name] = $i }
$heroName = @{}
foreach ($h in $snap.heroes) { $heroName[[string]$h.id] = $h.name }

# ---- Offers from the overlay log: one final offer per match, round and choice ----
if (-not (Test-Path $HistoryPath)) { throw 'No pick history yet. Play a Street Brawl match with the overlay open.' }
$rows = @(Import-Csv $HistoryPath)
$offers = @{}
foreach ($r in $rows) {
    if (-not $r.choice -or -not $r.offered_ranked) { continue }
    $parts = @($r.offered_ranked -split '\s\|\s')
    $items = @()
    foreach ($p in $parts) {
        if ($p -match '^\s*(\d+)\.\s+(.+?)\s+([\d.]+)%\s*$') { $items += [pscustomobject]@{ rank = [int]$Matches[1]; name = $Matches[2]; pct = [double]$Matches[3] } }
    }
    if ($items.Count -lt 2) { continue }
    $key = '{0}|{1}|{2}' -f $r.match_start, $r.round, $r.choice
    $o = [pscustomobject]@{ match = $r.match_start; time = [datetime]$r.date; round = $r.round; choice = $r.choice; hero = $r.hero; items = $items; status = $r.status; enhanced = $r.enhanced; seen = $r.picked }
    # Keep the last non-rerolled offer for each choice (and any pick the overlay saw for it).
    if ($offers.ContainsKey($key) -and -not $o.seen -and $offers[$key].seen) { $o.seen = $offers[$key].seen }
    if (-not $offers.ContainsKey($key) -or $r.status -ne 'rerolled' -or $offers[$key].status -eq 'rerolled') { $offers[$key] = $o }
}
$offerList = @($offers.Values | Sort-Object time)

# ---- Your Street Brawl matches from the public match history ----
$hist = @()
try { $hist = @(Get-Json "$Api/v1/players/$AccountId/match-history") } catch { }
$sb = @($hist | Where-Object { [int]$_.game_mode -eq 4 })
$epoch = [datetime]'1970-01-01Z'

function Get-MatchFor([datetime]$LocalTime) {
    $u = $LocalTime.ToUniversalTime()
    $best = $null; $bestD = 1e9
    foreach ($m in $sb) {
        $st = $epoch.AddSeconds([double]$m.start_time).ToUniversalTime()
        $d = ($u - $st).TotalMinutes
        if ($d -ge -10 -and $d -le 40 -and [Math]::Abs($d) -lt $bestD) { $bestD = [Math]::Abs($d); $best = $m }
    }
    return $best
}

function Get-Bought($Match) {
    $path = Join-Path $MatchDir ('{0}.json' -f $Match.match_id)
    $meta = $null
    if (Test-Path $path) { $meta = Get-Content $path -Raw -Encoding UTF8 | ConvertFrom-Json }
    else {
        try {
            $meta = Get-Json ("$Api/v1/matches/{0}/metadata" -f $Match.match_id)
            ($meta | ConvertTo-Json -Depth 12 -Compress) | Set-Content -Path $path -Encoding UTF8
        } catch { return $null }
    }
    $p = @($meta.match_info.players | Where-Object { [string]$_.account_id -eq [string]$AccountId }) | Select-Object -First 1
    if (-not $p) { return $null }
    $names = @{}
    foreach ($it in $p.items) { $x = $byId[[string]$it.item_id]; if ($x) { $names[$x.name] = 1 } }
    return [pscustomobject]@{ names = $names; won = ([string]$p.team -eq [string]$meta.match_info.winning_team) }
}

# ---- Combine ----
$matchKeys = @($offerList | ForEach-Object { $_.match } | Select-Object -Unique)
$matchRows = @()
$known = 0; $top = 0; $rankSum = 0
foreach ($mk in $matchKeys) {
    $mo = @($offerList | Where-Object { $_.match -eq $mk })
    $first = ($mo | Sort-Object time | Select-Object -First 1).time
    $m = Get-MatchFor $first
    $bought = $null
    if ($m) { $bought = Get-Bought $m }
    $mKnown = 0; $mTop = 0
    foreach ($o in $mo) {
        $o | Add-Member -NotePropertyName picked -NotePropertyValue '' -Force
        $hit = @()
        if ($bought) { $hit = @($o.items | Where-Object { $bought.names.ContainsKey($_.name) }) }
        elseif ($o.seen) { $hit = @($o.items | Where-Object { $_.name -eq $o.seen }) }
        if ($true) {
            if ($hit.Count -eq 1) {
                $o.picked = $hit[0].name
                $mKnown++; $known++; $rankSum += $hit[0].rank
                if ($hit[0].rank -eq 1) { $mTop++; $top++ }
            }
        }
    }
    $hero = (@($mo | Where-Object { $_.hero } | Group-Object hero | Sort-Object Count -Descending | Select-Object -First 1)).Name
    if ($m -and $heroName.ContainsKey([string]$m.hero_id)) { $hero = $heroName[[string]$m.hero_id] }
    $result = 'pending'
    if ($bought) { if ($bought.won) { $result = 'win' } else { $result = 'loss' } }
    $matchRows += [pscustomobject]@{ start = $mk; hero = $hero; result = $result; offers = $mo.Count; known = $mKnown; top = $mTop; list = $mo }
}

$done = @($matchRows | Where-Object { $_.result -ne 'pending' -and $_.known -gt 0 })
function Get-WinRate($set) {
    $s = @($set)
    if ($s.Count -eq 0) { return '-' }
    return ('{0:0}% ({1}-{2})' -f (100.0 * @($s | Where-Object { $_.result -eq 'win' }).Count / $s.Count), @($s | Where-Object { $_.result -eq 'win' }).Count, @($s | Where-Object { $_.result -eq 'loss' }).Count)
}
$followed = @($done | Where-Object { $_.top / $_.known -ge 0.5 })
$notFollowed = @($done | Where-Object { $_.top / $_.known -lt 0.5 })
$topRate = '-'; $avgRank = '-'
if ($known -gt 0) { $topRate = '{0:0}%' -f (100.0 * $top / $known); $avgRank = '{0:0.0}' -f ($rankSum / $known) }
$pending = @($matchRows | Where-Object { $_.result -eq 'pending' }).Count

# ---- HTML ----
$css = @'
.note{color:#A88B62;font-size:12px;text-align:center;margin-top:-16px;margin-bottom:22px}
body{background:#1B130E;color:#E7D6B4;font-family:"Segoe UI",sans-serif;margin:0;padding:32px}
.wrap{max-width:880px;margin:0 auto;border:1px solid #6E5330;padding:28px 32px;position:relative}
h1{font-family:Bahnschrift,"Segoe UI",sans-serif;font-weight:400;color:#F3E6CB;text-align:center;margin:0 0 4px;font-size:30px}
.sub{text-align:center;color:#A88B62;font-size:13px;margin-bottom:24px}
.stats{display:flex;gap:16px;justify-content:center;margin-bottom:28px;flex-wrap:wrap}
.stat{border:1px solid #6E5330;padding:12px 18px;text-align:center;min-width:120px}
.stat b{display:block;font-family:Bahnschrift,"Segoe UI",sans-serif;font-weight:400;font-size:28px;color:#F3E6CB}
.stat span{font-size:12px;color:#A88B62}
h2{font-family:Bahnschrift,"Segoe UI",sans-serif;font-weight:400;color:#C9A063;font-size:18px;border-bottom:1px solid #6E5330;padding-bottom:6px;margin-top:28px}
table{width:100%;border-collapse:collapse;font-size:13px}
td,th{padding:6px 8px;border-bottom:1px solid #3A2A1D;text-align:left;vertical-align:top}
th{color:#A88B62;font-weight:400}
.win{color:#A8C478}.loss{color:#D6705C}.pending{color:#A88B62}
.top{color:#C9A063}.dim{color:#A88B62}
.c{position:absolute;width:18px;height:18px;border-color:#C9A063;border-style:solid}
.tl{top:6px;left:6px;border-width:1.5px 0 0 1.5px}.tr{top:6px;right:6px;border-width:1.5px 1.5px 0 0}
.bl{bottom:6px;left:6px;border-width:0 0 1.5px 1.5px}.br{bottom:6px;right:6px;border-width:0 1.5px 1.5px 0}
'@
$sbH = New-Object System.Text.StringBuilder
[void]$sbH.Append("<!DOCTYPE html><html><head><meta charset='utf-8'><title>Street Brawl pick summary</title><style>$css</style></head><body><div class='wrap'><div class='c tl'></div><div class='c tr'></div><div class='c bl'></div><div class='c br'></div>")
[void]$sbH.Append("<h1>Street Brawl picks</h1><div class='sub'>Updated $(Get-Date -Format 'MMM d, h:mm tt')")
if ($pending -gt 0) { [void]$sbH.Append(" &nbsp;|&nbsp; $pending match(es) not on the stats site yet") }
[void]$sbH.Append("</div>")
if ($pending -gt 0) { [void]$sbH.Append("<div class='note'>Picks for those come from the overlay's own reading of the Item purchased panel; results appear once the stats site has the match.</div>") }
[void]$sbH.Append("<div class='stats'>")
foreach ($st in @(@($topRate, "took the top pick ($top of $known)"), @($avgRank, 'average rank of your pick'), @((Get-WinRate $followed), 'win rate when you mostly took the top pick'), @((Get-WinRate $notFollowed), 'win rate otherwise'))) {
    [void]$sbH.Append("<div class='stat'><b>$(Enc $st[0])</b><span>$(Enc $st[1])</span></div>")
}
[void]$sbH.Append("</div>")

# Hero tier list (Street Brawl, since the last big patch)
$ht = @(Get-HeroTable $snap)
$played = @{}
foreach ($mr in $matchRows) { if ($mr.hero) { $played[$mr.hero] = 1 } }
[void]$sbH.Append("<h2>Hero tier list</h2><div class='dim' style='font-size:12px;margin-bottom:8px'>Street Brawl win rate and how often each hero is picked, from $(Enc $snap.since) to $(Enc $snap.date). Tiers: S 55%+, A 51%+, B 47%+, C 44%+, D below. <span class=top>Gold</span> = heroes you played.</div>")
[void]$sbH.Append("<table><tr><th>#</th><th>Tier</th><th>Hero</th><th>Win rate</th><th>Picked in</th><th>Games</th></tr>")
foreach ($r in $ht) {
    $cls = ''
    if ($played.ContainsKey($r.name)) { $cls = " class='top'" }
    [void]$sbH.Append(("<tr{0}><td>{1}</td><td>{2}</td><td>{3}</td><td>{4:0.0}%</td><td>{5:0}% of matches</td><td>{6:N0}</td></tr>" -f $cls, $r.rank, (Get-HeroTier $r.winrate), (Enc $r.name), $r.winrate, $r.pickrate, $r.matches))
}
[void]$sbH.Append("</table>")

[void]$sbH.Append("<h2>By hero</h2><table><tr><th>Hero</th><th>Matches</th><th>Top pick</th><th>Win rate</th></tr>")
foreach ($g in ($matchRows | Group-Object hero | Sort-Object Count -Descending)) {
    $k = ($g.Group | Measure-Object known -Sum).Sum; $t = ($g.Group | Measure-Object top -Sum).Sum
    $tp = '-'; if ($k -gt 0) { $tp = '{0:0}% ({1} of {2})' -f (100.0 * $t / $k), $t, $k }
    [void]$sbH.Append("<tr><td>$(Enc $g.Name)</td><td>$($g.Count)</td><td>$(Enc $tp)</td><td>$(Enc (Get-WinRate @($g.Group | Where-Object { $_.result -ne 'pending' })))</td></tr>")
}
[void]$sbH.Append("</table>")

[void]$sbH.Append("<h2>Matches</h2><table><tr><th>Started</th><th>Hero</th><th>Result</th><th>Offers (your pick, top pick)</th></tr>")
foreach ($mr in ($matchRows | Sort-Object start -Descending)) {
    $lines = foreach ($o in ($mr.list | Sort-Object time)) {
        $topName = ($o.items | Sort-Object rank | Select-Object -First 1).name
        $pick = '<span class=dim>pick unknown</span>'
        if ($o.picked) {
            if ($o.picked -eq $topName) { $pick = "<span class=top>$(Enc $o.picked) (top)</span>" } else { $pick = "$(Enc $o.picked) <span class=dim>(top: $(Enc $topName))</span>" }
        }
        "R$(Enc $o.round) $(Enc $o.choice): $pick"
    }
    [void]$sbH.Append("<tr><td>$(Enc $mr.start)</td><td>$(Enc $mr.hero)</td><td class='$($mr.result)'>$($mr.result)</td><td>$($lines -join '<br>')</td></tr>")
}
[void]$sbH.Append("</table></div></body></html>")
[IO.File]::WriteAllText($OutPath, $sbH.ToString(), (New-Object Text.UTF8Encoding $false))
Write-Host "Summary written to $OutPath"
Start-Process $OutPath
