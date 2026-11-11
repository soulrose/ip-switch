# IP Switch: moves this PC's static IP between LAN and Wi-Fi, or puts both back on DHCP.
#   IpSwitch.ps1                 window (asks for admin once; without it each button asks)
#   IpSwitch.ps1 -Apply Lan      switch from a shortcut/terminal (admin), also Wifi / Dhcp
#   IpSwitch.ps1 -Apply Lan -DryRun   show what would change, no admin needed
param(
  [ValidateSet('Lan', 'Wifi', 'Dhcp')][string]$Apply,
  [switch]$DryRun,
  [string]$ResultFile,
  [switch]$NoElevate,
  [string]$ConfigDir,
  [int]$WaitSeconds = 180,
  [string]$ExePath,
  [switch]$CheckUpdate,
  [switch]$Update
)
$ErrorActionPreference = 'Stop'
# Portable exe passes -ConfigDir (next to the exe); otherwise settings live next to this script.
$DataDir = $(if ($ConfigDir) { $ConfigDir } else { $PSScriptRoot })
$ConfigPath = Join-Path $DataDir 'config.json'
$SelfArgs = $(if ($ConfigDir) { " -ConfigDir `"$ConfigDir`"" } else { '' })
if ($ExePath) { $SelfArgs += " -ExePath `"$ExePath`"" }
$AppVersion = $(try { (Get-Content -LiteralPath (Join-Path $PSScriptRoot 'VERSION') -Raw).Trim() } catch { '0.0.0' })
$UpdateRepo = 'soulrose/ip-switch'

# Which adapter holds the static IP in each mode. Only one adapter is ever static, so the
# same IP + gateway never sit on two adapters at once.
$Modes = [ordered]@{
  Lan  = @{ Lan = 'Static'; Wifi = 'Dhcp' }
  Wifi = @{ Lan = 'Dhcp'; Wifi = 'Static' }
  Dhcp = @{ Lan = 'Dhcp'; Wifi = 'Dhcp' }
}
$ModeLabel = @{ Lan = 'LAN'; Wifi = 'Wi-Fi'; Dhcp = 'อัตโนมัติ (DHCP)' }

function Test-Admin {
  ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

# ---------- config ----------
function Get-DefaultConfig {
  [pscustomobject]@{ Ip = ''; Mask = '255.255.255.0'; Gateway = ''; Dns = @(); LanAdapter = ''; WifiAdapter = ''; WifiSsid = ''; LastWifiSsid = '' }
}

function Read-Config {
  $c = Get-DefaultConfig
  if (Test-Path $ConfigPath) {
    try {
      $j = [IO.File]::ReadAllText($ConfigPath, [Text.Encoding]::UTF8) | ConvertFrom-Json
      foreach ($p in $c.PSObject.Properties.Name) { if ($null -ne $j.$p) { $c.$p = $j.$p } }
    } catch {}
  }
  $c.Dns = @($c.Dns | Where-Object { $_ } | ForEach-Object { "$_".Trim() })
  return $c
}

function Save-Config($c) {
  [IO.File]::WriteAllText($ConfigPath, ($c | ConvertTo-Json), (New-Object Text.UTF8Encoding $false))
}

function ConvertTo-IPv4([string]$s) {
  $s = "$s".Trim(); $a = $null
  if ($s -match '^\d{1,3}(\.\d{1,3}){3}$' -and [ipaddress]::TryParse($s, [ref]$a)) { return $a }
  return $null
}

function Get-PrefixLength([string]$mask) {
  $m = ConvertTo-IPv4 $mask
  if (-not $m) { return -1 }
  $bits = ($m.GetAddressBytes() | ForEach-Object { [Convert]::ToString($_, 2).PadLeft(8, '0') }) -join ''
  if ($bits -notmatch '^1+0*$') { return -1 }
  return ($bits -replace '0', '').Length
}

# Thai error list; empty = the static settings are usable.
function Test-Config($c) {
  $err = @()
  $ip = ConvertTo-IPv4 $c.Ip; $gw = ConvertTo-IPv4 $c.Gateway; $m = ConvertTo-IPv4 $c.Mask; $pl = Get-PrefixLength $c.Mask
  if (-not $ip) { $err += 'IP ไม่ถูกต้อง' }
  if ($pl -lt 8 -or $pl -gt 30) { $err += 'Subnet mask ไม่ถูกต้อง' }
  if (-not $gw) { $err += 'Gateway ไม่ถูกต้อง' }
  if ($ip -and $gw -and $pl -ge 8) {
    $ib = $ip.GetAddressBytes(); $gb = $gw.GetAddressBytes(); $mb = $m.GetAddressBytes()
    if ((0..3 | Where-Object { ($ib[$_] -band $mb[$_]) -ne ($gb[$_] -band $mb[$_]) }).Count) { $err += 'Gateway ไม่อยู่วงเดียวกับ IP' }
    if ($c.Ip.Trim() -eq $c.Gateway.Trim()) { $err += 'IP ซ้ำกับ Gateway' }
  }
  if (-not $c.Dns.Count) { $err += 'ใส่ DNS อย่างน้อย 1 ตัว' }
  foreach ($d in $c.Dns) { if (-not (ConvertTo-IPv4 $d)) { $err += "DNS $d ไม่ถูกต้อง" } }
  return $err
}

# ---------- adapters ----------
function Get-PhysicalAdapters {
  @(Get-NetAdapter -Physical -ErrorAction SilentlyContinue |
    Where-Object { $_.PhysicalMediaType -in '802.3', 'Native 802.11', 'Wireless LAN' } | Sort-Object ifIndex)
}

# The configured adapter by name, else the first connected one of that kind.
function Resolve-Adapters($c) {
  $all = Get-PhysicalAdapters
  $pick = {
    param($name, $media)
    if ($name) { $hit = $all | Where-Object { $_.Name -eq $name } | Select-Object -First 1; if ($hit) { return $hit } }
    $all | Where-Object { $_.PhysicalMediaType -in $media } | Sort-Object { $_.Status -ne 'Up' }, ifIndex | Select-Object -First 1
  }
  @{ Lan = (& $pick $c.LanAdapter @('802.3')); Wifi = (& $pick $c.WifiAdapter @('Native 802.11', 'Wireless LAN')) }
}

# Persistent settings come from the registry (what survives a reboot and what the old scripts left behind);
# live address/gateway/DNS come from the IP stack.
function Get-IfState($ad) {
  $reg = Get-ItemProperty "HKLM:\SYSTEM\CurrentControlSet\Services\Tcpip\Parameters\Interfaces\$($ad.InterfaceGuid)" -ErrorAction SilentlyContinue
  $i = $ad.ifIndex
  [pscustomobject]@{
    Name          = $ad.Name
    Desc          = $ad.InterfaceDescription
    Up            = ($ad.Status -eq 'Up')
    Disabled      = ($ad.Status -eq 'Disabled')
    Dhcp          = ($reg.EnableDHCP -eq 1)
    StaticIp      = @($reg.IPAddress | Where-Object { $_ -and $_ -ne '0.0.0.0' })
    StaticMask    = @($reg.SubnetMask | Where-Object { $_ -and $_ -ne '0.0.0.0' })
    StaticGateway = @($reg.DefaultGateway | Where-Object { $_ })
    StaticDns     = @("$($reg.NameServer)" -split '[,\s]+' | Where-Object { $_ })
    LiveIp        = @(Get-NetIPAddress -InterfaceIndex $i -AddressFamily IPv4 -ErrorAction SilentlyContinue | Where-Object { $_.PrefixOrigin -ne 'WellKnown' } | ForEach-Object { $_.IPAddress })
    LiveGateway   = @(Get-NetRoute -InterfaceIndex $i -DestinationPrefix '0.0.0.0/0' -ErrorAction SilentlyContinue | ForEach-Object { $_.NextHop } | Where-Object { $_ -ne '0.0.0.0' })
  }
}

# The IP this PC uses now, as settings defaults: a saved static IP first (that is the IP to switch),
# else the live address of a connected card with a gateway.
function Get-CurrentIpSettings {
  $ads = @(Get-PhysicalAdapters)
  foreach ($ad in $ads) {
    $s = Get-IfState $ad
    if (-not $s.Dhcp -and $s.StaticIp.Count -and $s.StaticGateway.Count) {
      return @{ Ip = $s.StaticIp[0]; Mask = @($s.StaticMask)[0]; Gateway = $s.StaticGateway[0]; Dns = @($s.StaticDns); From = "Static ที่ $($ad.Name)" }
    }
  }
  foreach ($ad in ($ads | Where-Object { $_.Status -eq 'Up' })) {
    $cfg = Get-NetIPConfiguration -InterfaceIndex $ad.ifIndex -ErrorAction SilentlyContinue
    $addr = @($cfg.IPv4Address | Where-Object { $_.PrefixOrigin -ne 'WellKnown' })[0]
    $gw = @($cfg.IPv4DefaultGateway | ForEach-Object { $_.NextHop })[0]
    if ($addr -and $gw) {
      $bits = ('1' * $addr.PrefixLength).PadRight(32, '0')
      $mask = (0..3 | ForEach-Object { [Convert]::ToInt32($bits.Substring($_ * 8, 8), 2) }) -join '.'
      return @{ Ip = $addr.IPAddress; Mask = $mask; Gateway = $gw; Dns = @($cfg.DNSServer | Where-Object { $_.AddressFamily -eq 2 } | ForEach-Object { $_.ServerAddresses }); From = "$($ad.Name) (DHCP ตอนนี้)" }
    }
  }
  return $null
}

# Saved Wi-Fi profiles and the networks in range now (with best signal %). netsh prints English on these PCs;
# if parsing finds nothing the caller falls back to the Windows Wi-Fi picker.
function Get-WifiNetworks {
  $saved = @(netsh.exe wlan show profiles | ForEach-Object { if ($_ -match '^\s+All User Profile\s+:\s+(.+?)\s*$') { $Matches[1] } })
  $visible = @{}; $cur = $null
  foreach ($line in (netsh.exe wlan show networks mode=bssid)) {
    if ($line -match '^SSID \d+ : (.*?)\s*$') { $cur = $Matches[1] }
    elseif ($null -ne $cur -and $line -match '^\s+Signal\s+:\s+(\d+)%') {
      $sig = [int]$Matches[1]
      if (-not $visible.ContainsKey($cur) -or $visible[$cur] -lt $sig) { $visible[$cur] = $sig }
    }
  }
  @{ Saved = $saved; Visible = $visible }
}

function Get-CurrentSsid {
  foreach ($line in (netsh.exe wlan show interfaces)) { if ($line -match '^\s+SSID\s+:\s+(.+?)\s*$') { return $Matches[1] } }
  return ''
}

# Only the network chosen in settings or the last one a Wi-Fi switch worked on, never any saved network:
# a phone hotspot in range would otherwise get the static IP.
function Connect-PreferredWifi($c) {
  $w = Get-WifiNetworks
  foreach ($ssid in @($c.WifiSsid, $c.LastWifiSsid) | Where-Object { $_ } | Select-Object -Unique) {
    if ($w.Saved -contains $ssid -and $w.Visible.ContainsKey($ssid)) {
      netsh.exe wlan connect name="$ssid" | Out-Null
      return $ssid
    }
  }
  return ''
}

function Open-WifiPicker { try { Start-Process 'ms-availablenetworks:' } catch { Start-Process 'ms-settings:network-wifi' } }

function Test-Desired($s, [string]$want, $c) {
  if ($want -eq 'Static') {
    return (-not $s.Dhcp) -and ($s.StaticIp -join ',') -eq $c.Ip.Trim() -and ($s.StaticMask -join ',') -eq $c.Mask.Trim() -and
      ($s.StaticGateway -join ',') -eq $c.Gateway.Trim() -and ($s.StaticDns -join ',') -eq ($c.Dns -join ',')
  }
  return $s.Dhcp -and -not $s.StaticGateway.Count -and -not $s.StaticDns.Count -and -not $s.StaticIp.Count
}

# Snapshot for the window: the adapter states plus which mode (if any) they match right now.
function Get-Snapshot($c) {
  $ads = Resolve-Adapters $c
  $states = @{}
  foreach ($role in 'Lan', 'Wifi') { if ($ads[$role]) { $states[$role] = Get-IfState $ads[$role] } }
  $current = ''; $near = ''
  foreach ($mode in $Modes.Keys) {
    $match = $true
    foreach ($role in $states.Keys) { if (-not (Test-Desired $states[$role] $Modes[$mode][$role] $c)) { $match = $false } }
    if ($match -and $states.Count) { $current = $mode; break }
  }
  # Not an exact match: the mode whose static adapter is already right (the other one has leftovers).
  if (-not $current) {
    foreach ($mode in 'Lan', 'Wifi') {
      $s = $states[$mode]
      if ($s -and (Test-Desired $s 'Static' $c)) { $near = $mode }
    }
    if (-not $near -and $states.Count -and -not @($states.Values | Where-Object { -not $_.Dhcp }).Count) { $near = 'Dhcp' }
  }
  @{ States = $states; Current = $current; Near = $near }
}

# ---------- apply ----------
function Remove-DefaultRoutes([int]$i) {
  Get-NetRoute -InterfaceIndex $i -DestinationPrefix '0.0.0.0/0' -PolicyStore PersistentStore -ErrorAction SilentlyContinue | Remove-NetRoute -Confirm:$false -ErrorAction SilentlyContinue
  Get-NetRoute -InterfaceIndex $i -DestinationPrefix '0.0.0.0/0' -PolicyStore ActiveStore -ErrorAction SilentlyContinue | Remove-NetRoute -Confirm:$false -ErrorAction SilentlyContinue
}

function Set-Dhcp($ad) {
  $i = $ad.ifIndex
  Remove-DefaultRoutes $i
  Get-NetIPAddress -InterfaceIndex $i -AddressFamily IPv4 -PrefixOrigin Manual -ErrorAction SilentlyContinue | Remove-NetIPAddress -Confirm:$false -ErrorAction SilentlyContinue
  Set-NetIPInterface -InterfaceIndex $i -AddressFamily IPv4 -Dhcp Enabled
  Set-DnsClientServerAddress -InterfaceIndex $i -ResetServerAddresses
  if ($ad.Status -eq 'Up') { Start-Process ipconfig.exe -ArgumentList '/renew', "`"$($ad.Name)`"" -WindowStyle Hidden }
}

function Set-Static($ad, $c) {
  $i = $ad.ifIndex
  if ($ad.Status -eq 'Disabled') { Enable-NetAdapter -Name $ad.Name -Confirm:$false; Start-Sleep -Seconds 2 }
  # The same IP left on any other adapter blocks New-NetIPAddress and would answer ARP twice.
  Get-NetIPAddress -IPAddress $c.Ip.Trim() -ErrorAction SilentlyContinue | Where-Object { $_.InterfaceIndex -ne $i } | Remove-NetIPAddress -Confirm:$false -ErrorAction SilentlyContinue
  Remove-DefaultRoutes $i
  $note = ''
  try {
    Set-NetIPInterface -InterfaceIndex $i -AddressFamily IPv4 -Dhcp Disabled -PolicyStore PersistentStore
    Set-NetIPInterface -InterfaceIndex $i -AddressFamily IPv4 -Dhcp Disabled -PolicyStore ActiveStore
    Get-NetIPAddress -InterfaceIndex $i -AddressFamily IPv4 -ErrorAction SilentlyContinue | Where-Object { $_.PrefixOrigin -ne 'WellKnown' } | Remove-NetIPAddress -Confirm:$false -ErrorAction SilentlyContinue
    New-NetIPAddress -InterfaceIndex $i -AddressFamily IPv4 -IPAddress $c.Ip.Trim() -PrefixLength (Get-PrefixLength $c.Mask) -DefaultGateway $c.Gateway.Trim() | Out-Null
  } catch {
    # A disconnected Wi-Fi card can keep DHCP on in one store and refuse NetTCPIP ("Inconsistent parameters
    # PolicyStore PersistentStore and Dhcp Enabled"); netsh writes the saved config directly and accepts it.
    $note = "$($_.InvocationInfo.MyCommand.Name): $($_.Exception.Message)"
    $out = netsh.exe interface ipv4 set address name="$($ad.Name)" source=static address=$($c.Ip.Trim()) mask=$($c.Mask.Trim()) gateway=$($c.Gateway.Trim()) 2>&1
    if ($LASTEXITCODE -ne 0) { throw "netsh: $(($out | Out-String).Trim()) (หลังจาก $note)" }
  }
  Set-DnsClientServerAddress -InterfaceIndex $i -ServerAddresses $c.Dns
  return $note
}

# Test-Connection goes through WMI and throws "Generic failure" while the IP is changing; a plain .NET ping does not.
function Test-Reply([string]$hostIp) {
  $p = New-Object System.Net.NetworkInformation.Ping
  try { return $p.Send($hostIp, 1000).Status -eq 'Success' } catch { return $false } finally { $p.Dispose() }
}

# Idempotent: an adapter already in the wanted state is not touched, so pressing the current mode
# again only cleans up the other adapter.
function Invoke-Mode([string]$mode) {
  $c = Read-Config
  $log = New-Object System.Collections.Generic.List[string]
  $ok = $true
  if ($Modes[$mode].Values -contains 'Static') {
    $err = @(Test-Config $c)
    if ($err.Count) { return @{ Ok = $false; Log = @('ตั้งค่า IP ก่อน: ' + ($err -join ', ')) } }
  }
  $ads = Resolve-Adapters $c
  # The card that gets the static IP must be usable before anything changes; otherwise LAN would already be on
  # DHCP and the PC would end up with the static IP on neither card.
  $target = @($Modes[$mode].Keys | Where-Object { $Modes[$mode][$_] -eq 'Static' })[0]
  if ($target -and -not $ads[$target]) { return @{ Ok = $false; Log = @("ไม่พบการ์ด $($ModeLabel[$target]) ในเครื่องนี้ จึงไม่ได้เปลี่ยนอะไร") } }
  # Windows silently keeps DHCP on for a Wi-Fi card that is not connected (every NetTCPIP/netsh call "succeeds"
  # and changes nothing), so wait for the connection first. A wired card takes a static IP unplugged too.
  if ($target -eq 'Wifi' -and -not $DryRun) {
    $ad = $ads['Wifi']
    if ($ad.Status -ne 'Up' -and -not (Test-Desired (Get-IfState $ad) 'Static' $c)) {
      if ($ad.Status -eq 'Disabled') { Enable-NetAdapter -Name $ad.Name -Confirm:$false; $log.Add("เปิดการ์ด $($ad.Name)") }
      # From the window the connect/picker is done by the window itself; from the command line do it here.
      if (-not $ResultFile) {
        $ssid = Connect-PreferredWifi $c
        if ($ssid) { $log.Add("เชื่อมต่อ $ssid ที่บันทึกไว้") } else { Open-WifiPicker; $log.Add('เปิดรายการ Wi-Fi ให้เลือก') }
      }
      foreach ($w in 1..$WaitSeconds) { Start-Sleep -Seconds 1; $ad = Get-NetAdapter -InterfaceIndex $ad.ifIndex; if ($ad.Status -eq 'Up') { break } }
      if ($ad.Status -ne 'Up') {
        $log.Add("$($ad.Name) ยังไม่ได้เชื่อมต่อ จึงยังไม่ได้เปลี่ยนอะไร LAN ยังเหมือนเดิม เชื่อมต่อ Wi-Fi แล้วกดอีกครั้ง")
        $since = (Get-Date).AddMinutes(-5)
        $fail = @(11006, 8002 | ForEach-Object { Get-WinEvent -FilterHashtable @{ LogName = 'Microsoft-Windows-WLAN-AutoConfig/Operational'; Id = $_; StartTime = $since } -MaxEvents 1 -ErrorAction SilentlyContinue })[0]
        if ($fail) {
          $ssid = [regex]::Match($fail.Message, '(?m)^\s*(?:Network )?SSID:\s*(.+?)\s*$').Groups[1].Value
          $why = [regex]::Match($fail.Message, '(?m)^\s*(?:Reason|Failure Reason):\s*(.+?)\s*$').Groups[1].Value
          $log.Add("Wi-Fi ต่อ $ssid ไม่ผ่าน: $why")
          if ($why -match 'key exchange|security') { $log.Add("มักเกิดจากรหัส Wi-Fi ที่บันทึกไว้ไม่ตรง ให้ลืมเครือข่าย $ssid แล้วต่อใหม่พร้อมใส่รหัส") }
        }
        return @{ Ok = $false; Log = @($log) }
      }
      Start-Sleep -Seconds 2
      $ads['Wifi'] = $ad
    }
  }
  # DHCP first: the static IP has to leave the old adapter before it can go on the new one.
  $steps = foreach ($role in 'Lan', 'Wifi') {
    if (-not $ads[$role]) { $log.Add("ไม่พบการ์ด $($ModeLabel[$role]) ข้าม"); continue }
    @{ Role = $role; Want = $Modes[$mode][$role] }
  }
  foreach ($st in @($steps | Sort-Object { $_.Want -eq 'Static' })) {
    $ad = $ads[$st.Role]; $n = $ad.Name
    $wantText = $(if ($st.Want -eq 'Static') { "Static $($c.Ip)" } else { 'DHCP' })
    if (Test-Desired (Get-IfState $ad) $st.Want $c) { $log.Add("$n เป็น $wantText อยู่แล้ว"); continue }
    if ($DryRun) { $log.Add("[ทดลอง] $n -> $wantText"); continue }
    try {
      $t0 = Get-Date
      if ($st.Want -eq 'Static') {
        $note = Set-Static $ad $c
        if ($note) { $log.Add("$n ใช้ netsh แทน ($note)") }
      } else { Set-Dhcp $ad }
      $sec = [int]((Get-Date) - $t0).TotalSeconds
      if ($sec -gt 5) { $log.Add("$n ใช้เวลา $sec วินาที (Windows ตอบช้า)") }
      $ad = Get-NetAdapter -InterfaceIndex $ad.ifIndex
      if (Test-Desired (Get-IfState $ad) $st.Want $c) {
        $log.Add("$n -> $wantText เรียบร้อย")
        if ($st.Want -eq 'Static' -and $st.Role -eq 'Wifi') {
          $now = Get-CurrentSsid
          if ($now) { $log.Add("Wi-Fi: $now (ครั้งหน้าจะต่อให้อัตโนมัติ)"); $c2 = Read-Config; $c2.LastWifiSsid = $now; Save-Config $c2 }
        }
      }
      else { $log.Add("$n ตั้งเป็น $wantText แล้วแต่อ่านค่ากลับไม่ตรง"); $ok = $false }
    } catch { $log.Add("$n ผิดพลาด: $($_.Exception.Message)"); $ok = $false }
  }
  # The check after the switch only reports; it never turns a switch that worked into a failure.
  if (-not $DryRun) {
    try {
      ipconfig.exe /flushdns | Out-Null
      $role = @($Modes[$mode].Keys | Where-Object { $Modes[$mode][$_] -eq 'Static' })[0]
      if ($ok -and $role -and $ads[$role] -and (Get-NetAdapter -InterfaceIndex $ads[$role].ifIndex).Status -eq 'Up') {
        $reach = $false
        foreach ($try in 1..5) { Start-Sleep -Seconds 1; if (Test-Reply $c.Gateway.Trim()) { $reach = $true; break } }
        $log.Add($(if ($reach) { "ping Gateway $($c.Gateway) ได้" } else { "ping Gateway $($c.Gateway) ยังไม่ได้ (เพิ่งเปลี่ยน รอสักครู่หรือตรวจสาย/IP)" }))
      } elseif ($ok -and $role) { $log.Add("$($ModeLabel[$role]) ยังไม่ได้เชื่อมต่อ ค่าถูกตั้งไว้แล้ว ใช้ได้เมื่อเชื่อมต่อ") }
    } catch { $log.Add("ตรวจหลังเปลี่ยนไม่ได้: $($_.Exception.Message)") }
  }
  return @{ Ok = $ok; Log = @($log) }
}

# ---------- updates ----------
# Updates are git tags vX.Y.Z on the GitHub repo. The portable exe of each version is dist/IpSwitch.exe at that tag
# and its notes are the CHANGELOG.md section. PowerShell does the HTTP so the Windows proxy settings apply.
function Set-WebDefaults {
  [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
  $proxy = [Net.WebRequest]::GetSystemWebProxy(); $proxy.Credentials = [Net.CredentialCache]::DefaultCredentials
  [Net.WebRequest]::DefaultWebProxy = $proxy
}

function Get-UpdateInfo {
  Set-WebDefaults
  $ver = { param($v) $m = [regex]::Match("$v", '^v?(\d+)\.(\d+)\.(\d+)$'); if ($m.Success) { [version]"$($m.Groups[1]).$($m.Groups[2]).$($m.Groups[3])" } }
  $h = @{ 'User-Agent' = 'ip-switch-updater'; 'Accept' = 'application/vnd.github+json' }
  # PowerShell 5.1 hands a JSON array from Invoke-RestMethod down the pipe as ONE item; store it first so it is enumerated
  $all = Invoke-RestMethod -Uri "https://api.github.com/repos/$UpdateRepo/tags?per_page=100" -Headers $h -UseBasicParsing -TimeoutSec 15
  $tags = @($all | ForEach-Object { $_ } | Where-Object { & $ver $_.name })
  if (-not $tags) { return @{ Current = $AppVersion; Latest = ''; Newer = $false } }
  $tag = ($tags | Sort-Object { & $ver $_.name } -Descending | Select-Object -First 1).name
  $newer = (& $ver $tag) -gt (& $ver $AppVersion)
  $notes = ''
  if ($newer) {
    try {
      $wc = New-Object Net.WebClient; $wc.Encoding = [Text.Encoding]::UTF8; $wc.Headers['User-Agent'] = 'ip-switch-updater'
      $text = $wc.DownloadString("https://raw.githubusercontent.com/$UpdateRepo/$tag/CHANGELOG.md")
      $m = [regex]::Match($text, "(?ms)^## $([regex]::Escape($tag.TrimStart('v')))\b.*?(?=^## |\z)")
      if ($m.Success) { $notes = $m.Value.Trim() }
    } catch {}
  }
  @{ Current = $AppVersion; Latest = $tag.TrimStart('v'); Tag = $tag; Newer = $newer; Notes = $notes
     ExeUrl = "https://raw.githubusercontent.com/$UpdateRepo/$tag/dist/IpSwitch.exe"
     Page = "https://github.com/$UpdateRepo/blob/$tag/CHANGELOG.md" }
}

# The portable launcher has exited by the time the window is up, so its exe can be replaced in place.
function Install-Update([string]$url, [string]$exe) {
  Set-WebDefaults
  $tmp = "$exe.download"
  $wc = New-Object Net.WebClient; $wc.Headers['User-Agent'] = 'ip-switch-updater'
  $wc.DownloadFile($url, $tmp)
  $bytes = [IO.File]::ReadAllBytes($tmp)
  if ($bytes.Length -lt 20KB -or $bytes[0] -ne 0x4D -or $bytes[1] -ne 0x5A) { Remove-Item -LiteralPath $tmp -Force; throw 'ไฟล์ที่ดาวน์โหลดมาไม่ใช่ตัวโปรแกรม' }
  Move-Item -LiteralPath $tmp -Destination $exe -Force
}

# ---------- command line ----------
if ($CheckUpdate -or $Update) {
  [Console]::OutputEncoding = [Text.Encoding]::UTF8
  try { $u = Get-UpdateInfo } catch { Write-Host "ตรวจอัปเดตไม่ได้: $($_.Exception.Message)"; exit 1 }
  if ($CheckUpdate) { $u | ConvertTo-Json; exit 0 }
  if (-not $u.Newer) { Write-Host "เป็นเวอร์ชันล่าสุดแล้ว ($AppVersion)"; exit 0 }
  if (-not $ExePath) { Write-Host "มีเวอร์ชันใหม่ $($u.Latest) ดาวน์โหลดที่ $($u.ExeUrl)"; exit 1 }
  try { Install-Update $u.ExeUrl $ExePath; Write-Host "อัปเดตเป็น $($u.Latest) แล้ว: $ExePath"; exit 0 }
  catch { Write-Host "อัปเดตไม่ได้: $($_.Exception.Message)"; exit 1 }
}

if ($Apply) {
  $runLog = Join-Path $DataDir 'last-run.log'
  $who = "$([Security.Principal.WindowsIdentity]::GetCurrent().Name) admin=$(Test-Admin)"
  try { Add-Content -LiteralPath $runLog -Encoding UTF8 -Value "[$(Get-Date -f 'yyyy-MM-dd HH:mm:ss')] start $Apply dry=$DryRun $who result=$ResultFile" } catch {}
  if (-not $DryRun -and -not (Test-Admin)) { $r = @{ Ok = $false; Log = @('ต้องรันแบบ Run as administrator') } }
  else {
    try { $r = Invoke-Mode $Apply }
    catch { $r = @{ Ok = $false; Log = @("ผิดพลาด: $($_.Exception.Message) (บรรทัด $($_.InvocationInfo.ScriptLineNumber))") } }
  }
  try { Add-Content -LiteralPath $runLog -Encoding UTF8 -Value ("[$(Get-Date -f 'yyyy-MM-dd HH:mm:ss')] end ok=$($r.Ok)`r`n  " + ($r.Log -join "`r`n  ")) } catch {}
  if ($ResultFile) {
    try { [IO.File]::WriteAllText($ResultFile, ($r | ConvertTo-Json), (New-Object Text.UTF8Encoding $false)) }
    catch { try { Add-Content -LiteralPath $runLog -Encoding UTF8 -Value "  cannot write result: $($_.Exception.Message)" } catch {} }
  }
  else { $r.Log | ForEach-Object { Write-Host $_ } }
  exit $(if ($r.Ok) { 0 } else { 1 })
}

if (-not $NoElevate -and -not (Test-Admin)) {
  try {
    Start-Process powershell.exe -Verb RunAs -WindowStyle Hidden -ArgumentList "-NoProfile -STA -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$PSCommandPath`" -NoElevate$SelfArgs"
    exit
  } catch {}   # UAC declined: open anyway, each button asks for admin on its own
}

# ---------- window ----------
Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase
Add-Type @"
using System; using System.Runtime.InteropServices;
public static class IpSwitchDwm {
  [StructLayout(LayoutKind.Sequential)] public struct Margins { public int L, R, T, B; }
  [DllImport("dwmapi.dll")] public static extern int DwmExtendFrameIntoClientArea(IntPtr h, ref Margins m);
  [DllImport("dwmapi.dll")] public static extern int DwmSetWindowAttribute(IntPtr h, int attr, ref int value, int size);
  [DllImport("shell32.dll", CharSet = CharSet.Unicode)] public static extern int SetCurrentProcessExplicitAppUserModelID(string id);
}
"@
# Own taskbar identity, so the button shows this window's icon instead of being grouped under PowerShell.
[void][IpSwitchDwm]::SetCurrentProcessExplicitAppUserModelID('OffLab.IpSwitch')

[xml]$xaml = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="IP Switch" Width="520" SizeToContent="Height" ResizeMode="CanMinimize"
        WindowStartupLocation="CenterScreen" Background="Transparent"
        FontFamily="Segoe UI Variable Text, Segoe UI, Leelawadee UI" FontSize="13" Foreground="#FF1B1B1B">
  <Window.Resources>
    <Style x:Key="Tile" TargetType="Button">
      <Setter Property="Cursor" Value="Hand"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="Button">
            <Border x:Name="bd" CornerRadius="8" Background="#B3FFFFFF" BorderBrush="#1F000000" BorderThickness="1" Padding="12,14">
              <ContentPresenter/>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True"><Setter TargetName="bd" Property="Background" Value="#F2FFFFFF"/></Trigger>
              <Trigger Property="IsPressed" Value="True"><Setter TargetName="bd" Property="Background" Value="#80FFFFFF"/></Trigger>
              <Trigger Property="Tag" Value="on">
                <Setter TargetName="bd" Property="Background" Value="#FFE0EEF9"/>
                <Setter TargetName="bd" Property="BorderBrush" Value="#FF0067C0"/>
                <Setter TargetName="bd" Property="BorderThickness" Value="2"/>
              </Trigger>
              <Trigger Property="IsEnabled" Value="False"><Setter TargetName="bd" Property="Opacity" Value="0.55"/></Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>
    <Style x:Key="Btn" TargetType="Button">
      <Setter Property="Cursor" Value="Hand"/>
      <Setter Property="Foreground" Value="#FF1B1B1B"/>
      <Setter Property="Background" Value="#CCFFFFFF"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="Button">
            <Border x:Name="bd" CornerRadius="4" Background="{TemplateBinding Background}" BorderBrush="#1F000000" BorderThickness="1" Padding="14,5">
              <ContentPresenter HorizontalAlignment="Center"/>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True"><Setter TargetName="bd" Property="Opacity" Value="0.85"/></Trigger>
              <Trigger Property="IsEnabled" Value="False"><Setter TargetName="bd" Property="Opacity" Value="0.5"/></Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>
    <Style TargetType="TextBox">
      <Setter Property="Padding" Value="6,4"/>
      <Setter Property="Background" Value="#E6FFFFFF"/>
      <Setter Property="BorderBrush" Value="#33000000"/>
      <Setter Property="Margin" Value="0,0,0,6"/>
    </Style>
    <Style TargetType="ComboBox"><Setter Property="Margin" Value="0,0,0,6"/></Style>
    <Style x:Key="Badge" TargetType="Border">
      <Setter Property="Visibility" Value="Collapsed"/>
      <Setter Property="HorizontalAlignment" Value="Right"/>
      <Setter Property="VerticalAlignment" Value="Top"/>
      <Setter Property="Background" Value="#FF0067C0"/>
      <Setter Property="CornerRadius" Value="9"/>
      <Setter Property="Padding" Value="8,1,8,2"/>
    </Style>
    <Style x:Key="Card" TargetType="Border">
      <Setter Property="Background" Value="#99FFFFFF"/>
      <Setter Property="BorderBrush" Value="#14000000"/>
      <Setter Property="BorderThickness" Value="1"/>
      <Setter Property="CornerRadius" Value="8"/>
      <Setter Property="Padding" Value="14,10"/>
      <Setter Property="Margin" Value="0,0,0,12"/>
    </Style>
  </Window.Resources>
  <Border x:Name="Root" Padding="20,16,20,16">
    <StackPanel>
      <Grid Margin="0,0,0,14">
        <Grid.ColumnDefinitions><ColumnDefinition Width="Auto"/><ColumnDefinition/></Grid.ColumnDefinitions>
        <Image x:Name="HeadIcon" Width="36" Height="36" Margin="0,2,12,0" VerticalAlignment="Top" RenderOptions.BitmapScalingMode="HighQuality"/>
        <StackPanel Grid.Column="1">
          <TextBlock Text="สลับ IP" FontSize="20" FontWeight="SemiBold"/>
          <TextBlock x:Name="Now" Foreground="#FF5C5C5C" TextWrapping="Wrap"/>
        </StackPanel>
      </Grid>

      <Border x:Name="UpdateCard" Style="{StaticResource Card}" BorderBrush="#800067C0" Visibility="Collapsed">
        <DockPanel>
          <StackPanel DockPanel.Dock="Right" Orientation="Horizontal" VerticalAlignment="Center" Margin="10,0,0,0">
            <Button x:Name="UpdateNotesBtn" Style="{StaticResource Btn}" Content="ดูรายละเอียด" Margin="0,0,8,0"/>
            <Button x:Name="UpdateBtn" Style="{StaticResource Btn}" Background="#FF0067C0" Foreground="White" Content="อัปเดตเลย"/>
          </StackPanel>
          <StackPanel>
            <TextBlock x:Name="UpdateTitle" FontWeight="SemiBold"/>
            <TextBlock x:Name="UpdateText" Foreground="#FF5C5C5C" FontSize="12" TextWrapping="Wrap"/>
          </StackPanel>
        </DockPanel>
      </Border>

      <UniformGrid Columns="3" Margin="0,0,0,12">
        <Button x:Name="TileLan" Style="{StaticResource Tile}" Margin="0,0,6,0">
          <Grid>
            <StackPanel>
              <TextBlock Text="&#xE839;" FontFamily="Segoe Fluent Icons, Segoe MDL2 Assets" FontSize="22" Foreground="#FF0067C0"/>
              <TextBlock Text="สาย LAN" FontSize="15" FontWeight="SemiBold" Margin="0,8,0,0"/>
              <TextBlock Text="IP ไปอยู่ที่สาย" Foreground="#FF5C5C5C" FontSize="12" TextWrapping="Wrap"/>
            </StackPanel>
            <Border x:Name="BadgeLan" Style="{StaticResource Badge}"><TextBlock Text="ใช้อยู่" Foreground="White" FontSize="11"/></Border>
          </Grid>
        </Button>
        <Button x:Name="TileWifi" Style="{StaticResource Tile}" Margin="3,0,3,0">
          <Grid>
            <StackPanel>
              <TextBlock Text="&#xE701;" FontFamily="Segoe Fluent Icons, Segoe MDL2 Assets" FontSize="22" Foreground="#FF0067C0"/>
              <TextBlock Text="Wi-Fi" FontSize="15" FontWeight="SemiBold" Margin="0,8,0,0"/>
              <TextBlock Text="IP ไปอยู่ที่ Wi-Fi" Foreground="#FF5C5C5C" FontSize="12" TextWrapping="Wrap"/>
            </StackPanel>
            <Border x:Name="BadgeWifi" Style="{StaticResource Badge}"><TextBlock Text="ใช้อยู่" Foreground="White" FontSize="11"/></Border>
          </Grid>
        </Button>
        <Button x:Name="TileDhcp" Style="{StaticResource Tile}" Margin="6,0,0,0">
          <Grid>
            <StackPanel>
              <TextBlock Text="&#xE774;" FontFamily="Segoe Fluent Icons, Segoe MDL2 Assets" FontSize="22" Foreground="#FF0067C0"/>
              <TextBlock Text="อัตโนมัติ" FontSize="15" FontWeight="SemiBold" Margin="0,8,0,0"/>
              <TextBlock Text="DHCP ทั้งสองการ์ด" Foreground="#FF5C5C5C" FontSize="12" TextWrapping="Wrap"/>
            </StackPanel>
            <Border x:Name="BadgeDhcp" Style="{StaticResource Badge}"><TextBlock Text="ใช้อยู่" Foreground="White" FontSize="11"/></Border>
          </Grid>
        </Button>
      </UniformGrid>

      <Border Style="{StaticResource Card}" Padding="12,10">
        <StackPanel>
          <Grid Margin="0,0,0,10">
            <Grid.ColumnDefinitions><ColumnDefinition Width="Auto"/><ColumnDefinition/><ColumnDefinition Width="Auto"/></Grid.ColumnDefinitions>
            <Border Width="34" Height="34" CornerRadius="6" Background="#140067C0" Margin="0,0,12,0" VerticalAlignment="Top">
              <TextBlock x:Name="LanDot" Text="&#xE839;" FontFamily="Segoe Fluent Icons, Segoe MDL2 Assets" FontSize="17" HorizontalAlignment="Center" VerticalAlignment="Center"/>
            </Border>
            <StackPanel Grid.Column="1">
              <TextBlock x:Name="LanName" FontWeight="SemiBold"/>
              <TextBlock x:Name="LanInfo" Foreground="#FF5C5C5C" TextWrapping="Wrap"/>
            </StackPanel>
            <Border x:Name="LanPill" Grid.Column="2" CornerRadius="9" Padding="8,1,8,2" VerticalAlignment="Top" Margin="8,0,0,0">
              <TextBlock x:Name="LanConn" FontSize="11"/>
            </Border>
          </Grid>
          <Grid>
            <Grid.ColumnDefinitions><ColumnDefinition Width="Auto"/><ColumnDefinition/><ColumnDefinition Width="Auto"/></Grid.ColumnDefinitions>
            <Border Width="34" Height="34" CornerRadius="6" Background="#140067C0" Margin="0,0,12,0" VerticalAlignment="Top">
              <TextBlock x:Name="WifiDot" Text="&#xE701;" FontFamily="Segoe Fluent Icons, Segoe MDL2 Assets" FontSize="17" HorizontalAlignment="Center" VerticalAlignment="Center"/>
            </Border>
            <StackPanel Grid.Column="1">
              <TextBlock x:Name="WifiName" FontWeight="SemiBold"/>
              <TextBlock x:Name="WifiInfo" Foreground="#FF5C5C5C" TextWrapping="Wrap"/>
            </StackPanel>
            <Border x:Name="WifiPill" Grid.Column="2" CornerRadius="9" Padding="8,1,8,2" VerticalAlignment="Top" Margin="8,0,0,0">
              <TextBlock x:Name="WifiConn" FontSize="11"/>
            </Border>
          </Grid>
        </StackPanel>
      </Border>

      <Border x:Name="LogCard" Style="{StaticResource Card}" Padding="0" Visibility="Collapsed">
        <Grid>
          <Grid.ColumnDefinitions><ColumnDefinition Width="4"/><ColumnDefinition/></Grid.ColumnDefinitions>
          <Border x:Name="LogBar" CornerRadius="8,0,0,8"/>
          <StackPanel Grid.Column="1" Margin="12,10,12,10">
            <TextBlock x:Name="Log" TextWrapping="Wrap" LineHeight="20"/>
            <ProgressBar x:Name="Busy" IsIndeterminate="True" Height="3" Margin="0,8,0,0" BorderThickness="0" Background="Transparent" Foreground="#FF0067C0" Visibility="Collapsed"/>
          </StackPanel>
        </Grid>
      </Border>

      <Expander x:Name="SettingsBox" Header="ตั้งค่า IP ของเครื่องนี้">
        <Border Style="{StaticResource Card}" Margin="0,8,0,0">
          <Grid>
            <Grid.ColumnDefinitions><ColumnDefinition Width="110"/><ColumnDefinition/></Grid.ColumnDefinitions>
            <Grid.RowDefinitions>
              <RowDefinition/><RowDefinition/><RowDefinition/><RowDefinition/><RowDefinition/><RowDefinition/><RowDefinition/><RowDefinition/><RowDefinition/>
            </Grid.RowDefinitions>
            <TextBlock Text="IP" VerticalAlignment="Center" Margin="0,0,0,6"/>
            <TextBox x:Name="FIp" Grid.Column="1"/>
            <TextBlock Grid.Row="1" Text="Subnet mask" VerticalAlignment="Center" Margin="0,0,0,6"/>
            <TextBox x:Name="FMask" Grid.Row="1" Grid.Column="1"/>
            <TextBlock Grid.Row="2" Text="Gateway" VerticalAlignment="Center" Margin="0,0,0,6"/>
            <TextBox x:Name="FGw" Grid.Row="2" Grid.Column="1"/>
            <TextBlock Grid.Row="3" Text="DNS 1" VerticalAlignment="Center" Margin="0,0,0,6"/>
            <TextBox x:Name="FDns1" Grid.Row="3" Grid.Column="1"/>
            <TextBlock Grid.Row="4" Text="DNS 2" VerticalAlignment="Center" Margin="0,0,0,6"/>
            <TextBox x:Name="FDns2" Grid.Row="4" Grid.Column="1"/>
            <TextBlock Grid.Row="5" Text="การ์ด LAN" VerticalAlignment="Center" Margin="0,0,0,6"/>
            <ComboBox x:Name="FLan" Grid.Row="5" Grid.Column="1"/>
            <TextBlock Grid.Row="6" Text="การ์ด Wi-Fi" VerticalAlignment="Center" Margin="0,0,0,6"/>
            <ComboBox x:Name="FWifi" Grid.Row="6" Grid.Column="1"/>
            <TextBlock Grid.Row="7" Text="Wi-Fi ที่ใช้" VerticalAlignment="Center" Margin="0,0,0,6"/>
            <ComboBox x:Name="FSsid" Grid.Row="7" Grid.Column="1"/>
            <DockPanel Grid.Row="8" Grid.ColumnSpan="2" Margin="0,4,0,0">
              <Button x:Name="SaveBtn" DockPanel.Dock="Right" Style="{StaticResource Btn}" Background="#FF0067C0" Foreground="White" Content="บันทึก"/>
              <Button x:Name="ReadBtn" DockPanel.Dock="Right" Style="{StaticResource Btn}" Margin="0,0,8,0" Content="ใช้ค่าปัจจุบัน" ToolTip="อ่าน IP ที่เครื่องใช้อยู่ตอนนี้มาใส่ช่องด้านบน"/>
              <TextBlock x:Name="SaveMsg" VerticalAlignment="Center" TextWrapping="Wrap" Margin="0,0,10,0"/>
            </DockPanel>
          </Grid>
        </Border>
      </Expander>

      <DockPanel Margin="0,12,0,0">
        <Button x:Name="RefreshBtn" DockPanel.Dock="Right" Style="{StaticResource Btn}" Content="รีเฟรช"/>
        <Button x:Name="AboutBtn" DockPanel.Dock="Right" Style="{StaticResource Btn}" Margin="0,0,8,0" Content="เกี่ยวกับ"/>
        <TextBlock x:Name="Hint" Foreground="#FF5C5C5C" FontSize="12" TextWrapping="Wrap" VerticalAlignment="Center" Margin="0,0,10,0"
                   Text="Static ที่ Wi-Fi ใช้กับทุกเครือข่าย Wi-Fi ย้ายไปเครือข่ายอื่นให้กด อัตโนมัติ"/>
      </DockPanel>
    </StackPanel>
  </Border>
</Window>
'@

$win = [Windows.Markup.XamlReader]::Load((New-Object System.Xml.XmlNodeReader $xaml))
$ui = @{}
foreach ($n in 'Root', 'HeadIcon', 'Now', 'TileLan', 'TileWifi', 'TileDhcp', 'BadgeLan', 'BadgeWifi', 'BadgeDhcp',
  'LanDot', 'LanName', 'LanInfo', 'LanPill', 'LanConn', 'WifiDot', 'WifiName', 'WifiInfo', 'WifiPill', 'WifiConn', 'LogCard', 'LogBar', 'Log', 'Busy',
  'Hint', 'SettingsBox', 'FSsid', 'ReadBtn', 'FIp', 'FMask', 'FGw', 'FDns1', 'FDns2', 'FLan', 'FWifi', 'SaveBtn', 'SaveMsg', 'RefreshBtn',
  'UpdateCard', 'UpdateTitle', 'UpdateText', 'UpdateBtn', 'UpdateNotesBtn', 'AboutBtn') { $ui[$n] = $win.FindName($n) }
$win.Title = "IP Switch $AppVersion"
$tiles = @{ Lan = $ui.TileLan; Wifi = $ui.TileWifi; Dhcp = $ui.TileDhcp }
$badges = @{ Lan = $ui.BadgeLan; Wifi = $ui.BadgeWifi; Dhcp = $ui.BadgeDhcp }
$brush = { param($hex) (New-Object Windows.Media.BrushConverter).ConvertFromString($hex) }

$iconPath = Join-Path $PSScriptRoot 'ip-switch.ico'
if (Test-Path $iconPath) {
  try {
    $frames = [Windows.Media.Imaging.BitmapDecoder]::Create([Uri]$iconPath, 'None', 'OnLoad').Frames
    $win.Icon = $frames | Where-Object { $_.PixelWidth -eq 32 } | Select-Object -First 1
    $ui.HeadIcon.Source = $frames | Sort-Object PixelWidth -Descending | Select-Object -First 1
  } catch {}
}

# Win11 acrylic behind the whole window; older Windows gets a plain light background.
$win.Add_SourceInitialized({
  $h = (New-Object System.Windows.Interop.WindowInteropHelper $win).Handle
  $backdrop = 3
  $ok = $false
  try {
    $m = New-Object IpSwitchDwm+Margins; $m.L = -1; $m.R = -1; $m.T = -1; $m.B = -1
    [System.Windows.Interop.HwndSource]::FromHwnd($h).CompositionTarget.BackgroundColor = [Windows.Media.Colors]::Transparent
    $ok = ([IpSwitchDwm]::DwmExtendFrameIntoClientArea($h, [ref]$m) -eq 0) -and ([IpSwitchDwm]::DwmSetWindowAttribute($h, 38, [ref]$backdrop, 4) -eq 0)
  } catch {}
  if ($ok) { $ui.Root.Background = & $brush '#66F3F3F3' } else { $win.Background = & $brush '#FFF3F3F3' }
})

function Show-Adapter($s, [string]$role, [string]$label) {
  $dot = $ui["${role}Dot"]; $name = $ui["${role}Name"]; $info = $ui["${role}Info"]; $pill = $ui["${role}Pill"]; $connText = $ui["${role}Conn"]
  if (-not $s) {
    $dot.Foreground = & $brush '#FF9A9A9A'; $name.Text = $label; $info.Text = 'ไม่พบการ์ดในเครื่องนี้'
    $pill.Visibility = 'Collapsed'; return
  }
  $pill.Visibility = 'Visible'
  $dot.Foreground = & $brush $(if ($s.Up) { '#FF0067C0' } else { '#FF9A9A9A' })
  if ($s.Up) { $pill.Background = & $brush '#FFDFF6DD'; $connText.Foreground = & $brush '#FF0F7B0F'; $connText.Text = 'เชื่อมต่อ' }
  else { $pill.Background = & $brush '#14000000'; $connText.Foreground = & $brush '#FF5C5C5C'; $connText.Text = $(if ($s.Disabled) { 'ถูกปิดอยู่' } else { 'ไม่ได้เชื่อมต่อ' }) }
  $name.Text = $(if ($s.Name -eq $label -or $s.Name -eq 'Ethernet') { $label } else { "$label   $($s.Name)" })
  if ($s.Dhcp) {
    $ip = $(if ($s.LiveIp.Count -and $s.Up) { $s.LiveIp -join ', ' } else { 'ยังไม่ได้ IP' })
    $text = "DHCP  ·  $ip"
    if ($s.StaticGateway.Count -or $s.StaticDns.Count -or $s.StaticIp.Count) {
      $text += "`nมีค่าเก่าค้าง (Gateway $($s.StaticGateway -join ', ')) กดปุ่มเพื่อล้าง"
      $info.Foreground = & $brush '#FF9D5D00'
    } else { $info.Foreground = & $brush '#FF5C5C5C' }
  } else {
    $text = "Static  ·  $($s.StaticIp -join ', ')  ·  GW $($s.StaticGateway -join ', ')`nDNS $($s.StaticDns -join ', ')"
    $info.Foreground = & $brush '#FF5C5C5C'
  }
  $info.Text = $text
}

function Update-Status {
  $c = Read-Config
  $snap = Get-Snapshot $c
  Show-Adapter $snap.States['Lan'] 'Lan' 'LAN'
  Show-Adapter $snap.States['Wifi'] 'Wifi' 'Wi-Fi'
  $on = $(if ($snap.Current) { $snap.Current } else { $snap.Near })
  foreach ($k in $tiles.Keys) {
    $tiles[$k].Tag = $(if ($k -eq $on) { 'on' } else { $null })
    $badges[$k].Visibility = $(if ($k -eq $snap.Current) { 'Visible' } else { 'Collapsed' })
  }
  $ui.Now.Text = $(if ($snap.Current) { "ตอนนี้: $($ModeLabel[$snap.Current])" }
    elseif ($snap.Near) { "ตอนนี้: $($ModeLabel[$snap.Near]) แต่การ์ดอีกตัวมีค่าเก่าค้าง กด $($ModeLabel[$snap.Near]) อีกครั้งเพื่อล้าง" }
    else { 'ตอนนี้: ค่าไม่ตรงกับปุ่มไหน กดเลือกเพื่อจัดให้ถูก' })
  $ui.Hint.Text = $(if (Test-Admin) { '' } else { 'กดปุ่มแล้ว Windows จะขอสิทธิ์ admin   ' }) + 'Static ที่ Wi-Fi ใช้กับทุกเครือข่าย Wi-Fi ย้ายไปเครือข่ายอื่นให้กด อัตโนมัติ'
}

function Fill-Settings {
  $c = Read-Config
  $ui.FIp.Text = $c.Ip; $ui.FMask.Text = $c.Mask; $ui.FGw.Text = $c.Gateway
  $ui.FDns1.Text = @($c.Dns)[0]; $ui.FDns2.Text = $(if ($c.Dns.Count -gt 1) { $c.Dns[1] } else { '' })
  $all = Get-PhysicalAdapters
  foreach ($pair in @(@($ui.FLan, $c.LanAdapter, '802.3'), @($ui.FWifi, $c.WifiAdapter, 'Wi'))) {
    $box = $pair[0]; $box.Items.Clear(); [void]$box.Items.Add('(หาให้อัตโนมัติ)')
    foreach ($a in $all) { [void]$box.Items.Add($a.Name) }
    $box.SelectedItem = $(if ($pair[1] -and $box.Items.Contains($pair[1])) { $pair[1] } else { '(หาให้อัตโนมัติ)' })
  }
  $ui.FSsid.Items.Clear()
  [void]$ui.FSsid.Items.Add($script:LastSsidItem)
  foreach ($p in (Get-WifiNetworks).Saved) { [void]$ui.FSsid.Items.Add($p) }
  $ui.FSsid.SelectedItem = $(if ($c.WifiSsid -and $ui.FSsid.Items.Contains($c.WifiSsid)) { $c.WifiSsid } else { $script:LastSsidItem })
  $ui.SettingsBox.IsExpanded = -not $c.Ip
  if (-not $c.Ip) {
    # First run: take the IP this PC uses now and save it straight away; settings stay open only if that fails.
    $cur = Get-CurrentIpSettings
    $first = Read-Config
    if ($cur) { $first.Ip = $cur.Ip; $first.Mask = $cur.Mask; $first.Gateway = $cur.Gateway; if ($cur.Dns.Count) { $first.Dns = @($cur.Dns | Select-Object -First 2) } }
    if ($cur -and -not @(Test-Config $first).Count) {
      Save-Config $first
      $ui.FIp.Text = $first.Ip; $ui.FMask.Text = $first.Mask; $ui.FGw.Text = $first.Gateway
      $ui.FDns1.Text = @($first.Dns)[0]; $ui.FDns2.Text = $(if ($first.Dns.Count -gt 1) { $first.Dns[1] } else { '' })
      $ui.SettingsBox.IsExpanded = $false
      Set-Log '#FF0F7B0F' "บันทึก IP ของเครื่องนี้ให้แล้ว: $($first.Ip)  GW $($first.Gateway)  (อ่านจาก $($cur.From))`nถ้าไม่ใช่ IP ที่ต้องการ แก้ได้ใน ตั้งค่า IP ของเครื่องนี้"
    }
    elseif (Fill-FromCurrent) { $ui.SaveMsg.Text += '  ตรวจแล้วกดบันทึก' } else { $ui.SaveMsg.Text = 'ใส่ IP ของเครื่องนี้ก่อนใช้ครั้งแรก' }
  }
}

function Fill-FromCurrent {
  $cur = Get-CurrentIpSettings
  if (-not $cur) { $ui.SaveMsg.Foreground = & $brush '#FFC42B1C'; $ui.SaveMsg.Text = 'อ่าน IP ปัจจุบันไม่ได้ (ยังไม่ได้เชื่อมต่อ)'; return $false }
  $ui.FIp.Text = $cur.Ip; $ui.FMask.Text = $cur.Mask; $ui.FGw.Text = $cur.Gateway
  if ($cur.Dns.Count) { $ui.FDns1.Text = $cur.Dns[0]; $ui.FDns2.Text = $(if ($cur.Dns.Count -gt 1) { $cur.Dns[1] } else { '' }) }
  $ui.SaveMsg.Foreground = & $brush '#FF5C5C5C'; $ui.SaveMsg.Text = "อ่านจาก $($cur.From)"
  return $true
}

$ui.ReadBtn.Add_Click({ [void](Fill-FromCurrent) })

$ui.SaveBtn.Add_Click({
  $auto = '(หาให้อัตโนมัติ)'
  $c = [pscustomobject]@{
    Ip = $ui.FIp.Text.Trim(); Mask = $ui.FMask.Text.Trim(); Gateway = $ui.FGw.Text.Trim()
    Dns = @($ui.FDns1.Text.Trim(), $ui.FDns2.Text.Trim() | Where-Object { $_ })
    LanAdapter = $(if ($ui.FLan.SelectedItem -and $ui.FLan.SelectedItem -ne $auto) { $ui.FLan.SelectedItem } else { '' })
    WifiAdapter = $(if ($ui.FWifi.SelectedItem -and $ui.FWifi.SelectedItem -ne $auto) { $ui.FWifi.SelectedItem } else { '' })
    WifiSsid = $(if ($ui.FSsid.SelectedItem -and $ui.FSsid.SelectedItem -ne $script:LastSsidItem) { $ui.FSsid.SelectedItem } else { '' })
    LastWifiSsid = (Read-Config).LastWifiSsid
  }
  $err = @(Test-Config $c)
  if ($err.Count) { $ui.SaveMsg.Foreground = & $brush '#FFC42B1C'; $ui.SaveMsg.Text = $err -join ', '; return }
  Save-Config $c
  $ui.SaveMsg.Foreground = & $brush '#FF0F7B0F'; $ui.SaveMsg.Text = 'บันทึกแล้ว กดปุ่มด้านบนเพื่อใช้'
  Update-Status
})

$script:job = $null
$script:LastSsidItem = '(อันล่าสุดที่ใช้ได้)'
$timer = New-Object Windows.Threading.DispatcherTimer
$timer.Interval = [TimeSpan]::FromMilliseconds(300)
$timer.Add_Tick({
  $j = $script:job
  $sec = [int]([DateTime]::Now - $j.Start).TotalSeconds
  # Saved Wi-Fi did not come up in time (or none was saved): open the Windows Wi-Fi list once.
  if ($j.PickerAt -and [DateTime]::Now -ge $j.PickerAt) {
    $j.PickerAt = $null
    if ((Get-NetAdapter -InterfaceIndex $j.WifiIndex -ErrorAction SilentlyContinue).Status -ne 'Up') {
      Open-WifiPicker
      $j.Text = "กำลังเปลี่ยนเป็น Wi-Fi ...`nเลือก Wi-Fi ในรายการที่เด้งขึ้น (รอได้ 3 นาที)"
    }
  }
  # No time limit: switching back from Wi-Fi took 3.5 minutes once and still finished correctly.
  $exited = $true
  try { $exited = $j.Proc.HasExited } catch {}
  if (-not $exited -and $sec -lt 600) {
    if ($sec -ne $j.Shown) { $j.Shown = $sec; $ui.Log.Text = "$($j.Text)`nผ่านไป $sec วินาที" }
    return
  }
  $timer.Stop()
  $r = $null
  try { $r = [IO.File]::ReadAllText($j.File, [Text.Encoding]::UTF8) | ConvertFrom-Json } catch {}
  Remove-Item $j.File -ErrorAction SilentlyContinue
  if ($r) {
    Set-Log $(if ($r.Ok) { '#FF0F7B0F' } else { '#FFC42B1C' }) ($r.Log -join "`n")
  } else {
    $code = '?'; try { $code = $j.Proc.ExitCode } catch {}
    $tail = ''; try { $tail = (Get-Content -LiteralPath (Join-Path $DataDir 'last-run.log') -Encoding UTF8 -Tail 4) -join "`n" } catch {}
    Set-Log '#FFC42B1C' "ไม่ได้ผลลัพธ์กลับมา (exit $code หลัง $sec วินาที)`n$tail"
  }
  foreach ($t in $tiles.Values) { $t.IsEnabled = $true }
  $script:job = $null
  Update-Status
})

# The switch runs in a child process (elevated when needed) so the window never freezes.
function Set-Log($color, [string]$text, [switch]$Busy) {
  $ui.LogBar.Background = & $brush $color
  $ui.Log.Foreground = & $brush $(if ($color -eq '#FFC42B1C') { '#FFA4262C' } else { '#FF1B1B1B' })
  $ui.Log.Text = $text
  $ui.Busy.Visibility = $(if ($Busy) { 'Visible' } else { 'Collapsed' })
  $ui.LogCard.Visibility = 'Visible'
}

function Start-Switch([string]$mode) {
  if ($script:job) { return }
  if ($Modes[$mode].Values -contains 'Static' -and @(Test-Config (Read-Config)).Count) {
    $ui.SettingsBox.IsExpanded = $true; $ui.SaveMsg.Foreground = & $brush '#FFC42B1C'; $ui.SaveMsg.Text = 'ใส่ IP แล้วกดบันทึกก่อน'; return
  }
  # Wi-Fi not connected: start connecting before the UAC prompt (no admin needed), so it is up by the time
  # the switch runs. A saved network connects by itself; otherwise the Windows Wi-Fi list opens.
  $c = Read-Config
  $wait = ''; $pickerAt = $null; $wifiIndex = 0
  $wifi = (Resolve-Adapters $c)['Wifi']
  if ($mode -eq 'Wifi' -and $wifi -and $wifi.Status -ne 'Up') {
    $wifiIndex = $wifi.ifIndex
    $ssid = Connect-PreferredWifi $c
    if ($ssid) { $wait = "`nกำลังเชื่อมต่อ $ssid (บันทึกไว้แล้ว)"; $pickerAt = [DateTime]::Now.AddSeconds(25) }
    else { Open-WifiPicker; $wait = "`nเลือก Wi-Fi ในรายการที่เด้งขึ้น (รอได้ 3 นาที)" }
  }
  $file = [IO.Path]::GetTempFileName()
  $argList = "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$PSCommandPath`" -Apply $mode -ResultFile `"$file`"$SelfArgs"
  try {
    if (Test-Admin) { $p = Start-Process powershell.exe -ArgumentList $argList -WindowStyle Hidden -PassThru }
    else { $p = Start-Process powershell.exe -Verb RunAs -ArgumentList $argList -WindowStyle Hidden -PassThru }
  } catch {
    Remove-Item $file -ErrorAction SilentlyContinue
    Set-Log '#FFC42B1C' 'ไม่ได้รับสิทธิ์ admin จึงยังไม่ได้เปลี่ยนอะไร'; return
  }
  foreach ($t in $tiles.Values) { $t.IsEnabled = $false }
  $text = "กำลังเปลี่ยนเป็น $($ModeLabel[$mode]) ...$wait"
  Set-Log '#FF0067C0' $text -Busy
  $script:job = @{ Proc = $p; File = $file; Start = [DateTime]::Now; Text = $text; Shown = -1; PickerAt = $pickerAt; WifiIndex = $wifiIndex }
  $timer.Start()
}

$ui.TileLan.Add_Click({ Start-Switch 'Lan' })
$ui.TileWifi.Add_Click({ Start-Switch 'Wifi' })
$ui.TileDhcp.Add_Click({ Start-Switch 'Dhcp' })
$ui.RefreshBtn.Add_Click({ Update-Status })

# Update check and download run as background jobs so the window never waits on the network.
$script:upd = $null; $script:updJob = $null; $script:updPhase = ''; $script:updManual = $false
$updTimer = New-Object Windows.Threading.DispatcherTimer
$updTimer.Interval = [TimeSpan]::FromMilliseconds(400)

function Start-UpdateJob([string]$phase, [string]$body) {
  $defs = "`$AppVersion = '$AppVersion'; `$UpdateRepo = '$UpdateRepo'`n" +
    "function Set-WebDefaults {${function:Set-WebDefaults}}`nfunction Get-UpdateInfo {${function:Get-UpdateInfo}}`n" +
    "function Install-Update {${function:Install-Update}}`n$body"
  $script:updPhase = $phase
  $script:updJob = Start-Job -ScriptBlock ([scriptblock]::Create($defs))
  $updTimer.Start()
}

function Start-UpdateCheck([switch]$Manual) {
  if ($script:updJob) { return }
  $script:updManual = [bool]$Manual
  if ($Manual) { Set-Log '#FF0067C0' 'กำลังตรวจอัปเดต...' -Busy }
  Start-UpdateJob 'check' 'Get-UpdateInfo | ConvertTo-Json -Compress'
}

$updTimer.Add_Tick({
  $j = $script:updJob
  if ($j.State -notin 'Completed', 'Failed', 'Stopped') { return }
  $updTimer.Stop()
  $out = $null; $err = ''
  try { $out = Receive-Job $j -ErrorAction Stop } catch { $err = $_.Exception.Message }
  if (-not $err -and $j.State -ne 'Completed') { $err = "$($j.ChildJobs[0].JobStateInfo.Reason.Message)" }
  Remove-Job $j -Force; $script:updJob = $null
  if ($script:updPhase -eq 'check') {
    if ($err -or -not $out) { if ($script:updManual) { Set-Log '#FFC42B1C' "ตรวจอัปเดตไม่ได้: $err" }; return }
    $script:upd = $out | ConvertFrom-Json
    if (-not $script:upd.Newer) { if ($script:updManual) { Set-Log '#FF0F7B0F' "เป็นเวอร์ชันล่าสุดแล้ว ($AppVersion)" }; return }
    $ui.UpdateTitle.Text = "มีเวอร์ชันใหม่ $($script:upd.Latest)  (ตอนนี้ $AppVersion)"
    $lines = @(($script:upd.Notes -split "`r?`n") | Where-Object { $_ -match '\S' -and $_ -notmatch '^##' } | ForEach-Object { $_ -replace '^\s*[-*]\s*', '' } | Select-Object -First 3)
    $ui.UpdateText.Text = $lines -join "`n"
    $ui.UpdateBtn.Content = $(if ($ExePath) { 'อัปเดตเลย' } else { 'ดาวน์โหลด' })
    $ui.UpdateCard.Visibility = 'Visible'
    if ($script:updManual) { $ui.LogCard.Visibility = 'Collapsed' }
  } else {
    if ($err) { $ui.UpdateBtn.IsEnabled = $true; Set-Log '#FFC42B1C' "อัปเดตไม่ได้: $err"; return }
    # the new exe unpacks its own version and opens a fresh window; this one closes
    Start-Process -FilePath $ExePath -WorkingDirectory (Split-Path $ExePath)
    $win.Close()
  }
})

# About: what this is, who made it, where it runs from and keeps its settings; update check lives here too.
function Show-About {
  [xml]$ax = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="เกี่ยวกับ IP Switch" Width="460" SizeToContent="Height" ResizeMode="NoResize" ShowInTaskbar="False"
        WindowStartupLocation="CenterOwner" Background="#FFF7F7F7"
        FontFamily="Segoe UI Variable Text, Segoe UI, Leelawadee UI" FontSize="13" Foreground="#FF1B1B1B">
  <Window.Resources>
    <Style TargetType="Button">
      <Setter Property="Cursor" Value="Hand"/>
      <Setter Property="Background" Value="#FFFFFFFF"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="Button">
            <Border x:Name="bd" CornerRadius="4" Background="{TemplateBinding Background}" BorderBrush="#1F000000" BorderThickness="1" Padding="{TemplateBinding Padding}">
              <ContentPresenter HorizontalAlignment="Center"/>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True"><Setter TargetName="bd" Property="Background" Value="#FFF0F0F0"/></Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>
  </Window.Resources>
  <StackPanel Margin="24,20,24,20">
    <Grid Margin="0,0,0,14">
      <Grid.ColumnDefinitions><ColumnDefinition Width="Auto"/><ColumnDefinition/></Grid.ColumnDefinitions>
      <Image x:Name="AIcon" Width="48" Height="48" Margin="0,0,14,0" VerticalAlignment="Top" RenderOptions.BitmapScalingMode="HighQuality"/>
      <StackPanel Grid.Column="1">
        <TextBlock Text="IP Switch" FontSize="20" FontWeight="SemiBold"/>
        <TextBlock x:Name="AVer" Foreground="#FF5C5C5C"/>
      </StackPanel>
    </Grid>
    <TextBlock TextWrapping="Wrap" Margin="0,0,0,14" Text="สลับ IP static ระหว่างสาย LAN, Wi-Fi และ DHCP ด้วยการกดปุ่มเดียว ล้าง gateway และ DNS เก่าที่ค้างให้ และต่อ Wi-Fi ที่เคยใช้ให้เอง"/>
    <Border Background="#FFFFFFFF" BorderBrush="#14000000" BorderThickness="1" CornerRadius="8" Padding="14,10">
      <Grid>
        <Grid.ColumnDefinitions><ColumnDefinition Width="110"/><ColumnDefinition/></Grid.ColumnDefinitions>
        <Grid.RowDefinitions><RowDefinition/><RowDefinition/><RowDefinition/><RowDefinition/><RowDefinition/></Grid.RowDefinitions>
        <TextBlock Text="ผู้พัฒนา" Foreground="#FF5C5C5C" Margin="0,0,0,8"/>
        <TextBlock Grid.Column="1" TextWrapping="Wrap" Margin="0,0,0,8" Text="DevTeam, Information Technology&#x0a;Faculty of Medicine Ramathibodi Hospital, Mahidol University"/>
        <TextBlock Grid.Row="1" Text="เวอร์ชัน" Foreground="#FF5C5C5C" Margin="0,0,0,8"/>
        <TextBlock x:Name="AVer2" Grid.Row="1" Grid.Column="1" Margin="0,0,0,8"/>
        <TextBlock Grid.Row="2" Text="ตัวโปรแกรม" Foreground="#FF5C5C5C" Margin="0,0,0,8"/>
        <TextBlock x:Name="AExe" Grid.Row="2" Grid.Column="1" TextWrapping="Wrap" FontFamily="Cascadia Mono, Consolas" FontSize="12" Margin="0,0,0,8"/>
        <TextBlock Grid.Row="3" Text="เก็บค่าที่" Foreground="#FF5C5C5C" Margin="0,0,0,8"/>
        <TextBlock x:Name="AData" Grid.Row="3" Grid.Column="1" TextWrapping="Wrap" FontFamily="Cascadia Mono, Consolas" FontSize="12" Margin="0,0,0,8"/>
        <TextBlock Grid.Row="4" Text="ระบบ" Foreground="#FF5C5C5C"/>
        <TextBlock x:Name="ASys" Grid.Row="4" Grid.Column="1" TextWrapping="Wrap"/>
      </Grid>
    </Border>
    <DockPanel Margin="0,16,0,0">
      <Button x:Name="ACloseBtn" DockPanel.Dock="Right" Content="ปิด" Padding="18,5" IsCancel="True"/>
      <Button x:Name="AUpdBtn" DockPanel.Dock="Right" Content="ตรวจอัปเดต" Padding="14,5" Margin="0,0,8,0"/>
      <Button x:Name="AFolderBtn" DockPanel.Dock="Left" Content="เปิดโฟลเดอร์ที่เก็บค่า" Padding="14,5" HorizontalAlignment="Left"/>
    </DockPanel>
  </StackPanel>
</Window>
'@
  $aw = [Windows.Markup.XamlReader]::Load((New-Object System.Xml.XmlNodeReader $ax))
  $aw.Owner = $win
  if ($ui.HeadIcon.Source) { $aw.FindName('AIcon').Source = $ui.HeadIcon.Source; $aw.Icon = $win.Icon }
  $kind = $(if ($ExePath) { 'ตัว portable' } else { 'สคริปต์' })
  $aw.FindName('AVer').Text = "เวอร์ชัน $AppVersion  ($kind)"
  $aw.FindName('AVer2').Text = $AppVersion
  $aw.FindName('AExe').Text = $(if ($ExePath) { $ExePath } else { $PSCommandPath })
  $aw.FindName('AData').Text = $ConfigPath
  $os = Get-CimInstance Win32_OperatingSystem -ErrorAction SilentlyContinue
  $aw.FindName('ASys').Text = "$($os.Caption) $($os.BuildNumber)  ·  PowerShell $($PSVersionTable.PSVersion)  ·  admin: $(if (Test-Admin) { 'ใช่' } else { 'ไม่ใช่' })"
  $aw.FindName('AFolderBtn').Add_Click({ Start-Process explorer.exe "/select,`"$ConfigPath`"" })
  $aw.FindName('AUpdBtn').Add_Click({ $aw.Close(); Start-UpdateCheck -Manual })
  $aw.FindName('ACloseBtn').Add_Click({ $aw.Close() })
  [void]$aw.ShowDialog()
}

$ui.AboutBtn.Add_Click({ Show-About })
$ui.UpdateNotesBtn.Add_Click({ if ($script:upd) { Start-Process $script:upd.Page } })
$ui.UpdateBtn.Add_Click({
  if (-not $script:upd) { return }
  if (-not $ExePath) { Start-Process $script:upd.ExeUrl; return }
  if ($script:updJob -or $script:job) { return }
  $ui.UpdateBtn.IsEnabled = $false
  Set-Log '#FF0067C0' "กำลังดาวน์โหลด $($script:upd.Latest) ..." -Busy
  $url = $script:upd.ExeUrl -replace "'", "''"; $exe = $ExePath -replace "'", "''"
  Start-UpdateJob 'install' "Install-Update '$url' '$exe'"
})
$win.Add_Activated({ if (-not $script:job) { Update-Status } })

Fill-Settings
Update-Status
Start-UpdateCheck
[void]$win.ShowDialog()
