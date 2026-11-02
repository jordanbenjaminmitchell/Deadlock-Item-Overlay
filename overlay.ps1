# Street Brawl item overlay window.
# Detects your hero and the offered items from the screen, and ranks the items with Street Brawl stats.
# Ctrl+Alt+D toggles click-through. Windows PowerShell 5.1, no downloads.

param([switch]$Preview, [switch]$Demo, [string]$DemoHero = 'Ivy', [string]$DemoItems = 'Burst Fire|Superior Duration|Spirit Resilience', [string]$DemoEnhanced = 'Burst Fire', [string]$DemoRare = '', [string]$DemoStatus = 'Choice 2 of 3   |   1 re-roll left')
# -Preview: visible to screenshots, screen reading off. -Demo: also show a sample offer (hero, items separated by |).
$ErrorActionPreference = 'Stop'
trap { Add-Content -Path (Join-Path $PSScriptRoot 'overlay_error.log') -Value ((Get-Date).ToString('s') + ' ' + $_.Exception.Message) -Encoding UTF8; break }
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
. (Join-Path $PSScriptRoot 'lib.ps1')
$script:screenOk = $false
$script:screenError = ''
try { . (Join-Path $PSScriptRoot 'screen.ps1'); $script:screenOk = $true } catch { $script:screenError = $_.Exception.Message }

if (-not ('OverlayForm' -as [type])) {
Add-Type -ReferencedAssemblies System.Windows.Forms, System.Drawing -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
using System.Windows.Forms;
public class OverlayForm : Form {
    [DllImport("user32.dll")] static extern bool RegisterHotKey(IntPtr hWnd, int id, uint mods, uint vk);
    [DllImport("user32.dll")] static extern bool UnregisterHotKey(IntPtr hWnd, int id);
    [DllImport("user32.dll")] static extern int GetWindowLong(IntPtr hWnd, int idx);
    [DllImport("user32.dll")] static extern int SetWindowLong(IntPtr hWnd, int idx, int val);
    [DllImport("user32.dll")] public static extern bool ReleaseCapture();
    [DllImport("user32.dll")] public static extern IntPtr SendMessage(IntPtr hWnd, int msg, int w, int l);
    [DllImport("user32.dll")] static extern bool SetProcessDPIAware();
    [DllImport("dwmapi.dll")] static extern int DwmSetWindowAttribute(IntPtr hwnd, int attr, ref int val, int size);
    const int GWL_EXSTYLE = -20, WS_EX_LAYERED = 0x80000, WS_EX_TRANSPARENT = 0x20, WM_HOTKEY = 0x312;
    public event EventHandler HotkeyPressed;
    public int LastHotkey;
    protected override bool ShowWithoutActivation { get { return true; } }
    public bool ClickThrough { get; private set; }
    public bool HotkeyOk { get; private set; }
    public static void MakeDpiAware() { try { SetProcessDPIAware(); } catch { } }
    protected override CreateParams CreateParams {
        get { CreateParams cp = base.CreateParams; if (ClickThrough) cp.ExStyle |= WS_EX_LAYERED | WS_EX_TRANSPARENT; return cp; }
    }
    protected override void OnHandleCreated(EventArgs e) {
        base.OnHandleCreated(e);
        HotkeyOk = RegisterHotKey(this.Handle, 1, 0x0001 | 0x0002 | 0x4000, (uint)Keys.D);
        RegisterHotKey(this.Handle, 2, 0x0001 | 0x0002 | 0x4000, (uint)Keys.S);
        RegisterHotKey(this.Handle, 3, 0x0001 | 0x0002 | 0x4000, (uint)Keys.E);
        try { int round = 2; DwmSetWindowAttribute(this.Handle, 33, ref round, 4); } catch { }
    }
    protected override void OnHandleDestroyed(EventArgs e) { UnregisterHotKey(this.Handle, 1); UnregisterHotKey(this.Handle, 2); UnregisterHotKey(this.Handle, 3); base.OnHandleDestroyed(e); }
    protected override void WndProc(ref Message m) {
        if (m.Msg == WM_HOTKEY && HotkeyPressed != null) { LastHotkey = (int)m.WParam; HotkeyPressed(this, EventArgs.Empty); }
        base.WndProc(ref m);
    }
    public void SetClickThrough(bool on) {
        int s = GetWindowLong(this.Handle, GWL_EXSTYLE);
        if (on) s |= WS_EX_LAYERED | WS_EX_TRANSPARENT; else s &= ~WS_EX_TRANSPARENT;
        SetWindowLong(this.Handle, GWL_EXSTYLE, s);
        ClickThrough = on;
    }
    public void StartDrag() { ReleaseCapture(); SendMessage(this.Handle, 0xA1, 0x2, 0); }
}
'@
}

# Sharp text at any Windows display scaling: draw in real pixels and scale the layout ourselves.
[OverlayForm]::MakeDpiAware()
[Windows.Forms.Application]::EnableVisualStyles()
$tmpG = [Drawing.Graphics]::FromHwnd([IntPtr]::Zero)
$script:dpi = $tmpG.DpiX / 96.0
$tmpG.Dispose()
function S([double]$v) { return [int][Math]::Round($v * $script:dpi) }

$SettingsPath = Join-Path $PSScriptRoot 'overlay_settings.json'
$LatestPath = Join-Path $PSScriptRoot 'data\latest.json'
$DebugPath = Join-Path $PSScriptRoot 'data\screen_debug.txt'
$ShopImagePath = Join-Path $PSScriptRoot 'data\last_shop.png'
$IconDir = Join-Path $PSScriptRoot 'data\icons'
$HistoryPath = Join-Path $PSScriptRoot 'data\pick_history.csv'

$settings = Read-JsonFile $SettingsPath
if ($null -eq $settings) { $settings = [pscustomobject]@{ x = 60; y = 240; opacity = 0.95; auto = $true } }
if ($null -eq $settings.PSObject.Properties['auto']) { $settings | Add-Member -NotePropertyName auto -NotePropertyValue $true }
$settings.auto = $true
if ($null -eq $settings.PSObject.Properties['enhBoost']) { $settings | Add-Member -NotePropertyName enhBoost -NotePropertyValue $false }

$script:snap = $null
$script:snapTime = $null
$script:shop = @()
$script:heroes = @()
$script:templateCount = 0
$script:gameBuild = ''
function Load-Data {
    $script:snap = Get-Snapshot
    $script:snapTime = (Get-Item $LatestPath).LastWriteTime
    $script:shop = @(Get-ShopItems $script:snap | Sort-Object name)
    $script:heroes = @(Get-PlayableHeroes $script:snap)
    $script:heroTable = @(Get-HeroTable $script:snap)
    if ($script:screenOk) { $script:templateCount = [ScreenReader]::LoadTemplates($IconDir) }
}

# Build number of the installed game (from its steam.inf), to compare with the stats build.
function Get-GameBuild {
    $paths = @()
    try {
        $p = Get-Process -Name deadlock -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($p -and $p.Path) { $paths += (Join-Path (Split-Path (Split-Path (Split-Path $p.Path))) 'citadel\steam.inf') }
    } catch { }
    $paths += 'C:\Program Files (x86)\Steam\steamapps\common\Deadlock\game\citadel\steam.inf'
    foreach ($f in $paths) {
        try {
            if (Test-Path $f) {
                $line = Select-String -Path $f -Pattern '^ClientVersion=(\d+)' | Select-Object -First 1
                if ($line) { return $line.Matches[0].Groups[1].Value }
            }
        } catch { }
    }
    return ''
}

# ---------- theme: Deadlock shop look (brown, brass, slot-colored rings) ----------
function C([int]$r, [int]$g, [int]$b, [int]$a = 255) { return [Drawing.Color]::FromArgb($a, $r, $g, $b) }
$colBg       = C 27 19 14
$colWell     = C 18 12 8
$colLine     = C 110 83 48
$colRing     = C 138 106 60
$colBrass    = C 201 160 99
$colBrassDim = C 168 139 98
$colText     = C 243 230 203
$colText2    = C 231 214 180
$colDim      = $colBrassDim
$colRed      = C 214 112 92
$colGreen    = C 168 196 120
$colAmber    = $colBrass
$colSlot = @{
    weapon   = (C 232 162 63)
    vitality = (C 123 194 79)
    spirit   = (C 176 124 232)
}
function New-FontSafe([string]$Family, [double]$Size, $Style = [Drawing.FontStyle]::Regular) {
    try { return New-Object Drawing.Font($Family, [single]$Size, $Style) } catch { return New-Object Drawing.Font('Segoe UI', [single]$Size, $Style) }
}
$disp = 'Bahnschrift'
$fontHero   = New-FontSafe $disp 17
$fontNumBig = New-FontSafe $disp 22
$fontNum    = New-FontSafe $disp 18
$fontName   = New-FontSafe 'Segoe UI' 9.5
$fontSmall  = New-FontSafe 'Segoe UI' 8.5
$fontTiny   = New-FontSafe $disp 8.5
$fontUi     = New-FontSafe 'Segoe UI' 9
$fontIcon   = New-FontSafe 'Segoe MDL2 Assets' 9.5
$script:brushes = @{}
function Get-Brush($Color) {
    $k = $Color.ToArgb()
    if (-not $script:brushes.ContainsKey($k)) { $script:brushes[$k] = New-Object Drawing.SolidBrush($Color) }
    return $script:brushes[$k]
}
function New-FlatButton([string]$Text) {
    $b = New-Object Windows.Forms.Button
    $b.Text = $Text
    $b.FlatStyle = 'Flat'
    $b.FlatAppearance.BorderSize = 1
    $b.FlatAppearance.BorderColor = $colLine
    $b.FlatAppearance.MouseOverBackColor = (C 40 29 21)
    $b.FlatAppearance.MouseDownBackColor = (C 52 38 27)
    $b.BackColor = $colBg
    $b.ForeColor = $colText2
    $b.Font = $fontUi
    $b.Cursor = [Windows.Forms.Cursors]::Hand
    $b.TabStop = $false
    return $b
}
function New-Combo([string]$Style) {
    $cb = New-Object Windows.Forms.ComboBox
    $cb.DropDownStyle = $Style
    $cb.FlatStyle = 'Flat'
    $cb.BackColor = (C 36 26 19)
    $cb.ForeColor = $colText2
    $cb.Font = $fontUi
    $cb.MaxDropDownItems = 20
    return $cb
}

# Item icons from data\item_icons\<id>.png, cached.
$ItemIconDir = Join-Path $PSScriptRoot 'data\item_icons'
$script:iconCache = @{}
function Get-ItemIcon($Name) {
    if ($script:iconCache.ContainsKey($Name)) { return $script:iconCache[$Name] }
    $bmp = $null
    $it = $null
    foreach ($i in $script:shop) { if ($i.name -eq $Name) { $it = $i; break } }
    if ($it) {
        $p = Join-Path $ItemIconDir ([string]$it.id + '.png')
        if (Test-Path $p) {
            try {
                $bytes = [IO.File]::ReadAllBytes($p)
                $ms = New-Object IO.MemoryStream(, $bytes)
                $tmp = New-Object Drawing.Bitmap($ms)
                $bmp = New-Object Drawing.Bitmap($tmp)
                $tmp.Dispose(); $ms.Dispose()
            } catch { $bmp = $null }
        }
    }
    $script:iconCache[$Name] = $bmp
    return $bmp
}

# ---------- window ----------
$W = S 480
$form = New-Object OverlayForm
$form.Text = 'Street Brawl picks'
$form.FormBorderStyle = 'None'
$form.TopMost = $true
$form.ShowInTaskbar = $true
$form.BackColor = $colBg
$form.ForeColor = $colText
$form.Font = $fontUi
$form.AutoScaleMode = 'None'
$form.StartPosition = 'Manual'
$form.Location = New-Object Drawing.Point([int]$settings.x, [int]$settings.y)
$form.ClientSize = New-Object Drawing.Size($W, (S 300))
$form.Opacity = [double]$settings.opacity
$form.KeyPreview = $true

# Frame: hairline border and art-deco corner brackets.
function Draw-Frame($g, [int]$w, [int]$h) {
    $pen = New-Object Drawing.Pen($colLine, 1)
    $g.DrawRectangle($pen, 0, 0, ($w - 1), ($h - 1))
    $pen.Dispose()
    $pb = New-Object Drawing.Pen($colBrass, [float](S 1.5))
    $i = S 6; $L = S 18
    $g.DrawLine($pb, $i, $i, ($i + $L), $i); $g.DrawLine($pb, $i, $i, $i, ($i + $L))
    $g.DrawLine($pb, ($w - $i - $L), $i, ($w - $i), $i); $g.DrawLine($pb, ($w - $i), $i, ($w - $i), ($i + $L))
    $g.DrawLine($pb, $i, ($h - $i), ($i + $L), ($h - $i)); $g.DrawLine($pb, $i, ($h - $i - $L), $i, ($h - $i))
    $g.DrawLine($pb, ($w - $i - $L), ($h - $i), ($w - $i), ($h - $i)); $g.DrawLine($pb, ($w - $i), ($h - $i - $L), ($w - $i), ($h - $i))
    $pb.Dispose()
}
$form.Add_Paint({ param($s, $e) $e.Graphics.SmoothingMode = 'AntiAlias'; Draw-Frame $e.Graphics $form.ClientSize.Width $form.ClientSize.Height })

$script:subtitle = ''
$script:subtitleColor = $colBrassDim

# Header: hero name centered, status line between hairlines. Drag it to move the window.
$header = New-Object Windows.Forms.Panel
$header.SetBounds((S 26), (S 8), ($W - (S 52)), (S 58))
$header.BackColor = $colBg
$header.Add_MouseDown({ $form.StartDrag() })
$header.Add_Paint({
    param($s, $e)
    $g = $e.Graphics
    $g.SmoothingMode = 'AntiAlias'
    $g.TextRenderingHint = 'ClearTypeGridFit'
    $hw = $header.Width
    $h = Get-SelectedHero
    $title = 'Detecting hero'
    if ($h) { $title = $h.name }
    $sfc = New-Object Drawing.StringFormat; $sfc.Alignment = 'Center'
    $stand = ''
    if ($h -and $script:heroTable) {
        $hr = $script:heroTable | Where-Object { $_.id -eq [string]$h.id } | Select-Object -First 1
        if ($hr) { $stand = '{0:0.0}%   |   #{1} of {2}' -f $hr.winrate, $hr.rank, $script:heroTable.Count }
    }
    if ($stand) {
        $tw = $g.MeasureString($title, $fontHero).Width
        $sw = $g.MeasureString($stand, $fontTiny).Width
        $x0 = ($hw - ($tw + (S 8) + $sw)) / 2
        $g.DrawString($title, $fontHero, (Get-Brush $colText), [float]$x0, [float](S 4))
        $g.DrawString($stand, $fontTiny, (Get-Brush $colBrassDim), [float]($x0 + $tw + (S 8)), [float](S 14))
    } else {
        $g.DrawString($title, $fontHero, (Get-Brush $colText), (New-Object Drawing.RectangleF(0, (S 4), $hw, (S 30))), $sfc)
    }
    $sub = $script:subtitle
    if ($sub) {
        $tw = $g.MeasureString($sub, $fontSmall).Width
        $ty = S 36
        $g.DrawString($sub, $fontSmall, (Get-Brush $script:subtitleColor), (New-Object Drawing.RectangleF(0, $ty, $hw, (S 18))), $sfc)
        $pen = New-Object Drawing.Pen($colRing, 1)
        $mid = $ty + (S 8)
        $g.DrawLine($pen, [float]($hw / 2 - $tw / 2 - (S 52)), [float]$mid, [float]($hw / 2 - $tw / 2 - (S 10)), [float]$mid)
        $g.DrawLine($pen, [float]($hw / 2 + $tw / 2 + (S 10)), [float]$mid, [float]($hw / 2 + $tw / 2 + (S 52)), [float]$mid)
        $pen.Dispose()
    }
})
$form.Controls.Add($header)

function New-IconButton([string]$Glyph) {
    $b = New-FlatButton $Glyph
    $b.FlatAppearance.BorderSize = 0
    $b.Font = $fontIcon
    $b.ForeColor = $colBrassDim
    return $b
}
$editBtn = New-IconButton ([string][char]0xE70F)
$editBtn.SetBounds(($header.Width - (S 56)), (S 2), (S 26), (S 24))
$header.Controls.Add($editBtn)
$closeBtn = New-IconButton ([string][char]0xE8BB)
$closeBtn.SetBounds(($header.Width - (S 28)), (S 2), (S 26), (S 24))
$closeBtn.Add_Click({ $form.Close() })
$header.Controls.Add($closeBtn)

# Manual controls, hidden until the edit button is pressed.
$manual = New-Object Windows.Forms.Panel
$manual.BackColor = $colBg
$manual.SetBounds((S 22), (S 70), ($W - (S 44)), (S 100))
$manual.Visible = $false
$form.Controls.Add($manual)
$mw = $manual.Width

$heroBox = New-Combo 'DropDownList'
$heroBox.MaxDropDownItems = 25
$heroBox.SetBounds(0, 0, [int]($mw * 0.46), (S 26))
$manual.Controls.Add($heroBox)

$topBtn = New-FlatButton 'Best by tier'
$topBtn.SetBounds(([int]($mw * 0.46) + (S 6)), 0, ([int]($mw * 0.30)), (S 26))
$manual.Controls.Add($topBtn)

$clearBtn = New-FlatButton 'Clear'
$clearBtn.SetBounds(([int]($mw * 0.76) + (S 12)), 0, ($mw - [int]($mw * 0.76) - (S 12)), (S 26))
$manual.Controls.Add($clearBtn)

$itemBoxes = @()
$iw = [int](($mw - (S 12)) / 3)
for ($k = 0; $k -lt 3; $k++) {
    $cb = New-Combo 'DropDown'
    $cb.AutoCompleteMode = 'SuggestAppend'
    $cb.AutoCompleteSource = 'ListItems'
    $cb.SetBounds(($k * ($iw + (S 6))), (S 34), $iw, (S 26))
    $manual.Controls.Add($cb)
    $itemBoxes += $cb
}
$boostBtn = New-FlatButton ''
$boostBtn.SetBounds(0, (S 68), $mw, (S 26))
$manual.Controls.Add($boostBtn)
function Update-BoostButton {
    if ($settings.enhBoost) { $boostBtn.Text = 'Enhanced boost: on (Ctrl+Alt+E)'; $boostBtn.ForeColor = $colBrass }
    else { $boostBtn.Text = 'Enhanced boost: off, regular win rate (Ctrl+Alt+E)'; $boostBtn.ForeColor = $colText2 }
}
function Switch-Boost {
    $settings.enhBoost = -not $settings.enhBoost
    Update-BoostButton
    Invoke-Rank
}
$boostBtn.Add_Click({ Switch-Boost })
Update-BoostButton

$editBtn.Add_Click({
    $manual.Visible = -not $manual.Visible
    if ($manual.Visible) { $editBtn.ForeColor = $colBrass } else { $editBtn.ForeColor = $colBrassDim }
    Update-View
})

# Results (drawn)
$cards = New-Object Windows.Forms.Panel
$cards.BackColor = $colBg
$cards.SetBounds((S 18), (S 70), ($W - (S 36)), (S 200))
[Windows.Forms.Control].GetProperty('DoubleBuffered', [Reflection.BindingFlags]'NonPublic,Instance').SetValue($cards, $true, $null)
$form.Controls.Add($cards)

# ---------- drawing ----------
$script:view = [pscustomobject]@{ kind = 'msg'; text = 'Loading'; color = $colBrassDim; result = $null; compact = $false }

function Get-SlotColor($Slot) {
    $c = $colSlot[[string]$Slot]
    if ($null -eq $c) { $c = $colBrassDim }
    return $c
}

function Draw-CenteredText($g, [string]$Text, $Font, $Color, [float]$x, [float]$y, [float]$w, [bool]$Paint) {
    if (-not $Text) { return 0 }
    $h = $g.MeasureString($Text, $Font, [int]$w).Height
    if ($Paint) {
        $sf = New-Object Drawing.StringFormat; $sf.Alignment = 'Center'
        $g.DrawString($Text, $Font, (Get-Brush $Color), (New-Object Drawing.RectangleF($x, $y, $w, ($h + 2))), $sf)
    }
    return $h
}

# Item medallion: thin brass outer ring, slot-colored inner ring, the item's shop icon inside.
function Draw-Medallion($g, [string]$Name, $SlotColor, [float]$cx, [float]$top, [float]$d, [float]$thick, [bool]$Paint) {
    if (-not $Paint) { return }
    $pen = New-Object Drawing.Pen($colRing, 1)
    $g.DrawEllipse($pen, [float]($cx - $d / 2), $top, $d, $d)
    $pen.Dispose()
    $gap = S 6
    $d2 = $d - 2 * $gap
    $x2 = $cx - $d2 / 2; $y2 = $top + $gap
    $g.FillEllipse((Get-Brush $colWell), $x2, $y2, $d2, $d2)
    $icon = Get-ItemIcon $Name
    $di = $d2 - 2 * $thick - (S 8)
    if ($icon) {
        $clip = New-Object Drawing.Drawing2D.GraphicsPath
        $clip.AddEllipse([float]($cx - $di / 2), [float]($y2 + ($d2 - $di) / 2), [float]$di, [float]$di)
        $old = $g.Clip
        $g.SetClip($clip)
        $g.InterpolationMode = 'HighQualityBicubic'
        $g.DrawImage($icon, [float]($cx - $di / 2), [float]($y2 + ($d2 - $di) / 2), [float]$di, [float]$di)
        $g.Clip = $old
        $clip.Dispose()
    }
    $pr = New-Object Drawing.Pen($SlotColor, $thick)
    $g.DrawEllipse($pr, [float]($x2 + $thick / 2), [float]($y2 + $thick / 2), [float]($d2 - $thick), [float]($d2 - $thick))
    $pr.Dispose()
}

# One offered item column. Returns its height.
function Draw-ItemColumn($g, $x, [int]$Rank, [float]$left, [float]$colW, [float]$top, [bool]$Paint) {
    $slotCol = Get-SlotColor $x.slot
    $best = ($Rank -eq 1)
    $cx = $left + $colW / 2
    $y = $top
    if ($best) { [void](Draw-CenteredText $g 'Best pick' $fontTiny $colBrass $left $y $colW $Paint) }
    $y += (S 16)
    $d = S 100
    $thick = [float](S 3)
    if ($best) { $d = S 118; $thick = [float](S 5) }
    $mTop = $y + ((S 118) - $d) / 2
    Draw-Medallion $g $x.name $slotCol $cx $mTop $d $thick $Paint
    $y += (S 118) + (S 8)
    $num = 'n/a'
    if ($null -ne $x.expected) { $num = '{0:0.0}%' -f $x.expected }
    $nf = $fontNum
    if ($best) { $nf = $fontNumBig }
    $y += (Draw-CenteredText $g $num $nf $colText $left $y $colW $Paint) - (S 2)
    $y += (Draw-CenteredText $g $x.name $fontName $colText2 $left $y $colW $Paint) + (S 1)
    $tags = @()
    if ($null -ne $x.score) {
        $base = $null
        if ($script:view.result) { $base = $script:view.result.baseline }
        if ($null -ne $base) { $tags += ('{0:+0.0;-0.0;0.0} vs {1:0.0}% avg' -f $x.score, $base) }
        else { $tags += ('{0:+0.0;-0.0;0.0} vs avg' -f $x.score) }
    }
    $line2 = ($tags -join '')
    $marks = @()
    if ($x.enhanced) {
        if ($x.enhLift -and $settings.enhBoost) { $marks += ('enhanced {0:+0.0;-0.0;0.0}' -f $x.enhLift.lift) } else { $marks += 'enhanced' }
    }
    if ($script:rareNames -contains $x.name) { $marks += 'rare' }
    if ($x.thin -and $x.matches -gt 0) { $marks += 'few games' }
    $vc = $colBrassDim
    if ($null -ne $x.score -and $x.score -le -0.5) { $vc = $colRed }
    $y += (Draw-CenteredText $g $line2 $fontSmall $vc $left $y $colW $Paint)
    if ($marks.Count -gt 0) { $y += (Draw-CenteredText $g ($marks -join '   ') $fontSmall $colBrass $left $y $colW $Paint) }
    if ($script:tooltipStats.ContainsKey($x.name)) {
        $y += (S 4)
        $y += (Draw-CenteredText $g ($script:tooltipStats[$x.name] -join "`n") $fontSmall $colText2 $left $y $colW $Paint)
    }
    if ($x.note) { $y += (S 4); $y += (Draw-CenteredText $g $x.note $fontSmall $colBrassDim $left $y $colW $Paint) }
    return ($y - $top)
}

# Draws (or only measures, when $Paint is false) the current view. Returns the height used.
function Draw-View($g, [int]$Width, [bool]$Paint) {
    $g.SmoothingMode = 'AntiAlias'
    $g.TextRenderingHint = 'ClearTypeGridFit'
    $v = $script:view
    if ($v.kind -eq 'msg') {
        $d = S 86
        if ($Paint) {
            $pen = New-Object Drawing.Pen($colRing, 1)
            $g.DrawEllipse($pen, [float](($Width - $d) / 2), [float](S 8), [float]$d, [float]$d)
            $pen.Dispose()
            $pen2 = New-Object Drawing.Pen($colLine, [float](S 3))
            $g.DrawEllipse($pen2, [float](($Width - $d) / 2 + (S 8)), [float](S 16), [float]($d - (S 16)), [float]($d - (S 16)))
            $pen2.Dispose()
        }
        $h = Draw-CenteredText $g $v.text $fontSmall $v.color (S 20) ((S 8) + $d + (S 12)) ($Width - (S 40)) $Paint
        return [int]((S 8) + $d + (S 12) + $h + (S 18))
    }
    $res = $v.result
    if ($v.compact) {
        $y = [float](S 2)
        $lastTier = -1
        foreach ($x in $res.ranked) {
            if ([int]$x.tier -ne $lastTier) {
                if ($Paint) {
                    $lab = 'Tier ' + $x.tier
                    $g.DrawString($lab, $fontTiny, (Get-Brush $colBrass), [float](S 4), [float]($y + (S 4)))
                    $lw = $g.MeasureString($lab, $fontTiny).Width
                    $pen = New-Object Drawing.Pen($colLine, 1)
                    $g.DrawLine($pen, [float]((S 10) + $lw), [float]($y + (S 12)), [float]($Width - (S 4)), [float]($y + (S 12)))
                    $pen.Dispose()
                }
                $y += (S 22); $lastTier = [int]$x.tier
            }
            if ($Paint) {
                $slotCol = Get-SlotColor $x.slot
                $pr = New-Object Drawing.Pen($slotCol, [float](S 2))
                $g.DrawEllipse($pr, [float](S 6), [float]($y + (S 3)), [float](S 16), [float](S 16))
                $pr.Dispose()
                $pct = '{0:0.0}%' -f $x.expected
                $pw = $g.MeasureString($pct, $fontNum).Width
                $sf = New-Object Drawing.StringFormat; $sf.Trimming = 'EllipsisCharacter'; $sf.FormatFlags = 'NoWrap'
                $g.DrawString($x.name, $fontName, (Get-Brush $colText2), (New-Object Drawing.RectangleF((S 30), ($y + (S 2)), ($Width - (S 40) - $pw), (S 20))), $sf)
                $g.DrawString($pct, $fontNum, (Get-Brush $colText), [float]($Width - $pw - (S 2)), [float]($y - (S 3)))
            }
            $y += (S 26)
        }
        return [int]($y + (S 8))
    }
    # Offered items in shop order (left to right), ranked by expected win %.
    $rankOf = @{}; $i = 1
    foreach ($x in $res.ranked) { $rankOf[$x.name] = $i; $i++ }
    $order = @()
    foreach ($cb in $itemBoxes) {
        $t = $cb.Text.Trim()
        if (-not $t) { continue }
        foreach ($x in $res.ranked) { if ($x.name -eq $t -and $order -notcontains $x) { $order += $x } }
    }
    foreach ($x in $res.ranked) { if ($order -notcontains $x) { $order += $x } }
    $n = [Math]::Min(3, $order.Count)
    $gapC = S 6
    $colW = [float](($Width - $gapC * 2) / 3)
    $startX = [float](($Width - ($colW * $n + $gapC * ($n - 1))) / 2)
    $maxH = 0
    for ($k = 0; $k -lt $n; $k++) {
        $hh = Draw-ItemColumn $g $order[$k] $rankOf[$order[$k].name] ($startX + $k * ($colW + $gapC)) $colW (S 2) $Paint
        if ($hh -gt $maxH) { $maxH = $hh }
    }
    $y = (S 2) + $maxH + (S 8)
    return [int]$y
}

$cards.Add_Paint({ param($s, $e) [void](Draw-View $e.Graphics $cards.Width $true) })

function Update-View {
    $top = $header.Bottom + (S 4)
    if ($manual.Visible) { $manual.Top = $top; $top = $manual.Bottom + (S 6) }
    $g = $cards.CreateGraphics()
    try { $h = Draw-View $g $cards.Width $false } finally { $g.Dispose() }
    $h = [Math]::Max($h, (S 40))
    $h = [Math]::Min($h, (S 720))
    $cards.SetBounds((S 18), $top, ($W - (S 36)), $h)
    $form.ClientSize = New-Object Drawing.Size($W, ($cards.Bottom + (S 20)))
    $cards.Invalidate()
    $header.Invalidate()
    $form.Invalidate()
}

function Show-Message([string]$Text, $Color) {
    $script:view = [pscustomobject]@{ kind = 'msg'; text = $Text; color = $Color; result = $null; compact = $false }
    Update-View
}
function Show-Ranking($Result, [bool]$Compact) {
    $script:view = [pscustomobject]@{ kind = 'rank'; text = ''; color = $colText; result = $Result; compact = $Compact }
    Update-View
}

function Set-Status([string]$Text, $Color) {
    if ($null -eq $Color) { $Color = $colBrassDim }
    if ($script:subtitle -ne $Text -or $script:subtitleColor -ne $Color) {
        $script:subtitle = $Text
        $script:subtitleColor = $Color
        $header.Invalidate()
    }
}

function Update-Footer { $header.Invalidate() }

function Get-SelectedHero {
    $name = [string]$heroBox.SelectedItem
    if (-not $name -or $name.StartsWith('---')) { return $null }
    foreach ($h in $script:heroes) { if ($h.name -eq $name) { return $h } }
    return $null
}

function Invoke-Rank {
    try {
        $h = Get-SelectedHero
        if ($null -eq $h) { Show-Message 'Waiting for your hero' $colDim; return }
        $picked = @(); $missing = @()
        foreach ($cb in $itemBoxes) {
            $t = $cb.Text.Trim()
            if ($t -eq '') { continue }
            $m = Find-ByName $t $script:shop
            if ($null -eq $m) { $missing += $t } else { $picked += $m }
        }
        if ($picked.Count -eq 0 -and $missing.Count -eq 0) { Show-Message 'Waiting for the shop' $colDim; return }
        if ($picked.Count -eq 0) { Show-Message ('Not recognized: ' + ($missing -join ', ')) $colRed; return }
        $res = Get-ItemRanking $script:snap $h $picked $script:enhancedNames ([bool]$settings.enhBoost)
        $script:lastRanking = $res
        Show-Ranking $res $false
        if ($missing.Count -gt 0) { Set-Status ('Not recognized: ' + ($missing -join ', ')) $colRed }
    } catch {
        Show-Message $_.Exception.Message $colRed
    }
}

function Invoke-Top {
    try {
        $h = Get-SelectedHero
        if ($null -eq $h) { Show-Message 'Pick a hero first.' $colDim; return }
        $res = Get-ItemRanking $script:snap $h $script:shop
        $res.ranked = @(Select-BestByTier $res.ranked 2)
        $res.closeCall = $false
        Show-Ranking $res $true
    } catch { Show-Message $_.Exception.Message $colRed }
}

function Fill-Lists {
    $keep = [string]$heroBox.SelectedItem
    $heroBox.Items.Clear()
    [void]$heroBox.Items.Add('--- hero ---')
    foreach ($nm in (@($script:heroes | ForEach-Object { $_.name }) | Sort-Object)) { [void]$heroBox.Items.Add($nm) }
    $idx = $heroBox.Items.IndexOf($keep)
    if ($idx -lt 0) { $idx = 0 }
    $heroBox.SelectedIndex = $idx
    foreach ($cb in $itemBoxes) {
        $txt = $cb.Text
        $cb.Items.Clear()
        foreach ($i in $script:shop) { [void]$cb.Items.Add($i.name) }
        $cb.Text = $txt
    }
}

function Save-Settings {
    if ($Preview) { return }
    $settings.x = $form.Location.X
    $settings.y = $form.Location.Y
    $settings | ConvertTo-Json | Set-Content -Path $SettingsPath -Encoding UTF8
}

# ---------- events ----------
$heroBox.Add_SelectedIndexChanged({ $header.Invalidate(); Invoke-Rank })
foreach ($cb in $itemBoxes) {
    $cb.Add_SelectedIndexChanged({ Invoke-Rank })
    $cb.Add_Leave({ Invoke-Rank })
    $cb.Add_KeyDown({ param($s, $e) if ($e.KeyCode -eq 'Return') { $e.SuppressKeyPress = $true; Invoke-Rank } })
}
$topBtn.Add_Click({ Invoke-Top })
$clearBtn.Add_Click({ $script:offer = @(); $script:offerChoice = ''; $script:enhancedNames = @(); $script:rareNames = @(); $script:tooltipStats = @{}; foreach ($cb in $itemBoxes) { $cb.Text = '' }; Invoke-Rank })
$form.Add_HotkeyPressed({
    if ($form.LastHotkey -eq 3) { Switch-Boost; return }
    if ($form.LastHotkey -eq 2) {
        # Ctrl+Alt+S: pin the window visible outside the item phase (or unpin).
        $script:pinned = -not $script:pinned
        Set-OverlayVisible ($script:pinned -or $script:shopVisible)
        Update-Footer
        return
    }
    $on = -not $form.ClickThrough
    if ($on) { $form.Opacity = [Math]::Min([double]$settings.opacity, 0.8) } else { $form.Opacity = [double]$settings.opacity }
    $form.SetClickThrough($on)
    Update-Footer
})

# ---------- screen reading ----------
$script:tick = 0
$script:enhancedNames = @()
$script:rareNames = @()
$script:offer = @()
$script:offerX = @{}
$script:offerChoice = ''
$script:pinned = $false
$script:shopVisible = $true
$script:noShop = 0
$script:lastRanking = $null
$script:match = @{ id = ''; lastRound = 0; hero = ''; last = [datetime]::MinValue }
$script:entries = New-Object System.Collections.ArrayList

function Set-OverlayVisible([bool]$Visible) {
    if ($form.Visible -ne $Visible) { $form.Visible = $Visible }
}

# ---------- pick history (data\pick_history.csv) ----------
function ConvertTo-CsvField($v) { return '"' + ([string]$v -replace '"', '""') + '"' }
function Write-Entry($e, [string]$Status) {
    if ($e.written) { return }
    $e.written = $true
    $order = @(); $top = ''; $pickedRank = ''; $enh = @(); $rar = @()
    if ($e.ranked) {
        $i = 1
        foreach ($x in $e.ranked) {
            $order += ('{0}. {1} {2:0.0}%' -f $i, $x.name, $x.expected)
            if ($i -eq 1) { $top = $x.name }
            if ($x.name -eq $e.picked) { $pickedRank = $i }
            if ($x.enhanced) { $enh += $x.name }
            $i++
        }
    } else { $order = $e.offered }
    $followed = ''
    if ($e.picked -and $top) { if ($e.picked -eq $top) { $followed = 'yes' } else { $followed = 'no' } }
    if (-not (Test-Path $HistoryPath)) {
        'date,match_start,round,choice,hero,offered_ranked,top_pick,picked,picked_rank,followed_top,enhanced,rare,status' | Set-Content -Path $HistoryPath -Encoding UTF8
    }
    $row = @($e.time.ToString('yyyy-MM-dd HH:mm:ss'), $e.match, $e.round, $e.choice, $e.hero, ($order -join ' | '), $top, $e.picked, $pickedRank, $followed, ($enh -join ' | '), (@($e.rare) -join ' | '), $Status)
    try { (($row | ForEach-Object { ConvertTo-CsvField $_ }) -join ',') | Add-Content -Path $HistoryPath -Encoding UTF8 } catch { }
}
function Update-MatchState([string]$Round, [string]$HeroName) {
    $now = Get-Date
    $m = $script:match
    $new = (-not $m.id) -or (($now - $m.last).TotalMinutes -gt 15)
    if ($Round -and $m.lastRound -and [int]$Round -lt $m.lastRound) { $new = $true }
    if ($HeroName -and $m.hero -and $HeroName -ne $m.hero) { $new = $true }
    if ($new) {
        foreach ($e in $script:entries) { Write-Entry $e 'no pick seen' }
        $script:entries.Clear()
        $script:match = @{ id = $now.ToString('yyyy-MM-dd HH:mm'); lastRound = 0; hero = $HeroName; last = $now }
        $m = $script:match
    }
    if ($Round) { $m.lastRound = [int]$Round }
    if ($HeroName) { $m.hero = $HeroName }
    $m.last = $now
}
function New-Entry([string[]]$Names, [string]$Round, [string]$Choice) {
    if ($script:entries.Count -gt 0) {
        $prev = $script:entries[$script:entries.Count - 1]
        if (-not $prev.written) {
            if ($Choice -and $prev.choice -eq $Choice -and $prev.round -eq $Round) { Write-Entry $prev 'rerolled' }
            else { Write-Entry $prev 'no pick seen' }
        }
    }
    $hn = ''
    $h = Get-SelectedHero
    if ($h) { $hn = $h.name }
    [void]$script:entries.Add([pscustomobject]@{
        time = (Get-Date); match = $script:match.id; round = $Round; choice = $Choice; hero = $hn
        offered = @($Names); ranked = $null; picked = ''; written = $false; rare = @()
    })
}
function Update-EntryRanking {
    if ($script:entries.Count -eq 0 -or $null -eq $script:lastRanking) { return }
    $e = $script:entries[$script:entries.Count - 1]
    if ($e.written) { return }
    $rk = @($script:lastRanking.ranked | ForEach-Object { $_.name })
    if (@($e.offered | Where-Object { $rk -notcontains $_ }).Count -eq 0) {
        $e.ranked = @($script:lastRanking.ranked | ForEach-Object { [pscustomobject]@{ name = $_.name; expected = $_.expected; enhanced = $_.enhanced } })
        $e.rare = @($script:rareNames)
    }
}
function Record-Pick([string]$Name) {
    for ($i = $script:entries.Count - 1; $i -ge [Math]::Max(0, $script:entries.Count - 2); $i--) {
        $e = $script:entries[$i]
        if (-not $e.written -and $e.offered -contains $Name) { $e.picked = $Name; Write-Entry $e 'picked'; return }
    }
}
function Get-MatchFollowText {
    $done = @($script:entries | Where-Object { $_.picked -and $_.ranked })
    if ($done.Count -eq 0) { return '' }
    $f = @($done | Where-Object { $_.picked -eq $_.ranked[0].name }).Count
    return ('   |   took the top pick {0} of {1} this match' -f $f, $done.Count)
}
$script:lastNamesKey = ''
$script:tooltipStats = @{}
$script:heroCandidate = ''
$script:lastItemsKey = ''
$script:lastHeroInfo = 'not checked yet'
function Write-ScreenDebug([string[]]$Lines) {
    try { $Lines | Set-Content -Path $DebugPath -Encoding UTF8 } catch { }
}
function Select-HeroById([string]$Id) {
    foreach ($h in $script:heroes) {
        if ([string]$h.id -eq $Id) {
            $idx = $heroBox.Items.IndexOf($h.name)
            if ($idx -ge 0 -and $heroBox.SelectedIndex -ne $idx) { $heroBox.SelectedIndex = $idx; return $true }
            return $false
        }
    }
    return $false
}
function Get-HeroName([string]$Id) {
    if (-not $Id) { return 'none' }
    foreach ($h in $script:heroes) { if ([string]$h.id -eq $Id) { return $h.name } }
    return "id $Id"
}
function Invoke-ScreenTick {
    if (-not $settings.auto -or -not $script:screenOk) { return }
    $script:tick++
    $activeProc = [ScreenReader]::ForegroundProcess()
    if ($activeProc -ne 'deadlock') {
        Set-OverlayVisible $true
        if ($script:tick % 4 -eq 0) { Set-Status 'Waiting for Deadlock' $colBrassDim }
        return
    }
    $bmp = $null
    $log = @()
    $changed = $false
    try {
        $bmp = [ScreenReader]::CaptureScreen()
        $log += ('{0}  screen {1}x{2}' -f (Get-Date -Format 'HH:mm:ss'), $bmp.Width, $bmp.Height)
        # Hero: every ~6 s, or every tick while no hero is picked. Needs two agreeing confident reads.
        if ($script:templateCount -gt 0 -and ($script:tick % 4 -eq 1 -or $null -eq (Get-SelectedHero))) {
            $m = [ScreenReader]::DetectHero($bmp)
            $script:lastHeroInfo = '{0} {1:0.00} (next {2} {3:0.00})' -f (Get-HeroName $m.HeroId), $m.Score, (Get-HeroName $m.SecondId), $m.Second
            if ($m.Score -ge 1.7 -and ($m.Score - $m.Second) -ge 0.25) {
                if ($script:heroCandidate -eq $m.HeroId) {
                    if (Select-HeroById $m.HeroId) { $changed = $true }
                } else { $script:heroCandidate = $m.HeroId }
            }
        }
        $log += ('hero: ' + $script:lastHeroInfo)
        $r = Read-Shop $bmp $script:shop $null
        $read = @($r.items | ForEach-Object { $_.name })
        for ($q = 0; $q -lt $read.Count; $q++) { if ($q -lt @($r.xs).Count) { $script:offerX[$read[$q]] = [double]$r.xs[$q] } }
        # Keep the offer stable: a frame that misses a name (tooltip, hover animation) must not drop it.
        $cur = @($script:offer)
        $newOffer = $read
        $offerEvent = 'new'
        if ($read.Count -gt 0 -and $cur.Count -gt 0 -and -not ($r.choice -and $script:offerChoice -and $r.choice -ne $script:offerChoice)) {
            $inCur = @($read | Where-Object { $cur -contains $_ })
            $extra = @($read | Where-Object { $cur -notcontains $_ })
            if ($extra.Count -eq 0) { $newOffer = $cur; $offerEvent = 'same' }
            elseif ($inCur.Count -gt 0 -and ($cur.Count + $extra.Count) -le 3) { $newOffer = $cur + $extra; $offerEvent = 'grow' }
        }
        if ($read.Count -gt 0) {
            $script:offer = @($newOffer | Sort-Object { if ($script:offerX.ContainsKey($_)) { $script:offerX[$_] } else { 0.5 } })
            if ($r.choice) { $script:offerChoice = $r.choice }
        }
        $names = @($script:offer)
        if ($read.Count -eq 0) { $names = @() }

        # Match tracking, item-phase visibility and picks.
        $selHero = Get-SelectedHero
        $selName = ''
        if ($selHero) { $selName = $selHero.name }
        Update-MatchState $r.round $selName
        if ($read.Count -gt 0 -or $r.shopOpen -or $r.purchased) {
            $script:noShop = 0; $script:shopVisible = $true; Set-OverlayVisible $true
        } else {
            $script:noShop++
            if ($script:noShop -ge 3) { $script:shopVisible = $false; Set-OverlayVisible $script:pinned }
        }
        if ($read.Count -gt 0 -and $r.choice -and $script:offer.Count -ge 2) {
            # One log row per real offer: new when the choice changes or the set is replaced (re-roll).
            $last = $null
            if ($script:entries.Count -gt 0) { $last = $script:entries[$script:entries.Count - 1] }
            $sameChoice = ($last -and $last.choice -eq $r.choice -and (-not $r.round -or -not $last.round -or $last.round -eq $r.round))
            $overlap = 0
            if ($last) { $overlap = @($script:offer | Where-Object { $last.offered -contains $_ }).Count }
            if (-not $sameChoice -or $overlap -eq 0) { New-Entry $script:offer $r.round $r.choice }
            elseif (-not $last.written) { $last.offered = @($script:offer) }
        }
        if ($r.purchased) { Record-Pick $r.purchased; $log += ('purchased: ' + $r.purchased) }
        $log += ('ocr lines: ' + (($r.lines | ForEach-Object { '[' + $_ + ']' }) -join ' '))
        $log += ('items read: ' + ($read -join ', ') + '  offer: ' + ($names -join ', ') + '  rare: ' + (@($r.rare) -join ', ') + '  enhanced: ' + (@($r.enhanced) -join ', ') + '  choice: ' + $r.choice + '  rerolls: ' + $r.rerolls)
        if ($r.tooltip) { $log += ('tooltip ' + $r.tooltip.name + ': ' + ($r.tooltip.stats -join ', ')) }
        if ($names.Count -ge 2 -or ($names.Count -ge 1 -and $r.shopOpen -and $r.choice)) {
            $namesKey = ($names -join '|')
            $enh = @($r.enhanced)
            # Same items still on screen: keep earlier Enhanced reads (OCR can miss the tag on a frame).
            if ($namesKey -eq $script:lastNamesKey) { foreach ($e in $script:enhancedNames) { if ($enh -notcontains $e) { $enh += $e } } }
            $rar = @($r.rare)
            if ($namesKey -eq $script:lastNamesKey) { foreach ($e in $script:rareNames) { if ($rar -notcontains $e) { $rar += $e } } }
            $script:rareNames = $rar
            $key = $namesKey + '#' + (($enh | Sort-Object) -join '|') + '#' + (($rar | Sort-Object) -join '|')
            $rerank = $false
            if ($namesKey -ne $script:lastNamesKey) { $script:tooltipStats = @{} }
            if ($r.tooltip -and $names -contains $r.tooltip.name) {
                $old = ''
                if ($script:tooltipStats.ContainsKey($r.tooltip.name)) { $old = $script:tooltipStats[$r.tooltip.name] -join '|' }
                if ($old -ne ($r.tooltip.stats -join '|')) { $script:tooltipStats[$r.tooltip.name] = $r.tooltip.stats; $rerank = $true }
            }
            if ($key -eq $script:lastItemsKey -and $rerank) { Invoke-Rank; Update-EntryRanking; $changed = $true }
            if ($key -ne $script:lastItemsKey) {
                $script:lastItemsKey = $key
                $script:lastNamesKey = $namesKey
                $script:enhancedNames = $enh
                for ($k = 0; $k -lt 3; $k++) {
                    if ($k -lt $names.Count) { $itemBoxes[$k].Text = $names[$k] } else { $itemBoxes[$k].Text = '' }
                }
                Invoke-Rank
                Update-EntryRanking
                $changed = $true
                try {
                    $snapRect = New-Object System.Drawing.Rectangle -ArgumentList @(0, 0, $bmp.Width, [int]($bmp.Height * 0.8))
                    $shot = [ScreenReader]::Crop($bmp, $snapRect, 1600); $shot.Save($ShopImagePath, [System.Drawing.Imaging.ImageFormat]::Png); $shot.Dispose()
                } catch { }
            }
            $info = 'Shop open'
            if ($r.choice) { $info = 'Choice ' + $r.choice }
            if ($r.rerolls -ne '') {
                if ($r.rerolls -match '^(0|no)$') { $info += '   |   no re-roll left' }
                elseif ($r.rerolls -eq '1') { $info += '   |   1 re-roll left' }
                else { $info += '   |   ' + $r.rerolls + ' re-rolls left' }
            }
            Set-Status ($info + (Get-MatchFollowText)) $colAmber
        } else {
            $hn = Get-HeroName $script:heroCandidate
            $hs = Get-SelectedHero
            $hst = $null
            if ($hs) { $hst = $script:snap.hero_stats.street_brawl.([string]$hs.id) }
            if ($hst -and $hst.matches -gt 0) { Set-Status ('Average win {0:0.0}%   |   {1:N0} Street Brawl games' -f (100.0 * $hst.wins / $hst.matches), $hst.matches) $colDim }
            elseif ($hn -eq 'none') { Set-Status 'Looking for your hero' $colDim } else { Set-Status 'Waiting for the item shop' $colDim }
        }
    } catch {
        Set-Status ('Reader error: ' + $_.Exception.Message) $colRed
        $log += ('error: ' + $_.Exception.Message)
        $changed = $true
    } finally {
        if ($bmp) { $bmp.Dispose() }
    }
    if ($changed -or $script:tick % 20 -eq 0) { Write-ScreenDebug $log }
}
$screenTimer = New-Object Windows.Forms.Timer
$screenTimer.Interval = 1500
$screenTimer.Add_Tick({ Invoke-ScreenTick })

$form.Add_KeyDown({ param($s, $e) if ($e.KeyCode -eq 'Escape') { $form.Close() } })
$form.Add_FormClosing({ Save-Settings })

# Reload when the daily refresh writes new data; re-check the installed game build.
$timer = New-Object Windows.Forms.Timer
$timer.Interval = 60000
$timer.Add_Tick({
    try {
        $script:gameBuild = Get-GameBuild
        if ((Test-Path $LatestPath) -and (Get-Item $LatestPath).LastWriteTime -ne $script:snapTime) {
            Load-Data; Fill-Lists; Invoke-Rank
        }
        Update-Footer
    } catch { }
})

try {
    Load-Data
} catch {
    [Windows.Forms.MessageBox]::Show("No data yet. Run collect.bat first.`n`n" + $_.Exception.Message, 'Street Brawl picks') | Out-Null
    exit 1
}
$script:gameBuild = Get-GameBuild
Fill-Lists
Update-View
$form.Add_Shown({
    Update-Footer; Invoke-Rank
    # Keep this window out of screen captures, so the reader never reads its own text.
    $hidden = $false
    if ($Preview) {
        $settings.auto = $false
        if ($Demo) {
            $form.Opacity = 1.0
            $idx = $heroBox.Items.IndexOf($DemoHero)
            if ($idx -ge 0) { $heroBox.SelectedIndex = $idx }
            $script:enhancedNames = @($DemoEnhanced -split '\|' | Where-Object { $_ })
            $script:rareNames = @($DemoRare -split '\|' | Where-Object { $_ })
            $di = @($DemoItems -split '\|')
            for ($k = 0; $k -lt 3; $k++) { if ($k -lt $di.Count) { $itemBoxes[$k].Text = $di[$k] } else { $itemBoxes[$k].Text = '' } }
            Invoke-Rank
            Set-Status $DemoStatus $colBrassDim
        } else { Set-Status 'Preview mode: screen reading off' $colDim }
        return
    }
    try { $hidden = [ScreenReader]::SetWindowDisplayAffinity($form.Handle, 0x11) } catch { }
    if (-not $hidden) { $settings.auto = $false; Set-Status 'Screen reading off: this Windows version cannot hide the window from capture.' $colRed }
    elseif (-not $script:screenOk) { Set-Status ('Screen reading unavailable: ' + $script:screenError) $colRed }
    elseif ($script:templateCount -eq 0) { Set-Status 'Hero detection needs icons: run collect.bat once.' $colRed }
})
$timer.Start()
$screenTimer.Start()
[Windows.Forms.Application]::Run($form)
$timer.Stop()
$screenTimer.Stop()
