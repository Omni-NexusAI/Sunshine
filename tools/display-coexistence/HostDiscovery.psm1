# Read-only host discovery for the Windows display coexistence package.
Set-StrictMode -Version 2

function Get-ObjectPropertyValue {
    param($InputObject, [Parameter(Mandatory = $true)][string]$Name)
    if ($null -eq $InputObject) { return $null }
    $property = $InputObject.PSObject.Properties[$Name]
    if ($null -eq $property) { return $null }
    return $property.Value
}

function ConvertTo-NormalizedDeviceId {
    param([AllowNull()][string]$Value)
    if ([string]::IsNullOrWhiteSpace($Value)) { return $null }
    return $Value.Trim().ToUpperInvariant()
}

function ConvertTo-NormalizedCaptureId {
    param([AllowNull()][string]$Value)
    if ([string]::IsNullOrWhiteSpace($Value)) { return $null }
    $candidate = $Value.Trim().Trim('"').Trim()
    $guid = [guid]::Empty
    if (-not [guid]::TryParse($candidate.Trim('{', '}'), [ref]$guid)) { return $null }
    return ('{' + $guid.ToString().ToLowerInvariant() + '}')
}

function Assert-SafePathChain {
    <# .SYNOPSIS Rejects relative, UNC, and reparse-point path components. #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [switch]$AllowMissingLeaf
    )
    if (-not [IO.Path]::IsPathRooted($Path)) { throw "Path must be absolute: $Path" }
    $full = [IO.Path]::GetFullPath($Path)
    if ($full.StartsWith('\\')) { throw "UNC paths are not allowed: $full" }
    $root = [IO.Path]::GetPathRoot($full)
    if ([string]::IsNullOrWhiteSpace($root)) { throw "Path has no local volume root: $full" }
    $current = $root
    $relative = $full.Substring($root.Length)
    foreach ($segment in @($relative -split '[\\/]' | Where-Object { $_ })) {
        $current = Join-Path $current $segment
        if (Test-Path -LiteralPath $current) {
            $item = Get-Item -LiteralPath $current -Force
            if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
                throw "Reparse points are not allowed in a protected path: $current"
            }
        } elseif (-not $AllowMissingLeaf -or $current -ne $full) {
            throw "Required path component does not exist: $current"
        }
    }
    return $full
}

function Get-TrustedProtectedSidValues {
    <# .SYNOPSIS Returns principals allowed to modify protected package paths. #>
    [CmdletBinding()]
    param()
    $trusted = New-Object System.Collections.Generic.List[string]
    $trusted.Add('S-1-5-18')       # LocalSystem
    $trusted.Add('S-1-5-32-544')  # BUILTIN\Administrators
    try {
        $trustedInstaller = (New-Object Security.Principal.NTAccount('NT SERVICE', 'TrustedInstaller')).Translate(
            [Security.Principal.SecurityIdentifier]).Value
        if ($trusted -notcontains $trustedInstaller) { $trusted.Add($trustedInstaller) }
    } catch {
        throw "TrustedInstaller SID could not be resolved; protected ACL validation cannot continue: $($_.Exception.Message)"
    }
    return $trusted.ToArray()
}

function Get-ProtectedPathAclAssessment {
    <# .SYNOPSIS Audits owner and effective write-capable allow ACEs on one protected path. #>
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$Path)
    $null = Assert-SafePathChain -Path $Path
    $acl = Get-Acl -LiteralPath $Path
    $trusted = @(Get-TrustedProtectedSidValues)
    try {
        $ownerSid = $acl.GetOwner([Security.Principal.SecurityIdentifier]).Value
    } catch {
        $ownerSid = (New-Object Security.Principal.NTAccount($acl.Owner)).Translate(
            [Security.Principal.SecurityIdentifier]).Value
    }
    $writeMask = [int64]([Security.AccessControl.FileSystemRights]::WriteData -bor
        [Security.AccessControl.FileSystemRights]::CreateFiles -bor
        [Security.AccessControl.FileSystemRights]::AppendData -bor
        [Security.AccessControl.FileSystemRights]::CreateDirectories -bor
        [Security.AccessControl.FileSystemRights]::WriteAttributes -bor
        [Security.AccessControl.FileSystemRights]::WriteExtendedAttributes -bor
        [Security.AccessControl.FileSystemRights]::Delete -bor
        [Security.AccessControl.FileSystemRights]::DeleteSubdirectoriesAndFiles -bor
        [Security.AccessControl.FileSystemRights]::ChangePermissions -bor
        [Security.AccessControl.FileSystemRights]::TakeOwnership)
    $untrustedWriteAces = New-Object System.Collections.Generic.List[object]
    foreach ($rule in $acl.GetAccessRules($true, $true, [Security.Principal.SecurityIdentifier])) {
        if (($rule.PropagationFlags -band [Security.AccessControl.PropagationFlags]::InheritOnly) -ne 0) { continue }
        $sid = $rule.IdentityReference.Value
        if ($rule.AccessControlType -eq [Security.AccessControl.AccessControlType]::Allow -and
            $trusted -notcontains $sid -and (([int64]$rule.FileSystemRights -band $writeMask) -ne 0)) {
            $untrustedWriteAces.Add([pscustomobject]@{
                    Sid = $sid
                    Rights = $rule.FileSystemRights.ToString()
                    Inherited = [bool]$rule.IsInherited
                })
        }
    }
    return [pscustomobject]@{
        Path = [IO.Path]::GetFullPath($Path)
        OwnerSid = $ownerSid
        OwnerTrusted = ($trusted -contains $ownerSid)
        UntrustedWriteAces = $untrustedWriteAces.ToArray()
        HasUntrustedWrite = ($untrustedWriteAces.Count -gt 0)
    }
}

function Test-PathWritableByStandardUsers {
    <# .SYNOPSIS Reports any write-capable allow ACE for a non-trusted principal. #>
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$Path)
    return [bool](Get-ProtectedPathAclAssessment -Path $Path).HasUntrustedWrite
}

function Assert-ProtectedPathAcl {
    <# .SYNOPSIS Requires trusted ownership and no non-trusted write-capable allow ACE. #>
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$Path)
    $assessment = Get-ProtectedPathAclAssessment -Path $Path
    if (-not $assessment.OwnerTrusted) {
        throw "Protected path has an untrusted owner SID $($assessment.OwnerSid): $Path"
    }
    if ($assessment.HasUntrustedWrite) {
        $details = @($assessment.UntrustedWriteAces | ForEach-Object { "$($_.Sid) [$($_.Rights)]" }) -join ', '
        throw "Protected path grants write-capable access to an untrusted principal: $Path - $details"
    }
    return $assessment
}

function Get-DisplayPnpRecords {
    <# .SYNOPSIS Enumerates display-class PnP records without changing device state. #>
    [CmdletBinding()]
    param()
    $entities = @(Get-CimInstance -ClassName Win32_PnPEntity -ErrorAction Stop |
        Where-Object { (Get-ObjectPropertyValue $_ 'PNPClass') -eq 'Display' })
    $entityById = @{}
    foreach ($entity in $entities) {
        $entityId = ConvertTo-NormalizedDeviceId ([string](Get-ObjectPropertyValue $entity 'DeviceID'))
        if ($entityId -and -not $entityById.ContainsKey($entityId)) { $entityById[$entityId] = $entity }
    }
    $drivers = @(Get-CimInstance -ClassName Win32_PnPSignedDriver -ErrorAction Stop |
        Where-Object { (Get-ObjectPropertyValue $_ 'DeviceClass') -eq 'DISPLAY' })
    foreach ($driver in $drivers) {
        $instanceId = [string](Get-ObjectPropertyValue $driver 'DeviceID')
        $hardwareIds = @()
        $driverHardware = Get-ObjectPropertyValue $driver 'HardwareID'
        if ($null -ne $driverHardware) { $hardwareIds += @($driverHardware) }
        if ($hardwareIds.Count -eq 0 -and (Get-Command Get-PnpDeviceProperty -ErrorAction SilentlyContinue)) {
            try {
                $property = Get-PnpDeviceProperty -InstanceId $instanceId -KeyName 'DEVPKEY_Device_HardwareIds' -ErrorAction Stop
                $hardwareIds += @($property.Data)
            } catch {
                # The signed-driver record remains useful; unresolved hardware IDs simply cannot match a provider.
            }
        }
        $problemCode = $null
        $normalizedId = ConvertTo-NormalizedDeviceId $instanceId
        if ($normalizedId -and $entityById.ContainsKey($normalizedId)) {
            $problemCode = Get-ObjectPropertyValue $entityById[$normalizedId] 'ConfigManagerErrorCode'
        }
        [pscustomobject]@{
            InstanceId = $instanceId
            HardwareIds = @($hardwareIds | Where-Object { $_ } | ForEach-Object { [string]$_ })
            Provider = [string](Get-ObjectPropertyValue $driver 'DriverProviderName')
            Manufacturer = [string](Get-ObjectPropertyValue $driver 'Manufacturer')
            Name = [string](Get-ObjectPropertyValue $driver 'DeviceName')
            ProblemCode = $problemCode
        }
    }
}

function Test-KnownDisplayProvider {
    param($Record, [Parameter(Mandatory = $true)][ValidateSet('Managed', 'VirtualDesktop')][string]$Role)
    $hardwareIds = @((Get-ObjectPropertyValue $Record 'HardwareIds'))
    if ($hardwareIds.Count -eq 0) {
        $single = Get-ObjectPropertyValue $Record 'HardwareID'
        if ($single) { $hardwareIds = @($single) }
    }
    $hardware = @($hardwareIds | ForEach-Object { ([string]$_).Trim().ToUpperInvariant() })
    $provider = [string](Get-ObjectPropertyValue $Record 'Provider')
    if ([string]::IsNullOrWhiteSpace($provider)) { $provider = [string](Get-ObjectPropertyValue $Record 'DriverProviderName') }
    $manufacturer = [string](Get-ObjectPropertyValue $Record 'Manufacturer')
    $name = [string](Get-ObjectPropertyValue $Record 'Name')
    if ([string]::IsNullOrWhiteSpace($name)) { $name = [string](Get-ObjectPropertyValue $Record 'DeviceName') }
    if (($provider + ' ' + $manufacturer + ' ' + $name) -match '(?i)Parsec|Meta|Oculus') { return $false }
    if ($Role -eq 'Managed') {
        return (($hardware -contains 'ROOT\MTTVDD') -and $provider.Trim() -ieq 'MikeTheTech')
    }
    $identity = ($provider + ' ' + $manufacturer + ' ' + $name).Trim()
    return (($hardware -contains 'ROOT\VDVMD') -and $identity -match '(?i)Virtual\s+Desktop')
}

function Resolve-DisplayProvider {
    <# .SYNOPSIS Resolves exactly one tested display provider or returns a bounded failure. #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][ValidateSet('Managed', 'VirtualDesktop')][string]$Role,
        [Parameter(Mandatory = $true)][AllowEmptyCollection()][object[]]$Records,
        [AllowNull()][string]$ExplicitId,
        [switch]$Optional
    )
    $known = @($Records | Where-Object { Test-KnownDisplayProvider -Record $_ -Role $Role })
    $selected = @()
    if (-not [string]::IsNullOrWhiteSpace($ExplicitId)) {
        $wanted = ConvertTo-NormalizedDeviceId $ExplicitId
        $byId = @($Records | Where-Object {
                $id = Get-ObjectPropertyValue $_ 'InstanceId'
                if ([string]::IsNullOrWhiteSpace([string]$id)) { $id = Get-ObjectPropertyValue $_ 'DeviceID' }
                (ConvertTo-NormalizedDeviceId ([string]$id)) -eq $wanted
            })
        if ($byId.Count -ne 1) {
            return [pscustomobject]@{ Role = $Role; Resolved = $false; Device = $null; Candidates = $known; Error = "Explicit $Role device ID was not found uniquely: $ExplicitId" }
        }
        if (-not (Test-KnownDisplayProvider -Record $byId[0] -Role $Role)) {
            return [pscustomobject]@{ Role = $Role; Resolved = $false; Device = $null; Candidates = $known; Error = "Explicit $Role device does not match the tested hardware ID and provider." }
        }
        $selected = @($byId[0])
    } else {
        $selected = $known
    }
    if ($selected.Count -eq 1) {
        return [pscustomobject]@{ Role = $Role; Resolved = $true; Device = $selected[0]; Candidates = $known; Error = $null }
    }
    if ($selected.Count -eq 0 -and $Optional) {
        return [pscustomobject]@{ Role = $Role; Resolved = $true; Device = $null; Candidates = $known; Error = $null }
    }
    $message = if ($selected.Count -eq 0) { "No tested $Role display provider was found." } else { "Multiple tested $Role display providers were found; provide an explicit device ID." }
    return [pscustomobject]@{ Role = $Role; Resolved = $false; Device = $null; Candidates = $known; Error = $message }
}

function Get-CommandExecutablePath {
    param([AllowNull()][string]$CommandLine)
    if ([string]::IsNullOrWhiteSpace($CommandLine)) { return $null }
    $trimmed = $CommandLine.Trim()
    if ($trimmed.StartsWith('"')) {
        $end = $trimmed.IndexOf('"', 1)
        if ($end -gt 1) { return $trimmed.Substring(1, $end - 1) }
        return $null
    }
    return ($trimmed -split '\s+', 2)[0]
}

function Get-SunshinePaths {
    param(
        [AllowNull()][string]$SunshineDirectory,
        [AllowNull()][string]$SunshineConfigPath,
        [AllowNull()][string]$SunshineLogPath,
        $SunshineService
    )
    $issues = New-Object System.Collections.Generic.List[string]
    $service = $SunshineService
    if ([string]::IsNullOrWhiteSpace($SunshineDirectory)) {
        if ($null -eq $service) {
            $service = Get-CimInstance -ClassName Win32_Service -Filter "Name='SunshineService'" -ErrorAction SilentlyContinue
        }
        if ($null -eq $service) {
            $issues.Add('SunshineService was not found; provide -SunshineDirectory.')
        } else {
            $serviceExecutable = Get-CommandExecutablePath ([string](Get-ObjectPropertyValue $service 'PathName'))
            if ([string]::IsNullOrWhiteSpace($serviceExecutable) -or [IO.Path]::GetFileName($serviceExecutable) -ine 'sunshinesvc.exe' -or
                [IO.Path]::GetFileName([IO.Path]::GetDirectoryName($serviceExecutable)) -ine 'tools') {
                $issues.Add('SunshineService does not reference the expected tools\sunshinesvc.exe path; provide -SunshineDirectory.')
            } else {
                $SunshineDirectory = Split-Path (Split-Path $serviceExecutable -Parent) -Parent
            }
        }
    }
    $sunshineExe = $null
    if (-not [string]::IsNullOrWhiteSpace($SunshineDirectory)) {
        try {
            $SunshineDirectory = Assert-SafePathChain -Path $SunshineDirectory
            if (-not (Test-Path -LiteralPath $SunshineDirectory -PathType Container)) { throw 'not a directory' }
            $sunshineExe = Join-Path $SunshineDirectory 'sunshine.exe'
            $null = Assert-SafePathChain -Path $sunshineExe
            if (-not (Test-Path -LiteralPath $sunshineExe -PathType Leaf)) { throw 'sunshine.exe is absent' }
        } catch {
            $issues.Add("Sunshine directory validation failed: $($_.Exception.Message)")
            $sunshineExe = $null
        }
    }
    if ([string]::IsNullOrWhiteSpace($SunshineConfigPath) -and $SunshineDirectory) {
        $SunshineConfigPath = Join-Path $SunshineDirectory 'config\sunshine.conf'
    }
    if (-not [string]::IsNullOrWhiteSpace($SunshineConfigPath)) {
        try {
            $SunshineConfigPath = Assert-SafePathChain -Path $SunshineConfigPath
            if (-not (Test-Path -LiteralPath $SunshineConfigPath -PathType Leaf)) { throw 'configuration file is absent' }
        } catch {
            $issues.Add("Sunshine config validation failed: $($_.Exception.Message)")
            $SunshineConfigPath = $null
        }
    } else {
        $issues.Add('Sunshine config path could not be determined.')
    }
    $configuredLogPath = $null
    if ($SunshineConfigPath -and $SunshineDirectory) {
        try {
            if (Test-PathWritableByStandardUsers -Path $SunshineConfigPath) { throw 'configuration is writable by standard users' }
            $pathEntries = Get-SunshineConfigEntries -Text (Get-Content -LiteralPath $SunshineConfigPath -Raw -Encoding UTF8 -ErrorAction Stop)
            if ($pathEntries.ContainsKey('log_path') -and $pathEntries['log_path'].Count -gt 1) { throw 'log_path is duplicated' }
            $rawLogPath = if ($pathEntries.ContainsKey('log_path') -and $pathEntries['log_path'].Count -eq 1) { $pathEntries['log_path'][0].Trim().Trim('"') } else { 'sunshine.log' }
            if ([string]::IsNullOrWhiteSpace($rawLogPath)) { $rawLogPath = 'sunshine.log' }
            if ([IO.Path]::IsPathRooted($rawLogPath)) { $configuredLogPath = [IO.Path]::GetFullPath($rawLogPath) }
            else { $configuredLogPath = [IO.Path]::GetFullPath((Join-Path (Join-Path $SunshineDirectory 'config') $rawLogPath)) }
        } catch {
            $issues.Add("Sunshine log_path discovery failed: $($_.Exception.Message)")
        }
    }
    if ([string]::IsNullOrWhiteSpace($SunshineLogPath)) {
        $SunshineLogPath = $configuredLogPath
    } elseif ($configuredLogPath) {
        try {
            $explicitLogPath = [IO.Path]::GetFullPath($SunshineLogPath)
            if ($explicitLogPath -ine $configuredLogPath) {
                $issues.Add("Explicit SunshineLogPath contradicts configured log_path. Configured: $configuredLogPath; explicit: $explicitLogPath")
            }
        } catch {
            $issues.Add("Explicit SunshineLogPath is invalid: $($_.Exception.Message)")
        }
    }
    if (-not [string]::IsNullOrWhiteSpace($SunshineLogPath)) {
        try {
            if (Test-Path -LiteralPath $SunshineLogPath) {
                $SunshineLogPath = Assert-SafePathChain -Path $SunshineLogPath
                if (-not (Test-Path -LiteralPath $SunshineLogPath -PathType Leaf)) { throw 'log path is not a file' }
            } else {
                $parent = Assert-SafePathChain -Path (Split-Path $SunshineLogPath -Parent)
                $SunshineLogPath = Join-Path $parent ([IO.Path]::GetFileName($SunshineLogPath))
            }
        } catch {
            $issues.Add("Sunshine log validation failed: $($_.Exception.Message)")
            $SunshineLogPath = $null
        }
    }
    [pscustomobject]@{
        Directory = $SunshineDirectory
        Exe = $sunshineExe
        ConfigPath = $SunshineConfigPath
        LogPath = $SunshineLogPath
        Service = $service
        Issues = $issues.ToArray()
    }
}

function Get-SunshineConfigEntries {
    param([Parameter(Mandatory = $true)][string]$Text)
    $entries = @{}
    foreach ($line in ($Text -split "`r?`n")) {
        if ($line -match '^\s*[#;]') { continue }
        if ($line -match '^\s*([A-Za-z0-9_]+)\s*=\s*(.*?)\s*$') {
            $key = $matches[1].ToLowerInvariant()
            if (-not $entries.ContainsKey($key)) { $entries[$key] = New-Object System.Collections.Generic.List[string] }
            $entries[$key].Add($matches[2])
        }
    }
    return $entries
}

function Read-SharedTextTail {
    param([Parameter(Mandatory = $true)][string]$Path, [int]$MaximumBytes = 8388608)
    $stream = [IO.File]::Open($Path, [IO.FileMode]::Open, [IO.FileAccess]::Read, ([IO.FileShare]::ReadWrite -bor [IO.FileShare]::Delete))
    try {
        $length = $stream.Length
        $start = [Math]::Max(0L, $length - [int64]$MaximumBytes)
        [void]$stream.Seek($start, [IO.SeekOrigin]::Begin)
        $buffer = New-Object byte[] ([int]($length - $start))
        $read = $stream.Read($buffer, 0, $buffer.Length)
        return [Text.Encoding]::UTF8.GetString($buffer, 0, $read)
    } finally { $stream.Dispose() }
}

function Get-BalancedJsonArray {
    param([Parameter(Mandatory = $true)][string]$Text, [Parameter(Mandatory = $true)][int]$StartIndex)
    $start = $Text.IndexOf('[', $StartIndex)
    if ($start -lt 0) { return $null }
    $depth = 0; $inString = $false; $escaped = $false
    for ($index = $start; $index -lt $Text.Length; $index++) {
        $character = $Text[$index]
        if ($inString) {
            if ($escaped) { $escaped = $false; continue }
            if ($character -eq '\') { $escaped = $true; continue }
            if ($character -eq '"') { $inString = $false }
            continue
        }
        if ($character -eq '"') { $inString = $true; continue }
        if ($character -eq '[') { $depth++ }
        elseif ($character -eq ']') {
            $depth--
            if ($depth -eq 0) { return $Text.Substring($start, $index - $start + 1) }
        }
    }
    return $null
}

function Get-SunshineDisplayEnumeration {
    <# .SYNOPSIS Reads the latest complete Sunshine display enumeration from its existing log. #>
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$LogPath)
    if (-not (Test-Path -LiteralPath $LogPath -PathType Leaf)) { return @() }
    $text = Read-SharedTextTail -Path $LogPath
    $matches = [regex]::Matches($text, '(?m)Currently available(?: display)? devices:\s*\r?$')
    for ($matchIndex = $matches.Count - 1; $matchIndex -ge 0; $matchIndex--) {
        $json = Get-BalancedJsonArray -Text $text -StartIndex ($matches[$matchIndex].Index + $matches[$matchIndex].Length)
        if ([string]::IsNullOrWhiteSpace($json)) { continue }
        try {
            $parsed = $json | ConvertFrom-Json -ErrorAction Stop
            $items = if ($parsed -is [Array]) { $parsed } else { @($parsed) }
            $normalized = foreach ($item in $items) {
                    [pscustomobject]@{
                        DeviceId = ConvertTo-NormalizedCaptureId ([string](Get-ObjectPropertyValue $item 'device_id'))
                        FriendlyName = [string](Get-ObjectPropertyValue $item 'friendly_name')
                        ManufacturerId = [string](Get-ObjectPropertyValue (Get-ObjectPropertyValue $item 'edid') 'manufacturer_id')
                        ProductCode = [string](Get-ObjectPropertyValue (Get-ObjectPropertyValue $item 'edid') 'product_code')
                        DisplayName = [string](Get-ObjectPropertyValue $item 'display_name')
                    }
                }
            return @($normalized)
        } catch {
            continue
        }
    }
    return @()
}

function Test-ManagedCaptureRecord {
    param($Record)
    return (([string](Get-ObjectPropertyValue $Record 'ManufacturerId')).Trim() -ieq 'MTT' -and
        ([string](Get-ObjectPropertyValue $Record 'ProductCode')).Trim() -eq '1337' -and
        ([string](Get-ObjectPropertyValue $Record 'FriendlyName')).Trim() -ieq 'VDD by MTT')
}

function Get-ValidatedVddSettingsPath {
    param([AllowNull()][string]$VddSettingsPath)
    $explicit = -not [string]::IsNullOrWhiteSpace($VddSettingsPath)
    if (-not $explicit) {
        $known = 'C:\VirtualDisplayDriver\vdd_settings.xml'
        if (Test-Path -LiteralPath $known -PathType Leaf) { $VddSettingsPath = $known } else { return $null }
    }
    try {
        $VddSettingsPath = Assert-SafePathChain -Path $VddSettingsPath
        if (-not (Test-Path -LiteralPath $VddSettingsPath -PathType Leaf)) { throw 'file is absent' }
        [xml]$xml = Get-Content -LiteralPath $VddSettingsPath -Raw -Encoding UTF8 -ErrorAction Stop
        $friendly = $xml.SelectSingleNode('//gpu/friendlyname')
        if ($null -eq $friendly) { throw 'expected gpu/friendlyname element is absent' }
        return $VddSettingsPath
    } catch {
        if ($explicit) { throw "VDD settings validation failed: $($_.Exception.Message)" }
        return $null
    }
}

function Get-DisplayHostConfiguration {
    <#
      .SYNOPSIS Performs bounded, read-only discovery for installer planning.
      .DESCRIPTION Hardware and capture targets must match tested providers. Unknown or ambiguous
      records are returned as blocking reasons; this function never changes services, drivers, tasks,
      configuration, display topology, resolution, GPU choice, or user pairing.
    #>
    [CmdletBinding()]
    param(
        [AllowNull()][string]$SunshineDirectory,
        [AllowNull()][string]$SunshineConfigPath,
        [AllowNull()][string]$SunshineLogPath,
        [AllowNull()][string]$ManagedDriverId,
        [AllowNull()][string]$VirtualDesktopDriverId,
        [AllowNull()][string]$CaptureDisplayId,
        [AllowNull()][string]$VddSettingsPath,
        [AllowNull()][object[]]$PnpRecords,
        [AllowNull()][object[]]$VideoControllers,
        $SunshineService
    )
    $blocking = New-Object System.Collections.Generic.List[string]
    $warnings = New-Object System.Collections.Generic.List[string]
    if (-not $PSBoundParameters.ContainsKey('PnpRecords')) { $PnpRecords = @(Get-DisplayPnpRecords) }
    if ($null -eq $PnpRecords) { $PnpRecords = @() }
    $managed = Resolve-DisplayProvider -Role Managed -Records @($PnpRecords) -ExplicitId $ManagedDriverId
    $virtualDesktop = Resolve-DisplayProvider -Role VirtualDesktop -Records @($PnpRecords) -ExplicitId $VirtualDesktopDriverId -Optional
    if (-not $managed.Resolved) { $blocking.Add($managed.Error) }
    if (@($managed.Candidates).Count -gt 1) {
        $blocking.Add('Multiple tested MTT providers are installed. Native MTT1337 output isolation cannot distinguish their adapters, so installation is refused even with -ManagedDriverId.')
    }
    if (-not $virtualDesktop.Resolved) { $blocking.Add($virtualDesktop.Error) }
    $managedProblemCode = $null
    if ($managed.Device) {
        $managedProblemCode = Get-ObjectPropertyValue $managed.Device 'ProblemCode'
        if ($null -eq $managedProblemCode) {
            $blocking.Add('Managed MTT driver availability could not be proven from its PnP problem code.')
        } elseif ([int]$managedProblemCode -eq 22) {
            $blocking.Add('Managed MTT driver is disabled (PnP problem code 22). Enable and validate it before installation; this installer does not change driver state.')
        } elseif ([int]$managedProblemCode -ne 0) {
            $blocking.Add("Managed MTT driver is unavailable (PnP problem code $managedProblemCode). Resolve it before installation.")
        }
    }

    $pathArguments = @{ SunshineDirectory = $SunshineDirectory; SunshineConfigPath = $SunshineConfigPath; SunshineLogPath = $SunshineLogPath }
    if ($PSBoundParameters.ContainsKey('SunshineService')) { $pathArguments.SunshineService = $SunshineService }
    $paths = Get-SunshinePaths @pathArguments
    foreach ($issue in $paths.Issues) { $blocking.Add($issue) }

    $configText = $null; $entries = @{}; $basePort = 47989
    $configuredCapture = $null; $settingChanges = New-Object System.Collections.Generic.List[object]
    $duplicates = New-Object System.Collections.Generic.List[string]
    if ($paths.ConfigPath) {
        try {
            if (Test-PathWritableByStandardUsers -Path $paths.ConfigPath) {
                throw 'configuration is writable by standard users; protected elevated reads are refused'
            }
            $configText = Get-Content -LiteralPath $paths.ConfigPath -Raw -Encoding UTF8 -ErrorAction Stop
            $entries = Get-SunshineConfigEntries -Text $configText
            foreach ($key in @('port', 'output_name', 'dd_configuration_option', 'dd_config_revert_on_disconnect', 'log_path', 'min_log_level')) {
                if ($entries.ContainsKey($key) -and $entries[$key].Count -gt 1) { $duplicates.Add($key) }
            }
            if ($duplicates.Count -gt 0) { $blocking.Add('Sunshine config has duplicate managed keys: ' + ($duplicates -join ', ')) }
            if ($entries.ContainsKey('port') -and $entries['port'].Count -eq 1) {
                $parsedPort = 0
                if (-not [int]::TryParse($entries['port'][0].Trim().Trim('"'), [ref]$parsedPort) -or $parsedPort -lt 1 -or $parsedPort -gt 65514) {
                    $blocking.Add('Sunshine base port is invalid; RTSP port cannot be derived safely.')
                } else { $basePort = $parsedPort }
            }
            if ($entries.ContainsKey('output_name') -and $entries['output_name'].Count -eq 1) {
                $configuredCapture = ConvertTo-NormalizedCaptureId $entries['output_name'][0]
            }
            $logLevel = if ($entries.ContainsKey('min_log_level') -and $entries['min_log_level'].Count -eq 1) { $entries['min_log_level'][0].Trim().Trim('"').ToLowerInvariant() } else { 'info' }
            if (@('verbose', 'debug', 'info', '0', '1', '2') -notcontains $logLevel) {
                $blocking.Add("Sunshine min_log_level must be verbose, debug, info, 0, 1, or 2 so session and display-enumeration events are available; current value: $logLevel")
            }
            $ddMode = if ($entries.ContainsKey('dd_configuration_option') -and $entries['dd_configuration_option'].Count -eq 1) { $entries['dd_configuration_option'][0].Trim().Trim('"') } else { $null }
            $revert = if ($entries.ContainsKey('dd_config_revert_on_disconnect') -and $entries['dd_config_revert_on_disconnect'].Count -eq 1) { $entries['dd_config_revert_on_disconnect'][0].Trim().Trim('"') } else { $null }
            if ($ddMode -ine 'ensure_active') { $settingChanges.Add([pscustomobject]@{ Key = 'dd_configuration_option'; Current = $ddMode; Required = 'ensure_active' }) }
            if ($revert -ine 'enabled') { $settingChanges.Add([pscustomobject]@{ Key = 'dd_config_revert_on_disconnect'; Current = $revert; Required = 'enabled' }) }
        } catch {
            $blocking.Add("Sunshine config could not be read: $($_.Exception.Message)")
        }
    }

    $displayEnumeration = @()
    if ($paths.LogPath) {
        try {
            if ((Test-Path -LiteralPath $paths.LogPath -PathType Leaf) -and (Test-PathWritableByStandardUsers -Path $paths.LogPath)) {
                throw 'log is writable by standard users; protected elevated reads are refused'
            }
            $displayEnumeration = @(Get-SunshineDisplayEnumeration -LogPath $paths.LogPath)
        }
        catch { $warnings.Add("Sunshine display enumeration could not be read: $($_.Exception.Message)") }
    }
    $managedCaptures = @($displayEnumeration | Where-Object { Test-ManagedCaptureRecord $_ })
    $requestedCapture = ConvertTo-NormalizedCaptureId $CaptureDisplayId
    if (-not [string]::IsNullOrWhiteSpace($CaptureDisplayId) -and $null -eq $requestedCapture) {
        $blocking.Add('CaptureDisplayId must be a UUID.')
    }
    $effectiveCapture = if ($requestedCapture) { $requestedCapture } else { $configuredCapture }
    $captureMatch = @($managedCaptures | Where-Object { $_.DeviceId -eq $effectiveCapture })
    if ($displayEnumeration.Count -eq 0) {
        $blocking.Add('No complete Sunshine display enumeration is available in the log; capture target/provider mapping cannot be proven.')
    } elseif ($null -eq $effectiveCapture) {
        $blocking.Add('Sunshine has no capture target. Provide -CaptureDisplayId from a logged MTT1337 display enumeration.')
    } elseif ($captureMatch.Count -ne 1) {
        $blocking.Add("Capture target $effectiveCapture is not a unique logged MTT1337 display. Provide -CaptureDisplayId for a validated MTT target.")
    }
    if ($requestedCapture -and $requestedCapture -ne $configuredCapture) {
        $settingChanges.Add([pscustomobject]@{ Key = 'output_name'; Current = $configuredCapture; Required = $requestedCapture })
    }

    if (-not $PSBoundParameters.ContainsKey('VideoControllers')) {
        $VideoControllers = @(Get-CimInstance -ClassName Win32_VideoController -ErrorAction SilentlyContinue)
    }
    $physicalGpuNames = @($VideoControllers | Where-Object {
            ([string](Get-ObjectPropertyValue $_ 'PNPDeviceID')) -match '^(?i)PCI\\'
        } | ForEach-Object { [string](Get-ObjectPropertyValue $_ 'Name') } | Where-Object { $_ } | Sort-Object -Unique)
    try { $validatedVddPath = Get-ValidatedVddSettingsPath -VddSettingsPath $VddSettingsPath }
    catch { $blocking.Add($_.Exception.Message); $validatedVddPath = $null }

    $managedId = $null
    if ($managed.Device) {
        $managedId = [string](Get-ObjectPropertyValue $managed.Device 'InstanceId')
        if ([string]::IsNullOrWhiteSpace($managedId)) { $managedId = [string](Get-ObjectPropertyValue $managed.Device 'DeviceID') }
    }
    $virtualDesktopId = $null
    if ($virtualDesktop.Device) {
        $virtualDesktopId = [string](Get-ObjectPropertyValue $virtualDesktop.Device 'InstanceId')
        if ([string]::IsNullOrWhiteSpace($virtualDesktopId)) { $virtualDesktopId = [string](Get-ObjectPropertyValue $virtualDesktop.Device 'DeviceID') }
    }
    $programData = [Environment]::GetFolderPath([Environment+SpecialFolder]::CommonApplicationData)
    $host = [pscustomobject][ordered]@{
        SchemaVersion = 1
        SunshineDirectory = $paths.Directory
        SunshineConfigPath = $paths.ConfigPath
        SunshineLogPath = $paths.LogPath
        SunshineExe = $paths.Exe
        ManagedDriverId = $managedId
        VirtualDesktopDriverId = $virtualDesktopId
        ManagedMonitorId = 'MTT1337'
        VirtualDesktopAdapter = 'Virtual Desktop Monitor'
        RtspPort = $basePort + 21
        VirtualDesktopPort = 38810
        IdleGraceSeconds = 8
        DisconnectGraceSeconds = 5
        RetrySeconds = 12
        PollSeconds = 2
        DataDirectory = Join-Path $programData 'Sunshine Display Coexistence'
        VddSettingsPath = $validatedVddPath
        TaskName = 'Sunshine Display Coexistence'
    }
    [pscustomobject]@{
        HostConfiguration = $host
        ManagedProvider = $managed
        ManagedDriverProblemCode = $managedProblemCode
        VirtualDesktopProvider = $virtualDesktop
        PhysicalGpuNames = $physicalGpuNames
        SunshineDisplayEnumeration = $displayEnumeration
        ManagedCaptureDisplays = $managedCaptures
        ConfiguredCaptureDisplayId = $configuredCapture
        EffectiveCaptureDisplayId = $effectiveCapture
        SunshineChangesRequired = $settingChanges.ToArray()
        CaptureTargetValidated = ($captureMatch.Count -eq 1)
        NeedsCaptureDisplayId = ($captureMatch.Count -ne 1)
        BlockingReasons = $blocking.ToArray()
        Warnings = $warnings.ToArray()
        ReadyForInstall = ($blocking.Count -eq 0)
        Limitations = @(
            'Capture UUID validation requires a complete Sunshine log enumeration for an MTT1337 display.',
            'Native display operations identify MTT1337 outputs by EDID and cannot isolate two installed MTT adapters.',
            'Discovery does not install drivers, choose a GPU, force a resolution, change display topology, or pair a user.',
            'Physical GPU names are audit data only; GPU selection requires an explicit later action and a validated VDD settings path.'
        )
    }
}

Export-ModuleMember -Function Assert-SafePathChain, Get-TrustedProtectedSidValues, Get-ProtectedPathAclAssessment, Test-PathWritableByStandardUsers, Assert-ProtectedPathAcl, Get-DisplayPnpRecords, Test-KnownDisplayProvider, Resolve-DisplayProvider, Get-SunshineDisplayEnumeration, Get-DisplayHostConfiguration
