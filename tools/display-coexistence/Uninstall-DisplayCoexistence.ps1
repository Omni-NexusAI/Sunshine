<#
.SYNOPSIS
Plans or removes the managed Windows display coexistence controller.
.DESCRIPTION
The default and -Plan modes are read-only. -Uninstall requires an elevated current-user
session, a positively idle Sunshine session, exact managed-task identity, and protected
install state. Recovery is retained. Unknown or modified files are never recursively deleted.
#>
[CmdletBinding()]
param([switch]$Plan, [switch]$Uninstall)

Set-StrictMode -Version 2
$ErrorActionPreference = 'Stop'
$trustedModulePaths = @((Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\Modules'), (Join-Path $PSHOME 'Modules')) |
    Where-Object { Test-Path -LiteralPath $_ -PathType Container } | Select-Object -Unique
$env:PSModulePath = $trustedModulePaths -join [IO.Path]::PathSeparator
$script:PackageMarker = 'SunshineDisplayCoexistence/v1'
$script:MutexName = 'Local\MoonlightHeadlessDisplayMutation'
Import-Module (Join-Path $PSScriptRoot 'HostDiscovery.psm1') -Force

function Test-Administrator {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    return ([Security.Principal.WindowsPrincipal]$identity).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Get-ProtectedFileSecurity {
    $administrators = New-Object Security.Principal.SecurityIdentifier('S-1-5-32-544')
    $system = New-Object Security.Principal.SecurityIdentifier('S-1-5-18')
    $users = New-Object Security.Principal.SecurityIdentifier('S-1-5-32-545')
    $security = New-Object Security.AccessControl.FileSecurity
    $security.SetAccessRuleProtection($true, $false)
    $security.SetOwner($administrators)
    foreach ($principal in @($administrators, $system)) {
        $security.AddAccessRule((New-Object Security.AccessControl.FileSystemAccessRule($principal,
                    [Security.AccessControl.FileSystemRights]::FullControl,
                    [Security.AccessControl.AccessControlType]::Allow)))
    }
    $security.AddAccessRule((New-Object Security.AccessControl.FileSystemAccessRule($users,
                [Security.AccessControl.FileSystemRights]::ReadAndExecute,
                [Security.AccessControl.AccessControlType]::Allow)))
    return $security
}

function Set-ProtectedFile {
    param([Parameter(Mandatory = $true)][string]$Path)
    $null = Assert-SafePathChain -Path $Path
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { throw "Protected file does not exist: $Path" }
    Set-Acl -LiteralPath $Path -AclObject (Get-ProtectedFileSecurity)
    [void](Assert-ProtectedPathAcl -Path $Path)
}

function Write-Utf8NoBomAtomic {
    param([string]$Path, [string]$Text)
    $temporary = Join-Path (Split-Path $Path -Parent) ('.write-' + [guid]::NewGuid().ToString('N') + '.tmp')
    try {
        [IO.File]::WriteAllText($temporary, $Text, (New-Object Text.UTF8Encoding($false)))
        Set-ProtectedFile -Path $temporary
        Move-Item -LiteralPath $temporary -Destination $Path -Force
        Set-ProtectedFile -Path $Path
    } finally { if (Test-Path -LiteralPath $temporary) { Remove-Item -LiteralPath $temporary -Force } }
}

function Write-JsonAtomic {
    param([string]$Path, $Value)
    Write-Utf8NoBomAtomic -Path $Path -Text (($Value | ConvertTo-Json -Depth 12) + "`r`n")
}

function Get-ProtectedDirectorySecurity {
    $administrators = New-Object Security.Principal.SecurityIdentifier('S-1-5-32-544')
    $system = New-Object Security.Principal.SecurityIdentifier('S-1-5-18')
    $users = New-Object Security.Principal.SecurityIdentifier('S-1-5-32-545')
    $security = New-Object Security.AccessControl.DirectorySecurity
    $security.SetAccessRuleProtection($true, $false); $security.SetOwner($administrators)
    $inheritance = [Security.AccessControl.InheritanceFlags]'ContainerInherit,ObjectInherit'
    foreach ($principal in @($administrators, $system)) {
        $security.AddAccessRule((New-Object Security.AccessControl.FileSystemAccessRule($principal,
                    [Security.AccessControl.FileSystemRights]::FullControl, $inheritance,
                    [Security.AccessControl.PropagationFlags]::None, [Security.AccessControl.AccessControlType]::Allow)))
    }
    $security.AddAccessRule((New-Object Security.AccessControl.FileSystemAccessRule($users,
                [Security.AccessControl.FileSystemRights]::ReadAndExecute, $inheritance,
                [Security.AccessControl.PropagationFlags]::None, [Security.AccessControl.AccessControlType]::Allow)))
    return $security
}

function Set-ProtectedDirectory {
    param([string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) {
        $null = Assert-SafePathChain -Path (Split-Path $Path -Parent)
        [void](New-Item -ItemType Directory -Path $Path)
    }
    $null = Assert-SafePathChain -Path $Path
    Set-Acl -LiteralPath $Path -AclObject (Get-ProtectedDirectorySecurity)
    [void](Assert-ProtectedPathAcl -Path $Path)
}

function Set-FileSddl {
    param([string]$Path, [string]$Sddl)
    $acl = Get-Acl -LiteralPath $Path
    $acl.SetSecurityDescriptorSddlForm($Sddl, [Security.AccessControl.AccessControlSections]::All)
    Set-Acl -LiteralPath $Path -AclObject $acl
}

function Assert-ContainedPath {
    param([string]$Path, [string]$Root)
    $full = [IO.Path]::GetFullPath($Path)
    $rootFull = [IO.Path]::GetFullPath($Root).TrimEnd('\') + '\'
    if (-not $full.StartsWith($rootFull, [StringComparison]::OrdinalIgnoreCase)) { throw "Recovery path escapes the protected data directory: $full" }
    $null = Assert-SafePathChain -Path $full
    [void](Assert-ProtectedPathAcl -Path $full)
    return $full
}

function Assert-ProtectedTreeAcl {
    param([Parameter(Mandatory = $true)][string]$Root, [int]$MaximumEntries = 256)
    [void](Assert-ProtectedPathAcl -Path $Root)
    $entries = @(Get-ChildItem -LiteralPath $Root -Force -Recurse)
    if ($entries.Count -gt $MaximumEntries) { throw "Protected tree exceeds the bounded ACL audit limit of $MaximumEntries entries: $Root" }
    foreach ($entry in $entries) {
        $null = Assert-SafePathChain -Path $entry.FullName
        [void](Assert-ProtectedPathAcl -Path $entry.FullName)
    }
}

function Get-TaskSnapshot {
    param([string]$TaskName)
    $scheduler = New-Object -ComObject 'Schedule.Service'; $scheduler.Connect()
    $folder = $scheduler.GetFolder('\')
    try { $task = $folder.GetTask($TaskName) } catch { return $null }
    $scheduled = Get-ScheduledTask -TaskName $TaskName -ErrorAction Stop
    $action = $task.Definition.Actions.Item(1)
    [pscustomobject]@{
        Name = $TaskName; Xml = $task.Xml; Sddl = $task.GetSecurityDescriptor(7); State = $scheduled.State.ToString()
        Execute = [string]$action.Path; Arguments = [string]$action.Arguments; WorkingDirectory = [string]$action.WorkingDirectory
    }
}

function Get-TaskScriptPath {
    param([string]$Arguments)
    if ([string]::IsNullOrWhiteSpace($Arguments)) { return $null }
    $match = [regex]::Match($Arguments, '(?i)(?:^|\s)-File\s+(?:"([^"]+)"|''([^'']+)''|(\S+))')
    if (-not $match.Success) { return $null }
    foreach ($index in 1..3) { if ($match.Groups[$index].Success) { return [IO.Path]::GetFullPath($match.Groups[$index].Value) } }
    return $null
}

function Test-ManagedTaskSnapshot {
    param($Snapshot, [string]$CodeDirectory, [string]$Runtime)
    if ($null -eq $Snapshot) { return $true }
    return ($Snapshot.Execute -ieq $Runtime -and
        (Get-TaskScriptPath $Snapshot.Arguments) -ieq (Join-Path $CodeDirectory 'Watch-StreamingDisplays.ps1') -and
        $Snapshot.WorkingDirectory -ieq $CodeDirectory)
}

function Restore-TaskSnapshot {
    param($Snapshot)
    if ($null -eq $Snapshot) { return }
    Register-ScheduledTask -TaskName $Snapshot.Name -Xml $Snapshot.Xml -Force | Out-Null
    $scheduler = New-Object -ComObject 'Schedule.Service'; $scheduler.Connect()
    $scheduler.GetFolder('\').GetTask($Snapshot.Name).SetSecurityDescriptor($Snapshot.Sddl, 0)
}

function Read-SavedTaskSnapshot {
    param($Record, [string]$TransactionDirectory, [string]$DataDirectory)
    if ($null -eq $Record) { return $null }
    $xmlPath = Assert-ContainedPath -Path (Join-Path $TransactionDirectory ([string]$Record.Xml)) -Root $DataDirectory
    $sddlPath = Assert-ContainedPath -Path (Join-Path $TransactionDirectory ([string]$Record.Sddl)) -Root $DataDirectory
    [pscustomobject]@{
        Name = [string]$Record.Name
        Xml = Get-Content -LiteralPath $xmlPath -Raw -Encoding UTF8
        Sddl = (Get-Content -LiteralPath $sddlPath -Raw -Encoding UTF8).Trim()
        State = [string]$Record.State
        Execute = [string]$Record.Execute
        Arguments = [string]$Record.Arguments
        WorkingDirectory = [string]$Record.WorkingDirectory
    }
}

function Enter-DisplayMutex {
    $mutex = New-Object Threading.Mutex($false, $script:MutexName)
    $held = $false
    try { $held = $mutex.WaitOne(60000) } catch [Threading.AbandonedMutexException] { $held = $true }
    if (-not $held) { $mutex.Dispose(); throw 'A display mutation is still running; uninstall made no changes.' }
    return $mutex
}

function Assert-SafeIdleSession {
    param([string]$SessionPolicyPath, $Configuration)
    Import-Module $SessionPolicyPath -Force
    $history = New-SessionHistory
    $session = Get-SunshineSessionState -Configuration $Configuration -History $history -DrainHistory
    if (-not (Test-SafeIdle -Session $session)) {
        throw "Sunshine is active, starting, or uncertain (Known=$($session.Known), Count=$($session.Count), Starting=$($session.Starting)); uninstall made no changes."
    }
}

function Stop-TaskAndWait {
    param([string]$TaskName)
    $task = Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
    if ($null -eq $task -or $task.State -ne 'Running') { return }
    Stop-ScheduledTask -TaskName $TaskName
    for ($attempt = 0; $attempt -lt 20; $attempt++) {
        if ((Get-ScheduledTask -TaskName $TaskName).State -ne 'Running') { return }
        Start-Sleep -Milliseconds 250
    }
    throw "Scheduled task did not stop: $TaskName"
}

function Get-ShortcutDetails {
    param([string]$Path)
    $shell = New-Object -ComObject WScript.Shell
    $shortcut = $shell.CreateShortcut($Path)
    [pscustomobject]@{ TargetPath = $shortcut.TargetPath; Arguments = $shortcut.Arguments; WorkingDirectory = $shortcut.WorkingDirectory }
}

if ($Plan -and $Uninstall) { throw 'Choose either -Plan or -Uninstall.' }
$isPlan = $Plan -or -not $Uninstall
$codeDirectory = Join-Path ([Environment]::GetFolderPath([Environment+SpecialFolder]::ProgramFiles)) 'Sunshine Display Coexistence'
$dataDirectory = Join-Path ([Environment]::GetFolderPath([Environment+SpecialFolder]::CommonApplicationData)) 'Sunshine Display Coexistence'
$codeMarker = Join-Path $codeDirectory '.sunshine-display-coexistence'
$dataMarker = Join-Path $dataDirectory 'config\.sunshine-display-coexistence'
$statePath = Join-Path $dataDirectory 'config\install-state.json'
$hostPath = Join-Path $codeDirectory 'host.json'
$blockers = New-Object System.Collections.Generic.List[string]
$metadataReadSafe = $true
if (-not (Test-Path -LiteralPath $codeDirectory -PathType Container) -and -not (Test-Path -LiteralPath $dataDirectory -PathType Container)) {
    $notInstalled = [pscustomobject]@{ Mode = if ($isPlan) { 'Plan' } else { 'Uninstall' }; ReadOnly = $isPlan; Installed = $false; BlockingReasons = @(); ChangedPaths = @() }
    if ($isPlan) { return ($notInstalled | ConvertTo-Json -Depth 8) }
    return $notInstalled
}
foreach ($path in @($codeDirectory, $dataDirectory)) {
    if (Test-Path -LiteralPath $path) {
        try { $null = Assert-SafePathChain -Path $path } catch { $blockers.Add($_.Exception.Message); $metadataReadSafe = $false }
    }
}
foreach ($path in @($codeDirectory, $dataDirectory, (Join-Path $dataDirectory 'config'), (Join-Path $dataDirectory 'recovery'))) {
    if (Test-Path -LiteralPath $path -PathType Container) {
        try { [void](Assert-ProtectedPathAcl -Path $path) }
        catch { $blockers.Add($_.Exception.Message); $metadataReadSafe = $false }
    }
}
if ($metadataReadSafe) {
    if (-not (Test-Path -LiteralPath $codeMarker -PathType Leaf)) {
        $blockers.Add('Code directory is missing the exact managed marker.')
    } else {
        try {
            [void](Assert-ProtectedPathAcl -Path $codeMarker)
            if ((Get-Content -LiteralPath $codeMarker -Raw -Encoding UTF8).Trim() -ne $script:PackageMarker) { $blockers.Add('Code directory has an invalid managed marker.') }
        } catch { $blockers.Add($_.Exception.Message) }
    }
    if (-not (Test-Path -LiteralPath $dataMarker -PathType Leaf)) {
        $blockers.Add('Data directory is missing the exact managed marker.')
    } else {
        try {
            [void](Assert-ProtectedPathAcl -Path $dataMarker)
            if ((Get-Content -LiteralPath $dataMarker -Raw -Encoding UTF8).Trim() -ne $script:PackageMarker) { $blockers.Add('Data directory has an invalid managed marker.') }
        } catch { $blockers.Add($_.Exception.Message) }
    }
}
if (-not (Test-Path -LiteralPath $statePath -PathType Leaf)) { $blockers.Add('Protected install state is absent.') }
if (-not (Test-Path -LiteralPath $hostPath -PathType Leaf)) { $blockers.Add('Protected host.json is absent.') }
$manifest = $null; $hostConfiguration = $null
if ($blockers.Count -eq 0) {
    try {
        [void](Assert-ProtectedPathAcl -Path $statePath)
        [void](Assert-ProtectedPathAcl -Path $hostPath)
        $manifest = Get-Content -LiteralPath $statePath -Raw -Encoding UTF8 | ConvertFrom-Json
        $hostConfiguration = Get-Content -LiteralPath $hostPath -Raw -Encoding UTF8 | ConvertFrom-Json
        if ($manifest.SchemaVersion -ne 1 -or $manifest.ManagedBy -ne $script:PackageMarker) { $blockers.Add('Install state is not a supported managed schema.') }
        if ($hostConfiguration.SchemaVersion -ne 1 -or $hostConfiguration.TaskName -ne 'Sunshine Display Coexistence') { $blockers.Add('host.json is not a supported managed schema.') }
        if ([IO.Path]::GetFullPath([string]$manifest.CodeDirectory) -ine [IO.Path]::GetFullPath($codeDirectory) -or
            [IO.Path]::GetFullPath([string]$manifest.DataDirectory) -ine [IO.Path]::GetFullPath($dataDirectory)) { $blockers.Add('Install-state paths do not match the protected package roots.') }
        if ($manifest.PreviousCodeBackup) {
            $upgradeTransaction = Assert-ContainedPath -Path ([string]$manifest.TransactionDirectory) -Root $dataDirectory
            [void](Assert-ContainedPath -Path (Join-Path $upgradeTransaction 'install-state.before.json') -Root $dataDirectory)
        }
        if ($blockers.Count -eq 0) { Assert-ProtectedTreeAcl -Root $codeDirectory }
    } catch { $blockers.Add("Protected install state could not be read: $($_.Exception.Message)") }
}
$currentTask = $null
if ($hostConfiguration) {
    $currentTask = Get-TaskSnapshot -TaskName ([string]$hostConfiguration.TaskName)
    if (-not (Test-ManagedTaskSnapshot -Snapshot $currentTask -CodeDirectory $codeDirectory -Runtime ([string]$manifest.Runtime))) {
        $blockers.Add('Scheduled task exists with an unmanaged action; uninstall refuses to stop it.')
    }
}
$planResult = [pscustomobject]@{
    Mode = if ($isPlan) { 'Plan' } else { 'Uninstall' }
    ReadOnly = $isPlan
    Installed = ($null -ne $manifest)
    CodeDirectory = $codeDirectory
    DataDirectory = $dataDirectory
    Task = $currentTask
    RestoreTargetTask = if ($manifest) { $manifest.OriginalTargetTask } else { $null }
    RestoreLegacyTask = if ($manifest) { $manifest.OriginalLegacyTask } else { $null }
    RetainRecovery = $true
    BlockingReasons = $blockers.ToArray()
    ReadyToUninstall = ($blockers.Count -eq 0)
    Limitations = @('Recovery and install-state records are retained.', 'Modified or unknown code and shortcuts are left in place.', 'Uninstall restores Sunshine config only when it still matches the installer-written hash.')
}
if ($isPlan) { return ($planResult | ConvertTo-Json -Depth 16) }
if ($blockers.Count -gt 0) { throw ('Uninstall is blocked: ' + ($blockers -join ' | ')) }
if (-not (Test-Administrator)) { throw '-Uninstall requires an explicit elevated administrator PowerShell session.' }

$transactionDirectory = Assert-ContainedPath -Path ([string]$manifest.TransactionDirectory) -Root $dataDirectory
$originalTarget = Read-SavedTaskSnapshot -Record $manifest.OriginalTargetTask -TransactionDirectory $transactionDirectory -DataDirectory $dataDirectory
$originalLegacy = Read-SavedTaskSnapshot -Record $manifest.OriginalLegacyTask -TransactionDirectory $transactionDirectory -DataDirectory $dataDirectory
$previousInstallState = $null
if ($manifest.PreviousCodeBackup) {
    $previousInstallState = Assert-ContainedPath -Path (Join-Path $transactionDirectory 'install-state.before.json') -Root $dataDirectory
}
$uninstallRecovery = Join-Path $dataDirectory ('recovery\uninstall-' + (Get-Date -Format 'yyyyMMdd-HHmmss') + '-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
Set-ProtectedDirectory -Path $uninstallRecovery
$removedCode = Join-Path $uninstallRecovery 'removed-code'
Set-ProtectedDirectory -Path $removedCode
$currentTaskBackup = $currentTask
$configCurrentBackup = $null
$configRestored = $false
$currentCodeMoved = $false
$previousCodeRestored = $false
$currentCodeBackup = $null
$currentInstallStateBackup = $null
$previousInstallStateRestored = $false
$movedFiles = New-Object System.Collections.Generic.List[object]
$shortcutActions = New-Object System.Collections.Generic.List[object]
$warnings = New-Object System.Collections.Generic.List[string]
$mutex = $null
$tasksToStart = New-Object System.Collections.Generic.List[string]

try {
    $mutex = Enter-DisplayMutex
    Assert-SafeIdleSession -SessionPolicyPath (Join-Path $codeDirectory 'SessionPolicy.psm1') -Configuration $hostConfiguration
    if ($currentTask) {
        Stop-TaskAndWait -TaskName $currentTask.Name
        Unregister-ScheduledTask -TaskName $currentTask.Name -Confirm:$false
    }

    if ($manifest.ConfigChanged) {
        Assert-SafeIdleSession -SessionPolicyPath (Join-Path $codeDirectory 'SessionPolicy.psm1') -Configuration $hostConfiguration
        $configPath = [string]$manifest.SunshineConfigPath
        $null = Assert-SafePathChain -Path $configPath
        [void](Assert-ProtectedPathAcl -Path $configPath)
        $backupPath = Assert-ContainedPath -Path ([string]$manifest.SunshineConfigBackup) -Root $dataDirectory
        $currentHash = (Get-FileHash -LiteralPath $configPath -Algorithm SHA256).Hash
        if ($currentHash -eq [string]$manifest.SunshineConfigPostInstallHash) {
            $configCurrentBackup = Join-Path $uninstallRecovery 'sunshine.conf.current'
            Copy-Item -LiteralPath $configPath -Destination $configCurrentBackup
            Set-ProtectedFile -Path $configCurrentBackup
            Copy-Item -LiteralPath $backupPath -Destination $configPath -Force
            $configRestored = $true
            Set-FileSddl -Path $configPath -Sddl ([string]$manifest.SunshineConfigOriginalSddl)
            [void](Assert-ProtectedPathAcl -Path $configPath)
        } else { $warnings.Add('Sunshine config changed after installation; its protected original backup was retained and the live file was not overwritten.') }
    }

    if ($manifest.PreviousCodeBackup) {
        $previousCode = Assert-ContainedPath -Path ([string]$manifest.PreviousCodeBackup) -Root $dataDirectory
        Assert-ProtectedTreeAcl -Root $previousCode
        $currentCodeBackup = Join-Path $uninstallRecovery 'current-code'
        Move-Item -LiteralPath $codeDirectory -Destination $currentCodeBackup
        $currentCodeMoved = $true
        Move-Item -LiteralPath $previousCode -Destination $codeDirectory
        $previousCodeRestored = $true
        $currentInstallStateBackup = Join-Path $uninstallRecovery 'install-state.current.json'
        Copy-Item -LiteralPath $statePath -Destination $currentInstallStateBackup
        Set-ProtectedFile -Path $currentInstallStateBackup
        Copy-Item -LiteralPath $previousInstallState -Destination $statePath -Force
        $previousInstallStateRestored = $true
        Set-ProtectedFile -Path $statePath
    } else {
        foreach ($property in $manifest.InstalledHashes.PSObject.Properties) {
            $path = Join-Path $codeDirectory $property.Name
            if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { continue }
            if ((Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash -ne [string]$property.Value) {
                $warnings.Add("Modified managed file was retained: $path")
                continue
            }
            $destination = Join-Path $removedCode $property.Name
            [void](Assert-ProtectedPathAcl -Path $path)
            $moveRecord = [pscustomobject]@{ Original = $path; Recovery = $destination; Moved = $false }
            $movedFiles.Add($moveRecord)
            Move-Item -LiteralPath $path -Destination $destination
            $moveRecord.Moved = $true
            [void](Assert-ProtectedPathAcl -Path $destination)
        }
        if ((Get-ChildItem -LiteralPath $codeDirectory -Force | Measure-Object).Count -eq 0) { Remove-Item -LiteralPath $codeDirectory }
    }

    foreach ($shortcut in @($manifest.Shortcuts)) {
        $path = [string]$shortcut.Path
        if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { continue }
        try { $null = Assert-SafePathChain -Path $path } catch { $warnings.Add("Unsafe shortcut path was retained: $path - $($_.Exception.Message)"); continue }
        $details = Get-ShortcutDetails -Path $path
        $managedScript = Get-TaskScriptPath $details.Arguments
        if ($details.TargetPath -ine [string]$manifest.Runtime -or $managedScript -ine (Join-Path $manifest.CodeDirectory 'GPU-Selector.ps1')) {
            $warnings.Add("Modified shortcut was retained: $path")
            continue
        }
        $currentBackup = Join-Path $uninstallRecovery (([IO.Path]::GetFileNameWithoutExtension($path)) + '.current.lnk')
        $currentSddl = (Get-Acl -LiteralPath $path).GetSecurityDescriptorSddlForm([Security.AccessControl.AccessControlSections]::All)
        Copy-Item -LiteralPath $path -Destination $currentBackup
        Set-ProtectedFile -Path $currentBackup
        if ($shortcut.Backup) {
            if (-not $shortcut.OriginalSddl) { $warnings.Add("Original shortcut ACL was not recorded; shortcut was retained: $path"); continue }
            $original = Assert-ContainedPath -Path ([string]$shortcut.Backup) -Root $dataDirectory
            Copy-Item -LiteralPath $original -Destination $path -Force
            Set-FileSddl -Path $path -Sddl ([string]$shortcut.OriginalSddl)
            $shortcutActions.Add([pscustomobject]@{ Path = $path; CurrentBackup = $currentBackup; CurrentSddl = $currentSddl; Restored = $true })
        } else {
            Remove-Item -LiteralPath $path -Force
            $shortcutActions.Add([pscustomobject]@{ Path = $path; CurrentBackup = $currentBackup; CurrentSddl = $currentSddl; Restored = $false })
        }
    }

    if ($originalTarget) {
        Restore-TaskSnapshot -Snapshot $originalTarget
        if ($originalTarget.State -eq 'Running') { $tasksToStart.Add($originalTarget.Name) }
    }
    if ($originalLegacy) {
        Restore-TaskSnapshot -Snapshot $originalLegacy
        if ($originalLegacy.State -eq 'Running') { $tasksToStart.Add($originalLegacy.Name) }
    }
    Write-JsonAtomic -Path (Join-Path $uninstallRecovery 'uninstall-result.json') -Value ([pscustomobject]@{
            Success = $true; Time = (Get-Date).ToString('o'); ConfigRestored = $configRestored
            RecoveryRetained = $true; Warnings = $warnings.ToArray()
        })
} catch {
    $failure = $_
    $rollbackSucceeded = $false
    try {
        foreach ($task in @($originalTarget, $originalLegacy)) {
            if ($task) { Unregister-ScheduledTask -TaskName $task.Name -Confirm:$false -ErrorAction SilentlyContinue }
        }
        if ($configRestored -and $configCurrentBackup -and (Test-Path -LiteralPath $configCurrentBackup)) {
            Copy-Item -LiteralPath $configCurrentBackup -Destination ([string]$manifest.SunshineConfigPath) -Force
            Set-FileSddl -Path ([string]$manifest.SunshineConfigPath) -Sddl ([string]$manifest.SunshineConfigOriginalSddl)
        }
        if ($previousInstallStateRestored -and $currentInstallStateBackup -and (Test-Path -LiteralPath $currentInstallStateBackup)) {
            Copy-Item -LiteralPath $currentInstallStateBackup -Destination $statePath -Force
            Set-ProtectedFile -Path $statePath
        }
        if ($previousCodeRestored) {
            $previousCode = [string]$manifest.PreviousCodeBackup
            if (Test-Path -LiteralPath $codeDirectory) { Move-Item -LiteralPath $codeDirectory -Destination $previousCode }
            $previousCodeRestored = $false
        }
        if ($currentCodeMoved -and $currentCodeBackup -and (Test-Path -LiteralPath $currentCodeBackup)) {
            Move-Item -LiteralPath $currentCodeBackup -Destination $codeDirectory
            $currentCodeMoved = $false
        }
        if (-not $manifest.PreviousCodeBackup) {
            if (-not (Test-Path -LiteralPath $codeDirectory)) { Set-ProtectedDirectory -Path $codeDirectory }
            foreach ($moved in $movedFiles) {
                if ($moved.Moved -and (Test-Path -LiteralPath $moved.Recovery)) { Move-Item -LiteralPath $moved.Recovery -Destination $moved.Original }
            }
        }
        foreach ($action in $shortcutActions) {
            if (Test-Path -LiteralPath $action.CurrentBackup) {
                Copy-Item -LiteralPath $action.CurrentBackup -Destination $action.Path -Force
                Set-FileSddl -Path $action.Path -Sddl $action.CurrentSddl
            }
        }
        # Restore the installed task only after its protected code is back. Starting is deferred until lock release.
        if ($currentTaskBackup) { Restore-TaskSnapshot -Snapshot $currentTaskBackup }
        Write-JsonAtomic -Path (Join-Path $uninstallRecovery 'uninstall-failure.json') -Value ([pscustomobject]@{ Success = $false; Time = (Get-Date).ToString('o'); Error = $failure.Exception.Message })
        $rollbackSucceeded = $true
    } catch {
        throw "Uninstall failed: $($failure.Exception.Message). Rollback also failed: $($_.Exception.Message). Recovery is at $uninstallRecovery."
    }
    if ($mutex) { $mutex.ReleaseMutex(); $mutex.Dispose(); $mutex = $null }
    if ($rollbackSucceeded -and $currentTaskBackup -and $currentTaskBackup.State -eq 'Running') {
        Assert-ProtectedTreeAcl -Root $codeDirectory
        Start-ScheduledTask -TaskName $currentTaskBackup.Name
    }
    throw
} finally {
    if ($mutex) { $mutex.ReleaseMutex(); $mutex.Dispose() }
}

foreach ($taskName in $tasksToStart) {
    try { Start-ScheduledTask -TaskName $taskName } catch { $warnings.Add("Restored task could not be started after releasing the mutex: $taskName - $($_.Exception.Message)") }
}

[pscustomobject]@{
    Success = $true
    ChangedPaths = @($codeDirectory, $dataDirectory)
    RecoveryDirectory = $uninstallRecovery
    RecoveryRetained = $true
    ConfigRestored = $configRestored
    RestoredTasksStartedAfterMutexRelease = $tasksToStart.ToArray()
    TestsRun = @('Managed markers/schema validation', 'Protected recovery ACL validation', 'Exact task-action validation', 'SessionPolicy safe-idle gate', 'Managed file hash checks')
    Warnings = $warnings.ToArray()
    Limitations = $planResult.Limitations
}
