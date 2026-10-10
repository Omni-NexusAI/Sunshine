<#
.SYNOPSIS
Plans or installs the bounded Windows display coexistence controller.
.DESCRIPTION
The default and -Plan modes are read-only. -Install requires an elevated current-user
session and installs only the supplied controller files, protected configuration, and one
interactive scheduled task. It never installs a display driver, changes a driver state,
selects a GPU, changes resolution/topology, pairs a user, or restarts Sunshine.
.PARAMETER ConfigureSunshine
Allows only necessary edits to output_name, dd_configuration_option, and
dd_config_revert_on_disconnect after the capture UUID has been validated against a logged
MTT1337 Sunshine display enumeration. A protected byte-for-byte backup is retained.
.PARAMETER MigrateLegacy
Allows migration of the exact legacy task named Sunshine Streaming Display Lifecycle when
its action targets a Moonlight Headless\Watch-StreamingDisplays.ps1 script.
#>
[CmdletBinding()]
param(
    [switch]$Plan,
    [switch]$Install,
    [AllowNull()][string]$SunshineDirectory,
    [AllowNull()][string]$SunshineConfigPath,
    [AllowNull()][string]$SunshineLogPath,
    [AllowNull()][string]$ManagedDriverId,
    [AllowNull()][string]$VirtualDesktopDriverId,
    [AllowNull()][string]$CaptureDisplayId,
    [AllowNull()][string]$VddSettingsPath,
    [switch]$ConfigureSunshine,
    [switch]$MigrateLegacy
)

Set-StrictMode -Version 2
$ErrorActionPreference = 'Stop'
$trustedModulePaths = @((Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\Modules'), (Join-Path $PSHOME 'Modules')) |
    Where-Object { Test-Path -LiteralPath $_ -PathType Container } | Select-Object -Unique
$env:PSModulePath = $trustedModulePaths -join [IO.Path]::PathSeparator
$script:PackageMarker = 'SunshineDisplayCoexistence/v1'
$script:MutexName = 'Local\MoonlightHeadlessDisplayMutation'
$script:RequiredRuntimeFiles = @(
    'Watch-StreamingDisplays.ps1',
    'DisplayTools.cs',
    'SessionPolicy.psm1',
    'Control-DisplayCoexistence.ps1',
    'GPU-Selector.ps1',
    'Select-StreamingGPU.ps1'
)
$script:PackageFiles = @(
    'HostDiscovery.psm1',
    'Install-DisplayCoexistence.ps1',
    'Uninstall-DisplayCoexistence.ps1'
)

Import-Module (Join-Path $PSScriptRoot 'HostDiscovery.psm1') -Force

function Test-Administrator {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    return ([Security.Principal.WindowsPrincipal]$identity).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Get-ProtectedDirectorySecurity {
    $administrators = New-Object Security.Principal.SecurityIdentifier('S-1-5-32-544')
    $system = New-Object Security.Principal.SecurityIdentifier('S-1-5-18')
    $users = New-Object Security.Principal.SecurityIdentifier('S-1-5-32-545')
    $security = New-Object Security.AccessControl.DirectorySecurity
    $security.SetAccessRuleProtection($true, $false)
    $security.SetOwner($administrators)
    $inheritance = [Security.AccessControl.InheritanceFlags]'ContainerInherit,ObjectInherit'
    foreach ($principal in @($administrators, $system)) {
        $security.AddAccessRule((New-Object Security.AccessControl.FileSystemAccessRule(
                    $principal, [Security.AccessControl.FileSystemRights]::FullControl, $inheritance,
                    [Security.AccessControl.PropagationFlags]::None, [Security.AccessControl.AccessControlType]::Allow)))
    }
    $security.AddAccessRule((New-Object Security.AccessControl.FileSystemAccessRule(
                $users, [Security.AccessControl.FileSystemRights]::ReadAndExecute, $inheritance,
                [Security.AccessControl.PropagationFlags]::None, [Security.AccessControl.AccessControlType]::Allow)))
    return $security
}

function Get-ProtectedFileSecurity {
    $administrators = New-Object Security.Principal.SecurityIdentifier('S-1-5-32-544')
    $system = New-Object Security.Principal.SecurityIdentifier('S-1-5-18')
    $users = New-Object Security.Principal.SecurityIdentifier('S-1-5-32-545')
    $security = New-Object Security.AccessControl.FileSecurity
    $security.SetAccessRuleProtection($true, $false)
    $security.SetOwner($administrators)
    foreach ($principal in @($administrators, $system)) {
        $security.AddAccessRule((New-Object Security.AccessControl.FileSystemAccessRule(
                    $principal, [Security.AccessControl.FileSystemRights]::FullControl,
                    [Security.AccessControl.AccessControlType]::Allow)))
    }
    $security.AddAccessRule((New-Object Security.AccessControl.FileSystemAccessRule(
                $users, [Security.AccessControl.FileSystemRights]::ReadAndExecute,
                [Security.AccessControl.AccessControlType]::Allow)))
    return $security
}

function Set-ProtectedDirectory {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'This private helper runs only inside the explicit -Install transaction and rollback boundary.')]
    param([Parameter(Mandatory = $true)][string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) {
        $null = Assert-SafePathChain -Path (Split-Path $Path -Parent)
        [void](New-Item -ItemType Directory -Path $Path)
    }
    $null = Assert-SafePathChain -Path $Path
    Set-Acl -LiteralPath $Path -AclObject (Get-ProtectedDirectorySecurity)
    [void](Assert-ProtectedPathAcl -Path $Path)
}

function Set-ProtectedFile {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'This private helper runs only inside the explicit -Install transaction and rollback boundary.')]
    param([Parameter(Mandatory = $true)][string]$Path)
    $null = Assert-SafePathChain -Path $Path
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { throw "Protected file does not exist: $Path" }
    Set-Acl -LiteralPath $Path -AclObject (Get-ProtectedFileSecurity)
    [void](Assert-ProtectedPathAcl -Path $Path)
}

function Write-Utf8NoBomAtomic {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$Text,
        [AllowNull()][ref]$Replaced
    )
    $parent = Split-Path $Path -Parent
    $temporary = Join-Path $parent ('.write-' + [guid]::NewGuid().ToString('N') + '.tmp')
    try {
        [IO.File]::WriteAllText($temporary, $Text, (New-Object Text.UTF8Encoding($false)))
        Set-ProtectedFile -Path $temporary
        Move-Item -LiteralPath $temporary -Destination $Path -Force
        if ($null -ne $Replaced) { $Replaced.Value = $true }
        Set-ProtectedFile -Path $Path
    } finally {
        if (Test-Path -LiteralPath $temporary) { Remove-Item -LiteralPath $temporary -Force }
    }
}

function Write-JsonAtomic {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)]$Value,
        [int]$Depth = 10,
        [AllowNull()][ref]$Replaced
    )
    $text = ($Value | ConvertTo-Json -Depth $Depth) + "`r`n"
    if ($null -ne $Replaced) { Write-Utf8NoBomAtomic -Path $Path -Text $text -Replaced $Replaced }
    else { Write-Utf8NoBomAtomic -Path $Path -Text $text }
}

function Get-FileSddl {
    param([Parameter(Mandatory = $true)][string]$Path)
    return (Get-Acl -LiteralPath $Path).GetSecurityDescriptorSddlForm([Security.AccessControl.AccessControlSections]::All)
}

function Set-FileSddl {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'This private helper runs only inside the explicit -Install transaction and rollback boundary.')]
    param([Parameter(Mandatory = $true)][string]$Path, [Parameter(Mandatory = $true)][string]$Sddl)
    $acl = Get-Acl -LiteralPath $Path
    $acl.SetSecurityDescriptorSddlForm($Sddl, [Security.AccessControl.AccessControlSections]::All)
    Set-Acl -LiteralPath $Path -AclObject $acl
}

function Get-WindowsPowerShellPath {
    $runtime = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    $null = Assert-SafePathChain -Path $runtime
    $acl = Get-Acl -LiteralPath $runtime
    $ownerSid = (New-Object Security.Principal.NTAccount($acl.Owner)).Translate([Security.Principal.SecurityIdentifier]).Value
    $trustedInstallerSid = (New-Object Security.Principal.NTAccount('NT SERVICE', 'TrustedInstaller')).Translate([Security.Principal.SecurityIdentifier]).Value
    $trustedOwners = @($trustedInstallerSid, 'S-1-5-18', 'S-1-5-32-544')
    if ($trustedOwners -notcontains $ownerSid) { throw "Windows PowerShell has an unexpected owner SID: $ownerSid" }
    $signature = Get-AuthenticodeSignature -LiteralPath $runtime
    if ($signature.Status -ne [Management.Automation.SignatureStatus]::Valid -or
        $null -eq $signature.SignerCertificate -or $signature.SignerCertificate.Subject -notmatch '(?i)Microsoft') {
        throw 'Windows PowerShell is not validly signed by Microsoft.'
    }
    return $runtime
}

function Get-TaskSnapshot {
    param([Parameter(Mandatory = $true)][string]$TaskName)
    $scheduler = New-Object -ComObject 'Schedule.Service'
    $scheduler.Connect()
    $folder = $scheduler.GetFolder('\')
    try { $task = $folder.GetTask($TaskName) } catch { return $null }
    $scheduled = Get-ScheduledTask -TaskName $TaskName -ErrorAction Stop
    $action = $task.Definition.Actions.Item(1)
    [pscustomobject]@{
        Name = $TaskName
        Xml = $task.Xml
        Sddl = $task.GetSecurityDescriptor(7)
        State = $scheduled.State.ToString()
        Execute = [string]$action.Path
        Arguments = [string]$action.Arguments
        WorkingDirectory = [string]$action.WorkingDirectory
    }
}

function Get-TaskScriptPath {
    param([AllowNull()][string]$Arguments)
    if ([string]::IsNullOrWhiteSpace($Arguments)) { return $null }
    $match = [regex]::Match($Arguments, '(?i)(?:^|\s)-File\s+(?:"([^"]+)"|''([^'']+)''|(\S+))')
    if (-not $match.Success) { return $null }
    foreach ($index in 1..3) { if ($match.Groups[$index].Success) { return [IO.Path]::GetFullPath($match.Groups[$index].Value) } }
    return $null
}

function Test-ManagedTaskSnapshot {
    param($Snapshot, [Parameter(Mandatory = $true)][string]$CodeDirectory, [Parameter(Mandatory = $true)][string]$PowerShellPath)
    if ($null -eq $Snapshot) { return $false }
    $expectedScript = Join-Path $CodeDirectory 'Watch-StreamingDisplays.ps1'
    $actualScript = Get-TaskScriptPath $Snapshot.Arguments
    return ($Snapshot.Execute -ieq $PowerShellPath -and $actualScript -ieq $expectedScript -and $Snapshot.WorkingDirectory -ieq $CodeDirectory)
}

function Test-LegacyTaskSnapshot {
    param($Snapshot, [Parameter(Mandatory = $true)][string]$PowerShellPath)
    if ($null -eq $Snapshot -or $Snapshot.Name -ne 'Sunshine Streaming Display Lifecycle') { return $false }
    if ($Snapshot.Execute -ine $PowerShellPath -and [IO.Path]::GetFileName($Snapshot.Execute) -ine 'powershell.exe' -and
        [IO.Path]::GetFileName($Snapshot.Execute) -ine 'pwsh.exe') { return $false }
    $scriptPath = Get-TaskScriptPath $Snapshot.Arguments
    if ([string]::IsNullOrWhiteSpace($scriptPath)) { return $false }
    return ([IO.Path]::GetFileName($scriptPath) -ieq 'Watch-StreamingDisplays.ps1' -and
        [IO.Path]::GetFileName((Split-Path $scriptPath -Parent)) -ieq 'Moonlight Headless')
}

function Set-TaskSecurityReadExecute {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'This private helper runs only inside the explicit -Install transaction and rollback boundary.')]
    param([Parameter(Mandatory = $true)][string]$TaskName, [Parameter(Mandatory = $true)][Security.Principal.SecurityIdentifier]$UserSid)
    $scheduler = New-Object -ComObject 'Schedule.Service'; $scheduler.Connect()
    $task = $scheduler.GetFolder('\').GetTask($TaskName)
    $original = $task.GetSecurityDescriptor(7)
    $descriptor = New-Object Security.AccessControl.RawSecurityDescriptor($original)
    $present = $false
    foreach ($ace in $descriptor.DiscretionaryAcl) {
        if ($ace -is [Security.AccessControl.CommonAce] -and $ace.AceQualifier -eq [Security.AccessControl.AceQualifier]::AccessAllowed -and
            $ace.SecurityIdentifier -eq $UserSid -and (($ace.AccessMask -band 0x1200A9) -eq 0x1200A9)) { $present = $true; break }
    }
    if (-not $present) {
        $ace = New-Object Security.AccessControl.CommonAce(
            [Security.AccessControl.AceFlags]::None, [Security.AccessControl.AceQualifier]::AccessAllowed,
            0x1200A9, $UserSid, $false, $null)
        $descriptor.DiscretionaryAcl.InsertAce($descriptor.DiscretionaryAcl.Count, $ace)
        $task.SetSecurityDescriptor($descriptor.GetSddlForm([Security.AccessControl.AccessControlSections]::All), 0)
    }
    return $original
}

function Restore-TaskSnapshot {
    param($Snapshot)
    if ($null -eq $Snapshot) { return }
    Register-ScheduledTask -TaskName $Snapshot.Name -Xml $Snapshot.Xml -Force | Out-Null
    $scheduler = New-Object -ComObject 'Schedule.Service'; $scheduler.Connect()
    $scheduler.GetFolder('\').GetTask($Snapshot.Name).SetSecurityDescriptor($Snapshot.Sddl, 0)
}

function Stop-TaskAndWait {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'This private helper runs only inside the explicit -Install transaction and rollback boundary.')]
    param([Parameter(Mandatory = $true)][string]$TaskName)
    $task = Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
    if ($null -eq $task) { return }
    if ($task.State -ne 'Running') { return }
    Stop-ScheduledTask -TaskName $TaskName -ErrorAction Stop
    for ($attempt = 0; $attempt -lt 20; $attempt++) {
        if ((Get-ScheduledTask -TaskName $TaskName -ErrorAction Stop).State -ne 'Running') { return }
        Start-Sleep -Milliseconds 250
    }
    throw "Scheduled task did not stop: $TaskName"
}

function Enter-DisplayMutex {
    $mutex = New-Object Threading.Mutex($false, $script:MutexName)
    $held = $false
    try { $held = $mutex.WaitOne(60000) } catch [Threading.AbandonedMutexException] { $held = $true }
    if (-not $held) { $mutex.Dispose(); throw 'A display mutation is still running; no controller or configuration was changed.' }
    return $mutex
}

function Assert-SafeIdleSession {
    param([Parameter(Mandatory = $true)][string]$SessionPolicyPath, [Parameter(Mandatory = $true)]$Configuration)
    Import-Module $SessionPolicyPath -Force
    $history = New-SessionHistory
    $session = Get-SunshineSessionState -Configuration $Configuration -History $history -DrainHistory
    if (-not (Test-SafeIdle -Session $session)) {
        throw "Sunshine is active, starting, or uncertain (Known=$($session.Known), Count=$($session.Count), Starting=$($session.Starting)); no controller or config was changed."
    }
    return $session
}

function Set-SunshineConfigValue {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'This pure helper returns transformed text and does not change external state.')]
    param([Parameter(Mandatory = $true)][string]$Text, [Parameter(Mandatory = $true)][string]$Key, [Parameter(Mandatory = $true)][string]$Value)
    $pattern = '(?im)^(\s*)' + [regex]::Escape($Key) + '\s*=.*$'
    $configMatches = [regex]::Matches($Text, $pattern)
    if ($configMatches.Count -gt 1) { throw "Sunshine config key is duplicated: $Key" }
    if ($configMatches.Count -eq 1) { return [regex]::Replace($Text, $pattern, ('$1' + $Key + ' = ' + $Value), 1) }
    $separator = if ($Text.EndsWith("`n")) { '' } else { "`r`n" }
    return $Text + $separator + $Key + ' = ' + $Value + "`r`n"
}

function Update-SunshineConfig {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'This private helper runs only inside the explicit -Install transaction and rollback boundary.')]
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][object[]]$Changes,
        [Parameter(Mandatory = $true)][string]$ExpectedHash,
        [Parameter(Mandatory = $true)][ref]$Replaced
    )
    if ((Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash -ne $ExpectedHash) {
        throw 'Sunshine config changed after discovery; rerun the plan before installing.'
    }
    $sddl = Get-FileSddl -Path $Path
    $text = Get-Content -LiteralPath $Path -Raw -Encoding UTF8
    foreach ($change in $Changes) { $text = Set-SunshineConfigValue -Text $text -Key $change.Key -Value ([string]$change.Required) }
    Write-Utf8NoBomAtomic -Path $Path -Text $text -Replaced $Replaced
    Set-FileSddl -Path $Path -Sddl $sddl
    [void](Assert-ProtectedPathAcl -Path $Path)
}

function Save-TaskSnapshot {
    param($Snapshot, [Parameter(Mandatory = $true)][string]$Directory, [Parameter(Mandatory = $true)][string]$Prefix)
    if ($null -eq $Snapshot) { return $null }
    $xmlName = $Prefix + '.xml'; $sddlName = $Prefix + '.sddl.txt'
    Write-Utf8NoBomAtomic -Path (Join-Path $Directory $xmlName) -Text $Snapshot.Xml
    Write-Utf8NoBomAtomic -Path (Join-Path $Directory $sddlName) -Text $Snapshot.Sddl
    [pscustomobject]@{
        Name = $Snapshot.Name; Xml = $xmlName; Sddl = $sddlName; State = $Snapshot.State
        Execute = $Snapshot.Execute; Arguments = $Snapshot.Arguments; WorkingDirectory = $Snapshot.WorkingDirectory
    }
}

function Register-CoexistenceTask {
    param(
        [Parameter(Mandatory = $true)][string]$TaskName,
        [Parameter(Mandatory = $true)][string]$CodeDirectory,
        [Parameter(Mandatory = $true)][string]$Runtime,
        [Parameter(Mandatory = $true)][Security.Principal.WindowsIdentity]$Identity
    )
    $watcher = Join-Path $CodeDirectory 'Watch-StreamingDisplays.ps1'
    $action = New-ScheduledTaskAction -Execute $Runtime -Argument ('-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File "' + $watcher + '"') -WorkingDirectory $CodeDirectory
    $principal = New-ScheduledTaskPrincipal -UserId $Identity.Name -LogonType Interactive -RunLevel Highest
    $trigger = New-ScheduledTaskTrigger -AtLogOn -User $Identity.Name
    $settings = New-ScheduledTaskSettingsSet -ExecutionTimeLimit ([timespan]::Zero) -MultipleInstances IgnoreNew -RestartCount 3 -RestartInterval (New-TimeSpan -Minutes 1) -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries
    Register-ScheduledTask -TaskName $TaskName -Action $action -Principal $principal -Trigger $trigger -Settings $settings -Description 'Bounded Sunshine and Virtual Desktop display coexistence controller.' -Force | Out-Null
}

function Get-ShortcutDetail {
    param([Parameter(Mandatory = $true)][string]$Path)
    $shell = New-Object -ComObject WScript.Shell
    $shortcut = $shell.CreateShortcut($Path)
    return [pscustomobject]@{ TargetPath = $shortcut.TargetPath; Arguments = $shortcut.Arguments; WorkingDirectory = $shortcut.WorkingDirectory }
}

function Set-GpuSelectorShortcut {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'This private helper runs only inside the explicit -Install transaction and rollback boundary.')]
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$Runtime,
        [Parameter(Mandatory = $true)][string]$CodeDirectory
    )
    $shell = New-Object -ComObject WScript.Shell
    $shortcut = $shell.CreateShortcut($Path)
    $shortcut.TargetPath = $Runtime
    $shortcut.Arguments = '-NoProfile -STA -WindowStyle Hidden -ExecutionPolicy Bypass -File "' + (Join-Path $CodeDirectory 'GPU-Selector.ps1') + '"'
    $shortcut.WorkingDirectory = $CodeDirectory
    $shortcut.Description = 'Select the explicitly requested Sunshine streaming GPU.'
    $shortcut.Save()
}

function Get-ManagedMarkerPath { param([string]$Directory) return (Join-Path $Directory '.sunshine-display-coexistence') }

function Test-ManagedDirectory {
    param([Parameter(Mandatory = $true)][string]$Directory, [Parameter(Mandatory = $true)][ValidateSet('Code', 'Data')][string]$Kind)
    if (-not (Test-Path -LiteralPath $Directory -PathType Container)) { return $false }
    $null = Assert-SafePathChain -Path $Directory
    [void](Assert-ProtectedPathAcl -Path $Directory)
    if ($Kind -eq 'Data') {
        $configDirectory = Join-Path $Directory 'config'
        if (-not (Test-Path -LiteralPath $configDirectory -PathType Container)) { return $false }
        $null = Assert-SafePathChain -Path $configDirectory
        [void](Assert-ProtectedPathAcl -Path $configDirectory)
    }
    $marker = if ($Kind -eq 'Code') { Get-ManagedMarkerPath $Directory } else { Join-Path $Directory 'config\.sunshine-display-coexistence' }
    if (-not (Test-Path -LiteralPath $marker -PathType Leaf)) { return $false }
    [void](Assert-ProtectedPathAcl -Path $marker)
    return ((Get-Content -LiteralPath $marker -Raw -Encoding UTF8).Trim() -eq $script:PackageMarker)
}

function Assert-ProtectedCodeTree {
    param([Parameter(Mandatory = $true)][string]$Directory, [Parameter(Mandatory = $true)][string[]]$Files)
    [void](Assert-ProtectedPathAcl -Path $Directory)
    foreach ($file in $Files) {
        $path = Join-Path $Directory $file
        if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { throw "Protected runtime file is missing: $path" }
        $null = Assert-SafePathChain -Path $path
        [void](Assert-ProtectedPathAcl -Path $path)
    }
}

function Undo-InstallTransaction {
    param(
        [bool]$NewTaskRegistered,
        [bool]$NewCodeActivated,
        $Configuration,
        $TaskSnapshot,
        $LegacySnapshot,
        [bool]$ConfigChanged,
        [AllowNull()][string]$ConfigBackup,
        [AllowNull()][string]$ConfigOriginalSddl,
        [object[]]$ShortcutRecords,
        [string]$CodeDirectory,
        [AllowNull()][string]$PreviousCodeBackup,
        [AllowNull()][string]$TransactionRoot,
        [AllowNull()][string]$InstallStatePath,
        [AllowNull()][string]$InstallStateBackup,
        [bool]$ManifestWritten,
        [string]$FailureMessage
    )
    if ($NewTaskRegistered) { Unregister-ScheduledTask -TaskName $Configuration.TaskName -Confirm:$false -ErrorAction SilentlyContinue }
    if ($ConfigChanged -and $ConfigBackup -and (Test-Path -LiteralPath $ConfigBackup)) {
        Copy-Item -LiteralPath $ConfigBackup -Destination $Configuration.SunshineConfigPath -Force
        if ($ConfigOriginalSddl) { Set-FileSddl -Path $Configuration.SunshineConfigPath -Sddl $ConfigOriginalSddl }
    }
    foreach ($shortcut in @($ShortcutRecords)) {
        if ($shortcut.Backup -and (Test-Path -LiteralPath $shortcut.Backup)) {
            Copy-Item -LiteralPath $shortcut.Backup -Destination $shortcut.Path -Force
            if ($shortcut.OriginalSddl) { Set-FileSddl -Path $shortcut.Path -Sddl $shortcut.OriginalSddl }
        } elseif ($shortcut.Disposition -eq 'Created' -and (Test-Path -LiteralPath $shortcut.Path)) {
            Remove-Item -LiteralPath $shortcut.Path -Force
        }
    }
    if ($NewCodeActivated -and (Test-Path -LiteralPath $CodeDirectory -PathType Container) -and
        (Test-ManagedDirectory -Directory $CodeDirectory -Kind Code)) {
        if (-not $TransactionRoot) { throw 'Rollback has no protected transaction directory for the activated code.' }
        $failedCode = Join-Path $TransactionRoot ('failed-code-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
        Move-Item -LiteralPath $CodeDirectory -Destination $failedCode
    }
    if ($PreviousCodeBackup -and (Test-Path -LiteralPath $PreviousCodeBackup -PathType Container)) {
        Move-Item -LiteralPath $PreviousCodeBackup -Destination $CodeDirectory
    }
    # Register prior definitions only after their referenced code has been restored. Starting is deferred until lock release.
    if ($null -ne $TaskSnapshot) { Restore-TaskSnapshot -Snapshot $TaskSnapshot }
    if ($null -ne $LegacySnapshot) { Restore-TaskSnapshot -Snapshot $LegacySnapshot }
    if ($ManifestWritten -and $InstallStatePath -and (Test-Path -LiteralPath $InstallStatePath)) {
        $failedState = Join-Path $TransactionRoot ('install-state.failed-' + [guid]::NewGuid().ToString('N').Substring(0, 8) + '.json')
        Move-Item -LiteralPath $InstallStatePath -Destination $failedState
    }
    if ($InstallStateBackup -and (Test-Path -LiteralPath $InstallStateBackup)) {
        Copy-Item -LiteralPath $InstallStateBackup -Destination $InstallStatePath -Force
        Set-ProtectedFile -Path $InstallStatePath
    }
    if ($TransactionRoot -and (Test-Path -LiteralPath $TransactionRoot)) {
        Write-JsonAtomic -Path (Join-Path $TransactionRoot 'install-failure.json') -Value ([pscustomobject]@{ Time = (Get-Date).ToString('o'); Error = $FailureMessage })
    }
}

if ($Plan -and $Install) { throw 'Choose either -Plan or -Install.' }
$isPlan = $Plan -or -not $Install
$discoveryArguments = @{
    SunshineDirectory = $SunshineDirectory; SunshineConfigPath = $SunshineConfigPath; SunshineLogPath = $SunshineLogPath
    ManagedDriverId = $ManagedDriverId; VirtualDesktopDriverId = $VirtualDesktopDriverId
    CaptureDisplayId = $CaptureDisplayId; VddSettingsPath = $VddSettingsPath
}
$discovery = Get-DisplayHostConfiguration @discoveryArguments
$programFiles = [Environment]::GetFolderPath([Environment+SpecialFolder]::ProgramFiles)
$codeDirectory = Join-Path $programFiles 'Sunshine Display Coexistence'
$dataDirectory = $discovery.HostConfiguration.DataDirectory
$allPackageFiles = @($script:RequiredRuntimeFiles + $script:PackageFiles)
$missingFiles = @($allPackageFiles | Where-Object { -not (Test-Path -LiteralPath (Join-Path $PSScriptRoot $_) -PathType Leaf) })
$runtimeForPlan = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
$taskSnapshot = Get-TaskSnapshot -TaskName $discovery.HostConfiguration.TaskName
$legacySnapshot = Get-TaskSnapshot -TaskName 'Sunshine Streaming Display Lifecycle'
$planBlockers = New-Object System.Collections.Generic.List[string]
foreach ($reason in $discovery.BlockingReasons) { $planBlockers.Add($reason) }
if ($missingFiles.Count -gt 0) { $planBlockers.Add('Package source files are missing: ' + ($missingFiles -join ', ')) }
if ($discovery.SunshineChangesRequired.Count -gt 0 -and -not $ConfigureSunshine) {
    $planBlockers.Add('Sunshine integration changes are required; rerun with -ConfigureSunshine after reviewing the plan.')
}
if ($null -ne $legacySnapshot -and -not $MigrateLegacy) {
    $planBlockers.Add('The legacy Sunshine Streaming Display Lifecycle task exists; migration requires -MigrateLegacy.')
}
if ($null -ne $legacySnapshot -and $MigrateLegacy -and -not (Test-LegacyTaskSnapshot -Snapshot $legacySnapshot -PowerShellPath $runtimeForPlan)) {
    $planBlockers.Add('The legacy task action is not the exact known Moonlight Headless watcher; migration is refused.')
}
if ($null -ne $taskSnapshot -and -not (Test-ManagedTaskSnapshot -Snapshot $taskSnapshot -CodeDirectory $codeDirectory -PowerShellPath $runtimeForPlan)) {
    $planBlockers.Add('The target scheduled task already exists with an unmanaged action.')
}
$managedCode = $false
if (Test-Path -LiteralPath $codeDirectory) {
    try {
        $managedCode = Test-ManagedDirectory -Directory $codeDirectory -Kind Code
        if ($managedCode) { Assert-ProtectedCodeTree -Directory $codeDirectory -Files @($allPackageFiles + @('host.json', '.sunshine-display-coexistence')) }
        else { $planBlockers.Add("Protected code target exists but is unmanaged: $codeDirectory") }
    } catch { $planBlockers.Add("Protected code target failed ACL/content validation: $($_.Exception.Message)") }
}
if (Test-Path -LiteralPath $dataDirectory) {
    try {
        if (-not (Test-ManagedDirectory -Directory $dataDirectory -Kind Data)) {
            $planBlockers.Add("Protected data target exists but is unmanaged: $dataDirectory")
        }
    } catch { $planBlockers.Add("Protected data target failed ACL/content validation: $($_.Exception.Message)") }
}

$planResult = [pscustomobject]@{
    Mode = if ($isPlan) { 'Plan' } else { 'Install' }
    ReadOnly = $isPlan
    Discovery = $discovery
    CodeDirectory = $codeDirectory
    DataDirectory = $dataDirectory
    TaskName = $discovery.HostConfiguration.TaskName
    PackageFiles = $allPackageFiles
    MissingPackageFiles = $missingFiles
    ExistingTargetTask = $taskSnapshot
    ExistingLegacyTask = $legacySnapshot
    ConfigureSunshine = $ConfigureSunshine.IsPresent
    MigrateLegacy = $MigrateLegacy.IsPresent
    BlockingReasons = $planBlockers.ToArray()
    NeedsCaptureDisplayConfigured = $discovery.NeedsCaptureDisplayId
    PlannedSunshineChanges = $discovery.SunshineChangesRequired
    ReadyToInstall = ($planBlockers.Count -eq 0)
    Limitations = @($discovery.Limitations + @(
            'The installer does not restart Sunshine; configuration changes take effect through Sunshine normal lifecycle.',
            'A fresh capture target is never guessed. Missing or unproven targets require -CaptureDisplayId backed by Sunshine log enumeration.',
            'Starting the controller proves task launch only, not live capture, Virtual Desktop handoff, or sustained reliability.'
        ))
}
if ($isPlan) { return ($planResult | ConvertTo-Json -Depth 16) }
if (-not (Test-Administrator)) { throw '-Install requires an explicit elevated administrator PowerShell session.' }
if ($planBlockers.Count -gt 0) { throw ('Install is blocked: ' + ($planBlockers -join ' | ')) }

$null = Assert-SafePathChain -Path $PSScriptRoot
$null = Assert-SafePathChain -Path $programFiles
$null = Assert-SafePathChain -Path (Split-Path $dataDirectory -Parent)
[void](Assert-ProtectedPathAcl -Path $discovery.HostConfiguration.SunshineConfigPath)
if (Test-Path -LiteralPath $codeDirectory) {
    $null = Assert-SafePathChain -Path $codeDirectory
    [void](Assert-ProtectedPathAcl -Path $codeDirectory)
}
if (Test-Path -LiteralPath $dataDirectory) {
    $null = Assert-SafePathChain -Path $dataDirectory
    [void](Assert-ProtectedPathAcl -Path $dataDirectory)
}

$runtime = Get-WindowsPowerShellPath
$identity = [Security.Principal.WindowsIdentity]::GetCurrent()
$timestamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$codeStage = Join-Path $programFiles ('Sunshine Display Coexistence.staging.' + [guid]::NewGuid().ToString('N'))
$dataExists = Test-Path -LiteralPath $dataDirectory
$dataStage = if ($dataExists) { $null } else { Join-Path (Split-Path $dataDirectory -Parent) ('Sunshine Display Coexistence.staging.' + [guid]::NewGuid().ToString('N')) }
$transactionRoot = $null
$previousCodeBackup = $null
$newTaskRegistered = $false
$newCodeActivated = $false
$configChanged = $false
$configBackup = $null
$configOriginalSddl = $null
$configOriginalHash = (Get-FileHash -LiteralPath $discovery.HostConfiguration.SunshineConfigPath -Algorithm SHA256).Hash
$configPostHash = $configOriginalHash
$installStatePath = Join-Path $dataDirectory 'config\install-state.json'
$installStateBackup = $null
$manifestWritten = $false
$mutex = $null
$success = $false
$shortcutRecords = New-Object System.Collections.Generic.List[object]
$installWarnings = New-Object System.Collections.Generic.List[string]
$targetWasRunning = ($null -ne $taskSnapshot -and $taskSnapshot.State -eq 'Running')
$legacyWasRunning = ($null -ne $legacySnapshot -and $legacySnapshot.State -eq 'Running')

try {
    Set-ProtectedDirectory -Path $codeStage
    Write-Utf8NoBomAtomic -Path (Get-ManagedMarkerPath $codeStage) -Text ($script:PackageMarker + "`r`n")
    $sourceHashes = [ordered]@{}
    foreach ($file in $allPackageFiles) {
        $source = Join-Path $PSScriptRoot $file
        $null = Assert-SafePathChain -Path $source
        if ((Get-Item -LiteralPath $source).Attributes -band [IO.FileAttributes]::ReparsePoint) { throw "Package source is a reparse point: $source" }
        $stagedFile = Join-Path $codeStage $file
        Copy-Item -LiteralPath $source -Destination $stagedFile
        Set-ProtectedFile -Path $stagedFile
        $sourceHash = (Get-FileHash -LiteralPath $source -Algorithm SHA256).Hash
        $destinationHash = (Get-FileHash -LiteralPath $stagedFile -Algorithm SHA256).Hash
        if ($sourceHash -ne $destinationHash) { throw "Staged package hash mismatch: $file" }
        $sourceHashes[$file] = $destinationHash
    }
    Write-JsonAtomic -Path (Join-Path $codeStage 'host.json') -Value $discovery.HostConfiguration

    if (-not $dataExists) {
        Set-ProtectedDirectory -Path $dataStage
        Set-ProtectedDirectory -Path (Join-Path $dataStage 'config')
        Set-ProtectedDirectory -Path (Join-Path $dataStage 'recovery')
        Write-Utf8NoBomAtomic -Path (Join-Path $dataStage 'config\.sunshine-display-coexistence') -Text ($script:PackageMarker + "`r`n")
        Move-Item -LiteralPath $dataStage -Destination $dataDirectory
        $dataStage = $null
        [void](Test-ManagedDirectory -Directory $dataDirectory -Kind Data)
    } else {
        foreach ($subdirectory in @('config', 'recovery')) {
            $path = Join-Path $dataDirectory $subdirectory
            if (-not (Test-Path -LiteralPath $path -PathType Container)) { throw "Managed data directory is missing $subdirectory." }
            $null = Assert-SafePathChain -Path $path
            [void](Assert-ProtectedPathAcl -Path $path)
        }
    }
    $transactionRoot = Join-Path $dataDirectory ('recovery\install-' + $timestamp + '-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
    Set-ProtectedDirectory -Path $transactionRoot
    if (Test-Path -LiteralPath $installStatePath -PathType Leaf) {
        $installStateBackup = Join-Path $transactionRoot 'install-state.before.json'
        [void](Assert-ProtectedPathAcl -Path $installStatePath)
        Copy-Item -LiteralPath $installStatePath -Destination $installStateBackup
        Set-ProtectedFile -Path $installStateBackup
    }
    $savedTarget = Save-TaskSnapshot -Snapshot $taskSnapshot -Directory $transactionRoot -Prefix 'target-task-before'
    $savedLegacy = Save-TaskSnapshot -Snapshot $legacySnapshot -Directory $transactionRoot -Prefix 'legacy-task-before'
    if ($discovery.SunshineChangesRequired.Count -gt 0) {
        $configBackup = Join-Path $transactionRoot 'sunshine.conf.before'
        Copy-Item -LiteralPath $discovery.HostConfiguration.SunshineConfigPath -Destination $configBackup
        Set-ProtectedFile -Path $configBackup
        $configOriginalSddl = Get-FileSddl -Path $discovery.HostConfiguration.SunshineConfigPath
        Write-Utf8NoBomAtomic -Path (Join-Path $transactionRoot 'sunshine.conf.before.sddl.txt') -Text $configOriginalSddl
    }

    $mutex = Enter-DisplayMutex
    [void](Assert-SafeIdleSession -SessionPolicyPath (Join-Path $codeStage 'SessionPolicy.psm1') -Configuration $discovery.HostConfiguration)
    if ($null -ne $taskSnapshot) {
        [void](Assert-SafeIdleSession -SessionPolicyPath (Join-Path $codeStage 'SessionPolicy.psm1') -Configuration $discovery.HostConfiguration)
        Stop-TaskAndWait -TaskName $taskSnapshot.Name
    }
    if ($null -ne $legacySnapshot) {
        [void](Assert-SafeIdleSession -SessionPolicyPath (Join-Path $codeStage 'SessionPolicy.psm1') -Configuration $discovery.HostConfiguration)
        Stop-TaskAndWait -TaskName $legacySnapshot.Name
        Unregister-ScheduledTask -TaskName $legacySnapshot.Name -Confirm:$false
    }
    if ($discovery.SunshineChangesRequired.Count -gt 0) {
        [void](Assert-SafeIdleSession -SessionPolicyPath (Join-Path $codeStage 'SessionPolicy.psm1') -Configuration $discovery.HostConfiguration)
        Update-SunshineConfig -Path $discovery.HostConfiguration.SunshineConfigPath -Changes $discovery.SunshineChangesRequired -ExpectedHash $configOriginalHash -Replaced ([ref]$configChanged)
        $configPostHash = (Get-FileHash -LiteralPath $discovery.HostConfiguration.SunshineConfigPath -Algorithm SHA256).Hash
    }
    if (Test-Path -LiteralPath $codeDirectory) {
        $previousCodeBackup = Join-Path $transactionRoot 'code-before'
        Move-Item -LiteralPath $codeDirectory -Destination $previousCodeBackup
    }
    Move-Item -LiteralPath $codeStage -Destination $codeDirectory
    $codeStage = $null
    $newCodeActivated = $true
    Assert-ProtectedCodeTree -Directory $codeDirectory -Files @($allPackageFiles + @('host.json', '.sunshine-display-coexistence'))
    Register-CoexistenceTask -TaskName $discovery.HostConfiguration.TaskName -CodeDirectory $codeDirectory -Runtime $runtime -Identity $identity
    $newTaskRegistered = $true
    [void](Set-TaskSecurityReadExecute -TaskName $discovery.HostConfiguration.TaskName -UserSid $identity.User)
    $desktop = [Environment]::GetFolderPath([Environment+SpecialFolder]::DesktopDirectory)
    if (-not [string]::IsNullOrWhiteSpace($desktop) -and (Test-Path -LiteralPath $desktop -PathType Container)) {
        try { $null = Assert-SafePathChain -Path $desktop }
        catch { $installWarnings.Add("GPU selector shortcut was skipped because the Desktop path is unsafe: $($_.Exception.Message)"); $desktop = $null }
    }
    if ($desktop) {
        $sunshineShortcut = Join-Path $desktop 'Sunshine GPU Selector.lnk'
        $sunshineBackup = $null
        $sunshineOriginalSddl = $null
        $sunshineDisposition = 'Created'
        $writeSunshineShortcut = $true
        if (Test-Path -LiteralPath $sunshineShortcut -PathType Leaf) {
            $existingShortcut = Get-ShortcutDetail -Path $sunshineShortcut
            $existingScript = Get-TaskScriptPath $existingShortcut.Arguments
            if ($existingShortcut.TargetPath -ieq $runtime -and $existingScript -ieq (Join-Path $codeDirectory 'GPU-Selector.ps1')) {
                $sunshineBackup = Join-Path $transactionRoot 'sunshine-gpu-selector.before.lnk'
                $sunshineOriginalSddl = Get-FileSddl -Path $sunshineShortcut
                Copy-Item -LiteralPath $sunshineShortcut -Destination $sunshineBackup
                Set-ProtectedFile -Path $sunshineBackup
                $sunshineDisposition = 'Replaced'
            } else {
                $writeSunshineShortcut = $false
                $installWarnings.Add("Existing unmanaged shortcut was left unchanged: $sunshineShortcut")
            }
        }
        if ($writeSunshineShortcut) {
            Set-GpuSelectorShortcut -Path $sunshineShortcut -Runtime $runtime -CodeDirectory $codeDirectory
            $shortcutRecords.Add([pscustomobject]@{ Path = $sunshineShortcut; Backup = $sunshineBackup; OriginalSddl = $sunshineOriginalSddl; Disposition = $sunshineDisposition })
        }

        $legacyShortcut = Join-Path $desktop 'Moonlight GPU Selector.lnk'
        if ($MigrateLegacy -and (Test-Path -LiteralPath $legacyShortcut -PathType Leaf)) {
            $legacyDetails = Get-ShortcutDetail -Path $legacyShortcut
            $legacyScript = Get-TaskScriptPath $legacyDetails.Arguments
            if ($legacyScript -and [IO.Path]::GetFileName($legacyScript) -ieq 'GPU-Selector.ps1' -and
                [IO.Path]::GetFileName((Split-Path $legacyScript -Parent)) -ieq 'Moonlight Headless') {
                $legacyBackup = Join-Path $transactionRoot 'moonlight-gpu-selector.before.lnk'
                $legacyOriginalSddl = Get-FileSddl -Path $legacyShortcut
                Copy-Item -LiteralPath $legacyShortcut -Destination $legacyBackup
                Set-ProtectedFile -Path $legacyBackup
                Set-GpuSelectorShortcut -Path $legacyShortcut -Runtime $runtime -CodeDirectory $codeDirectory
                $shortcutRecords.Add([pscustomobject]@{ Path = $legacyShortcut; Backup = $legacyBackup; OriginalSddl = $legacyOriginalSddl; Disposition = 'ReplacedLegacy' })
            }
        }
    }
    $installedHashes = [ordered]@{}
    foreach ($file in @($allPackageFiles + @('host.json', '.sunshine-display-coexistence'))) {
        $installedHashes[$file] = (Get-FileHash -LiteralPath (Join-Path $codeDirectory $file) -Algorithm SHA256).Hash
    }
    $manifest = [pscustomobject][ordered]@{
        SchemaVersion = 1
        ManagedBy = $script:PackageMarker
        InstalledAt = (Get-Date).ToString('o')
        CodeDirectory = $codeDirectory
        DataDirectory = $dataDirectory
        TaskName = $discovery.HostConfiguration.TaskName
        UserName = $identity.Name
        UserSid = $identity.User.Value
        Runtime = $runtime
        TransactionDirectory = $transactionRoot
        PreviousCodeBackup = $previousCodeBackup
        OriginalTargetTask = $savedTarget
        OriginalLegacyTask = $savedLegacy
        ConfigChanged = $configChanged
        SunshineConfigPath = $discovery.HostConfiguration.SunshineConfigPath
        SunshineConfigBackup = $configBackup
        SunshineConfigOriginalSddl = $configOriginalSddl
        SunshineConfigOriginalHash = $configOriginalHash
        SunshineConfigPostInstallHash = $configPostHash
        InstalledHashes = $installedHashes
        Shortcuts = $shortcutRecords.ToArray()
    }
    Write-JsonAtomic -Path $installStatePath -Value $manifest -Depth 12 -Replaced ([ref]$manifestWritten)
    $success = $true
} catch {
    $failure = $_
    $rollbackSucceeded = $false
    try {
        Undo-InstallTransaction -NewTaskRegistered $newTaskRegistered -NewCodeActivated $newCodeActivated -Configuration $discovery.HostConfiguration `
            -TaskSnapshot $taskSnapshot -LegacySnapshot $legacySnapshot -ConfigChanged $configChanged -ConfigBackup $configBackup `
            -ConfigOriginalSddl $configOriginalSddl -ShortcutRecords $shortcutRecords.ToArray() -CodeDirectory $codeDirectory `
            -PreviousCodeBackup $previousCodeBackup -TransactionRoot $transactionRoot -InstallStatePath $installStatePath `
            -InstallStateBackup $installStateBackup -ManifestWritten $manifestWritten -FailureMessage $failure.Exception.Message
        $rollbackSucceeded = $true
    } catch {
        $failure = New-Object Management.Automation.ErrorRecord(
            (New-Object InvalidOperationException("Install failed: $($failure.Exception.Message). Rollback also failed: $($_.Exception.Message)")),
            'DisplayCoexistenceRollbackFailed', [Management.Automation.ErrorCategory]::InvalidOperation, $null)
    }
    if ($null -ne $mutex) { $mutex.ReleaseMutex(); $mutex.Dispose(); $mutex = $null }
    if ($rollbackSucceeded) {
        if ($targetWasRunning) { Start-ScheduledTask -TaskName $taskSnapshot.Name }
        if ($legacyWasRunning) { Start-ScheduledTask -TaskName $legacySnapshot.Name }
    }
    throw $failure
} finally {
    if ($null -ne $mutex) { $mutex.ReleaseMutex(); $mutex.Dispose() }
    if ($codeStage -and (Test-Path -LiteralPath $codeStage) -and [IO.Path]::GetFileName($codeStage) -like 'Sunshine Display Coexistence.staging.*') {
        Remove-Item -LiteralPath $codeStage -Recurse -Force
    }
    if ($dataStage -and (Test-Path -LiteralPath $dataStage) -and [IO.Path]::GetFileName($dataStage) -like 'Sunshine Display Coexistence.staging.*') {
        Remove-Item -LiteralPath $dataStage -Recurse -Force
    }
}

if ($success) {
    $statePath = Join-Path $dataDirectory 'automatic-display-state.json'
    $startedAt = Get-Date
    try {
        Assert-ProtectedCodeTree -Directory $codeDirectory -Files @($allPackageFiles + @('host.json', '.sunshine-display-coexistence'))
        [void](Assert-ProtectedPathAcl -Path $installStatePath)
        Start-ScheduledTask -TaskName $discovery.HostConfiguration.TaskName
        $startupVerified = $false
        for ($attempt = 0; $attempt -lt 40; $attempt++) {
            Start-Sleep -Milliseconds 500
            $task = Get-ScheduledTask -TaskName $discovery.HostConfiguration.TaskName -ErrorAction Stop
            if ($task.State -ne 'Running') { continue }
            if (-not (Test-Path -LiteralPath $statePath -PathType Leaf)) { continue }
            $stateItem = Get-Item -LiteralPath $statePath
            if ($stateItem.LastWriteTime -lt $startedAt.AddSeconds(-1)) { continue }
            try {
                Set-ProtectedFile -Path $statePath
                $reported = Get-Content -LiteralPath $statePath -Raw -Encoding UTF8 | ConvertFrom-Json
            } catch { continue }
            if (-not $reported.ControllerPid) { continue }
            $controllerProcess = Get-Process -Id ([int]$reported.ControllerPid) -ErrorAction SilentlyContinue
            if (-not $controllerProcess -or $controllerProcess.StartTime -lt $startedAt.AddSeconds(-1) -or $controllerProcess.Path -ine $runtime) { continue }
            $controllerCim = Get-CimInstance -ClassName Win32_Process -Filter ('ProcessId = ' + [int]$reported.ControllerPid) -ErrorAction SilentlyContinue
            if ($null -eq $controllerCim -or [string]$controllerCim.ExecutablePath -ine $runtime) { continue }
            $reportedScript = Get-TaskScriptPath -Arguments ([string]$controllerCim.CommandLine)
            if ($reportedScript -ine (Join-Path $codeDirectory 'Watch-StreamingDisplays.ps1')) { continue }
            $startupVerified = $true
            break
        }
        if (-not $startupVerified) { throw 'The controller task did not remain running and report a new live ControllerPid.' }
    } catch {
        $startupFailure = $_
        $startupMutex = $null
        try {
            $startupMutex = Enter-DisplayMutex
            if ($configChanged) {
                [void](Assert-SafeIdleSession -SessionPolicyPath (Join-Path $codeDirectory 'SessionPolicy.psm1') -Configuration $discovery.HostConfiguration)
            }
            Stop-TaskAndWait -TaskName $discovery.HostConfiguration.TaskName
            Undo-InstallTransaction -NewTaskRegistered $true -NewCodeActivated $true -Configuration $discovery.HostConfiguration `
                -TaskSnapshot $taskSnapshot -LegacySnapshot $legacySnapshot -ConfigChanged $configChanged -ConfigBackup $configBackup `
                -ConfigOriginalSddl $configOriginalSddl -ShortcutRecords $shortcutRecords.ToArray() -CodeDirectory $codeDirectory `
                -PreviousCodeBackup $previousCodeBackup -TransactionRoot $transactionRoot -InstallStatePath $installStatePath `
                -InstallStateBackup $installStateBackup -ManifestWritten $manifestWritten -FailureMessage $startupFailure.Exception.Message
        } catch {
            throw "Controller startup failed: $($startupFailure.Exception.Message). Safe rollback could not complete: $($_.Exception.Message). Recovery is retained at $transactionRoot."
        } finally {
            if ($startupMutex) { $startupMutex.ReleaseMutex(); $startupMutex.Dispose() }
        }
        if ($targetWasRunning) { Start-ScheduledTask -TaskName $taskSnapshot.Name }
        if ($legacyWasRunning) { Start-ScheduledTask -TaskName $legacySnapshot.Name }
        throw "Controller startup failed and the prior installation state was restored: $($startupFailure.Exception.Message)"
    }
}

[pscustomobject]@{
    Success = $true
    ChangedPaths = @($codeDirectory, $dataDirectory, (Join-Path $dataDirectory 'config\install-state.json'))
    TaskName = $discovery.HostConfiguration.TaskName
    TaskStartedAfterMutexRelease = $true
    SunshineConfigChanged = $configChanged
    RecoveryDirectory = $transactionRoot
    TestsRun = @('Provider identity validation', 'Sunshine capture UUID to MTT1337 log mapping', 'Protected-path/reparse checks', 'Source/destination SHA256 checks', 'SessionPolicy safe-idle gate', 'Scheduled-task action and ACL verification')
    Warnings = $installWarnings.ToArray()
    Limitations = $planResult.Limitations
}
