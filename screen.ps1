# Screen reading for the overlay: hero detection (ability icon matching) and shop item names
# (Windows built-in text recognition). Reads pixels only: no game memory, no injection.
# Windows PowerShell 5.1, no downloads.

Add-Type -AssemblyName System.Drawing
if (-not ('ScreenReader' -as [type])) {
Add-Type -ReferencedAssemblies System.Drawing -TypeDefinition @'
using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Drawing;
using System.Drawing.Drawing2D;
using System.Drawing.Imaging;
using System.IO;
using System.Runtime.InteropServices;

public class HeroMatch {
    public string HeroId = ""; public double Score; public string SecondId = ""; public double Second;
}

public static class ScreenReader {
    [DllImport("user32.dll")] static extern IntPtr SetThreadDpiAwarenessContext(IntPtr ctx);
    [DllImport("user32.dll")] static extern int GetSystemMetrics(int i);
    [DllImport("user32.dll")] static extern IntPtr GetForegroundWindow();
    [DllImport("user32.dll")] static extern uint GetWindowThreadProcessId(IntPtr h, out uint pid);
    [DllImport("user32.dll")] public static extern bool SetWindowDisplayAffinity(IntPtr h, uint affinity);

    const int S = 32;
    static readonly double[] Scales = { 0.55, 0.65, 0.75, 0.85 };
    static readonly double[] SlotOffsets = { -101, -34, 33, 100 }; // HUD ability slots, in a 1456x819 frame
    static bool[] mask;
    // heroId -> slot (0..3) -> list of template vectors (one per scale)
    static Dictionary<string, List<float[]>[]> templates = new Dictionary<string, List<float[]>[]>();

    static ScreenReader() {
        mask = new bool[S * S];
        double rr = (S / 2.0 * 0.85) * (S / 2.0 * 0.85);
        for (int y = 0; y < S; y++) for (int x = 0; x < S; x++) {
            double dx = x - S / 2.0 + 0.5, dy = y - S / 2.0 + 0.5;
            mask[y * S + x] = dx * dx + dy * dy <= rr;
        }
    }

    public static string ForegroundProcess() {
        try { uint pid; GetWindowThreadProcessId(GetForegroundWindow(), out pid); return Process.GetProcessById((int)pid).ProcessName; }
        catch { return ""; }
    }

    // Full primary screen in physical pixels, even when Windows display scaling is above 100%.
    public static Bitmap CaptureScreen() {
        IntPtr old = IntPtr.Zero;
        try { old = SetThreadDpiAwarenessContext(new IntPtr(-4)); } catch { }
        try {
            int w = GetSystemMetrics(0), h = GetSystemMetrics(1);
            Bitmap bmp = new Bitmap(w, h, PixelFormat.Format24bppRgb);
            using (Graphics g = Graphics.FromImage(bmp)) g.CopyFromScreen(0, 0, 0, 0, new Size(w, h));
            return bmp;
        } finally {
            if (old != IntPtr.Zero) { try { SetThreadDpiAwarenessContext(old); } catch { } }
        }
    }

    public static Bitmap Crop(Bitmap src, Rectangle r, int maxWidth) {
        r.Intersect(new Rectangle(0, 0, src.Width, src.Height));
        int w = r.Width, h = r.Height;
        if (maxWidth > 0 && w > maxWidth) { h = (int)(h * (double)maxWidth / w); w = maxWidth; }
        Bitmap b = new Bitmap(w, h, PixelFormat.Format24bppRgb);
        using (Graphics g = Graphics.FromImage(b)) {
            g.InterpolationMode = InterpolationMode.HighQualityBilinear;
            g.DrawImage(src, new Rectangle(0, 0, w, h), r, GraphicsUnit.Pixel);
        }
        return b;
    }

    // Crop, scale and rotate a region, then keep only bright low-color pixels (white text) as black on white.
    public static Bitmap WhiteTextMask(Bitmap src, Rectangle r, double scale, float angle) {
        int w = (int)(r.Width * scale), h = (int)(r.Height * scale);
        Bitmap b = new Bitmap(w, h, PixelFormat.Format24bppRgb);
        using (Graphics g = Graphics.FromImage(b)) {
            g.Clear(Color.Black);
            g.InterpolationMode = InterpolationMode.HighQualityBicubic;
            g.TranslateTransform(w / 2f, h / 2f);
            g.RotateTransform(angle);
            g.DrawImage(src, new Rectangle(-w / 2, -h / 2, w, h), r, GraphicsUnit.Pixel);
        }
        BitmapData d = b.LockBits(new Rectangle(0, 0, w, h), ImageLockMode.ReadWrite, PixelFormat.Format24bppRgb);
        byte[] px = new byte[d.Stride * h];
        Marshal.Copy(d.Scan0, px, 0, px.Length);
        for (int y = 0; y < h; y++) for (int x = 0; x < w; x++) {
            int i = y * d.Stride + x * 3;
            int mx = Math.Max(px[i], Math.Max(px[i + 1], px[i + 2]));
            int mn = Math.Min(px[i], Math.Min(px[i + 1], px[i + 2]));
            byte v = (mx >= 185 && mx - mn <= 55) ? (byte)0 : (byte)255;
            px[i] = v; px[i + 1] = v; px[i + 2] = v;
        }
        Marshal.Copy(px, 0, d.Scan0, px.Length);
        b.UnlockBits(d);
        return b;
    }

    static float[] ReadChannel(Bitmap b, bool alpha) {
        float[] v = new float[S * S];
        BitmapData d = b.LockBits(new Rectangle(0, 0, S, S), ImageLockMode.ReadOnly, PixelFormat.Format32bppArgb);
        byte[] px = new byte[d.Stride * S];
        Marshal.Copy(d.Scan0, px, 0, px.Length);
        b.UnlockBits(d);
        for (int y = 0; y < S; y++) for (int x = 0; x < S; x++) {
            int i = y * d.Stride + x * 4;
            v[y * S + x] = alpha ? px[i + 3] / 255f : (0.114f * px[i] + 0.587f * px[i + 1] + 0.299f * px[i + 2]) / 255f;
        }
        return v;
    }

    // Outline strength, so light-on-dark and dark-on-light icons match the same way.
    static float[] EdgeVector(float[] a) {
        float[] e = new float[S * S];
        for (int y = 0; y < S; y++) for (int x = 0; x < S; x++) {
            float gx = (x > 0 && x < S - 1) ? a[y * S + x + 1] - a[y * S + x - 1] : 0f;
            float gy = (y > 0 && y < S - 1) ? a[(y + 1) * S + x] - a[(y - 1) * S + x] : 0f;
            e[y * S + x] = (float)Math.Sqrt(gx * gx + gy * gy);
        }
        List<float> v = new List<float>();
        double sum = 0; int n = 0;
        for (int i = 0; i < S * S; i++) if (mask[i]) { v.Add(e[i]); sum += e[i]; n++; }
        float mean = (float)(sum / n);
        double norm = 0;
        float[] r = new float[n];
        for (int i = 0; i < n; i++) { r[i] = v[i] - mean; norm += r[i] * r[i]; }
        norm = Math.Sqrt(norm);
        if (norm > 0) for (int i = 0; i < n; i++) r[i] = (float)(r[i] / norm);
        return r;
    }

    // Icon files are named <heroId>_<slot 1-4>.png
    public static int LoadTemplates(string dir) {
        templates.Clear();
        if (!Directory.Exists(dir)) return 0;
        int count = 0;
        foreach (string f in Directory.GetFiles(dir, "*_*.png")) {
            string name = Path.GetFileNameWithoutExtension(f);
            int us = name.LastIndexOf('_');
            int slot;
            if (us < 1 || !int.TryParse(name.Substring(us + 1), out slot) || slot < 1 || slot > 4) continue;
            string hero = name.Substring(0, us);
            try {
                using (Bitmap src = new Bitmap(f)) {
                    List<float[]>[] slots;
                    if (!templates.TryGetValue(hero, out slots)) {
                        slots = new List<float[]>[4];
                        for (int k = 0; k < 4; k++) slots[k] = new List<float[]>();
                        templates[hero] = slots;
                    }
                    foreach (double sc in Scales) {
                        int sz = (int)(S * sc);
                        using (Bitmap c = new Bitmap(S, S, PixelFormat.Format32bppArgb)) {
                            using (Graphics g = Graphics.FromImage(c)) {
                                g.Clear(Color.Transparent);
                                g.InterpolationMode = InterpolationMode.HighQualityBilinear;
                                int o = (S - sz) / 2;
                                g.DrawImage(src, new Rectangle(o, o, sz, sz));
                            }
                            slots[slot - 1].Add(EdgeVector(ReadChannel(c, true)));
                        }
                    }
                    count++;
                }
            } catch { }
        }
        return count;
    }

    public static HeroMatch DetectHero(Bitmap screen) {
        HeroMatch m = new HeroMatch();
        if (templates.Count == 0) return m;
        double unit = screen.Height / 819.0;
        double cy = 773 * unit, r = 28 * unit;
        List<float[]>[] crops = new List<float[]>[4];
        for (int k = 0; k < 4; k++) {
            crops[k] = new List<float[]>();
            double cx = screen.Width / 2.0 + SlotOffsets[k] * unit;
            for (int dx = -8; dx <= 8; dx += 2) for (int dy = -8; dy <= 8; dy += 2) {
                Rectangle rc = new Rectangle((int)(cx + dx * unit - r), (int)(cy + dy * unit - r), (int)(2 * r), (int)(2 * r));
                using (Bitmap c = new Bitmap(S, S, PixelFormat.Format32bppArgb)) {
                    using (Graphics g = Graphics.FromImage(c)) {
                        g.InterpolationMode = InterpolationMode.HighQualityBilinear;
                        g.DrawImage(screen, new Rectangle(0, 0, S, S), rc, GraphicsUnit.Pixel);
                    }
                    crops[k].Add(EdgeVector(ReadChannel(c, false)));
                }
            }
        }
        foreach (KeyValuePair<string, List<float[]>[]> kv in templates) {
            double total = 0;
            for (int k = 0; k < 4; k++) {
                double best = 0;
                foreach (float[] t in kv.Value[k]) foreach (float[] c in crops[k]) {
                    double dot = 0;
                    int n = Math.Min(t.Length, c.Length);
                    for (int i = 0; i < n; i++) dot += t[i] * c[i];
                    if (dot > best) best = dot;
                }
                total += best;
            }
            if (total > m.Score) { m.Second = m.Score; m.SecondId = m.HeroId; m.Score = total; m.HeroId = kv.Key; }
            else if (total > m.Second) { m.Second = total; m.SecondId = kv.Key; }
        }
        return m;
    }
}
'@
}

# ---------- Windows built-in text recognition (Windows.Media.Ocr) ----------
Add-Type -AssemblyName System.Runtime.WindowsRuntime
$null = [Windows.Media.Ocr.OcrEngine, Windows.Foundation, ContentType = WindowsRuntime]
$null = [Windows.Graphics.Imaging.BitmapDecoder, Windows.Foundation, ContentType = WindowsRuntime]
$null = [Windows.Graphics.Imaging.SoftwareBitmap, Windows.Foundation, ContentType = WindowsRuntime]
$script:AsTaskOp = [System.WindowsRuntimeSystemExtensions].GetMethods() | Where-Object {
    $_.Name -eq 'AsTask' -and $_.GetParameters().Count -eq 1 -and $_.GetParameters()[0].ParameterType.Name -eq 'IAsyncOperation`1'
} | Select-Object -First 1
$script:OcrEngine = [Windows.Media.Ocr.OcrEngine]::TryCreateFromUserProfileLanguages()

function Wait-WinRt($Operation, [Type]$ResultType) {
    $task = $script:AsTaskOp.MakeGenericMethod($ResultType).Invoke($null, @($Operation))
    [void]$task.Wait(5000)
    return $task.Result
}

# Returns OCR lines (text, x center, y center, in the bitmap's pixels).
function Get-OcrLines([System.Drawing.Bitmap]$Bitmap) {
    if ($null -eq $script:OcrEngine) { throw 'Windows text recognition is not available (no OCR language installed).' }
    $ms = New-Object System.IO.MemoryStream
    try {
        $Bitmap.Save($ms, [System.Drawing.Imaging.ImageFormat]::Png)
        $ms.Position = 0
        $ras = [System.IO.WindowsRuntimeStreamExtensions]::AsRandomAccessStream($ms)
        $decoder = Wait-WinRt ([Windows.Graphics.Imaging.BitmapDecoder]::CreateAsync($ras)) ([Windows.Graphics.Imaging.BitmapDecoder])
        $soft = Wait-WinRt ($decoder.GetSoftwareBitmapAsync()) ([Windows.Graphics.Imaging.SoftwareBitmap])
        $res = Wait-WinRt ($script:OcrEngine.RecognizeAsync($soft)) ([Windows.Media.Ocr.OcrResult])
        $out = foreach ($line in $res.Lines) {
            $x0 = 1e9; $x1 = 0; $y0 = 1e9; $y1 = 0
            foreach ($w in $line.Words) {
                $r = $w.BoundingRect
                if ($r.X -lt $x0) { $x0 = $r.X }; if ($r.X + $r.Width -gt $x1) { $x1 = $r.X + $r.Width }
                if ($r.Y -lt $y0) { $y0 = $r.Y }; if ($r.Y + $r.Height -gt $y1) { $y1 = $r.Y + $r.Height }
            }
            [pscustomobject]@{ text = $line.Text; x = ($x0 + $x1) / 2; y = ($y0 + $y1) / 2; x0 = $x0; h = ($y1 - $y0) }
        }
        if ($soft) { $soft.Dispose() }
        return @($out)
    } finally { $ms.Dispose() }
}

# Strict item-name match for OCR text (avoids matching tooltip words).
function Find-ItemStrict([string]$Text, $Items, [int]$Divisor = 6) {
    $q = ConvertTo-Key $Text
    if ($q.Length -lt 4) { return $null }
    $best = $null; $bestD = 999
    foreach ($c in $Items) {
        $k = ConvertTo-Key $c.name
        if ($k -eq $q) { return $c }
        if ([Math]::Abs($k.Length - $q.Length) -gt 3) { continue }
        $d = Get-EditDistance $q $k
        if ($d -lt $bestD) { $bestD = $d; $best = $c }
    }
    if ($best -and $bestD -le [Math]::Max(1, [Math]::Floor($q.Length / $Divisor))) { return $best }
    return $null
}

function Test-EnhancedText([string]$Text) {
    $k = ConvertTo-Key $Text
    if ($k.Length -lt 6) { return $false }
    if ($k.Contains('enhanc')) { return $true }
    return ((Get-EditDistance ($k.Substring(0, [Math]::Min(8, $k.Length))) 'enhanced') -le 2)
}

$script:RescueMiss = @{}
$script:StatRegex = '^\s*([+\-]?\d+(?:[.,]\d+)?)\s*(%|m/s|m|s)?\S*\s+([A-Za-z].*?)\s*$'
$script:ValueOnlyRegex = '^\s*([+\-]?\d+(?:[.,]\d+)?)\s*(%|m/s|m|s)?\S{0,2}\s*$'

function Format-StatValue($Match) {
    $v = $Match.Groups[1].Value -replace ',', '.'
    return ($v + $Match.Groups[2].Value)
}
function Clean-Label([string]$Text) {
    $t = ($Text -replace '[^A-Za-z&'' ]', ' ') -replace '\s+', ' '
    return $t.Trim()
}

# One pass of text recognition over the top 80% of the screen. Returns:
#   items (offered items, left to right), enhanced (names), choice ("2 of 3"), rerolls ("1"),
#   tooltip (@{ name; stats = @("+24% Fire Rate", ...) } for the hovered offered item), lines (raw text)
function Read-Shop([System.Drawing.Bitmap]$Screen, $ShopItems, [string]$SavePath) {
    $W = $Screen.Width; $H = $Screen.Height
    $rx = [int]($W * 0.02); $rw = [int]($W * 0.94); $rh = [int]($H * 0.80)
    $rect = New-Object System.Drawing.Rectangle -ArgumentList @($rx, 0, $rw, $rh)
    $img = [ScreenReader]::Crop($Screen, $rect, 2400)
    try {
        $k = $rw / $img.Width
        $lines = @(foreach ($l in (Get-OcrLines $img)) {
            [pscustomobject]@{
                text = $l.text
                fx = ($rx + $l.x * $k) / $W; fy = ($l.y * $k) / $H
                fx0 = ($rx + $l.x0 * $k) / $W; fh = ($l.h * $k) / $H
            }
        })

        # Offered item names: large text in the lower middle band.
        $found = @(); $pos = @(); $seen = @{}
        foreach ($l in ($lines | Where-Object { $_.fy -ge 0.42 -and $_.fx -ge 0.08 -and $_.fx -le 0.84 -and $_.fh -ge 0.021 } | Sort-Object fx)) {
            $m = Find-ItemStrict $l.text $ShopItems
            if ($m -and -not $seen.ContainsKey($m.name)) { $seen[$m.name] = 1; $found += $m; $pos += $l }
        }

        # Shop is open if the choice text or any item name was read.
        $shopOpen = ($found.Count -gt 0) -or (@($lines | Where-Object { $_.text -match '(?i)cho[i1l]ce\s*[1-3]' }).Count -gt 0)

        # Rescue pass for slots with no name read (rare items: tilted, glowing, animated text).
        if ($shopOpen) {
            $slots = @(@{ x = 0.28; y = 0.69 }, @{ x = 0.495; y = 0.47 }, @{ x = 0.72; y = 0.69 })
            $seenKey = (@($found | ForEach-Object { $_.name }) -join '|')
            for ($si = 0; $si -lt $slots.Count; $si++) {
                $sl = $slots[$si]
                $has = $false
                foreach ($p in $pos) { if ([Math]::Abs($p.fx - $sl.x) -lt 0.1) { $has = $true } }
                if ($has) { continue }
                # An empty slot (item already taken) would be retried every check: wait 6 s after a miss.
                $missKey = "$si|$seenKey"
                if ($script:RescueMiss.ContainsKey($missKey) -and ((Get-Date) - $script:RescueMiss[$missKey]).TotalSeconds -lt 6) { continue }
                $gotIt = $false
                $r2 = New-Object System.Drawing.Rectangle -ArgumentList @([int](($sl.x - 0.13) * $W), [int](($sl.y - 0.06) * $H), [int](0.26 * $W), [int](0.12 * $H))
                foreach ($ang in @(0, -6, 6)) {
                    $mask = [ScreenReader]::WhiteTextMask($Screen, $r2, 2.0, [float]$ang)
                    try { $rl = Get-OcrLines $mask } finally { $mask.Dispose() }
                    $hit = $null
                    foreach ($l in $rl) { $mm = Find-ItemStrict $l.text $ShopItems 5; if ($mm -and -not $seen.ContainsKey($mm.name)) { $hit = $mm; break } }
                    if ($hit) {
                        $seen[$hit.name] = 1; $found += $hit
                        $pos += [pscustomobject]@{ text = $hit.name; fx = $sl.x; fy = $sl.y; fx0 = $sl.x - 0.05; fh = 0.03 }
                        $gotIt = $true
                        break
                    }
                }
                if (-not $gotIt) { $script:RescueMiss[$missKey] = Get-Date }
            }
            # keep left-to-right order
            if ($found.Count -gt 1) {
                $order = @(0..($found.Count - 1) | Sort-Object { $pos[$_].fx })
                $found = @($order | ForEach-Object { $found[$_] }); $pos = @($order | ForEach-Object { $pos[$_] })
            }
        }

        # RARE! tags sit at the top of an item circle.
        $rare = @()
        foreach ($l in $lines) {
            if ((ConvertTo-Key $l.text) -notmatch '^rare') { continue }
            for ($i = 0; $i -lt $pos.Count; $i++) {
                if ([Math]::Abs($pos[$i].fx - $l.fx) -lt 0.09 -and $l.fy -lt $pos[$i].fy -and $rare -notcontains $found[$i].name) { $rare += $found[$i].name }
            }
        }

        # ENHANCED tags sit just under an item name.
        $enhanced = @()
        foreach ($l in $lines) {
            if ($l.fy -lt 0.42 -or -not (Test-EnhancedText $l.text)) { continue }
            $bestI = -1; $bestDx = [double]::MaxValue
            for ($i = 0; $i -lt $pos.Count; $i++) {
                $dx = [Math]::Abs($pos[$i].fx - $l.fx)
                if ($l.fy -gt $pos[$i].fy -and ($l.fy - $pos[$i].fy) -lt 0.09 -and $dx -lt $bestDx) { $bestDx = $dx; $bestI = $i }
            }
            if ($bestI -ge 0 -and $bestDx -lt 0.09 -and $enhanced -notcontains $found[$bestI].name) { $enhanced += $found[$bestI].name }
        }

        # Round number (top centre) and the "ITEM PURCHASED" panel (right edge).
        $round = ''; $purchased = ''
        foreach ($l in $lines) {
            if (-not $round -and $l.fy -lt 0.12 -and $l.text -match '(?i)r[o0]und\s*([1-9])') { $round = $Matches[1] }
            $lk = ConvertTo-Key $l.text
            if ($l.fx -ge 0.78 -and ($lk.Contains('purchas') -or $lk.Contains('itempurch'))) {
                foreach ($c in $lines) {
                    if ($c.fx -ge 0.78 -and $c.fy -gt $l.fy -and ($c.fy - $l.fy) -lt 0.07) {
                        $pm = Find-ItemStrict $c.text $ShopItems
                        if ($pm) { $purchased = $pm.name; break }
                    }
                }
            }
        }

        # Choice number and re-rolls left.
        $choice = ''; $rerolls = ''
        foreach ($l in $lines) {
            if (-not $choice -and $l.text -match '(?i)cho[i1l]ce\s*([1-3])\s*[o0][fF]\s*([1-3])') { $choice = '{0} of {1}' -f $Matches[1], $Matches[2] }
            if (-not $rerolls -and $l.text -match '(?i)(\d+|no)\s*re.?ro[l1I]{2}s?\s*rema') { $rerolls = $Matches[1] }
        }

        # Tooltip of the hovered item: its title repeats an offered name, above or apart from the shop label.
        $tooltip = $null
        $titleCands = @($lines | Where-Object { $_.fh -ge 0.018 })
        foreach ($f in $found) {
            $hits = @($titleCands | Where-Object { (Find-ItemStrict $_.text @($f)) -ne $null } | Sort-Object fy)
            if ($hits.Count -lt 2) { continue }
            $title = $hits[0]
            $body = @($lines | Where-Object {
                $_.fy -gt $title.fy -and $_.fy -lt ($title.fy + 0.45) -and $_.fx0 -ge ($title.fx0 - 0.03) -and $_.fx0 -le ($title.fx0 + 0.25)
            } | Sort-Object fy, fx)
            $stats = @(); $used = @{}
            for ($i = 0; $i -lt $body.Count; $i++) {
                if ($used.ContainsKey($i)) { continue }
                $t = $body[$i].text
                $mm = [regex]::Match($t, $script:StatRegex)
                if ($mm.Success) {
                    $lab = Clean-Label $mm.Groups[3].Value
                    if ($lab.Length -ge 3) { $stats += ('{0} {1}' -f (Format-StatValue $mm), $lab) }
                    continue
                }
                $mv = [regex]::Match($t, $script:ValueOnlyRegex)
                if ($mv.Success) {
                    # Grid cell: value on one line, label just below it.
                    for ($j = $i + 1; $j -lt $body.Count; $j++) {
                        $c = $body[$j]
                        if ($c.fy - $body[$i].fy -gt 0.06) { break }
                        if ([Math]::Abs($c.fx - $body[$i].fx) -lt 0.05 -and -not [regex]::IsMatch($c.text, $script:ValueOnlyRegex)) {
                            $lab = Clean-Label $c.text
                            if ($lab.Length -ge 3) { $stats += ('{0} {1}' -f (Format-StatValue $mv), $lab); $used[$j] = 1 }
                            break
                        }
                    }
                }
            }
            if ($stats.Count -gt 0) { $tooltip = [pscustomobject]@{ name = $f.name; stats = @($stats | Select-Object -First 8) } }
            break
        }

        if ($SavePath -and $found.Count -ge 2) { $img.Save($SavePath, [System.Drawing.Imaging.ImageFormat]::Png) }
        return [pscustomobject]@{
            items = $found; round = $round; purchased = $purchased; xs = @($pos | ForEach-Object { $_.fx }); enhanced = $enhanced; rare = $rare; shopOpen = $shopOpen; choice = $choice; rerolls = $rerolls; tooltip = $tooltip
            lines = @($lines | ForEach-Object { $_.text })
        }
    } finally { $img.Dispose() }
}
