# Builds ScreenShot as a single self-contained .exe and installs it for the current user.
#   powershell -ExecutionPolicy Bypass -File windows\install.ps1
$ErrorActionPreference = 'Stop'
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$dest = Join-Path $env:LOCALAPPDATA 'Programs\ScreenShot'

# Use a dotnet that actually has an SDK (a runtime-only install can't build).
function Test-Sdk($exe) { $exe -and (Test-Path $exe) -and (& $exe --list-sdks 2>$null) }
$localDotnet = Join-Path $env:LOCALAPPDATA 'Microsoft\dotnet\dotnet.exe'
$dotnet = (Get-Command dotnet -ErrorAction SilentlyContinue).Source
if (-not (Test-Sdk $dotnet)) { $dotnet = $localDotnet }
if (-not (Test-Sdk $dotnet)) {
    Write-Host 'Installing .NET SDK (user-local)...'
    $s = Join-Path $env:TEMP 'dotnet-install.ps1'
    Invoke-WebRequest https://dot.net/v1/dotnet-install.ps1 -OutFile $s
    & $s -Channel LTS -InstallDir (Join-Path $env:LOCALAPPDATA 'Microsoft\dotnet')
}

$out = Join-Path $here 'publish'
& $dotnet publish (Join-Path $here 'src\ScreenShot.csproj') -c Release -o $out `
    --self-contained true -p:PublishSingleFile=true -p:EnableCompressionInSingleFile=true `
    -p:IncludeNativeLibrariesForSelfExtract=true -p:DebugType=none
if ($LASTEXITCODE -ne 0) { throw 'Build failed' }

Get-Process ScreenShot -ErrorAction SilentlyContinue | Stop-Process -Force
Start-Sleep -Milliseconds 500
New-Item -ItemType Directory -Force $dest | Out-Null
Copy-Item (Join-Path $out 'ScreenShot.exe') $dest -Force
$exe = Join-Path $dest 'ScreenShot.exe'

# Start Menu shortcut
$lnk = Join-Path ([Environment]::GetFolderPath('Programs')) 'ScreenShot.lnk'
$sh = New-Object -ComObject WScript.Shell
$sc = $sh.CreateShortcut($lnk); $sc.TargetPath = $exe; $sc.WorkingDirectory = $dest; $sc.Save()

# Launch at login (toggle off later from the tray menu)
$run = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run'
Set-ItemProperty $run -Name ScreenShot -Value "`"$exe`""

Start-Process $exe -ArgumentList '--welcome'
Write-Host "Installed to $exe"
