# Draws ip-switch.ico (window/taskbar icon) and copies it to ..\.icons\ip-switch.ico for the OffLab card.
#   powershell -ExecutionPolicy Bypass -File make-icon.ps1
Add-Type -AssemblyName System.Drawing
$here = $PSScriptRoot

function New-Icon([int]$size) {
  $bmp = New-Object System.Drawing.Bitmap $size, $size, ([System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
  $g = [System.Drawing.Graphics]::FromImage($bmp)
  $g.SmoothingMode = 'AntiAlias'; $g.Clear([System.Drawing.Color]::Transparent)
  $k = $size / 64.0

  $r = 14 * $k; $e = $size - 1
  $tile = New-Object System.Drawing.Drawing2D.GraphicsPath
  $tile.AddArc(0, 0, 2 * $r, 2 * $r, 180, 90); $tile.AddArc($e - 2 * $r, 0, 2 * $r, 2 * $r, 270, 90)
  $tile.AddArc($e - 2 * $r, $e - 2 * $r, 2 * $r, 2 * $r, 0, 90); $tile.AddArc(0, $e - 2 * $r, 2 * $r, 2 * $r, 90, 90); $tile.CloseFigure()
  $rect = New-Object System.Drawing.RectangleF 0, 0, $size, $size
  $fill = New-Object System.Drawing.Drawing2D.LinearGradientBrush $rect, ([System.Drawing.Color]::FromArgb(255, 0, 120, 212)), ([System.Drawing.Color]::FromArgb(255, 0, 74, 150)), 90
  $g.FillPath($fill, $tile)

  $w = [single][Math]::Max(1.6, 4.6 * $k)
  $pen = New-Object System.Drawing.Pen ([System.Drawing.Color]::White), $w
  $pen.StartCap = 'Round'; $pen.EndCap = 'Round'; $pen.LineJoin = 'Round'
  # top arrow -> right, bottom arrow <- left: the IP moving between two cards
  $g.DrawLine($pen, 15 * $k, 23 * $k, 47 * $k, 23 * $k)
  $g.DrawLines($pen, [System.Drawing.PointF[]]@((New-Object System.Drawing.PointF (39 * $k), (15 * $k)), (New-Object System.Drawing.PointF (47 * $k), (23 * $k)), (New-Object System.Drawing.PointF (39 * $k), (31 * $k))))
  $g.DrawLine($pen, 49 * $k, 41 * $k, 17 * $k, 41 * $k)
  $g.DrawLines($pen, [System.Drawing.PointF[]]@((New-Object System.Drawing.PointF (25 * $k), (33 * $k)), (New-Object System.Drawing.PointF (17 * $k), (41 * $k)), (New-Object System.Drawing.PointF (25 * $k), (49 * $k))))
  $g.Dispose()
  return $bmp
}

# ICO with PNG-compressed frames (Windows Vista and later).
$sizes = 16, 24, 32, 48, 64, 128, 256
$pngs = foreach ($s in $sizes) { $ms = New-Object IO.MemoryStream; (New-Icon $s).Save($ms, [System.Drawing.Imaging.ImageFormat]::Png); , $ms.ToArray() }
$out = New-Object IO.MemoryStream; $bw = New-Object IO.BinaryWriter $out
$bw.Write([uint16]0); $bw.Write([uint16]1); $bw.Write([uint16]$sizes.Count)
$offset = 6 + 16 * $sizes.Count
for ($n = 0; $n -lt $sizes.Count; $n++) {
  $s = $sizes[$n]; $b = $(if ($s -ge 256) { 0 } else { $s })
  $bw.Write([byte]$b); $bw.Write([byte]$b); $bw.Write([byte]0); $bw.Write([byte]0)
  $bw.Write([uint16]1); $bw.Write([uint16]32); $bw.Write([uint32]$pngs[$n].Length); $bw.Write([uint32]$offset)
  $offset += $pngs[$n].Length
}
foreach ($p in $pngs) { $bw.Write($p) }
$bw.Flush()
[IO.File]::WriteAllBytes((Join-Path $here 'ip-switch.ico'), $out.ToArray())
$icons = Join-Path (Split-Path $here) '.icons'
if (Test-Path $icons) { Copy-Item (Join-Path $here 'ip-switch.ico') (Join-Path $icons 'ip-switch.ico') -Force }
(New-Icon 256).Save((Join-Path $env:TEMP 'ip-switch-preview.png'))
"ok"
