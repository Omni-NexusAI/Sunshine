<#
.SYNOPSIS
Runs offline tests for the Sunshine display-coexistence policy and recovery parser.

.DESCRIPTION
Imports SessionPolicy.psm1, compiles DisplayTools.cs once, parses every PowerShell
file in the package without executing scripts, and uses only uniquely owned test
fixtures below .claude/.scratch. The tests do not call display Apply methods,
installers, services, scheduled tasks, device tools, or native display mutation APIs.

.PARAMETER ReportPath
Optional path for a JSON report. Its parent directory must already exist.

.EXAMPLE
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tools\display-coexistence\tests\Test-DisplayCoexistence.ps1

.EXAMPLE
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tools\display-coexistence\tests\Test-DisplayCoexistence.ps1 -ReportPath .\.claude\display-coexistence-tests.json
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $false)]
    [string] $ReportPath
)

Set-StrictMode -Version 2
$ErrorActionPreference = 'Stop'

$script:Results = @()
$utf8NoBom = New-Object System.Text.UTF8Encoding($false)
$testsRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$packageRoot = Split-Path -Parent $testsRoot
$repoRoot = Split-Path -Parent (Split-Path -Parent $packageRoot)
$scratchRoot = Join-Path $repoRoot '.claude\.scratch'
$fixtureName = 'Test-DisplayCoexistence-{0}-{1}' -f $PID, ([guid]::NewGuid().ToString('N'))
$fixtureRoot = Join-Path $scratchRoot $fixtureName
$policyPath = Join-Path $packageRoot 'SessionPolicy.psm1'
$displayToolsPath = Join-Path $packageRoot 'DisplayTools.cs'
$sessionPolicyModule = $null

function Assert-True {
    param([bool] $Condition, [string] $Message)
    if (-not $Condition) { throw $Message }
}

function Assert-Equal {
    param($Expected, $Actual, [string] $Message)
    if ($Expected -ne $Actual) {
        throw ('{0} Expected <{1}> but received <{2}>.' -f $Message, $Expected, $Actual)
    }
}

function Write-FixtureText {
    param([string] $Path, [string] $Text)
    [System.IO.File]::WriteAllText($Path, $Text, $utf8NoBom)
}

function Add-FixtureText {
    param([string] $Path, [string] $Text)
    [System.IO.File]::AppendAllText($Path, $Text, $utf8NoBom)
}

function New-LogPath {
    param([string] $Name)
    return (Join-Path $fixtureRoot ($Name + '.log'))
}

function Write-LargeSessionLog {
    param(
        [string] $Path,
        [string] $Prefix,
        [long] $MinimumBytes,
        [string] $Suffix = ''
    )
    $stream = [System.IO.File]::Create($Path)
    try {
        $prefixBytes = $utf8NoBom.GetBytes($Prefix)
        $stream.Write($prefixBytes, 0, $prefixBytes.Length)
        $fillerBytes = $utf8NoBom.GetBytes(([string]::new('x', 1023) + "`n"))
        while ($stream.Length -lt $MinimumBytes) {
            $stream.Write($fillerBytes, 0, $fillerBytes.Length)
        }
        if ($Suffix) {
            $suffixBytes = $utf8NoBom.GetBytes($Suffix)
            $stream.Write($suffixBytes, 0, $suffixBytes.Length)
        }
    } finally {
        $stream.Dispose()
    }
}

function New-SyntheticSessionRuntime {
    param([string] $Name, [string] $LogPath)
    $root = Join-Path $fixtureRoot $Name
    $configDirectory = Join-Path $root 'config'
    [void](New-Item -ItemType Directory -Path $configDirectory)
    $configPath = Join-Path $configDirectory 'sunshine.conf'
    Write-FixtureText $configPath "min_log_level = info`r`nlog_path = `"$LogPath`"`r`n"
    $processStart = (Get-Date).AddMinutes(-3)
    $processStart = $processStart.AddTicks(-($processStart.Ticks % [TimeSpan]::TicksPerMillisecond))
    return [pscustomobject]@{
        Configuration = [pscustomobject]@{
            SunshineDirectory = $root
            SunshineConfigPath = $configPath
            SunshineLogPath = $LogPath
            SunshineExe = Join-Path $root 'sunshine.exe'
            RtspPort = 48010
        }
        Process = [pscustomobject]@{
            Id = 41001
            Path = Join-Path $root 'sunshine.exe'
            StartTime = $processStart
        }
    }
}

function Invoke-WithMockedSessionRuntime {
    param($Process, [scriptblock] $Body)
    if ($null -eq $sessionPolicyModule) { throw 'SessionPolicy module is not loaded.' }
    & $sessionPolicyModule {
        param($SyntheticProcess)
        $script:DisplayCoexistenceTestProcess = $SyntheticProcess
        Set-Item -Path 'Function:script:Get-Process' -Value {
            [CmdletBinding()]
            param([string] $Name)
            if ($Name -ne 'sunshine') { throw ('Unexpected process query in offline test: ' + $Name) }
            return $script:DisplayCoexistenceTestProcess
        }
        Set-Item -Path 'Function:script:Get-NetTCPConnection' -Value {
            [CmdletBinding()]
            param([int] $LocalPort, [string] $State)
            if ($State -ne 'Established') { throw ('Unexpected TCP state query in offline test: ' + $State) }
            return @()
        }
    } $Process
    $mockText = & $sessionPolicyModule {
        return (Get-Command Get-Process -CommandType Function).ScriptBlock.ToString()
    }
    Assert-True ($mockText -match 'DisplayCoexistenceTestProcess') 'Module-scoped process mock was not installed.'
    try {
        & $Body
    } finally {
        & $sessionPolicyModule {
            Remove-Item -Path 'Function:script:Get-Process' -ErrorAction SilentlyContinue
            Remove-Item -Path 'Function:script:Get-NetTCPConnection' -ErrorAction SilentlyContinue
            Remove-Variable -Name DisplayCoexistenceTestProcess -Scope Script -ErrorAction SilentlyContinue
        }
    }
}

function Invoke-TestCase {
    param([string] $Name, [scriptblock] $Body)
    $started = Get-Date
    try {
        & $Body
        $result = [pscustomobject]@{
            Name = $Name
            Passed = $true
            DurationMs = [math]::Round(((Get-Date) - $started).TotalMilliseconds, 2)
            Error = $null
        }
        Write-Output ('[PASS] {0}' -f $Name)
    } catch {
        $result = [pscustomobject]@{
            Name = $Name
            Passed = $false
            DurationMs = [math]::Round(((Get-Date) - $started).TotalMilliseconds, 2)
            Error = $_.Exception.Message
        }
        Write-Output ('[FAIL] {0}: {1}' -f $Name, $_.Exception.Message)
    }
    $script:Results += $result
}

function Assert-RecoveryRejectedBeforeNativeCall {
    param(
        [string] $Path,
        [string] $ExpectedMessage,
        [string] $ExpectedExceptionType
    )
    $caught = $null
    try {
        [void][SunshineDisplays]::RestoreTopology($Path)
    } catch {
        $caught = $_.Exception
    }
    Assert-True ($null -ne $caught) 'Malformed topology was accepted.'
    $current = $caught
    while ($null -ne $current.InnerException) { $current = $current.InnerException }
    if ($ExpectedMessage) {
        Assert-True ($caught.ToString().Contains($ExpectedMessage)) ('Expected rejection message was absent: ' + $ExpectedMessage)
    }
    if ($ExpectedExceptionType) {
        Assert-Equal $ExpectedExceptionType $current.GetType().FullName 'Unexpected deepest exception type.'
    }
    Assert-True (-not $caught.ToString().Contains('SetDisplayConfig')) 'Malformed input reached the native apply boundary.'
}

if (-not (Test-Path -LiteralPath $scratchRoot -PathType Container)) {
    [void](New-Item -ItemType Directory -Path $scratchRoot)
}
if (Test-Path -LiteralPath $fixtureRoot) {
    throw ('Refusing to reuse an existing fixture directory: ' + $fixtureRoot)
}
[void](New-Item -ItemType Directory -Path $fixtureRoot)

try {
    Invoke-TestCase 'PowerShell package files parse without execution' {
        $files = @(Get-ChildItem -LiteralPath $packageRoot -Recurse -File | Where-Object { $_.Extension -in @('.ps1', '.psm1') })
        Assert-True ($files.Count -gt 0) 'No package PowerShell files were found.'
        foreach ($file in $files) {
            $tokens = $null
            $parseErrors = $null
            [void][System.Management.Automation.Language.Parser]::ParseFile($file.FullName, [ref]$tokens, [ref]$parseErrors)
            Assert-Equal 0 @($parseErrors).Count ('PowerShell parse errors in ' + $file.FullName)
        }
    }

    Invoke-TestCase 'Task ACL failure retains successful registration bookkeeping in memory' {
        $installPath = Join-Path $packageRoot 'Install-DisplayCoexistence.ps1'
        $tokens = $null
        $parseErrors = $null
        $installAst = [System.Management.Automation.Language.Parser]::ParseFile($installPath, [ref]$tokens, [ref]$parseErrors)
        Assert-Equal 0 @($parseErrors).Count 'Installer could not be parsed for fault injection.'
        $transactionTry = @($installAst.FindAll({
                    param($node)
                    $node -is [System.Management.Automation.Language.TryStatementAst] -and
                    $node.Body.Extent.Text -match 'Register-CoexistenceTask' -and
                    $node.Body.Extent.Text -match 'Set-TaskSecurityReadExecute'
                }, $true))[0]
        Assert-True ($null -ne $transactionTry) 'Installer transaction try block was not found.'
        $statements = @($transactionTry.Body.Statements)
        $registerIndex = -1; $bookkeepingIndex = -1; $aclIndex = -1
        for ($index = 0; $index -lt $statements.Count; $index++) {
            $statementText = $statements[$index].Extent.Text
            if ($statementText -match '^\s*Register-CoexistenceTask\b') { $registerIndex = $index }
            elseif ($statementText -match '^\s*\$newTaskRegistered\s*=\s*\$true\s*$') { $bookkeepingIndex = $index }
            elseif ($statementText -match '^\s*\[void\]\(Set-TaskSecurityReadExecute\b') { $aclIndex = $index }
        }
        Assert-True ($registerIndex -ge 0 -and $bookkeepingIndex -ge 0 -and $aclIndex -ge 0) 'Installer task registration sequence is incomplete.'
        Assert-True ($registerIndex -lt $bookkeepingIndex -and $bookkeepingIndex -lt $aclIndex) 'Task registration bookkeeping is not established before ACL application.'
        $exactSequence = @(
            $statements[$registerIndex].Extent.Text
            $statements[$bookkeepingIndex].Extent.Text
            $statements[$aclIndex].Extent.Text
        ) -join "`r`n"
        $harnessText = @'
$probe = @{ RegisterCalls = 0; AclCalls = 0 }
function Register-CoexistenceTask {
    param($TaskName, $CodeDirectory, $Runtime, $Identity)
    $probe.RegisterCalls++
}
function Set-TaskSecurityReadExecute {
    param($TaskName, $UserSid)
    $probe.AclCalls++
    throw 'Injected task ACL failure'
}
$discovery = [pscustomobject]@{ HostConfiguration = [pscustomobject]@{ TaskName = 'Synthetic Task' } }
$codeDirectory = 'X:\synthetic-code'
$runtime = 'X:\synthetic-powershell.exe'
$identity = [pscustomobject]@{ User = 'S-1-5-21-synthetic' }
$newTaskRegistered = $false
$caught = $null
try {
'@ + $exactSequence + @'
} catch {
    $caught = $_.Exception.Message
}
[pscustomobject]@{
    RegisterCalls = $probe.RegisterCalls
    AclCalls = $probe.AclCalls
    NewTaskRegistered = $newTaskRegistered
    Error = $caught
}
'@
        $probeResult = & ([scriptblock]::Create($harnessText))
        Assert-Equal 1 $probeResult.RegisterCalls 'In-memory task registration call count mismatch.'
        Assert-Equal 1 $probeResult.AclCalls 'In-memory task ACL call count mismatch.'
        Assert-True $probeResult.NewTaskRegistered 'ACL failure lost successful task-registration bookkeeping.'
        Assert-Equal 'Injected task ACL failure' $probeResult.Error 'Injected ACL failure was not observed.'
    }

    Invoke-TestCase 'Uninstall failure restores current code and manifest in memory' {
        $uninstallPath = Join-Path $packageRoot 'Uninstall-DisplayCoexistence.ps1'
        $tokens = $null
        $parseErrors = $null
        $uninstallAst = [System.Management.Automation.Language.Parser]::ParseFile($uninstallPath, [ref]$tokens, [ref]$parseErrors)
        Assert-Equal 0 @($parseErrors).Count 'Uninstaller could not be parsed for fault injection.'
        $transactionTry = @($uninstallAst.FindAll({
                    param($node)
                    $node -is [System.Management.Automation.Language.TryStatementAst] -and
                    $node.Body.Extent.Text -match '\$previousInstallStateRestored\s*=\s*\$true' -and
                    $node.CatchClauses.Count -gt 0
                }, $true))[0]
        Assert-True ($null -ne $transactionTry) 'Uninstaller transaction try block was not found.'
        $forwardSwap = @($transactionTry.Body.FindAll({
                    param($node)
                    $node -is [System.Management.Automation.Language.IfStatementAst] -and
                    $node.Extent.Text -match '\$manifest\.PreviousCodeBackup' -and
                    $node.Extent.Text -match '\$previousInstallStateRestored\s*=\s*\$true'
                }, $true))[0]
        Assert-True ($null -ne $forwardSwap) 'Uninstaller code-and-manifest swap block was not found.'
        $rollbackTry = @($transactionTry.CatchClauses[0].Body.FindAll({
                    param($node)
                    $node -is [System.Management.Automation.Language.TryStatementAst] -and
                    $node.Body.Extent.Text -match '\$previousInstallStateRestored' -and
                    $node.Body.Extent.Text -match '\$currentCodeMoved'
                }, $true))[0]
        Assert-True ($null -ne $rollbackTry) 'Uninstaller rollback try block was not found.'
        $rollbackStatements = @($rollbackTry.Body.Statements | Where-Object {
                $_ -is [System.Management.Automation.Language.IfStatementAst] -and
                ($_.Extent.Text -match '^\s*if \(\$previousInstallStateRestored' -or
                    $_.Extent.Text -match '^\s*if \(\$previousCodeRestored' -or
                    $_.Extent.Text -match '^\s*if \(\$currentCodeMoved')
            })
        Assert-Equal 3 $rollbackStatements.Count 'Uninstaller rollback does not expose all three code/manifest restore branches.'
        $rollbackText = @($rollbackStatements | ForEach-Object { $_.Extent.Text }) -join "`r`n"
        $harnessText = @'
$store = @{
    'C:\__DisplayCoexistenceSynthetic\code' = 'current-code'
    'C:\__DisplayCoexistenceSynthetic\data\previous-code' = 'previous-code'
    'C:\__DisplayCoexistenceSynthetic\data\state.json' = 'current-manifest'
    'C:\__DisplayCoexistenceSynthetic\data\previous-state.json' = 'previous-manifest'
}
function Test-Path {
    param([string]$LiteralPath, [string]$PathType)
    return $store.ContainsKey($LiteralPath)
}
function Move-Item {
    param([string]$LiteralPath, [string]$Destination)
    if (-not $store.ContainsKey($LiteralPath)) { throw ('Synthetic source is absent: ' + $LiteralPath) }
    $store[$Destination] = $store[$LiteralPath]
    $store.Remove($LiteralPath)
}
function Copy-Item {
    param([string]$LiteralPath, [string]$Destination, [switch]$Force)
    if (-not $store.ContainsKey($LiteralPath)) { throw ('Synthetic source is absent: ' + $LiteralPath) }
    $store[$Destination] = $store[$LiteralPath]
}
function Set-ProtectedFile { param([string]$Path) }
function Assert-ContainedPath { param([string]$Path, [string]$Root) return $Path }
function Assert-ProtectedTreeAcl { param([string]$Root) }
$manifest = [pscustomobject]@{ PreviousCodeBackup = 'C:\__DisplayCoexistenceSynthetic\data\previous-code' }
$dataDirectory = 'C:\__DisplayCoexistenceSynthetic\data'
$uninstallRecovery = 'C:\__DisplayCoexistenceSynthetic\recovery'
$codeDirectory = 'C:\__DisplayCoexistenceSynthetic\code'
$statePath = 'C:\__DisplayCoexistenceSynthetic\data\state.json'
$previousInstallState = 'C:\__DisplayCoexistenceSynthetic\data\previous-state.json'
$currentCodeMoved = $false
$previousCodeRestored = $false
$currentCodeBackup = $null
$currentInstallStateBackup = $null
$previousInstallStateRestored = $false
$caught = $null
try {
'@ + $forwardSwap.Extent.Text + @'
    throw 'Injected post-swap uninstall failure'
} catch {
    $caught = $_.Exception.Message
'@ + "`r`n" + $rollbackText + "`r`n" + @'
}
[pscustomobject]@{
    ActiveCode = $store['C:\__DisplayCoexistenceSynthetic\code']
    PreviousCode = $store['C:\__DisplayCoexistenceSynthetic\data\previous-code']
    ActiveManifest = $store['C:\__DisplayCoexistenceSynthetic\data\state.json']
    Error = $caught
    CurrentCodeMoved = $currentCodeMoved
    PreviousCodeRestored = $previousCodeRestored
}
'@
        $probeResult = & ([scriptblock]::Create($harnessText))
        Assert-Equal 'current-code' $probeResult.ActiveCode 'Rollback did not restore the current code directory.'
        Assert-Equal 'previous-code' $probeResult.PreviousCode 'Rollback did not return previous code to its recovery location.'
        Assert-Equal 'current-manifest' $probeResult.ActiveManifest 'Rollback did not restore the current install manifest.'
        Assert-Equal 'Injected post-swap uninstall failure' $probeResult.Error 'Injected uninstall failure was not observed.'
        Assert-True (-not $probeResult.CurrentCodeMoved) 'Current-code move bookkeeping was not cleared by rollback.'
        Assert-True (-not $probeResult.PreviousCodeRestored) 'Previous-code restore bookkeeping was not cleared by rollback.'
    }

    Invoke-TestCase 'Sunshine config writer atomically preserves output key and Unicode without BOM' {
        $selectorPath = Join-Path $packageRoot 'Select-StreamingGPU.ps1'
        $tokens = $null
        $parseErrors = $null
        $selectorAst = [System.Management.Automation.Language.Parser]::ParseFile($selectorPath, [ref]$tokens, [ref]$parseErrors)
        Assert-Equal 0 @($parseErrors).Count 'GPU selector could not be parsed for config-writer extraction.'
        $writerFunction = @($selectorAst.FindAll({
                    param($node)
                    $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'Write-SunshineConfig'
                }, $true))[0]
        Assert-True ($null -ne $writerFunction) 'Write-SunshineConfig was not found.'

        $writerRoot = Join-Path $fixtureRoot 'sunshine-config-writer'
        [void](New-Item -ItemType Directory -Path $writerRoot)
        $configPath = Join-Path $writerRoot 'sunshine.conf'
        Write-FixtureText $configPath "output_name = \\.\DISPLAY7`r`nadapter_name = Old GPU`r`n"
        $unicodeText = 'Caf' + [char]0x00E9 + ' ' + [char]0x96EA
        $replacement = "output_name = \\.\DISPLAY7`r`nadapter_name = NVIDIA GeForce RTX 3070`r`ncomment = $unicodeText`r`n"
        $harnessText = @'
param($OwnedRoot, $ConfigPath, $Replacement)
$probe = @{ AssertCalls = 0; GetAclCalls = 0; SetAclCalls = 0 }
$ownedFull = [IO.Path]::GetFullPath($OwnedRoot).TrimEnd('\')
function Assert-OwnedFixturePath {
    param([string]$Path)
    $candidate = [IO.Path]::GetFullPath($Path)
    if ($candidate -ne $ownedFull -and -not $candidate.StartsWith($ownedFull + '\', [StringComparison]::OrdinalIgnoreCase)) {
        throw ('ACL mock escaped its fixture: ' + $candidate)
    }
}
function Assert-ProtectedPathAcl {
    param([string]$Path)
    Assert-OwnedFixturePath $Path
    $probe.AssertCalls++
    return $true
}
function Get-Acl {
    param([string]$LiteralPath)
    Assert-OwnedFixturePath $LiteralPath
    $probe.GetAclCalls++
    return [pscustomobject]@{ FixtureAcl = $true }
}
function Set-Acl {
    param([string]$LiteralPath, $AclObject)
    Assert-OwnedFixturePath $LiteralPath
    if (-not $AclObject.FixtureAcl) { throw 'Unexpected ACL object.' }
    $probe.SetAclCalls++
    $probe.StagedBytes = [IO.File]::ReadAllBytes($LiteralPath)
    $probe.StagedText = [IO.File]::ReadAllText($LiteralPath, [Text.Encoding]::UTF8)
}
'@ + "`r`n" + $writerFunction.Extent.Text + "`r`n" + @'
Write-SunshineConfig -Path $ConfigPath -Text $Replacement
[pscustomobject]@{
    Probe = $probe
    Bytes = [IO.File]::ReadAllBytes($ConfigPath)
    Text = [IO.File]::ReadAllText($ConfigPath, [Text.Encoding]::UTF8)
}
'@
        $writerResult = & ([scriptblock]::Create($harnessText)) $writerRoot $configPath $replacement
        Assert-Equal 4 $writerResult.Probe.AssertCalls 'Protected-path validation count mismatch.'
        Assert-Equal 1 $writerResult.Probe.GetAclCalls 'Source ACL was not captured exactly once.'
        Assert-Equal 1 $writerResult.Probe.SetAclCalls 'Temporary file ACL was not applied exactly once.'
        Assert-Equal $replacement $writerResult.Text 'Atomic replacement changed the supplied Unicode text.'
        Assert-True $writerResult.Text.StartsWith('output_name = \\.\DISPLAY7') 'The first output_name key was not preserved in the replaced config.'
        Assert-True $writerResult.Text.Contains($unicodeText) 'Unicode configuration text was not preserved in the replaced config.'
        Assert-True ($writerResult.Bytes.Length -ge 3) 'Replaced config was unexpectedly short.'
        Assert-True (-not ($writerResult.Bytes[0] -eq 0xEF -and $writerResult.Bytes[1] -eq 0xBB -and $writerResult.Bytes[2] -eq 0xBF)) 'Config writer emitted a UTF-8 BOM.'
        Assert-Equal 0 @(Get-ChildItem -LiteralPath $writerRoot -Filter '.gpu-*.tmp').Count 'Atomic-write temporary file was not removed.'
    }

    Invoke-TestCase 'GPU rollback finally re-enables code-22 MTT after Sunshine start failure' {
        $selectorPath = Join-Path $packageRoot 'Select-StreamingGPU.ps1'
        $tokens = $null
        $parseErrors = $null
        $selectorAst = [System.Management.Automation.Language.Parser]::ParseFile($selectorPath, [ref]$tokens, [ref]$parseErrors)
        Assert-Equal 0 @($parseErrors).Count 'GPU selector could not be parsed for rollback extraction.'
        $rollbackTry = @($selectorAst.FindAll({
                    param($node)
                    $node -is [System.Management.Automation.Language.TryStatementAst] -and
                    $null -ne $node.Finally -and
                    $node.Body.Extent.Text -match 'Start-Service SunshineService' -and
                    $node.Finally.Extent.Text -match 'ManagedDriverRecoveryAttempted'
                }, $true))[0]
        Assert-True ($null -ne $rollbackTry) 'GPU rollback try/catch/finally block was not found.'
        $harnessText = @'
$probe = @{ EnableCalls = 0; StartCalls = 0 }
function Stop-Service { [CmdletBinding()] param([string]$Name) }
function Disable-PnpDevice { [CmdletBinding()] param([string]$InstanceId, [switch]$Confirm) }
function Copy-Item { param([string]$LiteralPath, [string]$Destination) }
function Enable-PnpDevice {
    [CmdletBinding()]
    param([string]$InstanceId, [switch]$Confirm)
    if ($InstanceId -ne 'ROOT\DISPLAY\MTT-TEST') { throw ('Unexpected device mutation target: ' + $InstanceId) }
    $probe.EnableCalls++
}
function Start-Sleep { param([int]$Seconds) }
function Start-Service {
    param([string]$Name)
    $probe.StartCalls++
    throw 'Injected Sunshine startup failure'
}
function Get-CimInstance {
    param([string]$ClassName)
    if ($ClassName -ne 'Win32_PnPEntity') { throw ('Unexpected CIM class: ' + $ClassName) }
    return [pscustomobject]@{ PNPDeviceID = 'ROOT\DISPLAY\MTT-TEST'; ConfigManagerErrorCode = 22 }
}
$driverId = 'ROOT\DISPLAY\MTT-TEST'
$backup = 'C:\synthetic-backup'
$sunConfig = 'C:\synthetic-sunshine.conf'
$vddConfig = 'C:\synthetic-vdd.xml'
$before = @()
$rollback = @{}
'@ + "`r`n" + $rollbackTry.Extent.Text + "`r`n" + @'
[pscustomobject]@{ Probe = $probe; Rollback = $rollback }
'@
        $rollbackResult = & ([scriptblock]::Create($harnessText))
        Assert-Equal 1 $rollbackResult.Probe.StartCalls 'Injected Sunshine start path did not execute exactly once.'
        Assert-Equal 2 $rollbackResult.Probe.EnableCalls 'MTT was not re-enabled both before startup and from the rollback finally guard.'
        Assert-True (-not $rollbackResult.Rollback.Restored) 'Rollback claimed success after injected Sunshine startup failure.'
        Assert-Equal 'Injected Sunshine startup failure' $rollbackResult.Rollback.Error 'Injected startup failure was not recorded.'
        Assert-True $rollbackResult.Rollback.ManagedDriverRecoveryAttempted 'Rollback finally did not record its managed-driver recovery attempt.'
    }

    Invoke-TestCase 'Watcher recovers code-22 MTT with Virtual Desktop active and ObserveOnly stays mutation-free' {
        $watchSource = Join-Path $packageRoot 'Watch-StreamingDisplays.ps1'
        $engine = [Diagnostics.Process]::GetCurrentProcess().MainModule.FileName
        foreach ($scenario in @(
                [pscustomobject]@{ Name = 'recover-with-vd'; ObserveOnly = $false; ExpectedEnable = 1 },
                [pscustomobject]@{ Name = 'observe-only'; ObserveOnly = $true; ExpectedEnable = 0 }
            )) {
            $scenarioRoot = Join-Path $fixtureRoot ('watch-' + $scenario.Name)
            [void](New-Item -ItemType Directory -Path $scenarioRoot)
            Copy-Item -LiteralPath $watchSource -Destination (Join-Path $scenarioRoot 'Watch-StreamingDisplays.ps1')
            $fakeDisplayTools = @'
public class FakeDisplayOutput {
    public bool Active;
    public bool Virtual;
    public string Adapter;
}
public static class SunshineDisplays {
    public static bool MttEnabled = false;
    public static FakeDisplayOutput[] List() {
        if (MttEnabled) {
            return new FakeDisplayOutput[] {
                new FakeDisplayOutput { Active = true, Virtual = false, Adapter = "Virtual Desktop Adapter" },
                new FakeDisplayOutput { Active = true, Virtual = true, Adapter = "MTT Adapter" }
            };
        }
        return new FakeDisplayOutput[] {
            new FakeDisplayOutput { Active = true, Virtual = false, Adapter = "Virtual Desktop Adapter" }
        };
    }
}
'@
            Write-FixtureText (Join-Path $scenarioRoot 'DisplayTools.cs') $fakeDisplayTools
            $fakePolicy = @'
function New-SessionHistory { return @{} }
function Get-SunshineSessionState { param($Configuration, $History); return @{ Known = $true; Count = 0; Starting = $false; LastEvent = $null } }
function Get-DisplayDecision { param($Session, $ManagedActive, $OtherActive, $PreferredConnected, $Settled); return 'Idle' }
Export-ModuleMember -Function New-SessionHistory,Get-SunshineSessionState,Get-DisplayDecision
'@
            Write-FixtureText (Join-Path $scenarioRoot 'SessionPolicy.psm1') $fakePolicy
            $configuration = [ordered]@{
                SchemaVersion = 1
                DataDirectory = $scenarioRoot
                ManagedDriverId = 'ROOT\DISPLAY\MTT-TEST'
                VirtualDesktopDriverId = 'ROOT\DISPLAY\VD-TEST'
                VirtualDesktopPort = 38810
                VirtualDesktopAdapter = 'Virtual Desktop Adapter'
                PollSeconds = 1
                IdleGraceSeconds = 0
                DisconnectGraceSeconds = 0
                RetrySeconds = 1
            }
            Write-FixtureText (Join-Path $scenarioRoot 'host.json') ($configuration | ConvertTo-Json)
            $wrapperPath = Join-Path $scenarioRoot 'Invoke-WatcherFixture.ps1'
            $wrapper = @'
param([switch]$ObserveOnly)
$ErrorActionPreference = 'Stop'
$global:DisplayCoexistenceMutationPath = Join-Path $PSScriptRoot 'device-mutations.txt'
function Get-PnpDeviceProperty {
    param([string]$InstanceId, [string]$KeyName)
    $code = if ($InstanceId -eq 'ROOT\DISPLAY\MTT-TEST') { 22 } else { 0 }
    return [pscustomobject]@{ Data = $code }
}
function Enable-PnpDevice {
    [CmdletBinding()]
    param([string]$InstanceId, [switch]$Confirm)
    if ($InstanceId -ne 'ROOT\DISPLAY\MTT-TEST') { throw ('Unexpected enabled device: ' + $InstanceId) }
    [SunshineDisplays]::MttEnabled = $true
    [IO.File]::AppendAllText($global:DisplayCoexistenceMutationPath, "Enable:$InstanceId`r`n", (New-Object Text.UTF8Encoding($false)))
}
function Disable-PnpDevice {
    [CmdletBinding()]
    param([string]$InstanceId, [switch]$Confirm)
    [IO.File]::AppendAllText($global:DisplayCoexistenceMutationPath, "Disable:$InstanceId`r`n", (New-Object Text.UTF8Encoding($false)))
}
function Start-Sleep { param([int]$Seconds) }
function Get-Process {
    [CmdletBinding()]
    param([Parameter(Position=0)][string]$Name, [int]$Id)
    if ($PSBoundParameters.ContainsKey('Id')) { return [pscustomobject]@{ Id = $Id; ProcessName = 'powershell-fixture' } }
    if ($Name -eq 'VirtualDesktop.Streamer') { return [pscustomobject]@{ Id = 4422 } }
    throw ('Unexpected process query: ' + $Name)
}
function Get-NetTCPConnection {
    param([int]$LocalPort, [string]$State)
    return [pscustomobject]@{ OwningProcess = 4422 }
}
$watch = Join-Path $PSScriptRoot 'Watch-StreamingDisplays.ps1'
if ($ObserveOnly) { & $watch -Once -ObserveOnly } else { & $watch -Once }
'@
            Write-FixtureText $wrapperPath $wrapper
            $arguments = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $wrapperPath)
            if ($scenario.ObserveOnly) { $arguments += '-ObserveOnly' }
            $childOutput = @(& $engine @arguments 2>&1)
            $childExit = $LASTEXITCODE
            Assert-Equal 0 $childExit ('Watcher fixture failed: ' + ($childOutput -join ' | '))
            $mutationPath = Join-Path $scenarioRoot 'device-mutations.txt'
            $mutations = if (Test-Path -LiteralPath $mutationPath) { @(Get-Content -LiteralPath $mutationPath) } else { @() }
            Assert-Equal $scenario.ExpectedEnable @($mutations | Where-Object { $_ -eq 'Enable:ROOT\DISPLAY\MTT-TEST' }).Count ('MTT recovery count mismatch for ' + $scenario.Name + '.')
            Assert-Equal 0 @($mutations | Where-Object { $_ -like 'Disable:*' }).Count ('Watcher disabled a device in ' + $scenario.Name + '.')
            Assert-True (Test-Path -LiteralPath (Join-Path $scenarioRoot 'automatic-display-state.json')) ('Watcher did not complete its bounded observation for ' + $scenario.Name + '.')
        }
    }

    Invoke-TestCase 'Session policy exports are present' {
        Assert-True (Test-Path -LiteralPath $policyPath -PathType Leaf) ('Missing policy module: ' + $policyPath)
        $script:sessionPolicyModule = Import-Module -Name $policyPath -Force -PassThru
        $expected = @('New-SessionHistory', 'Read-SessionHistory', 'Test-SessionLogConfiguration', 'Test-SafeIdle', 'Get-DisplayDecision', 'Get-SunshineSessionState')
        foreach ($command in $expected) {
            Assert-True ($sessionPolicyModule.ExportedCommands.ContainsKey($command)) ('Missing module export: ' + $command)
        }
    }

    Invoke-TestCase 'DisplayTools compiles once and exposes SunshineDisplays' {
        Assert-True (Test-Path -LiteralPath $displayToolsPath -PathType Leaf) ('Missing C# helper: ' + $displayToolsPath)
        $displayType = ([System.Management.Automation.PSTypeName]'SunshineDisplays').Type
        if ($null -eq $displayType) {
            Add-Type -Path $displayToolsPath
            $displayType = ([System.Management.Automation.PSTypeName]'SunshineDisplays').Type
        }
        Assert-True ($null -ne $displayType) 'DisplayTools.cs did not define SunshineDisplays.'
    }

    Invoke-TestCase 'Multiple clients retain remaining active count' {
        $path = New-LogPath 'multiple-clients'
        Write-FixtureText $path ("[2026-10-10 12:00:00.000]: Info: CLIENT CONNECTED`r`n[2026-10-10 12:00:01.000]: Info: CLIENT CONNECTED`r`n[2026-10-10 12:00:02.000]: Info: CLIENT DISCONNECTED`r`n")
        $state = Read-SessionHistory -History (New-SessionHistory) -LogPath $path -ProcessId 101
        Assert-True $state.Known 'Complete history should be known.'
        Assert-Equal 1 $state.Count 'One client should remain connected.'
        Assert-Equal 'DISCONNECTED' $state.LastEvent 'Last event mismatch.'
    }

    Invoke-TestCase 'Partial disconnect becomes underflow unknown only when completed' {
        $path = New-LogPath 'partial-underflow'
        Write-FixtureText $path '[2026-10-10 12:00:00.000]: Info: CLIENT DISCON'
        $history = New-SessionHistory
        $partial = Read-SessionHistory -History $history -LogPath $path -ProcessId 102
        Assert-True $partial.Known 'An incomplete line must remain buffered without changing the count.'
        Assert-Equal 0 $partial.Count 'Partial line changed the client count.'
        Add-FixtureText $path "NECTED`r`n"
        $completed = Read-SessionHistory -History $history -LogPath $path -ProcessId 102
        Assert-True (-not $completed.Known) 'Disconnect underflow must make history unknown.'
        Assert-Equal 'DISCONNECTED' $completed.LastEvent 'Completed event was not recognized.'
    }

    Invoke-TestCase 'Unexpected truncation remains unknown until process identity changes' {
        $path = New-LogPath 'truncation'
        Write-FixtureText $path "[2026-10-10 12:00:00.000]: Info: CLIENT CONNECTED`r`n"
        $history = New-SessionHistory
        $initial = Read-SessionHistory -History $history -LogPath $path -ProcessId 103
        Assert-True $initial.Known 'Initial complete log should be known.'
        Write-FixtureText $path "x`r`n"
        $truncated = Read-SessionHistory -History $history -LogPath $path -ProcessId 103
        Assert-True (-not $truncated.Known) 'Truncation under the same process must be unknown.'
        Write-FixtureText $path "[2026-10-10 12:01:00.000]: Info: CLIENT CONNECTED`r`n"
        $newProcess = Read-SessionHistory -History $history -LogPath $path -ProcessId 104
        Assert-True $newProcess.Known 'A new process identity should establish fresh history.'
        Assert-Equal 1 $newProcess.Count 'Fresh process history count mismatch.'
    }

    Invoke-TestCase 'Missing log is unknown and rotation invalidates prior history' {
        $path = New-LogPath 'rotation'
        $history = New-SessionHistory
        $missing = Read-SessionHistory -History $history -LogPath $path -ProcessId 105
        Assert-True (-not $missing.Known) 'Missing log must be unknown.'
        Write-FixtureText $path "[2026-10-10 12:00:00.000]: Info: CLIENT CONNECTED`r`n"
        $initial = Read-SessionHistory -History $history -LogPath $path -ProcessId 105
        Assert-True $initial.Known 'Initial post-creation history should be known.'
        $oldCreation = (Get-Item -LiteralPath $path).CreationTimeUtc
        Remove-Item -LiteralPath $path -Force
        Write-FixtureText $path "[2026-10-10 12:02:00.000]: Info: CLIENT DISCONNECTED`r`n"
        (Get-Item -LiteralPath $path).CreationTimeUtc = $oldCreation.AddSeconds(2)
        $rotated = Read-SessionHistory -History $history -LogPath $path -ProcessId 105
        Assert-True (-not $rotated.Known) 'Rotated log under the same process must be unknown.'
    }

    Invoke-TestCase 'History over four MiB with an unterminated record is unknown' {
        $path = New-LogPath 'oversize-partial'
        Write-FixtureText $path ([string]::new('x', (4 * 1024 * 1024) + 1))
        $history = New-SessionHistory
        $state = Read-SessionHistory -History $history -LogPath $path -ProcessId 106
        Assert-True (-not $state.Known) 'Oversize partial history must be unknown.'
        Assert-True $history.Uncertain 'Oversize partial history did not latch uncertainty.'
        Assert-True ($history.Offset -le 1048576) 'A single history read exceeded its one MiB bound.'
    }

    Invoke-TestCase 'Bounded runtime drain makes stable retained history over one MiB known' {
        $path = New-LogPath 'runtime-drain-stable'
        $runtime = New-SyntheticSessionRuntime -Name 'runtime-drain-stable-host' -LogPath $path
        $marker = $runtime.Process.StartTime.AddSeconds(2).ToString('yyyy-MM-dd HH:mm:ss.fff', [Globalization.CultureInfo]::InvariantCulture)
        $connected = $runtime.Process.StartTime.AddSeconds(4).ToString('yyyy-MM-dd HH:mm:ss.fff', [Globalization.CultureInfo]::InvariantCulture)
        $disconnected = $runtime.Process.StartTime.AddSeconds(6).ToString('yyyy-MM-dd HH:mm:ss.fff', [Globalization.CultureInfo]::InvariantCulture)
        $prefix = "[$marker]: Info: Sunshine version: 2026.1010.1`r`n"
        $suffix = "[$connected]: Info: CLIENT CONNECTED`r`n[$disconnected]: Info: CLIENT DISCONNECTED`r`n"
        Write-LargeSessionLog -Path $path -Prefix $prefix -MinimumBytes (3 * 1048576) -Suffix $suffix
        (Get-Item -LiteralPath $path).LastWriteTimeUtc = $runtime.Process.StartTime.ToUniversalTime().AddSeconds(20)
        $history = New-SessionHistory
        Invoke-WithMockedSessionRuntime -Process $runtime.Process -Body {
            $state = Get-SunshineSessionState -Configuration $runtime.Configuration -History $history -DrainHistory
            Assert-True $state.Known 'Stable retained history did not become known after bounded draining.'
            Assert-True (-not $state.Starting) 'Old stable synthetic log was treated as startup activity.'
            Assert-Equal 0 $state.Count 'Balanced retained-history events left an active client.'
            Assert-Equal (Get-Item -LiteralPath $path).Length $history.Offset 'Drain did not reach the stable file end.'
        }
    }

    Invoke-TestCase 'Bounded runtime drain stops immediately when retained history becomes uncertain' {
        $path = New-LogPath 'runtime-drain-uncertain'
        $runtime = New-SyntheticSessionRuntime -Name 'runtime-drain-uncertain-host' -LogPath $path
        $marker = $runtime.Process.StartTime.AddSeconds(2).ToString('yyyy-MM-dd HH:mm:ss.fff', [Globalization.CultureInfo]::InvariantCulture)
        $badEvent = $runtime.Process.StartTime.AddSeconds(3).ToString('yyyy-MM-dd HH:mm:ss.fff', [Globalization.CultureInfo]::InvariantCulture)
        $prefix = "[$marker]: Info: Sunshine version: 2026.1010.1`r`n[$badEvent]: Info: CLIENT DISCONNECTED`r`n"
        Write-LargeSessionLog -Path $path -Prefix $prefix -MinimumBytes (3 * 1048576)
        (Get-Item -LiteralPath $path).LastWriteTimeUtc = $runtime.Process.StartTime.ToUniversalTime().AddSeconds(20)
        $history = New-SessionHistory
        Invoke-WithMockedSessionRuntime -Process $runtime.Process -Body {
            $state = Get-SunshineSessionState -Configuration $runtime.Configuration -History $history -DrainHistory
            Assert-True (-not $state.Known) 'Underflow history became known during draining.'
            Assert-True $history.Uncertain 'Malformed retained history did not latch uncertainty.'
            Assert-Equal 1048576 $history.Offset 'Drain continued after uncertainty was established.'
        }
    }

    Invoke-TestCase 'Bounded runtime drain exhausts sixteen chunks without claiming known state' {
        $path = New-LogPath 'runtime-drain-exhausted'
        $runtime = New-SyntheticSessionRuntime -Name 'runtime-drain-exhausted-host' -LogPath $path
        $marker = $runtime.Process.StartTime.AddSeconds(2).ToString('yyyy-MM-dd HH:mm:ss.fff', [Globalization.CultureInfo]::InvariantCulture)
        $prefix = "[$marker]: Info: Sunshine version: 2026.1010.1`r`n"
        Write-LargeSessionLog -Path $path -Prefix $prefix -MinimumBytes (17 * 1048576)
        (Get-Item -LiteralPath $path).LastWriteTimeUtc = $runtime.Process.StartTime.ToUniversalTime().AddSeconds(20)
        $history = New-SessionHistory
        Invoke-WithMockedSessionRuntime -Process $runtime.Process -Body {
            $state = Get-SunshineSessionState -Configuration $runtime.Configuration -History $history -DrainHistory
            Assert-True (-not $state.Known) 'Chunk-limit exhaustion incorrectly claimed complete history.'
            Assert-True (-not $history.Uncertain) 'Safe chunk-limit exhaustion incorrectly marked stable history uncertain.'
            Assert-Equal (16 * 1048576) $history.Offset 'Default drain did not stop at sixteen one-MiB chunks.'
            Assert-True ($history.Offset -lt (Get-Item -LiteralPath $path).Length) 'Bound-exhaustion fixture was accidentally drained completely.'
        }
    }

    Invoke-TestCase 'Embedded and suffixed fake events are ignored' {
        $path = New-LogPath 'anchored-events'
        $text = @(
            'command output: [2026-10-10 12:00:00.000]: Info: CLIENT CONNECTED'
            '[2026-10-10 12:00:01.000]: Info: CLIENT CONNECTED trailing output'
            '[2026-10-10 12:00:02.000]: Info: CLIENT CONNECTED'
        ) -join "`r`n"
        Write-FixtureText $path ($text + "`r`n")
        $state = Read-SessionHistory -History (New-SessionHistory) -LogPath $path -ProcessId 107
        Assert-True $state.Known 'Complete anchored-event fixture should be known.'
        Assert-Equal 1 $state.Count 'Only the standalone event line should count.'
    }

    Invoke-TestCase 'Runtime binding rejects a stale prior-process startup marker' {
        $path = New-LogPath 'runtime-stale-prior-pid'
        $processStart = (Get-Date).AddMinutes(-2)
        $staleMarker = $processStart.AddMinutes(-10).ToString('yyyy-MM-dd HH:mm:ss.fff', [Globalization.CultureInfo]::InvariantCulture)
        Write-FixtureText $path ("[{0}]: Info: Sunshine version: 2026.1010.1`r`n[{0}]: Info: CLIENT CONNECTED`r`n" -f $staleMarker)
        (Get-Item -LiteralPath $path).LastWriteTimeUtc = $processStart.ToUniversalTime().AddSeconds(2)
        $state = Read-SessionHistory -History (New-SessionHistory) -LogPath $path -ProcessId 201 -ProcessStartTime $processStart
        Assert-True (-not $state.Known) 'A prior-process startup marker was accepted for the current process.'
    }

    Invoke-TestCase 'Runtime binding accepts a current startup marker and complete events' {
        $path = New-LogPath 'runtime-current-marker'
        $processStart = (Get-Date).AddMinutes(-2)
        $marker = $processStart.AddSeconds(2).ToString('yyyy-MM-dd HH:mm:ss.fff', [Globalization.CultureInfo]::InvariantCulture)
        $connected = $processStart.AddSeconds(4).ToString('yyyy-MM-dd HH:mm:ss.fff', [Globalization.CultureInfo]::InvariantCulture)
        $disconnected = $processStart.AddSeconds(6).ToString('yyyy-MM-dd HH:mm:ss.fff', [Globalization.CultureInfo]::InvariantCulture)
        Write-FixtureText $path ("[{0}]: Info: Sunshine version: 2026.1010.1`r`n[{1}]: Info: CLIENT CONNECTED`r`n[{2}]: Info: CLIENT DISCONNECTED`r`n" -f $marker, $connected, $disconnected)
        (Get-Item -LiteralPath $path).LastWriteTimeUtc = $processStart.ToUniversalTime().AddSeconds(7)
        $history = New-SessionHistory
        $state = Read-SessionHistory -History $history -LogPath $path -ProcessId 202 -ProcessStartTime $processStart
        Assert-True $state.Known 'Current process marker and complete events did not establish known history.'
        Assert-True $history.ProcessBound 'History did not latch the current process binding.'
        Assert-Equal 0 $state.Count 'Balanced current-process events should leave no active clients.'
        Assert-Equal 'DISCONNECTED' $state.LastEvent 'Current-process last event mismatch.'
    }

    Invoke-TestCase 'Runtime binding rejects history without a startup marker' {
        $path = New-LogPath 'runtime-missing-marker'
        $processStart = (Get-Date).AddMinutes(-2)
        $connected = $processStart.AddSeconds(4).ToString('yyyy-MM-dd HH:mm:ss.fff', [Globalization.CultureInfo]::InvariantCulture)
        Write-FixtureText $path ("[{0}]: Info: CLIENT CONNECTED`r`n" -f $connected)
        (Get-Item -LiteralPath $path).LastWriteTimeUtc = $processStart.ToUniversalTime().AddSeconds(5)
        $state = Read-SessionHistory -History (New-SessionHistory) -LogPath $path -ProcessId 203 -ProcessStartTime $processStart
        Assert-True (-not $state.Known) 'Event history without a Sunshine startup marker was accepted.'
    }

    Invoke-TestCase 'Runtime binding rejects a current marker in a stale log file' {
        $path = New-LogPath 'runtime-stale-file'
        $processStart = (Get-Date).AddMinutes(-2)
        $marker = $processStart.AddSeconds(2).ToString('yyyy-MM-dd HH:mm:ss.fff', [Globalization.CultureInfo]::InvariantCulture)
        Write-FixtureText $path ("[{0}]: Info: Sunshine version: 2026.1010.1`r`n" -f $marker)
        (Get-Item -LiteralPath $path).LastWriteTimeUtc = $processStart.ToUniversalTime().AddSeconds(-2)
        $state = Read-SessionHistory -History (New-SessionHistory) -LogPath $path -ProcessId 204 -ProcessStartTime $processStart
        Assert-True (-not $state.Known) 'A log last written before process startup was accepted.'
    }

    Invoke-TestCase 'Runtime binding enforces the minus-one through plus-thirty-five-second marker window' {
        $processStart = (Get-Date).AddMinutes(-2)
        $processStart = $processStart.AddTicks(-($processStart.Ticks % [TimeSpan]::TicksPerMillisecond))
        foreach ($sample in @(
                [pscustomobject]@{ Name = 'lower-bound'; OffsetMs = -1000; Expected = $true },
                [pscustomobject]@{ Name = 'upper-bound'; OffsetMs = 35000; Expected = $true },
                [pscustomobject]@{ Name = 'below-bound'; OffsetMs = -1001; Expected = $false },
                [pscustomobject]@{ Name = 'above-bound'; OffsetMs = 35001; Expected = $false }
            )) {
            $path = New-LogPath ('runtime-window-' + $sample.Name)
            $marker = $processStart.AddMilliseconds($sample.OffsetMs).ToString('yyyy-MM-dd HH:mm:ss.fff', [Globalization.CultureInfo]::InvariantCulture)
            Write-FixtureText $path ("[{0}]: Info: Sunshine version: 2026.1010.1`r`n" -f $marker)
            (Get-Item -LiteralPath $path).LastWriteTimeUtc = $processStart.ToUniversalTime().AddSeconds(40)
            $state = Read-SessionHistory -History (New-SessionHistory) -LogPath $path -ProcessId (300 + [math]::Abs($sample.OffsetMs)) -ProcessStartTime $processStart
            Assert-Equal $sample.Expected $state.Known ('Marker-window result mismatch for ' + $sample.Name + '.')
        }
    }

    Invoke-TestCase 'Session log configuration accepts Info-capable levels and matching relative path' {
        $sunshineDirectory = Join-Path $fixtureRoot 'session-config-valid'
        $configuration = [pscustomobject]@{
            SunshineDirectory = $sunshineDirectory
            SunshineLogPath = Join-Path (Join-Path $sunshineDirectory 'config') 'session.log'
        }
        foreach ($level in @('info', '0', '1', '2')) {
            $text = "min_log_level = $level`r`nlog_path = session.log`r`n"
            Assert-True (Test-SessionLogConfiguration -Configuration $configuration -ConfigText $text) ("Accepted log level or relative path was rejected: $level")
        }
    }

    Invoke-TestCase 'Session log configuration rejects quiet warning and error severities' {
        $sunshineDirectory = Join-Path $fixtureRoot 'session-config-severity'
        $configuration = [pscustomobject]@{
            SunshineDirectory = $sunshineDirectory
            SunshineLogPath = Join-Path (Join-Path $sunshineDirectory 'config') 'sunshine.log'
        }
        foreach ($level in @('quiet', 'warning', 'error')) {
            $text = "min_log_level = $level`r`nlog_path = sunshine.log`r`n"
            Assert-True (-not (Test-SessionLogConfiguration -Configuration $configuration -ConfigText $text)) ("Unsafe log severity was accepted: $level")
        }
    }

    Invoke-TestCase 'Session log configuration rejects log redirection mismatch' {
        $sunshineDirectory = Join-Path $fixtureRoot 'session-config-redirect'
        $configuration = [pscustomobject]@{
            SunshineDirectory = $sunshineDirectory
            SunshineLogPath = Join-Path (Join-Path $sunshineDirectory 'config') 'sunshine.log'
        }
        $text = "min_log_level = info`r`nlog_path = redirected.log`r`n"
        Assert-True (-not (Test-SessionLogConfiguration -Configuration $configuration -ConfigText $text)) 'A redirected log path was accepted as the protected session log.'
    }

    Invoke-TestCase 'Safe idle requires positive known idle state' {
        Assert-True (Test-SafeIdle @{ Known = $true; Count = 0; Starting = $false }) 'Known idle state should be safe.'
        Assert-True (-not (Test-SafeIdle @{ Known = $false; Count = 0; Starting = $false })) 'Unknown state was treated as safe.'
        Assert-True (-not (Test-SafeIdle @{ Known = $true; Count = 0; Starting = $true })) 'Startup state was treated as safe.'
        Assert-True (-not (Test-SafeIdle @{ Known = $true; Count = 1; Starting = $false })) 'Active session was treated as safe.'
    }

    Invoke-TestCase 'Unknown session preserves displays' {
        Assert-Equal 'Preserve' (Get-DisplayDecision @{ Known = $false; Count = 0; Starting = $false } 1 1 $true $true) 'Unknown decision mismatch.'
    }

    Invoke-TestCase 'Startup grace preserves displays' {
        Assert-Equal 'Preserve' (Get-DisplayDecision @{ Known = $true; Count = 0; Starting = $true } 1 1 $true $true) 'Startup decision mismatch.'
    }

    Invoke-TestCase 'Active client preserves displays' {
        Assert-Equal 'Preserve' (Get-DisplayDecision @{ Known = $true; Count = 1; Starting = $false } 1 1 $true $true) 'Active-client decision mismatch.'
    }

    Invoke-TestCase 'No managed display is idle' {
        Assert-Equal 'Idle' (Get-DisplayDecision @{ Known = $true; Count = 0; Starting = $false } 0 1 $true $true) 'Idle decision mismatch.'
    }

    Invoke-TestCase 'Grace period settles before parking' {
        Assert-Equal 'Settle' (Get-DisplayDecision @{ Known = $true; Count = 0; Starting = $false } 1 1 $true $false) 'Settle decision mismatch.'
    }

    Invoke-TestCase 'Non-managed active desktop permits parking managed display' {
        Assert-Equal 'Park' (Get-DisplayDecision @{ Known = $true; Count = 0; Starting = $false } 1 1 $true $true) 'Park decision mismatch.'
    }

    Invoke-TestCase 'Virtual Desktop ready permits preferred handoff' {
        Assert-Equal 'Handoff' (Get-DisplayDecision @{ Known = $true; Count = 0; Starting = $false } 1 0 $true $true) 'Handoff decision mismatch.'
    }

    Invoke-TestCase 'Last desktop remains when no other desktop exists' {
        Assert-Equal 'KeepLastDesktop' (Get-DisplayDecision @{ Known = $true; Count = 0; Starting = $false } 1 0 $false $true) 'Last-desktop decision mismatch.'
    }

    Invoke-TestCase 'Preferred display not ready keeps last desktop' {
        Assert-Equal 'KeepLastDesktop' (Get-DisplayDecision @{ Known = $true; Count = 0; Starting = $false } 2 0 $false $true) 'Preferred-not-ready decision mismatch.'
    }

    Invoke-TestCase 'Zero-byte recovery topology throws before native apply' {
        $path = Join-Path $fixtureRoot 'topology-zero.bin'
        [System.IO.File]::WriteAllBytes($path, (New-Object byte[] 0))
        Assert-RecoveryRejectedBeforeNativeCall $path $null 'System.IO.EndOfStreamException'
    }

    Invoke-TestCase 'Truncated recovery topology throws before native apply' {
        $path = Join-Path $fixtureRoot 'topology-truncated.bin'
        $stream = [System.IO.File]::Create($path)
        try {
            $writer = New-Object System.IO.BinaryWriter($stream)
            $writer.Write([int]1)
            $writer.Write([int]64)
            $writer.Write((New-Object byte[] 71))
            $writer.Flush()
        } finally {
            if ($null -ne $writer) { $writer.Dispose() } else { $stream.Dispose() }
        }
        Assert-RecoveryRejectedBeforeNativeCall $path 'Truncated recovery topology' $null
    }

    Invoke-TestCase 'Out-of-bounds recovery topology throws before native apply' {
        $path = Join-Path $fixtureRoot 'topology-out-of-bounds.bin'
        $stream = [System.IO.File]::Create($path)
        try {
            $writer = New-Object System.IO.BinaryWriter($stream)
            $writer.Write([int]101)
            $writer.Write([int]64)
            $writer.Flush()
        } finally {
            if ($null -ne $writer) { $writer.Dispose() } else { $stream.Dispose() }
        }
        Assert-RecoveryRejectedBeforeNativeCall $path 'Invalid recovery topology' $null
    }
} finally {
    $fullFixture = [System.IO.Path]::GetFullPath($fixtureRoot).TrimEnd('\')
    $fullScratch = [System.IO.Path]::GetFullPath($scratchRoot).TrimEnd('\')
    $fixtureParent = [System.IO.Path]::GetDirectoryName($fullFixture)
    $fixtureLeaf = [System.IO.Path]::GetFileName($fullFixture)
    if ($fixtureParent -ne $fullScratch -or -not $fixtureLeaf.StartsWith('Test-DisplayCoexistence-')) {
        throw ('Refusing unsafe fixture cleanup target: ' + $fullFixture)
    }
    if (Test-Path -LiteralPath $fullFixture) {
        Remove-Item -LiteralPath $fullFixture -Recurse -Force
    }
}

$passed = @($script:Results | Where-Object { $_.Passed }).Count
$failed = $script:Results.Count - $passed
Write-Output ''
Write-Output ('Case count: {0}' -f $script:Results.Count)
Write-Output ('Passed: {0}; Failed: {1}' -f $passed, $failed)
Write-Output 'Cases:'
foreach ($result in $script:Results) {
    Write-Output (' - {0}: {1}' -f $(if ($result.Passed) { 'PASS' } else { 'FAIL' }), $result.Name)
}

if ($ReportPath) {
    $reportFullPath = [System.IO.Path]::GetFullPath($ReportPath)
    $reportParent = [System.IO.Path]::GetDirectoryName($reportFullPath)
    if (-not (Test-Path -LiteralPath $reportParent -PathType Container)) {
        throw ('ReportPath parent directory does not exist: ' + $reportParent)
    }
    $report = [pscustomobject]@{
        SchemaVersion = 1
        GeneratedUtc = (Get-Date).ToUniversalTime().ToString('o')
        PowerShellVersion = $PSVersionTable.PSVersion.ToString()
        CaseCount = $script:Results.Count
        Passed = $passed
        Failed = $failed
        Cases = $script:Results
    }
    [System.IO.File]::WriteAllText($reportFullPath, ($report | ConvertTo-Json -Depth 5), $utf8NoBom)
    Write-Output ('JSON report: ' + $reportFullPath)
}

if ($failed -gt 0) {
    throw ('Display-coexistence offline tests failed: {0} of {1} cases.' -f $failed, $script:Results.Count)
}
