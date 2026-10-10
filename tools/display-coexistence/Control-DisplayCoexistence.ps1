<# .SYNOPSIS Pauses or reloads only the approved display task, without interrupting an in-flight handoff. #>
param([Parameter(Mandatory=$true)][ValidateSet('Pause','Resume')][string]$Action)
$ErrorActionPreference='Stop'
$configuration=Get-Content -LiteralPath (Join-Path $PSScriptRoot 'host.json') -Raw -Encoding UTF8 | ConvertFrom-Json
$task=Get-ScheduledTask -TaskName $configuration.TaskName
$expected=Join-Path $PSScriptRoot 'Watch-StreamingDisplays.ps1'
if($task.Actions.Count -ne 1 -or $task.Actions.Arguments -notlike ('*-File "'+$expected+'"')){throw 'The scheduled task does not reference this protected controller.'}
$mutex=New-Object Threading.Mutex($false,'Local\MoonlightHeadlessDisplayMutation')
$held=$false
try {
    try{$held=$mutex.WaitOne(60000)}catch [Threading.AbandonedMutexException]{$held=$true}
    if(-not $held){throw 'A display handoff is still running; the controller was not stopped.'}
    Stop-ScheduledTask -TaskName $configuration.TaskName
    for($wait=0;$wait -lt 10 -and (Get-ScheduledTask -TaskName $configuration.TaskName).State -eq 'Running';$wait++){Start-Sleep -Milliseconds 500}
    if((Get-ScheduledTask -TaskName $configuration.TaskName).State -eq 'Running'){throw 'The controller has not exited; no replacement was started.'}
}finally{if($held){$mutex.ReleaseMutex()};$mutex.Dispose()}
if($Action -eq 'Resume'){Start-ScheduledTask -TaskName $configuration.TaskName}
[pscustomobject]@{Action=$Action;TaskState=(Get-ScheduledTask -TaskName $configuration.TaskName).State.ToString()}
