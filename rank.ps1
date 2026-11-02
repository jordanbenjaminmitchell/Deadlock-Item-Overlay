# Command-line check: rank the items offered in one Street Brawl set.
# Usage:  rank.bat Ivy "Tesla Bullets" "Toxic Bullets" "Burst Fire"
#         rank.bat Ivy tesla toxic burst          (short or misspelled names are matched)
#         rank.bat -Top Ivy                        (best 2 items per tier for the hero)

param(
    [switch]$Top,
    [Parameter(Position = 0)][string]$Hero,
    [Parameter(Position = 1, ValueFromRemainingArguments = $true)][string[]]$Items
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'lib.ps1')

try {
    $snap = Get-Snapshot
    $heroes = Get-PlayableHeroes $snap
    $shop = Get-ShopItems $snap

    if (-not $Hero) { throw 'Give a hero name, e.g. rank.bat Ivy "Tesla Bullets" "Toxic Bullets" "Burst Fire"' }
    $h = Find-ByName $Hero $heroes
    if ($null -eq $h) { throw ("Hero not found: '{0}'. Did you mean: {1}?" -f $Hero, ((Get-Suggestions $Hero $heroes) -join ', ')) }

    $picked = @()
    if ($Top) {
        $picked = $shop
    } else {
        if (-not $Items -or $Items.Count -lt 1) { throw 'List the offered items after the hero name.' }
        foreach ($q in $Items) {
            $m = Find-ByName $q $shop
            if ($null -eq $m) { throw ("Item not found: '{0}'. Did you mean: {1}?" -f $q, ((Get-Suggestions $q $shop) -join ', ')) }
            $picked += $m
        }
    }

    $res = Get-ItemRanking $snap $h $picked
    $list = $res.ranked
    if ($Top) { $list = @(Select-BestByTier $list 2) }

    Write-Host ''
    Write-Host ('{0} - Street Brawl - data from {1} (since last big patch {2})' -f $res.hero, $res.date, $snap.last_patch) -ForegroundColor Cyan
    Write-Host ('{0} average win rate: {1:0.0}% over {2:N0} matches' -f $res.hero, $res.baseline, $res.heroMatches)
    Write-Host ''
    $n = 1
    foreach ($x in $list) {
        $color = 'Gray'
        if ($n -eq 1) { $color = 'Green' }
        if ($null -eq $x.delta) {
            Write-Host ('#{0} {1} (T{2} {3}) - no data' -f $n, $x.name, $x.tier, $x.slot) -ForegroundColor $color
        } else {
            $line = '#{0} {1} (T{2} {3})  expected win {4:0.0}% ({5:+0.0;-0.0;0.0} vs avg)  buy rate {6:0}%  n={7:N0}' -f $n, $x.name, $x.tier, $x.slot, $x.expected, $x.score, $x.buyrate, $x.matches
            if ($x.good) { $line += '  [Good tag]' }
            Write-Host $line -ForegroundColor $color
        }
        Write-Host ('    ' + $x.reason)
        $n++
    }
    Write-Host ''
    exit 0
} catch {
    Write-Host $_.Exception.Message -ForegroundColor Red
    exit 1
}
