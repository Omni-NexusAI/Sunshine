param([Parameter(Mandatory=$true)][string]$AdapterName)
$ErrorActionPreference='Stop'
$env:PSModulePath=Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\Modules'
$configuration=Get-Content -LiteralPath (Join-Path $PSScriptRoot 'host.json') -Raw -Encoding UTF8 | ConvertFrom-Json
$root=$configuration.DataDirectory
Import-Module (Join-Path $PSScriptRoot 'SessionPolicy.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'HostDiscovery.psm1') -Force
$adapter=$AdapterName
$driverId=$configuration.ManagedDriverId
$sunConfig=$configuration.SunshineConfigPath
$vddConfig=$configuration.VddSettingsPath
Add-Type -Path (Join-Path $PSScriptRoot 'DisplayTools.cs')
function Save($value,$name){$value | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath (Join-Path $root $name) -Encoding UTF8}
function Write-SunshineConfig {
 <# .SYNOPSIS Replaces trusted configuration atomically using UTF-8 without a BOM. #>
 param([string]$Path,[string]$Text)
 [void](Assert-ProtectedPathAcl -Path $Path)
 $parent=Split-Path $Path -Parent
 [void](Assert-ProtectedPathAcl -Path $parent)
 $acl=Get-Acl -LiteralPath $Path
 $temporary=Join-Path $parent ('.gpu-'+[guid]::NewGuid().ToString('N')+'.tmp')
 try {
  [IO.File]::WriteAllText($temporary,$Text,(New-Object Text.UTF8Encoding($false)))
  Set-Acl -LiteralPath $temporary -AclObject $acl
  [void](Assert-ProtectedPathAcl -Path $temporary)
  [IO.File]::Replace($temporary,$Path,[NullString]::Value)
  [void](Assert-ProtectedPathAcl -Path $Path)
 }finally{if(Test-Path -LiteralPath $temporary){Remove-Item -LiteralPath $temporary -Force}}
}
function Check-Originals($before) {
 $current=@([SunshineDisplays]::List())
 foreach($item in @($before | Where-Object {$_.Active -and -not $_.Virtual})) {
  $same=@($current | Where-Object {$_.Name -eq $item.Name -and $_.Id -eq $item.Id})
  if($same.Count -ne 1){throw 'An existing monitor disappeared.'}
  foreach($field in @('Active','Primary','X','Y','Width','Height','Hz')){if($same[0].$field -ne $item.$field){throw "Existing monitor changed: $field"}}
 }
}
$started=$false
$displayMutex=New-Object Threading.Mutex($false,'Local\MoonlightHeadlessDisplayMutation')
$displayLock=$false
try {
 try{$displayLock=$displayMutex.WaitOne(30000)}catch [Threading.AbandonedMutexException]{$displayLock=$true}
 if(-not $displayLock){throw 'The automatic display controller is busy; try the GPU switch again.'}
 $principal=[Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()
 if(-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)){throw 'Administrator approval required.'}
 $cards=@(Get-CimInstance Win32_VideoController | Where-Object Name -eq $adapter)
 if($cards.Count -ne 1){throw 'Selected GPU is not uniquely available.'}
 if((Get-Service SunshineService).Status -ne 'Running'){throw 'Sunshine must be running before switching GPUs.'}
 if(-not $vddConfig -or -not (Test-Path -LiteralPath $vddConfig)){throw 'A validated MikeTheTech XML settings file is required for coordinated GPU selection.'}
 if(-not (Test-SafeIdle (Get-SunshineSessionState -Configuration $configuration -History (New-SessionHistory) -DrainHistory))){throw 'Close Moonlight and wait for Sunshine to become idle before changing GPUs.'}
 if($adapter -match '[\r\n]' -or $adapter.Contains('"')){throw 'Unsupported adapter name.'}
 $before=@([SunshineDisplays]::List())
 if(-not @($before | Where-Object {$_.Active -and -not $_.Virtual}).Count){throw 'Open Virtual Desktop or Meta with its own display before changing the stream GPU.'}
 $stamp=Get-Date -Format 'yyyyMMdd-HHmmss'
 $backup=Join-Path $root ('recovery\gpu-'+$stamp)
 New-Item -ItemType Directory -Path $backup | Out-Null
 Copy-Item -LiteralPath $sunConfig -Destination (Join-Path $backup 'sunshine.conf')
 Copy-Item -LiteralPath $vddConfig -Destination (Join-Path $backup 'vdd_settings.xml')
 [SunshineDisplays]::SaveTopology((Join-Path $backup 'topology.bin'))
 [SunshineDisplays]::SaveOriginalTopology((Join-Path $backup 'original-displays.bin'))
 $started=$true
 Stop-Service SunshineService
 Start-Sleep -Seconds 3
 Disable-PnpDevice -InstanceId $driverId -Confirm:$false
 Start-Sleep -Seconds 2
 [xml]$xml=Get-Content -LiteralPath $vddConfig -Raw
 $xml.vdd_settings.gpu.friendlyname=$adapter
 $xml.Save($vddConfig)
 $text=[IO.File]::ReadAllText($sunConfig,[Text.Encoding]::UTF8)
 if($text -match '(?m)^adapter_name\s*='){$text=[regex]::Replace($text,'(?m)^adapter_name\s*=.*$',('adapter_name = '+$adapter))}else{$text=$text.TrimEnd()+"`r`nadapter_name = $adapter`r`n"}
 Write-SunshineConfig -Path $sunConfig -Text $text
 Start-Service SunshineService
 Start-Sleep -Seconds 3
 Enable-PnpDevice -InstanceId $driverId -Confirm:$false
 Start-Sleep -Seconds 5
 $driver=Get-CimInstance Win32_PnPEntity | Where-Object PNPDeviceID -eq $driverId
 if($driver.ConfigManagerErrorCode -ne 0){throw "Virtual display driver failed to start with selected GPU (Windows problem code $($driver.ConfigManagerErrorCode))."}
 Check-Originals $before
 $attach=[SunshineDisplays]::AttachVirtual(0,0)
 if($attach -ne 0){throw "Windows rejected the selected virtual display: $attach"}
 Start-Sleep -Seconds 2
 Check-Originals $before
 Restart-Service SunshineService
 Start-Sleep -Seconds 8
 Check-Originals $before
 $log=Get-Content -LiteralPath $configuration.SunshineLogPath -Raw
 if($log -notmatch ([regex]::Escape("config: 'adapter_name' = "+$adapter))){throw 'Sunshine did not load the requested adapter setting.'}
 if($log -notmatch ([regex]::Escape('Device Description : '+$adapter))){throw 'Sunshine could not capture using the selected GPU.'}
 if($log -notmatch 'created encoder (HEVC|H264|AV1)|Found (H.264|HEVC|AV1) encoder'){throw 'Sunshine could not initialize an encoder.'}
 if($log -match 'Fatal:'){throw 'Sunshine reported a fatal startup error.'}
 Save @{Success=$true;GPU=$adapter;Time=(Get-Date).ToString('o');OriginalDisplaysPreserved=$true;Displays=@([SunshineDisplays]::List());RecoveryFolder=$backup;LiveStreamVerified=$false} 'gpu-result.json'
 if(-not @($before | Where-Object {$_.Active -and $_.Virtual}).Count -and (Test-SafeIdle (Get-SunshineSessionState -Configuration $configuration -History (New-SessionHistory) -DrainHistory))){
  $park=[SunshineDisplays]::ParkVirtualDisplays()
  if($park -ne 0){throw "Could not return the Moonlight display to its idle state: $park"}
 }
 "Selected $adapter for the virtual display and Sunshine. Reconnect Moonlight to verify the live stream."
} catch {
 $errorText=$_.Exception.Message
 if($started) {
  $rollback=@{}
  try {
   Stop-Service SunshineService -ErrorAction SilentlyContinue
   Disable-PnpDevice -InstanceId $driverId -Confirm:$false
   Copy-Item -LiteralPath (Join-Path $backup 'sunshine.conf') -Destination $sunConfig
   Copy-Item -LiteralPath (Join-Path $backup 'vdd_settings.xml') -Destination $vddConfig
   # Recover display availability independently of Sunshine service startup.
   Enable-PnpDevice -InstanceId $driverId -Confirm:$false
   Start-Sleep -Seconds 5
   Start-Service SunshineService
   Start-Sleep -Seconds 3
   $rollback.Topology=[SunshineDisplays]::RestoreTopology((Join-Path $backup 'topology.bin'))
   if($rollback.Topology -ne 0){
    $rollback.OriginalTopology=[SunshineDisplays]::RestoreTopology((Join-Path $backup 'original-displays.bin'))
    if($rollback.OriginalTopology -ne 0){throw 'Windows could not restore the saved original monitor layout.'}
    $rollback.VirtualActivation=[SunshineDisplays]::AttachVirtual(0,0)
   }
   Check-Originals $before
   Restart-Service SunshineService
   $rollback.Restored=$true
  }catch{$rollback.Error=$_.Exception.Message;$rollback.Restored=$false}
  finally{
   try{
    $driver=Get-CimInstance Win32_PnPEntity | Where-Object PNPDeviceID -eq $driverId
    if($driver.ConfigManagerErrorCode -eq 22){Enable-PnpDevice -InstanceId $driverId -Confirm:$false}
    $rollback.ManagedDriverRecoveryAttempted=$true
   }catch{$rollback.ManagedDriverRecoveryError=$_.Exception.Message}
  }
  Save $rollback 'gpu-rollback.json'
 }
 Save @{Error=$errorText;GPU=$adapter;Time=(Get-Date).ToString('o')} 'gpu-error.json'
 throw $errorText
} finally {
 if($displayLock){$displayMutex.ReleaseMutex()}
 $displayMutex.Dispose()
}
