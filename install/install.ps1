# Installs or updates PaceCoach (and the small PaceCheck diagnostic app) in
# Assetto Corsa. Start it by double-clicking "Install PaceCoach.bat".
#
# What it does:
#   1. Finds your Assetto Corsa folder through Steam, or asks you for it.
#   2. Takes PaceCoach from the folder next to this script, or, when there is
#      none (or with -Latest), downloads the newest version from GitHub.
#   3. Moves any PaceCoach folders already in apps\lua out of the way (into
#      apps\PaceCoach-old-<date>, nothing is deleted) and copies the new one
#      in under the one name the game accepts.
# Your saved laps are in Documents\Assetto Corsa\PaceCoach and are not touched.

param(
  [string]$AcRoot = '',
  [switch]$Latest
)

$ErrorActionPreference = 'Stop'
$repoZip = 'https://github.com/ptonik/PaceCoach/archive/refs/heads/main.zip'

function Say {
  param([string]$Text = '', [string]$Color = 'Gray')
  Write-Host $Text -ForegroundColor $Color
}

function Test-AcRoot {
  param([string]$Path)
  if (-not $Path) { return $false }
  if (-not (Test-Path -LiteralPath $Path)) { return $false }
  return (Test-Path -LiteralPath (Join-Path $Path 'acs.exe')) -or
    (Test-Path -LiteralPath (Join-Path $Path 'AssettoCorsa.exe'))
}

function Find-AssettoCorsa {
  $steamDirs = @()
  foreach ($key in @('HKCU:\Software\Valve\Steam', 'HKLM:\SOFTWARE\WOW6432Node\Valve\Steam', 'HKLM:\SOFTWARE\Valve\Steam')) {
    try {
      $props = Get-ItemProperty -Path $key -ErrorAction Stop
      foreach ($name in @('SteamPath', 'InstallPath')) {
        $value = $props.$name
        if ($value) { $steamDirs += ($value -replace '/', '\') }
      }
    } catch { }
  }
  $steamDirs += 'C:\Program Files (x86)\Steam'
  $steamDirs += 'C:\Program Files\Steam'

  $libraries = @()
  foreach ($steam in ($steamDirs | Select-Object -Unique)) {
    $libraries += $steam
    $vdf = Join-Path $steam 'steamapps\libraryfolders.vdf'
    if (Test-Path -LiteralPath $vdf) {
      foreach ($line in (Get-Content -LiteralPath $vdf)) {
        if ($line -match '"path"\s+"([^"]+)"') {
          $libraries += ($Matches[1] -replace '\\\\', '\')
        }
      }
    }
  }
  foreach ($library in ($libraries | Select-Object -Unique)) {
    $candidate = Join-Path $library 'steamapps\common\assettocorsa'
    if (Test-AcRoot $candidate) { return $candidate }
  }
  return $null
}

function Test-AppFolder {
  param([string]$Path)
  if (-not $Path) { return $false }
  return (Test-Path -LiteralPath (Join-Path $Path 'manifest.ini')) -and
    (Test-Path -LiteralPath (Join-Path $Path 'PaceCoach.lua')) -and
    (Test-Path -LiteralPath (Join-Path $Path 'src\app.lua'))
}

$temp = $null
try {
  Say
  Say 'PaceCoach installer' 'Cyan'
  Say

  if (Get-Process -Name 'acs' -ErrorAction SilentlyContinue) {
    throw 'Assetto Corsa is running. Close the game and start this again.'
  }

  # 1. The game.
  $ac = $AcRoot
  if (-not (Test-AcRoot $ac)) { $ac = Find-AssettoCorsa }
  while (-not (Test-AcRoot $ac)) {
    Say 'Assetto Corsa was not found automatically.' 'Yellow'
    Say 'In Steam: right-click Assetto Corsa, Manage, Browse local files, and copy the path of that folder.'
    $answer = Read-Host 'Paste the path of your assettocorsa folder here (or just press Enter to stop)'
    if (-not $answer) { throw 'No Assetto Corsa folder was given.' }
    $ac = $answer.Trim().Trim('"')
  }
  Say "Assetto Corsa:  $ac"
  if (-not (Test-Path -LiteralPath (Join-Path $ac 'extension'))) {
    Say 'Note: Custom Shaders Patch does not seem to be installed. PaceCoach needs it (install it from Content Manager).' 'Yellow'
  }
  $lua = Join-Path $ac 'apps\lua'
  if (-not (Test-Path -LiteralPath $lua)) { New-Item -ItemType Directory -Path $lua | Out-Null }

  # 2. The files to install.
  $source = $null
  if (-not $Latest) {
    foreach ($dir in @((Join-Path $PSScriptRoot 'PaceCoach'), (Split-Path -Parent $PSScriptRoot))) {
      if (Test-AppFolder $dir) { $source = $dir; break }
    }
  }
  if (-not $source) {
    Say 'Downloading the newest PaceCoach from GitHub...'
    $temp = Join-Path $env:TEMP ('PaceCoach-install-' + [Guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $temp | Out-Null
    $zip = Join-Path $temp 'PaceCoach.zip'
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    Invoke-WebRequest -Uri $repoZip -OutFile $zip -UseBasicParsing
    Expand-Archive -LiteralPath $zip -DestinationPath $temp
    $source = Join-Path $temp 'PaceCoach-main'
    if (-not (Test-AppFolder $source)) { throw 'The download did not contain PaceCoach.' }
  }
  $version = 'unknown'
  $match = Select-String -LiteralPath (Join-Path $source 'manifest.ini') -Pattern '^VERSION\s*=\s*(\S+)' | Select-Object -First 1
  if ($match) { $version = $match.Matches[0].Groups[1].Value }
  Say "Installing:     PaceCoach $version"

  $checkSource = $null
  foreach ($dir in @((Join-Path $PSScriptRoot 'PaceCheck'), (Join-Path $source 'extras\PaceCheck'))) {
    if (Test-Path -LiteralPath (Join-Path $dir 'PaceCheck.lua')) { $checkSource = $dir; break }
  }

  # 3. Move older copies out of the way. Nothing is deleted.
  $old = @(Get-ChildItem -LiteralPath $lua -Directory | Where-Object { $_.Name -like 'PaceCoach*' -or $_.Name -eq 'PaceCheck' })
  if ($old.Count -gt 0) {
    $backup = Join-Path $ac ('apps\PaceCoach-old-' + (Get-Date -Format 'yyyyMMdd-HHmmss'))
    New-Item -ItemType Directory -Path $backup | Out-Null
    foreach ($dir in $old) {
      Move-Item -LiteralPath $dir.FullName -Destination (Join-Path $backup $dir.Name)
      Say "Moved the old '$($dir.Name)' folder to $backup"
    }
  }

  # 4. Copy the new one in, under the name the game expects.
  $target = Join-Path $lua 'PaceCoach'
  New-Item -ItemType Directory -Path $target | Out-Null
  foreach ($name in @('manifest.ini', 'icon.png', 'PaceCoach.lua', 'PaceCoach-main.lua', 'README.md', 'LICENSE')) {
    $from = Join-Path $source $name
    if (Test-Path -LiteralPath $from) { Copy-Item -LiteralPath $from -Destination $target }
  }
  foreach ($name in @('src', 'sounds')) {
    Copy-Item -LiteralPath (Join-Path $source $name) -Destination $target -Recurse
  }
  if (-not (Test-AppFolder $target)) { throw "Copying to $target did not complete." }
  if ($checkSource) { Copy-Item -LiteralPath $checkSource -Destination (Join-Path $lua 'PaceCheck') -Recurse }

  Say
  Say "Done. PaceCoach $version is in $target" 'Green'
  Say 'Start a session, move the mouse to the right edge of the screen and click PaceCoach.'
  Say 'If its window stays empty, open PaceCheck from the same bar and send a screenshot of it.'
  if ($old.Count -gt 0) { Say 'The folder with the old copies can be deleted whenever you like.' }
} catch {
  Say
  Say ('Stopped: ' + $_.Exception.Message) 'Red'
  exit 1
} finally {
  if ($temp -and (Test-Path -LiteralPath $temp)) {
    Remove-Item -LiteralPath $temp -Recurse -Force -ErrorAction SilentlyContinue
  }
}
