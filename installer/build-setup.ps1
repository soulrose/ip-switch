# Builds dist\IpSwitch-Setup.exe around the portable dist\IpSwitch.exe (build that first with portable\build-portable.ps1).
#   powershell -ExecutionPolicy Bypass -File installer\build-setup.ps1
$ErrorActionPreference = 'Stop'
$app = Split-Path $PSScriptRoot
$exe = Join-Path $app 'dist\IpSwitch.exe'
if (-not (Test-Path $exe)) { throw 'dist\IpSwitch.exe is missing: run portable\build-portable.ps1 first' }
$out = Join-Path $app 'dist\IpSwitch-Setup.exe'
$csc = Join-Path $env:WINDIR 'Microsoft.NET\Framework64\v4.0.30319\csc.exe'
if (-not (Test-Path $csc)) { $csc = Join-Path $env:WINDIR 'Microsoft.NET\Framework\v4.0.30319\csc.exe' }
& $csc /nologo /target:winexe /codepage:65001 "/win32icon:$(Join-Path $app 'ip-switch.ico')" `
  /reference:System.Windows.Forms.dll /reference:System.Drawing.dll `
  "/resource:$exe,IpSwitch.exe" "/resource:$(Join-Path $app 'VERSION'),VERSION" "/out:$out" (Join-Path $PSScriptRoot 'Setup.cs')
if ($LASTEXITCODE -ne 0) { throw "csc failed ($LASTEXITCODE)" }
"setup: $out ($([math]::Round((Get-Item $out).Length / 1KB)) KB)"
