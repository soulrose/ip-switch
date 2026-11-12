# Builds dist\IpSwitch.exe (version from VERSION): one portable exe with the app files (no config.json, so each PC reads its own
# IP on first run) embedded as a zip, compiled with the C# compiler that ships with Windows.
#   powershell -ExecutionPolicy Bypass -File portable\build-portable.ps1
$ErrorActionPreference = 'Stop'
$app = Split-Path $PSScriptRoot
$ver = (Get-Content (Join-Path $app 'VERSION') -Raw).Trim()
# A window whose XAML does not parse never opens (the app just hangs hidden), so refuse to build one.
$errs = $null
$ast = [Management.Automation.Language.Parser]::ParseFile((Join-Path $app 'IpSwitch.ps1'), [ref]$null, [ref]$errs)
if ($errs.Count) { throw "IpSwitch.ps1 does not parse: $($errs[0].Message) (line $($errs[0].Extent.StartLineNumber))" }
foreach ($h in $ast.FindAll({ $args[0] -is [Management.Automation.Language.StringConstantExpressionAst] -and $args[0].Value -match '^\s*<Window' }, $true)) {
  try { [void][xml]$h.Value } catch { throw "XAML at line $($h.Extent.StartLineNumber) is broken: $($_.Exception.Message)" }
}

$files = 'IpSwitch.ps1', 'README.md', 'ip-switch.ico', 'VERSION'
$stage = Join-Path $env:TEMP 'ip-switch-portable'
if (Test-Path $stage) { Remove-Item -Recurse -Force $stage }
New-Item -ItemType Directory $stage | Out-Null
foreach ($f in $files) { Copy-Item (Join-Path $app $f) $stage }
$zip = Join-Path $env:TEMP 'ip-switch-payload.zip'
if (Test-Path $zip) { Remove-Item -Force $zip }
Compress-Archive -Path (Join-Path $stage '*') -DestinationPath $zip

$dist = Join-Path $app 'dist'
New-Item -ItemType Directory -Force $dist | Out-Null
$out = Join-Path $dist "IpSwitch.exe"   # fixed name: the in-app update replaces this file and downloads it by tag
$csc = Join-Path $env:WINDIR 'Microsoft.NET\Framework64\v4.0.30319\csc.exe'
if (-not (Test-Path $csc)) { $csc = Join-Path $env:WINDIR 'Microsoft.NET\Framework\v4.0.30319\csc.exe' }
& $csc /nologo /target:winexe /codepage:65001 "/win32icon:$(Join-Path $app 'ip-switch.ico')" `
  /reference:System.Windows.Forms.dll /reference:System.IO.Compression.dll /reference:System.IO.Compression.FileSystem.dll `
  "/resource:$zip,payload.zip" "/out:$out" (Join-Path $PSScriptRoot 'IpSwitch.cs')
if ($LASTEXITCODE -ne 0) { throw "csc failed ($LASTEXITCODE)" }
Remove-Item -Recurse -Force $stage, $zip
"portable: $out ($([math]::Round((Get-Item $out).Length / 1KB)) KB)"
