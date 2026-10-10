<#
.SYNOPSIS
Runs pure offline regression tests for HostDiscovery.psm1.

.DESCRIPTION
Uses injected PnP, video-controller, and service records plus uniquely owned files
under the repository .claude/.scratch directory. The suite reads only its synthetic
Sunshine configuration, log, executable placeholders, and VDD settings. It does not
query or modify live PnP devices, services, tasks, display topology, or host configs.

.EXAMPLE
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tools\display-coexistence\tests\Test-HostDiscovery.ps1

.EXAMPLE
pwsh.exe -NoProfile -File .\tools\display-coexistence\tests\Test-HostDiscovery.ps1
#>
[CmdletBinding()]
param()

Set-StrictMode -Version 2
$ErrorActionPreference = 'Stop'

$script:Results = @()
$utf8NoBom = New-Object System.Text.UTF8Encoding($false)
$testsRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$packageRoot = Split-Path -Parent $testsRoot
$repoRoot = Split-Path -Parent (Split-Path -Parent $packageRoot)
$scratchRoot = Join-Path $repoRoot '.claude\.scratch'
$fixtureName = 'Test-HostDiscovery-{0}-{1}' -f $PID, ([guid]::NewGuid().ToString('N'))
$fixtureRoot = Join-Path $scratchRoot $fixtureName
$modulePath = Join-Path $packageRoot 'HostDiscovery.psm1'
$managedCaptureId = '{f179c550-a2e7-42b4-87d5-000000000137}'
$secondManagedCaptureId = '{fa8b43ad-9b31-432c-a8cc-000000000137}'
$physicalCaptureId = '{05f9cba1-f90f-4c56-b2c9-00000000beef}'
$hostDiscoveryModule = $null
$originalPathWritableFunction = $null
$pathWritableMockInstalled = $false

function Assert-True {
    param([bool] $Condition, [string] $Message)
    if (-not $Condition) { throw $Message }
}

function Assert-False {
    param([bool] $Condition, [string] $Message)
    if ($Condition) { throw $Message }
}

function Assert-Equal {
    param($Expected, $Actual, [string] $Message)
    if ($Expected -ne $Actual) {
        throw ('{0} Expected <{1}> but received <{2}>.' -f $Message, $Expected, $Actual)
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

function Write-FixtureText {
    param([string] $Path, [string] $Text)
    [System.IO.File]::WriteAllText($Path, $Text, $utf8NoBom)
}

function New-ProviderRecord {
    param(
        [string] $InstanceId,
        [string[]] $HardwareIds,
        [string] $Provider,
        [string] $Manufacturer,
        [string] $Name,
        $ProblemCode = 0
    )
    return [pscustomobject]@{
        InstanceId = $InstanceId
        HardwareIds = @($HardwareIds)
        Provider = $Provider
        Manufacturer = $Manufacturer
        Name = $Name
        ProblemCode = $ProblemCode
    }
}

function New-ManagedRecord {
    param([string] $InstanceId)
    return (New-ProviderRecord -InstanceId $InstanceId -HardwareIds @('ROOT\MTTVDD') -Provider 'MikeTheTech' -Manufacturer 'MikeTheTech' -Name 'Virtual Display Driver by MTT' -ProblemCode 0)
}

function New-VirtualDesktopRecord {
    param([string] $InstanceId)
    return (New-ProviderRecord -InstanceId $InstanceId -HardwareIds @('ROOT\VDVMD') -Provider 'Virtual Desktop, Inc.' -Manufacturer 'Virtual Desktop' -Name 'Virtual Desktop Monitor' -ProblemCode 0)
}

function New-DisplayJson {
    param(
        [string] $DeviceId,
        [string] $FriendlyName,
        [string] $ManufacturerId,
        [string] $ProductCode,
        [string] $DisplayName
    )
    return [ordered]@{
        device_id = $DeviceId
        friendly_name = $FriendlyName
        edid = [ordered]@{ manufacturer_id = $ManufacturerId; product_code = $ProductCode }
        display_name = $DisplayName
    }
}

function Write-SunshineEnumerationLog {
    param([string] $Path, [object[]] $Displays)
    $json = ConvertTo-Json -InputObject @($Displays) -Depth 5
    $text = "[2026-10-10 12:00:00.000]: Info: Currently available display devices:`r`n$json`r`n"
    Write-FixtureText -Path $Path -Text $text
}

function New-SyntheticSunshineHost {
    param(
        [string] $Name,
        [string] $ConfiguredCaptureId,
        [object[]] $Displays
    )
    $root = Join-Path $fixtureRoot $Name
    $tools = Join-Path $root 'tools'
    $config = Join-Path $root 'config'
    [void](New-Item -ItemType Directory -Path $tools)
    [void](New-Item -ItemType Directory -Path $config)
    [System.IO.File]::WriteAllBytes((Join-Path $root 'sunshine.exe'), (New-Object byte[] 0))
    [System.IO.File]::WriteAllBytes((Join-Path $tools 'sunshinesvc.exe'), (New-Object byte[] 0))
    $configPath = Join-Path $config 'sunshine.conf'
    $logPath = Join-Path $config 'sunshine.log'
    $vddPath = Join-Path $root 'vdd_settings.xml'
    $configText = @(
        'port = 47989'
        ('output_name = "{0}"' -f $ConfiguredCaptureId)
        'dd_configuration_option = ensure_active'
        'dd_config_revert_on_disconnect = enabled'
    ) -join "`r`n"
    Write-FixtureText -Path $configPath -Text ($configText + "`r`n")
    Write-SunshineEnumerationLog -Path $logPath -Displays $Displays
    Write-FixtureText -Path $vddPath -Text '<settings><gpu><friendlyname>NVIDIA GeForce Test GPU</friendlyname></gpu></settings>'
    return [pscustomobject]@{
        Root = $root
        ConfigPath = $configPath
        LogPath = $logPath
        VddPath = $vddPath
        Service = [pscustomobject]@{ PathName = ('"{0}"' -f (Join-Path $tools 'sunshinesvc.exe')) }
    }
}

if (-not (Test-Path -LiteralPath $scratchRoot -PathType Container)) {
    [void](New-Item -ItemType Directory -Path $scratchRoot)
}
if (Test-Path -LiteralPath $fixtureRoot) {
    throw ('Refusing to reuse an existing fixture directory: ' + $fixtureRoot)
}
[void](New-Item -ItemType Directory -Path $fixtureRoot)

try {
    Assert-True (Test-Path -LiteralPath $modulePath -PathType Leaf) ('Missing discovery module: ' + $modulePath)
    $hostDiscoveryModule = Import-Module -Name $modulePath -Force -PassThru
    $originalPathWritableFunction = & $hostDiscoveryModule {
        return (Get-Command Test-PathWritableByStandardUsers -CommandType Function).ScriptBlock
    }
    & $hostDiscoveryModule {
        param([string] $SyntheticFixtureRoot)
        $script:HostDiscoveryTestFixtureRoot = [System.IO.Path]::GetFullPath($SyntheticFixtureRoot).TrimEnd('\')
        $script:HostDiscoveryTestWritablePath = $null
        Set-Item -Path 'Function:script:Test-PathWritableByStandardUsers' -Value {
            [CmdletBinding()]
            param([Parameter(Mandatory = $true)][string] $Path)
            $full = [System.IO.Path]::GetFullPath($Path).TrimEnd('\')
            $prefix = $script:HostDiscoveryTestFixtureRoot + [System.IO.Path]::DirectorySeparatorChar
            if ($full -ne $script:HostDiscoveryTestFixtureRoot -and
                -not $full.StartsWith($prefix, [System.StringComparison]::OrdinalIgnoreCase)) {
                throw ('Test ACL mock refused a path outside its synthetic fixture root: ' + $full)
            }
            if ($script:HostDiscoveryTestWritablePath -and
                $full.Equals($script:HostDiscoveryTestWritablePath, [System.StringComparison]::OrdinalIgnoreCase)) {
                return $true
            }
            return $false
        }
    } $fixtureRoot
    $installedMockText = & $hostDiscoveryModule {
        return (Get-Command Test-PathWritableByStandardUsers -CommandType Function).ScriptBlock.ToString()
    }
    Assert-True ($installedMockText -match 'HostDiscoveryTestFixtureRoot') 'Module-scoped ACL mock was not installed.'
    $pathWritableMockInstalled = $true

    Invoke-TestCase 'Required host-discovery exports are present' {
        $expected = @(
            'Resolve-DisplayProvider',
            'Test-KnownDisplayProvider',
            'Get-SunshineDisplayEnumeration',
            'Get-DisplayHostConfiguration'
        )
        foreach ($command in $expected) {
            Assert-True ($hostDiscoveryModule.ExportedCommands.ContainsKey($command)) ('Missing module export: ' + $command)
        }
    }

    Invoke-TestCase 'ACL mock refuses every path outside the exact synthetic fixture root' {
        $outsidePath = Join-Path ([Environment]::GetFolderPath([Environment+SpecialFolder]::Windows)) 'System32'
        $caught = $null
        try {
            [void](& $hostDiscoveryModule { param([string] $Path) Test-PathWritableByStandardUsers -Path $Path } $outsidePath)
        } catch {
            $caught = $_.Exception
        }
        Assert-True ($null -ne $caught) 'ACL mock accepted a live path outside the fixture root.'
        Assert-True ($caught.Message -match 'outside its synthetic fixture root') 'ACL mock refusal was not explicit.'
    }

    Invoke-TestCase 'Known managed provider requires MTT hardware and provider identity' {
        $known = New-ManagedRecord 'ROOT\DISPLAY\CURRENT-MANAGED-A7'
        Assert-True (Test-KnownDisplayProvider -Record $known -Role Managed) 'Known MTT provider was rejected.'
        $wrongProvider = New-ProviderRecord -InstanceId 'ROOT\DISPLAY\CURRENT-MANAGED-B8' -HardwareIds @('ROOT\MTTVDD') -Provider 'Unrelated Vendor' -Manufacturer 'Unrelated Vendor' -Name 'Virtual Display' -ProblemCode 0
        Assert-False (Test-KnownDisplayProvider -Record $wrongProvider -Role Managed) 'Non-MTT provider was accepted as managed.'
        $physical = New-ProviderRecord -InstanceId 'PCI\VEN_10DE&DEV_FAKE' -HardwareIds @('PCI\VEN_10DE&DEV_FAKE') -Provider 'NVIDIA' -Manufacturer 'NVIDIA' -Name 'Physical GPU' -ProblemCode 0
        Assert-False (Test-KnownDisplayProvider -Record $physical -Role Managed) 'Physical PCI device was accepted as managed.'
    }

    Invoke-TestCase 'Known Virtual Desktop provider excludes lookalike providers' {
        $known = New-VirtualDesktopRecord 'ROOT\DISPLAY\CURRENT-VD-C9'
        Assert-True (Test-KnownDisplayProvider -Record $known -Role VirtualDesktop) 'Known Virtual Desktop provider was rejected.'
        $meta = New-ProviderRecord -InstanceId 'ROOT\DISPLAY\CURRENT-VD-D0' -HardwareIds @('ROOT\VDVMD') -Provider 'Meta' -Manufacturer 'Virtual Desktop' -Name 'Virtual Desktop Monitor' -ProblemCode 0
        Assert-False (Test-KnownDisplayProvider -Record $meta -Role VirtualDesktop) 'Excluded Meta provider was accepted as Virtual Desktop.'
    }

    Invoke-TestCase 'Arbitrary current ROOT instance ID resolves without hardcoded identity' {
        $currentId = 'ROOT\DISPLAY\HOST-GENERATED-7F31'
        $managed = New-ManagedRecord $currentId
        $resolved = Resolve-DisplayProvider -Role Managed -Records @($managed) -ExplicitId $currentId.ToLowerInvariant()
        Assert-True $resolved.Resolved 'Injected current ROOT instance ID did not resolve.'
        Assert-Equal $currentId $resolved.Device.InstanceId 'Resolved device identity was replaced or hardcoded.'
    }

    Invoke-TestCase 'Ambiguous managed providers require explicit current ID' {
        $first = New-ManagedRecord 'ROOT\DISPLAY\DYNAMIC-ONE'
        $second = New-ManagedRecord 'ROOT\DISPLAY\DYNAMIC-TWO'
        $ambiguous = Resolve-DisplayProvider -Role Managed -Records @($first, $second)
        Assert-False $ambiguous.Resolved 'Ambiguous managed providers resolved implicitly.'
        Assert-Equal 2 @($ambiguous.Candidates).Count 'Ambiguous candidate count mismatch.'
        Assert-True ($ambiguous.Error -match 'Multiple tested Managed') 'Ambiguity error was not specific.'
        $explicit = Resolve-DisplayProvider -Role Managed -Records @($first, $second) -ExplicitId $second.InstanceId
        Assert-True $explicit.Resolved 'Explicit current ID did not resolve ambiguity.'
        Assert-Equal $second.InstanceId $explicit.Device.InstanceId 'Explicit provider selected the wrong record.'
    }

    Invoke-TestCase 'Unsupported explicit and non-MTT explicit devices are rejected' {
        $managed = New-ManagedRecord 'ROOT\DISPLAY\KNOWN-MTT'
        $impostor = New-ProviderRecord -InstanceId 'ROOT\DISPLAY\NOT-MTT' -HardwareIds @('ROOT\MTTVDD') -Provider 'Unknown Provider' -Manufacturer 'Unknown' -Name 'Display' -ProblemCode 0
        $records = @($managed, $impostor)
        $missing = Resolve-DisplayProvider -Role Managed -Records $records -ExplicitId 'ROOT\DISPLAY\ABSENT'
        Assert-False $missing.Resolved 'Absent explicit provider resolved.'
        Assert-True ($missing.Error -match 'not found uniquely') 'Absent explicit provider error mismatch.'
        $rejected = Resolve-DisplayProvider -Role Managed -Records $records -ExplicitId $impostor.InstanceId
        Assert-False $rejected.Resolved 'Explicit non-MTT provider resolved.'
        Assert-True ($rejected.Error -match 'does not match') 'Non-MTT explicit rejection error mismatch.'
    }

    Invoke-TestCase 'Absent Virtual Desktop provider is valid when optional' {
        $resolved = Resolve-DisplayProvider -Role VirtualDesktop -Records @() -Optional
        Assert-True $resolved.Resolved 'Optional absent Virtual Desktop provider should resolve.'
        Assert-True ($null -eq $resolved.Device) 'Optional absent provider returned a device.'
        Assert-Equal 0 @($resolved.Candidates).Count 'Optional absent provider returned candidates.'
    }

    Invoke-TestCase 'Sunshine log enumeration parses normalized MTT UUID and physical display' {
        $path = Join-Path $fixtureRoot 'enumeration.log'
        $mtt = New-DisplayJson -DeviceId $managedCaptureId.ToUpperInvariant() -FriendlyName 'VDD by MTT' -ManufacturerId 'MTT' -ProductCode '1337' -DisplayName '\\.\DISPLAY137'
        $physical = New-DisplayJson -DeviceId $physicalCaptureId -FriendlyName 'Physical Monitor' -ManufacturerId 'DEL' -ProductCode '4098' -DisplayName '\\.\DISPLAY1'
        Write-SunshineEnumerationLog -Path $path -Displays @($mtt, $physical)
        $records = @(Get-SunshineDisplayEnumeration -LogPath $path)
        Assert-Equal 2 $records.Count 'Display enumeration count mismatch.'
        Assert-Equal $managedCaptureId $records[0].DeviceId 'MTT capture UUID was not normalized.'
        Assert-Equal 'MTT' $records[0].ManufacturerId 'MTT manufacturer ID mismatch.'
        Assert-Equal '1337' $records[0].ProductCode 'MTT product code mismatch.'
        Assert-Equal $physicalCaptureId $records[1].DeviceId 'Physical capture UUID mismatch.'
    }

    Invoke-TestCase 'Latest incomplete enumeration falls back to prior complete JSON' {
        $path = Join-Path $fixtureRoot 'enumeration-fallback.log'
        $mtt = New-DisplayJson -DeviceId $managedCaptureId -FriendlyName 'VDD by MTT' -ManufacturerId 'MTT' -ProductCode '1337' -DisplayName '\\.\DISPLAY137'
        Write-SunshineEnumerationLog -Path $path -Displays @($mtt)
        [System.IO.File]::AppendAllText($path, "[2026-10-10 12:01:00.000]: Info: Currently available display devices:`r`n[{`"device_id`":", $utf8NoBom)
        $records = @(Get-SunshineDisplayEnumeration -LogPath $path)
        Assert-Equal 1 $records.Count 'Complete earlier enumeration was not recovered.'
        Assert-Equal $managedCaptureId $records[0].DeviceId 'Fallback returned the wrong enumeration.'
    }

    Invoke-TestCase 'Mocked host discovery preserves arbitrary provider IDs and validates MTT capture' {
        $mtt = New-DisplayJson -DeviceId $managedCaptureId -FriendlyName 'VDD by MTT' -ManufacturerId 'MTT' -ProductCode '1337' -DisplayName '\\.\DISPLAY137'
        $physical = New-DisplayJson -DeviceId $physicalCaptureId -FriendlyName 'Physical Monitor' -ManufacturerId 'DEL' -ProductCode '4098' -DisplayName '\\.\DISPLAY1'
        $fixtureHost = New-SyntheticSunshineHost -Name 'valid-host' -ConfiguredCaptureId $managedCaptureId -Displays @($mtt, $physical)
        $managedId = 'ROOT\DISPLAY\RUNTIME-MTT-82AF'
        $virtualDesktopId = 'ROOT\DISPLAY\RUNTIME-VD-14C2'
        $pnp = @((New-ManagedRecord $managedId), (New-VirtualDesktopRecord $virtualDesktopId))
        $gpus = @([pscustomobject]@{ PNPDeviceID = 'PCI\VEN_10DE&DEV_TEST'; Name = 'NVIDIA GeForce Test GPU' })
        $result = Get-DisplayHostConfiguration -PnpRecords $pnp -VideoControllers $gpus -SunshineService $fixtureHost.Service -VddSettingsPath $fixtureHost.VddPath
        Assert-True $result.ReadyForInstall ('Synthetic valid host was blocked: ' + (@($result.BlockingReasons) -join '; '))
        Assert-True $result.CaptureTargetValidated 'MTT capture target was not validated.'
        Assert-Equal $managedId $result.HostConfiguration.ManagedDriverId 'Managed runtime ID was not preserved.'
        Assert-Equal $virtualDesktopId $result.HostConfiguration.VirtualDesktopDriverId 'Virtual Desktop runtime ID was not preserved.'
        Assert-Equal 'NVIDIA GeForce Test GPU' $result.PhysicalGpuNames[0] 'Injected physical GPU audit record mismatch.'
    }

    Invoke-TestCase 'Mocked host discovery permits absent optional Virtual Desktop provider' {
        $mtt = New-DisplayJson -DeviceId $managedCaptureId -FriendlyName 'VDD by MTT' -ManufacturerId 'MTT' -ProductCode '1337' -DisplayName '\\.\DISPLAY137'
        $fixtureHost = New-SyntheticSunshineHost -Name 'no-vd-host' -ConfiguredCaptureId $managedCaptureId -Displays @($mtt)
        $result = Get-DisplayHostConfiguration -PnpRecords @((New-ManagedRecord 'ROOT\DISPLAY\ONLY-MTT-55')) -VideoControllers @() -SunshineService $fixtureHost.Service -VddSettingsPath $fixtureHost.VddPath
        Assert-True $result.VirtualDesktopProvider.Resolved 'Absent optional Virtual Desktop provider blocked discovery.'
        Assert-True ($null -eq $result.VirtualDesktopProvider.Device) 'Absent optional Virtual Desktop provider returned a device.'
        Assert-True $result.ReadyForInstall ('Optional provider absence unexpectedly blocked install: ' + (@($result.BlockingReasons) -join '; '))
    }

    Invoke-TestCase 'Multiple MTT adapters block full host discovery even with explicit provider ID' {
        $mtt = New-DisplayJson -DeviceId $managedCaptureId -FriendlyName 'VDD by MTT' -ManufacturerId 'MTT' -ProductCode '1337' -DisplayName '\\.\DISPLAY137'
        $fixtureHost = New-SyntheticSunshineHost -Name 'ambiguous-host' -ConfiguredCaptureId $managedCaptureId -Displays @($mtt)
        $firstId = 'ROOT\DISPLAY\AMBIGUOUS-A'
        $secondId = 'ROOT\DISPLAY\AMBIGUOUS-B'
        $pnp = @((New-ManagedRecord $firstId), (New-ManagedRecord $secondId))
        $result = Get-DisplayHostConfiguration -PnpRecords $pnp -VideoControllers @() -SunshineService $fixtureHost.Service -ManagedDriverId $secondId -VddSettingsPath $fixtureHost.VddPath
        Assert-True $result.ManagedProvider.Resolved 'Pure provider resolution did not honor the explicit current ID.'
        Assert-Equal $secondId $result.ManagedProvider.Device.InstanceId 'Explicit provider ID selected the wrong MTT record.'
        Assert-False $result.ReadyForInstall 'Multiple MTT adapters did not block full host discovery.'
        Assert-True ((@($result.BlockingReasons) -join ' ') -match 'Native MTT1337 output isolation') 'Native multi-MTT ambiguity was not reported.'
    }

    Invoke-TestCase 'Protected ACL gate blocks a standard-user-writable synthetic config' {
        $mtt = New-DisplayJson -DeviceId $managedCaptureId -FriendlyName 'VDD by MTT' -ManufacturerId 'MTT' -ProductCode '1337' -DisplayName '\\.\DISPLAY137'
        $fixtureHost = New-SyntheticSunshineHost -Name 'writable-config-host' -ConfiguredCaptureId $managedCaptureId -Displays @($mtt)
        try {
            & $hostDiscoveryModule {
                param([string] $WritablePath)
                $script:HostDiscoveryTestWritablePath = [System.IO.Path]::GetFullPath($WritablePath).TrimEnd('\')
            } $fixtureHost.ConfigPath
            $result = Get-DisplayHostConfiguration -PnpRecords @((New-ManagedRecord 'ROOT\DISPLAY\ACL-MTT')) -VideoControllers @() -SunshineService $fixtureHost.Service -VddSettingsPath $fixtureHost.VddPath
            Assert-False $result.ReadyForInstall 'Writable synthetic config did not block installation readiness.'
            Assert-True ((@($result.BlockingReasons) -join ' ') -match 'configuration is writable by standard users') 'Protected config ACL rejection was not reported.'
        } finally {
            & $hostDiscoveryModule { $script:HostDiscoveryTestWritablePath = $null }
        }
    }

    Invoke-TestCase 'Physical capture target cannot satisfy managed MTT capture validation' {
        $mtt = New-DisplayJson -DeviceId $managedCaptureId -FriendlyName 'VDD by MTT' -ManufacturerId 'MTT' -ProductCode '1337' -DisplayName '\\.\DISPLAY137'
        $physical = New-DisplayJson -DeviceId $physicalCaptureId -FriendlyName 'Physical Monitor' -ManufacturerId 'DEL' -ProductCode '4098' -DisplayName '\\.\DISPLAY1'
        $fixtureHost = New-SyntheticSunshineHost -Name 'physical-capture-host' -ConfiguredCaptureId $physicalCaptureId -Displays @($mtt, $physical)
        $result = Get-DisplayHostConfiguration -PnpRecords @((New-ManagedRecord 'ROOT\DISPLAY\MTT-FOR-CAPTURE')) -VideoControllers @() -SunshineService $fixtureHost.Service -VddSettingsPath $fixtureHost.VddPath
        Assert-False $result.CaptureTargetValidated 'Physical display was accepted as the managed capture target.'
        Assert-False $result.ReadyForInstall 'Physical capture target did not block installation readiness.'
        Assert-True ((@($result.BlockingReasons) -join ' ') -match 'not a unique logged MTT1337 display') 'Physical capture rejection reason mismatch.'
    }

    Invoke-TestCase 'Explicit physical capture UUID cannot override managed capture requirement' {
        $mtt = New-DisplayJson -DeviceId $managedCaptureId -FriendlyName 'VDD by MTT' -ManufacturerId 'MTT' -ProductCode '1337' -DisplayName '\\.\DISPLAY137'
        $physical = New-DisplayJson -DeviceId $physicalCaptureId -FriendlyName 'Physical Monitor' -ManufacturerId 'DEL' -ProductCode '4098' -DisplayName '\\.\DISPLAY1'
        $fixtureHost = New-SyntheticSunshineHost -Name 'physical-override-host' -ConfiguredCaptureId $managedCaptureId -Displays @($mtt, $physical)
        $result = Get-DisplayHostConfiguration -PnpRecords @((New-ManagedRecord 'ROOT\DISPLAY\MTT-FOR-OVERRIDE')) -VideoControllers @() -SunshineService $fixtureHost.Service -CaptureDisplayId $physicalCaptureId -VddSettingsPath $fixtureHost.VddPath
        Assert-False $result.CaptureTargetValidated 'Explicit physical capture UUID bypassed managed capture validation.'
        Assert-False $result.ReadyForInstall 'Explicit physical capture UUID did not block readiness.'
        Assert-Equal $physicalCaptureId $result.EffectiveCaptureDisplayId 'Explicit capture UUID was not evaluated.'
    }
} finally {
    if ($pathWritableMockInstalled -and $null -ne $hostDiscoveryModule -and $null -ne $originalPathWritableFunction) {
        & $hostDiscoveryModule {
            param([scriptblock] $OriginalFunction)
            Set-Item -Path 'Function:script:Test-PathWritableByStandardUsers' -Value $OriginalFunction
            Remove-Variable -Name HostDiscoveryTestFixtureRoot -Scope Script -ErrorAction SilentlyContinue
            Remove-Variable -Name HostDiscoveryTestWritablePath -Scope Script -ErrorAction SilentlyContinue
        } $originalPathWritableFunction
    }
    $fullFixture = [System.IO.Path]::GetFullPath($fixtureRoot).TrimEnd('\')
    $fullScratch = [System.IO.Path]::GetFullPath($scratchRoot).TrimEnd('\')
    $fixtureParent = [System.IO.Path]::GetDirectoryName($fullFixture)
    $fixtureLeaf = [System.IO.Path]::GetFileName($fullFixture)
    if ($fixtureParent -ne $fullScratch -or -not $fixtureLeaf.StartsWith('Test-HostDiscovery-')) {
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

if ($failed -gt 0) {
    throw ('Host-discovery offline tests failed: {0} of {1} cases. HostDiscovery.psm1 fixes are owned by Hume.' -f $failed, $script:Results.Count)
}
