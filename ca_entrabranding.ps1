<# 
.SYNOPSIS
  Brand asset generator.

.DESCRIPTION
  From a single input image, produce:
   - Background image 1920x1080 (<300KB, JPEG)
   - Header logo 245x36 (≤10KB target; PNG first, fall back to JPEG if needed)
   - Banner logo 245x36 (≤50KB target; PNG first, fall back to JPEG if needed)
   - Square logo (light) 240x240 (≤50KB target)
   - Square logo (dark)  240x240 (≤50KB target)
  Also writes page background colour to a small text file for reference.

.NOTES
  Requires Windows PowerShell 5.1+ on Windows (uses System.Drawing).
#>

param(
  [Parameter(Mandatory=$true)]
  [string]$InputImage,

  [Parameter(Mandatory=$true)]
  [string]$OutputDir,

  # Page background colour (used to pad images / wallpapers), e.g. "#FFFFFF"
  [string]$PageBgHex = "#FFFFFF",

  # Light and dark theme backdrop colours for square logos
  [string]$LightThemeBgHex = "#FFFFFF",
  [string]$DarkThemeBgHex  = "#111111",

  # Optional: override file size caps (bytes)
  [int]$BgMaxBytes      = 300KB,
  [int]$HeaderMaxBytes  = 10KB,
  [int]$BannerMaxBytes  = 50KB,
  [int]$SquareMaxBytes  = 50KB
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

# Ensure System.Drawing is available
Add-Type -AssemblyName System.Drawing

function Convert-HexToColor {
  param([string]$Hex)
  $h = $Hex.Trim()
  if ($h -notmatch '^#?[0-9A-Fa-f]{6}$') { throw "Invalid hex colour: $Hex" }
  if ($h.StartsWith('#')) { $h = $h.Substring(1) }
  $r = [Convert]::ToInt32($h.Substring(0,2),16)
  $g = [Convert]::ToInt32($h.Substring(2,2),16)
  $b = [Convert]::ToInt32($h.Substring(4,2),16)
  return [System.Drawing.Color]::FromArgb($r,$g,$b)
}

function Get-ImageCodec([string]$mime) {
  return [System.Drawing.Imaging.ImageCodecInfo]::GetImageEncoders() |
    Where-Object { $_.MimeType -eq $mime }
}

function Save-JpegWithSizeCap {
  param(
    [System.Drawing.Bitmap]$Bitmap,
    [string]$Path,
    [int]$MaxBytes,
    [int]$MinQuality = 35
  )
  $jpeg = Get-ImageCodec "image/jpeg"
  $params = New-Object System.Drawing.Imaging.EncoderParameters(1)
  # Start high, step down
  foreach ($q in 95,90,85,80,75,70,65,60,55,50,45,40,38,36,$MinQuality) {
    $qval = [System.Drawing.Imaging.Encoder]::Quality
    $params.Param[0] = New-Object System.Drawing.Imaging.EncoderParameter($qval, [int64]$q)
    $Bitmap.Save($Path, $jpeg, $params)
    $size = (Get-Item $Path).Length
    if ($size -le $MaxBytes) { return $true }
  }
  return $false
}

function Save-PngOrFallbackJpeg {
  param(
    [System.Drawing.Bitmap]$Bitmap,
    [string]$BasePathWithoutExt,
    [int]$MaxBytes,
    [System.Drawing.Color]$FillForJpeg
  )
  $pngPath = "$BasePathWithoutExt.png"
  $jpgPath = "$BasePathWithoutExt.jpg"

  # Try PNG first
  $Bitmap.Save($pngPath, [System.Drawing.Imaging.ImageFormat]::Png)
  if ((Get-Item $pngPath).Length -le $MaxBytes) {
    return $pngPath
  }

  # Fallback to JPEG on a flattened white/dark background (logos rarely need alpha)
  using namespace System.Drawing
  $canvas = New-Object Bitmap($Bitmap.Width, $Bitmap.Height, [System.Drawing.Imaging.PixelFormat]::Format24bppRgb)
  $g = [Graphics]::FromImage($canvas)
  try {
    $g.Clear($FillForJpeg)
    $g.DrawImage($Bitmap, 0, 0, $Bitmap.Width, $Bitmap.Height)
  } finally { $g.Dispose() }

  if (!(Save-JpegWithSizeCap -Bitmap $canvas -Path $jpgPath -MaxBytes $MaxBytes)) {
    Write-Warning "Could not meet size cap for $BasePathWithoutExt (PNG and JPEG). Keeping the smallest."
    $smallest = @($pngPath, $jpgPath | Where-Object { Test-Path $_ }) | Sort-Object { (Get-Item $_).Length } | Select-Object -First 1
    if ($smallest -ne $jpgPath -and (Test-Path $jpgPath)) { Remove-Item $jpgPath -Force }
    if ($smallest -ne $pngPath -and (Test-Path $pngPath)) { Remove-Item $pngPath -Force }
    $canvas.Dispose()
    return $smallest
  } else {
    if (Test-Path $pngPath) { Remove-Item $pngPath -Force }
    $canvas.Dispose()
    return $jpgPath
  }
}

function Resize-And-Pad {
  param(
    [System.Drawing.Image]$Src,
    [int]$TargetW,
    [int]$TargetH,
    [System.Drawing.Color]$BgColor
  )
  using namespace System.Drawing
  $scale = [Math]::Min($TargetW / $Src.Width, $TargetH / $Src.Height)
  if ($scale -le 0) { throw "Invalid scale computation." }
  $newW = [int][Math]::Round($Src.Width  * $scale)
  $newH = [int][Math]::Round($Src.Height * $scale)

  $bmp = New-Object Bitmap($TargetW, $TargetH, [System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
  $g = [Graphics]::FromImage($bmp)
  try {
    $g.SmoothingMode  = [Drawing2D.SmoothingMode]::HighQuality
    $g.InterpolationMode = [Drawing2D.InterpolationMode]::HighQualityBicubic
    $g.PixelOffsetMode   = [Drawing2D.PixelOffsetMode]::HighQuality
    $g.Clear($BgColor)
    $offsetX = [int](($TargetW - $newW) / 2)
    $offsetY = [int](($TargetH - $newH) / 2)
    $g.DrawImage($Src, $offsetX, $offsetY, $newW, $newH)
  } finally { $g.Dispose() }
  return $bmp
}

function Resize-FitExact {
  param(
    [System.Drawing.Image]$Src,
    [int]$TargetW,
    [int]$TargetH,
    [System.Drawing.Color]$BgColor
  )
  # This version prefers *fitting height* for very wide logos to avoid excessive horizontal padding.
  $fitByHeight = ($Src.Width / [double]$Src.Height) -gt ($TargetW / [double]$TargetH)
  using namespace System.Drawing

  if ($fitByHeight) {
    $scale = $TargetH / $Src.Height
  } else {
    $scale = $TargetW / $Src.Width
  }

  $newW = [int][Math]::Round($Src.Width  * $scale)
  $newH = [int][Math]::Round($Src.Height * $scale)

  $bmp = New-Object Bitmap($TargetW, $TargetH, [System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
  $g = [Graphics]::FromImage($bmp)
  try {
    $g.SmoothingMode  = [Drawing2D.SmoothingMode]::HighQuality
    $g.InterpolationMode = [Drawing2D.InterpolationMode]::HighQualityBicubic
    $g.PixelOffsetMode   = [Drawing2D.PixelOffsetMode]::HighQuality
    $g.Clear($BgColor)
    $offsetX = [int](($TargetW - $newW) / 2)
    $offsetY = [int](($TargetH - $newH) / 2)
    $g.DrawImage($Src, $offsetX, $offsetY, $newW, $newH)
  } finally { $g.Dispose() }
  return $bmp
}

function Crop-CenterSquare {
  param([System.Drawing.Image]$Src)
  $side = [Math]::Min($Src.Width, $Src.Height)
  $x = [int](($Src.Width  - $side) / 2)
  $y = [int](($Src.Height - $side) / 2)

  $rect = New-Object System.Drawing.Rectangle($x,$y,$side,$side)
  $bmp = New-Object System.Drawing.Bitmap($side, $side, [System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
  $g = [System.Drawing.Graphics]::FromImage($bmp)
  try {
    $g.SmoothingMode  = [System.Drawing.Drawing2D.SmoothingMode]::HighQuality
    $g.InterpolationMode = [System.Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic
    $g.PixelOffsetMode   = [System.Drawing.Drawing2D.PixelOffsetMode]::HighQuality
    $g.DrawImage($Src, [System.Drawing.Rectangle]::new(0,0,$side,$side), $rect, [System.Drawing.GraphicsUnit]::Pixel)
  } finally { $g.Dispose() }
  return $bmp
}

# Prepare colours and IO
$pageBg   = Convert-HexToColor $PageBgHex
$lightBg  = Convert-HexToColor $LightThemeBgHex
$darkBg   = Convert-HexToColor $DarkThemeBgHex

if (!(Test-Path $InputImage)) { throw "Input image not found: $InputImage" }
if (!(Test-Path $OutputDir)) { New-Item -ItemType Directory -Path $OutputDir | Out-Null }

# Subfolders
$bgDir     = Join-Path $OutputDir "background"
$logoDir   = Join-Path $OutputDir "logos"
$squareDir = Join-Path $OutputDir "square"
New-Item -ItemType Directory -Force -Path $bgDir,$logoDir,$squareDir | Out-Null

# Load once
$srcImg = [System.Drawing.Image]::FromFile((Resolve-Path $InputImage))

try {
  # 1) Background 1920x1080, JPEG, <300KB
  $bgBmp = Resize-And-Pad -Src $srcImg -TargetW 1920 -TargetH 1080 -BgColor $pageBg
  $bgPath = Join-Path $bgDir "background_1920x1080.jpg"
  if (!(Save-JpegWithSizeCap -Bitmap $bgBmp -Path $bgPath -MaxBytes $BgMaxBytes)) {
    Write-Warning "Background could not be reduced under $([int]($BgMaxBytes/1KB))KB. Saved the smallest achievable JPEG."
  }
  $bgBmp.Dispose()

  # 2) Header logo 245x36 (try PNG then fallback to JPEG to meet ≤10KB)
  $hdrBmp = Resize-FitExact -Src $srcImg -TargetW 245 -TargetH 36 -BgColor $pageBg
  $null = Save-PngOrFallbackJpeg -Bitmap $hdrBmp `
            -BasePathWithoutExt (Join-Path $logoDir "header_logo_245x36") `
            -MaxBytes $HeaderMaxBytes -FillForJpeg $pageBg
  $hdrBmp.Dispose()

  # 3) Banner logo 245x36 (≤50KB)
  $banBmp = Resize-FitExact -Src $srcImg -TargetW 245 -TargetH 36 -BgColor $pageBg
  $null = Save-PngOrFallbackJpeg -Bitmap $banBmp `
            -BasePathWithoutExt (Join-Path $logoDir "banner_logo_245x36") `
            -MaxBytes $BannerMaxBytes -FillForJpeg $pageBg
  $banBmp.Dispose()

  # 4) Square logos 240x240 (light/dark, ≤50KB each)
  $sqBase = Crop-CenterSquare -Src $srcImg

  foreach ($theme in @(
    @{ Name="light"; Bg=$lightBg },
    @{ Name="dark";  Bg=$darkBg  }
  )) {
    using namespace System.Drawing
    $canvas = New-Object Bitmap(240,240, [System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
    $g = [Graphics]::FromImage($canvas)
    try {
      $g.SmoothingMode  = [Drawing2D.SmoothingMode]::HighQuality
      $g.InterpolationMode = [Drawing2D.InterpolationMode]::HighQualityBicubic
      $g.PixelOffsetMode   = [Drawing2D.PixelOffsetMode]::HighQuality
      $g.Clear($theme.Bg)

      # Fit the cropped square to 240x240
      $g.DrawImage($sqBase, 0,0,240,240)
    } finally { $g.Dispose() }

    $outBase = Join-Path $squareDir "square_logo_${($theme.Name)}_240x240"
    $null = Save-PngOrFallbackJpeg -Bitmap $canvas -BasePathWithoutExt $outBase -MaxBytes $SquareMaxBytes -FillForJpeg $theme.Bg
    $canvas.Dispose()
  }

  $sqBase.Dispose()

  # 5) Write page background colour reference
  $metaPath = Join-Path $OutputDir "page_background_colour.txt"
  "Page background colour: $PageBgHex" | Out-File -Encoding utf8 -FilePath $metaPath -Force

  # 6) Write Entra admin centre CSS helper snippet
  $cssPath = Join-Path $OutputDir "entra_branding.css"
  $cssContent = @'
:root {
  --fontStack-monospace: "Monaspace Neon", ui-monospace, SFMono-Regular, "SF Mono", Menlo, Monaco, Consolas, "Liberation Mono", "Courier New", monospace;
  --tab-size-preference: 4;
}

pre,
code {
  tab-size: var(--tab-size-preference);
  font-family: var(--fontStack-monospace);
}
'@
  Set-Content -LiteralPath $cssPath -Value $cssContent -Encoding UTF8

  Write-Host "All assets generated in: $OutputDir" -ForegroundColor Green
}
finally {
  $srcImg.Dispose()
}
