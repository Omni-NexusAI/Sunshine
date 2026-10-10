param([switch]$Once,[switch]$ObserveOnly)
$ErrorActionPreference='Stop'
$env:PSModulePath=Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\Modules'
$configuration=Get-Content -LiteralPath (Join-Path $PSScriptRoot 'host.json') -Raw -Encoding UTF8 | ConvertFrom-Json
if($configuration.SchemaVersion -ne 1){throw 'Unsupported host configuration.'}
$root=$configuration.DataDirectory
Import-Module (Join-Path $PSScriptRoot 'SessionPolicy.psm1') -Force
Add-Type -Path (Join-Path $PSScriptRoot 'DisplayTools.cs')
${mtt}=$configuration.ManagedDriverId
${vd}=$configuration.VirtualDesktopDriverId

$mutex=New-Object Threading.Mutex($false,'Local\MoonlightHeadlessDisplayMutation')
$activeSince=$null
$retryAfter=[datetime]::MinValue
$lastState=''
$script:history=New-SessionHistory
function Problem($id){(Get-PnpDeviceProperty -InstanceId $id -KeyName DEVPKEY_Device_ProblemCode -ErrorAction Stop).Data}
function Get-CurrentSession { Get-SunshineSessionState -Configuration $configuration -History $script:history }
function Test-PreferredConnection {
 $streamers=@(Get-Process 'VirtualDesktop.Streamer' -ErrorAction SilentlyContinue | Select-Object -ExpandProperty Id)
 if(-not $vd -or $streamers.Count -eq 0){return $false}
 return @((Get-NetTCPConnection -LocalPort $configuration.VirtualDesktopPort -State Established -ErrorAction SilentlyContinue) | Where-Object {$_.OwningProcess -in $streamers}).Count -gt 0
}
try {
 do {
  $held=$false
  try {
   try{$held=$mutex.WaitOne($(if($Once){5000}else{0}))}catch [Threading.AbandonedMutexException]{$held=$true}
   if(-not $held){if($Once){throw 'The display controller is busy; no observation or mutation was performed.'};Start-Sleep -Seconds $configuration.PollSeconds;continue}
   $session=Get-CurrentSession
   $outputs=@([SunshineDisplays]::List())
   # A stopped handoff may leave MTT disabled even after another desktop appeared.
   if((Problem $mtt) -eq 22 -and -not $ObserveOnly){
    Enable-PnpDevice -InstanceId $mtt -Confirm:$false
    Start-Sleep -Seconds 2
    $outputs=@([SunshineDisplays]::List())
   }
   if(-not @($outputs | Where-Object Active).Count -and -not $ObserveOnly){
    if((Problem $mtt) -eq 22){Enable-PnpDevice -InstanceId $mtt -Confirm:$false}
    Start-Sleep -Seconds 2
    if(-not @([SunshineDisplays]::List() | Where-Object Active).Count){
     $recover=[SunshineDisplays]::AttachVirtual(0,0)
     if($recover -ne 0){throw "Interrupted handoff recovery failed: $recover"}
    }
    $outputs=@([SunshineDisplays]::List())
   }
   $activeMTT=@($outputs | Where-Object {$_.Active -and $_.Virtual})
   $other=@($outputs | Where-Object {$_.Active -and -not $_.Virtual})
   $action='Idle; Moonlight screens remain available but inactive'
   if(-not @($outputs | Where-Object Active).Count -and $ObserveOnly){$action='Would recover an interrupted headless handoff; observation only'}
   if($activeMTT.Count -gt 0){if(-not $activeSince){$activeSince=Get-Date}}else{$activeSince=$null}
   # Allow capture preparation before CLIENT CONNECTED is logged.
   $grace=$configuration.IdleGraceSeconds
   if($session.LastEvent -eq 'DISCONNECTED'){${grace}=$configuration.DisconnectGraceSeconds}
   $settled=$activeSince -and ((Get-Date)-$activeSince).TotalSeconds -ge $grace -and (Get-Date) -ge $retryAfter
   $decision=Get-DisplayDecision -Session $session -ManagedActive $activeMTT.Count -OtherActive $other.Count -PreferredConnected (Test-PreferredConnection) -Settled ([bool]$settled)
   if(-not $session.Known){$action='Session state uncertain; preserving all screens'}
   elseif($session.Count -gt 0 -or $session.Starting){$action='Moonlight session or startup; preserving its capture screen'}
   elseif($decision -eq 'Settle'){$action='Allowing display and stream startup to settle'}
   elseif($decision -in @('Park','Handoff')){
    if($decision -eq 'Handoff'){
     $action='Virtual Desktop headless handoff'
     if(-not $ObserveOnly){
      $recovery=Join-Path $root ('recovery\automatic-vd-'+(Get-Date -Format 'yyyyMMdd-HHmmss'))
      New-Item -ItemType Directory -Path $recovery | Out-Null
      [SunshineDisplays]::SaveTopology((Join-Path $recovery 'before.bin'))

      try{
       $confirm=Get-CurrentSession
       if(-not $confirm.Known -or $confirm.Count -gt 0 -or $confirm.Starting){throw 'Moonlight is starting; delaying the Virtual Desktop handoff.'}
       Disable-PnpDevice -InstanceId $mtt -Confirm:$false
       if((Problem $vd) -eq 22){Enable-PnpDevice -InstanceId $vd -Confirm:$false}
       $vdActive=$false
       for($wait=0;$wait -lt 12;$wait++){
        if(@([SunshineDisplays]::List() | Where-Object {$_.Active -and $_.Adapter -eq $configuration.VirtualDesktopAdapter}).Count){$vdActive=$true;break}
        Start-Sleep -Seconds 1
       }
       if(-not $vdActive){throw 'Virtual Desktop has no active display.'}
       [SunshineDisplays]::SaveOriginalTopology((Join-Path $recovery 'vd.bin'))
       if((Problem $mtt) -eq 22){Enable-PnpDevice -InstanceId $mtt -Confirm:$false}
       $finalCheck=Get-CurrentSession
       if(-not $finalCheck.Known -or $finalCheck.Count -gt 0 -or $finalCheck.Starting){
        $action='Moonlight starting during handoff; preserving the capture topology'
       }else{
        $park=[SunshineDisplays]::RestoreTopology((Join-Path $recovery 'vd.bin'))
        if($park -ne 0){throw "Idle display parking failed: $park"}
       }
      }catch{
       if((Problem $mtt) -eq 22){Enable-PnpDevice -InstanceId $mtt -Confirm:$false;Start-Sleep -Seconds 2}
       $rollbackCheck=Get-CurrentSession
       $restore=0
       if($rollbackCheck.Known -and $rollbackCheck.Count -eq 0 -and -not $rollbackCheck.Starting){$restore=[SunshineDisplays]::RestoreTopology((Join-Path $recovery 'before.bin'))}
       if(-not @([SunshineDisplays]::List() | Where-Object Active).Count){$restore=[SunshineDisplays]::AttachVirtual(0,0)}
       if($restore -ne 0 -and -not @([SunshineDisplays]::List() | Where-Object Active).Count){throw "Handoff failed and Windows rejected recovery: $restore"}
       $retryAfter=(Get-Date).AddSeconds($configuration.RetrySeconds)
       throw
      }
     }
    }elseif($other.Count -gt 0){
     $action='Parking unused Moonlight screens; preserving existing desktop'
     if(-not $ObserveOnly){
      $confirm=Get-CurrentSession
      if(-not $confirm.Known -or $confirm.Count -gt 0 -or $confirm.Starting){throw 'Moonlight is starting; no idle parking change made.'}
      $park=[SunshineDisplays]::ParkVirtualDisplays()
      if($park -ne 0){throw "Windows rejected idle display parking: $park"}
     }
    }
   }
   elseif($decision -eq 'KeepLastDesktop'){$action='Keeping the last desktop active until another display is available'}
   $state=@{ControllerPid=$PID;ControllerProcess=(Get-Process -Id $PID).ProcessName;Action=$action;SessionKnown=$session.Known;MoonlightClients=$session.Count;ObserveOnly=$ObserveOnly.IsPresent;DriverProblem=(Problem $mtt);ActiveDisplays=@([SunshineDisplays]::List() | Where-Object Active)}
   $serialized=$state | ConvertTo-Json -Depth 8 -Compress
   if($serialized -ne $lastState){$state.Time=(Get-Date).ToString('o');$state | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath (Join-Path $root 'automatic-display-state.json') -Encoding UTF8;$lastState=$serialized}
  }catch{
   @{Error=$_.Exception.Message;Time=(Get-Date).ToString('o')} | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $root 'automatic-display-error.json') -Encoding UTF8
   if($Once){throw}
  }finally{if($held){$mutex.ReleaseMutex()}}
  if(-not $Once){Start-Sleep -Seconds $configuration.PollSeconds}
 }while(-not $Once)
}finally{$mutex.Dispose()}
