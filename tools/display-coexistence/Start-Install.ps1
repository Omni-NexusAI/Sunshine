<# .SYNOPSIS Audits the current host, then requests one Windows elevation for explicit installation. #>
$ErrorActionPreference='Stop'
$planText=& (Join-Path $PSScriptRoot 'Install-DisplayCoexistence.ps1') -Plan
$plan=$planText | ConvertFrom-Json
$planText
if(-not $plan.ReadyToInstall){throw 'Resolve the displayed planning blockers before installation.'}
$runtime=Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
$arguments='-NoProfile -ExecutionPolicy Bypass -File "'+(Join-Path $PSScriptRoot 'Install-DisplayCoexistence.ps1')+'" -Install'
$process=Start-Process -FilePath $runtime -ArgumentList $arguments -Verb RunAs -WindowStyle Hidden -PassThru
$process.WaitForExit();$process.Refresh()
if($process.ExitCode -ne 0){throw 'Installation did not complete. Run Inspect.cmd and inspect the protected installation report.'}
'Installed. Open your streaming apps normally. Use the Sunshine GPU selector for deliberate adapter changes.'
