# Brand Asset Generator
# ---------------------
# Takes one source image and generates:
#  - Background: 1920x1080 <300KB (JPEG)
#  - Header logo: 245x36 ≤10KB (PNG or JPEG fallback)
#  - Banner logo: 245x36 ≤50KB (PNG or JPEG fallback)
#  - Square logos (light/dark): 240x240 ≤50KB each
#  - Writes page background colour reference text file
#
# Compatible with Windows PowerShell 5.1+
# -------------------------------------------------------------------------

Add-Type -AssemblyName System.Drawing

param(
  [Parameter(Mandatory = $true)]
  [string]$InputImage,

  [Parameter(Mandatory = $true)]
  [string]$OutputDir,

  [string]$PageBgHex = "#FFFFFF",
  [string]$LightThemeBgHex = "#FFFFFF",
  [string]$DarkThemeBgHex = "#111111",

  [int]$BgMaxBytes = 300KB,
  [int]$HeaderMaxBytes = 10KB,
  [int]$BannerMaxBytes = 50KB,
  [int]$SquareMaxBytes = 50KB
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

#--- Helper: convert HEX to System.Drawing.Color
function Convert-HexToColor {
  param([string]$Hex)
  $h = $Hex.Trim()
  if ($h -notmatch '^#?[0-9A-Fa-f]{6}$') { throw "Invalid hex colour: $Hex" }
  if ($h.StartsWith('#')) { $h = $h.Substring(1) }
  $r = [Convert]::ToInt32($h.Substring(0, 2), 16)
  $g = [Convert]::ToInt32($h.Substring(2, 2), 16)
  $b = [Convert]::ToInt32($h.Substring(4, 2), 16)
  return [System.Drawing.Color]::FromArgb($r, $g, $b)
}

#--- Atomic write to avoid OneDrive lockups
function Save-Atomic {
  param(
    [Parameter(Mandatory)] [string]$FinalPath,
    [Parameter(Mandatory)] [ScriptBlock]$SaveAction
  )
  $dir = Split-Path -Parent $FinalPath
  if (!(Test-Path $dir)) { New-Item -ItemType Directory -Path $dir | Out-Null }

  $temp = Join-Path ([IO.Path]::GetTempPath()) ("img_" + [guid]::NewGuid().ToString("N") + [IO.Path]::GetExtension($FinalPath))
  try {
    & $SaveAction.InvokeReturnAsIs($temp)
    if (Test-Path $FinalPath) {
      Move-Item -Path $temp -Destination $FinalPath -Force
    } else {
      Move-Item -Path $temp -Destination $FinalPath
    }
  } catch {
    if (Test-Path $temp) { Remove-Item $temp -Force -ErrorAction SilentlyContinue }
    throw
  }
}

#--- Save JPEG under size cap
function Save-JpegWithSizeCap {
  param(
    [System.Drawing.Bitmap]$Bitmap,
    [string]$Path,
    [int]$MaxBytes,
    [int]$MinQuality = 35
  )
  $jpeg = [System.Drawing.Imaging.ImageCodecInfo]::GetImageEncoders() | Where-Object { $_.MimeType -eq "image/jpeg" }
  $encParams = New-Object System.Drawing.Imaging.EncoderParameters(1)
  $qEnc = [System.Drawing.Imaging.Encoder]::Quality

  foreach ($q in 95,90,85,80,75,70,65,60,55,50,45,40,38,36,$MinQuality) {
    $encParams.Param[0] = New-Object System.Drawing.Imaging.EncoderParameter($qEnc, [int64]$q)
    $tmpOut = Join-Path ([IO.Path]::GetTempPath()) ("try_" + [guid]::NewGuid().ToString("N") + ".jpg")
    try {
      $Bitmap.Save($tmpOut, $jpeg, $encParams)
      $len = (Get-Item $tmpOut).Length
      if ($len -le $MaxBytes) {
        Save-Atomic -FinalPath $Path -SaveAction { param($p) Copy-Item $tmpOut $p -Force }
        Remove-Item $tmpOut -Force
        return $true
      }
    } finally {
      if (Test-Path $tmpOut) { Remove-Item $tmpOut -Force -ErrorAction SilentlyContinue }
    }
  }
  # fallback best effort
  $bestTmp = Join-Path ([IO.Path]::GetTempPath()) ("best_" + [guid]::NewGuid().ToString("N") + ".jpg")
  try {
    $encParams.Param[0] = New-Object System.Drawing.Imaging.EncoderParameter($qEnc, [int64]$MinQuality)
    $Bitmap.Save($bestTmp, $jpeg, $encParams)
    Save-Atomic -FinalPath $Path -SaveAction { param($p) Copy-Item $bestTmp $p -Force }
  } finally {
    if (Test-Path $bestTmp) { Remove-Item $bestTmp -Force -ErrorAction SilentlyContinue }
  }
  return $false
}

#--- Save PNG or fallback to JPEG if too large
function Save-PngOrFallbackJpeg {
  param(
    [System.Drawing.Bitmap]$Bitmap,
    [string]$BasePathWithoutExt,
    [int]$MaxBytes,
    [System.Drawing.Color]$FillForJpeg
  )
  $pngPath = "$BasePathWithoutExt.png"
  $jpgPath = "$BasePathWithoutExt.jpg"

  Save-Atomic -FinalPath $pngPath -SaveAction {
    param($p) $Bitmap.Save($p, [System.Drawing.Imaging.ImageFormat]::Png)
  }
  if ((Get-Item $pngPath).Length -le $MaxBytes) {
    if (Test-Path $jpgPath) { Remove-Item $jpgPath -Force -ErrorAction SilentlyContinue }
    return $pngPath
  }

  # fallback JPEG
  $canvas = New-Object System.Drawing.Bitmap($Bitmap.Width, $Bitmap.Height, [System.Drawing.Imaging.PixelFormat]::Format24bppRgb)
  $g = [System.Drawing.Graphics]::FromImage($canvas)
  try {
    $g.Clear($FillForJpeg)
    $g.DrawImage($Bitmap, 0, 0, $Bitmap.Width, $Bitmap.Height)
  } finally { $g.Dispose() }

  try {
    if (!(Save-JpegWithSizeCap -Bitmap $canvas -Path $jpgPath -MaxBytes $MaxBytes)) {
      $sizes = @()
      if (Test-Path $pngPath) { $sizes += [pscustomobject]@{ Path=$pngPath; Size=(Get-Item $pngPath).Length } }
      if (Test-Path $jpgPath) { $sizes += [pscustomobject]@{ Path=$jpgPath; Size=(Get-Item $jpgPath).Length } }
      $keep = $sizes | Sort-Object Size | Select-Object -First 1
      foreach ($p in @($pngPath, $jpgPath)) {
        if ($p -ne $keep.Path -and (Test-Path $p)) { Remove-Item $p -Force -ErrorAction SilentlyContinue }
      }
      return $keep.Path
    } else {
      if (Test-Path $pngPath) { Remove-Item $pngPath -Force -ErrorAction SilentlyContinue }
      return $jpgPath
    }
  } finally {
    $canvas.Dispose()
  }
}

#--- Resize + pad to exact canvas
function Resize-And-Pad {
  param(
    [System.Drawing.Image]$Src,
    [int]$TargetW,
    [int]$TargetH,
    [System.Drawing.Color]$BgColor
  )
  $scale = [Math]::Min($TargetW / $Src.Width, $TargetH / $Src.Height)
  $newW = [int][Math]::Round($Src.Width * $scale)
  $newH = [int][Math]::Round($Src.Height * $scale)
  $bmp = New-Object System.Drawing.Bitmap($TargetW, $TargetH, [System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
  $g = [System.Drawing.Graphics]::FromImage($bmp)
  try {
    $g.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::HighQuality
    $g.InterpolationMode = [System.Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic
    $g.PixelOffsetMode = [System.Drawing.Drawing2D.PixelOffsetMode]::HighQuality
    $g.Clear($BgColor)
    $g.DrawImage($Src, [int](($TargetW - $newW) / 2), [int](($TargetH - $newH) / 2), $newW, $newH)
  } finally { $g.Dispose() }
  return $bmp
}

#--- Fit exact (logos)
function Resize-FitExact {
  param(
    [System.Drawing.Image]$Src,
    [int]$TargetW,
    [int]$TargetH,
    [System.Drawing.Color]$BgColor
  )
  $scale = [Math]::Min($TargetW / $Src.Width, $TargetH / $Src.Height)
  $newW = [int][Math]::Round($Src.Width * $scale)
  $newH = [int][Math]::Round($Src.Height * $scale)
  $bmp = New-Object System.Drawing.Bitmap($TargetW, $TargetH, [System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
  $g = [System.Drawing.Graphics]::FromImage($bmp)
  try {
    $g.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::HighQuality
    $g.InterpolationMode = [System.Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic
    $g.PixelOffsetMode = [System.Drawing.Drawing2D.PixelOffsetMode]::HighQuality
    $g.Clear($BgColor)
    $g.DrawImage($Src, [int](($TargetW - $newW) / 2), [int](($TargetH - $newH) / 2), $newW, $newH)
  } finally { $g.Dispose() }
  return $bmp
}

#--- Crop to centered square
function Crop-CenterSquare {
  param([System.Drawing.Image]$Src)
  $side = [Math]::Min($Src.Width, $Src.Height)
  $x = [int](($Src.Width - $side) / 2)
  $y = [int](($Src.Height - $side) / 2)
  $rect = New-Object System.Drawing.Rectangle($x, $y, $side, $side)
  $bmp = New-Object System.Drawing.Bitmap($side, $side, [System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
  $g = [System.Drawing.Graphics]::FromImage($bmp)
  try {
    $g.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::HighQuality
    $g.InterpolationMode = [System.Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic
    $g.PixelOffsetMode = [System.Drawing.Drawing2D.PixelOffsetMode]::HighQuality
    $g.DrawImage($Src, [System.Drawing.Rectangle]::new(0,0,$side,$side), $rect, [System.Drawing.GraphicsUnit]::Pixel)
  } finally { $g.Dispose() }
  return $bmp
}

#--- Prepare directories and colours
$pageBg  = Convert-HexToColor $PageBgHex
$lightBg = Convert-HexToColor $LightThemeBgHex
$darkBg  = Convert-HexToColor $DarkThemeBgHex

if (!(Test-Path $InputImage)) { throw "Input image not found: $InputImage" }
if (!(Test-Path $OutputDir)) { New-Item -ItemType Directory -Path $OutputDir | Out-Null }

$bgDir     = Join-Path $OutputDir "background"
$logoDir   = Join-Path $OutputDir "logos"
$squareDir = Join-Path $OutputDir "square"
New-Item -ItemType Directory -Force -Path $bgDir,$logoDir,$squareDir | Out-Null

#--- Load source image
$srcImg = [System.Drawing.Image]::FromFile((Resolve-Path $InputImage))
try {
  # Background 1920x1080
  Write-Host "Creating background..."
  $bgBmp = Resize-And-Pad -Src $srcImg -TargetW 1920 -TargetH 1080 -BgColor $pageBg
  $bgPath = Join-Path $bgDir "background_1920x1080.jpg"
  if (!(Save-JpegWithSizeCap -Bitmap $bgBmp -Path $bgPath -MaxBytes $BgMaxBytes)) {
    Write-Warning "Background exceeded $([int]($BgMaxBytes/1KB))KB cap."
  }
  $bgBmp.Dispose()

  # Header 245x36
  Write-Host "Creating header logo..."
  $hdrBmp = Resize-FitExact -Src $srcImg -TargetW 245 -TargetH 36 -BgColor $pageBg
  $null = Save-PngOrFallbackJpeg -Bitmap $hdrBmp -BasePathWithoutExt (Join-Path $logoDir "header_logo_245x36") -MaxBytes $HeaderMaxBytes -FillForJpeg $pageBg
  $hdrBmp.Dispose()

  # Banner 245x36
  Write-Host "Creating banner logo..."
  $banBmp = Resize-FitExact -Src $srcImg -TargetW 245 -TargetH 36 -BgColor $pageBg
  $null = Save-PngOrFallbackJpeg -Bitmap $banBmp -BasePathWithoutExt (Join-Path $logoDir "banner_logo_245x36") -MaxBytes $BannerMaxBytes -FillForJpeg $pageBg
  $banBmp.Dispose()

  # Square logos
  Write-Host "Creating square logos..."
  $sqBase = Crop-CenterSquare -Src $srcImg
  foreach ($theme in @(
    @{ Name="light"; Bg=$lightBg },
    @{ Name="dark";  Bg=$darkBg  }
  )) {
    $canvas = New-Object System.Drawing.Bitmap(240,240,[System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
    $g = [System.Drawing.Graphics]::FromImage($canvas)
    try {
      $g.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::HighQuality
      $g.InterpolationMode = [System.Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic
      $g.PixelOffsetMode = [System.Drawing.Drawing2D.PixelOffsetMode]::HighQuality
      $g.Clear($theme.Bg)
      $g.DrawImage($sqBase,0,0,240,240)
    } finally { $g.Dispose() }
    $outBase = Join-Path $squareDir "square_logo_${($theme.Name)}_240x240"
    $null = Save-PngOrFallbackJpeg -Bitmap $canvas -BasePathWithoutExt $outBase -MaxBytes $SquareMaxBytes -FillForJpeg $theme.Bg
    $canvas.Dispose()
  }
  $sqBase.Dispose()

  "Page background colour: $PageBgHex" | Out-File -Encoding utf8 -FilePath (Join-Path $OutputDir "page_background_colour.txt") -Force
  Write-Host "All assets generated successfully in: $OutputDir" -ForegroundColor Green
}
finally {
  $srcImg.Dispose()
}
