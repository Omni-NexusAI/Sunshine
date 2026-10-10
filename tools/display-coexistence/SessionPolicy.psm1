# Session tracking and display policy; no display mutations occur in this module.
Set-StrictMode -Version 2

function New-SessionHistory {
    <#
    .SYNOPSIS
    Creates bounded incremental Sunshine session history.
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification='Constructs only in-memory session history; no system state changes occur.')]
    [CmdletBinding()]
    [OutputType([hashtable])]
    param()
    return @{ Pid = 0; Offset = 0L; Count = 0; Pending = ''; Creation = [datetime]::MinValue; Uncertain = $false; LastEvent = ''; ProcessBound = $false }
}

function Read-SessionHistory {
    <#
    .SYNOPSIS
    Reads complete client records, preserving uncertainty after a log reset.
       .PARAMETER History Mutable state belonging to one controller process.
       .PARAMETER LogPath Sunshine's existing log, not a client-supplied file.
       .PARAMETER ProcessId Current Sunshine process identity.
    #>
    param([hashtable]$History, [string]$LogPath, [int]$ProcessId, [datetime]$ProcessStartTime = [datetime]::MinValue)
    if (-not (Test-Path -LiteralPath $LogPath -PathType Leaf)) { return @{ Known = $false; Count = 0; LastEvent = '' } }
    $info = Get-Item -LiteralPath $LogPath
    if ($History.Pid -ne $ProcessId) {
        $History.Clear()
        foreach ($entry in (New-SessionHistory).GetEnumerator()) { $History[$entry.Key] = $entry.Value }
        $History.Pid = $ProcessId; $History.Creation = $info.CreationTimeUtc
    } elseif ($info.Length -lt $History.Offset -or $info.CreationTimeUtc -ne $History.Creation) {
        $History.Uncertain = $true
    }
    if ($History.Uncertain) { return @{ Known = $false; Count = 0; LastEvent = $History.LastEvent } }
    $stream = [IO.File]::Open($LogPath, [IO.FileMode]::Open, [IO.FileAccess]::Read, ([IO.FileShare]::ReadWrite -bor [IO.FileShare]::Delete))
    try {
        [void]$stream.Seek($History.Offset, [IO.SeekOrigin]::Begin)
        $buffer = New-Object byte[] ([int][Math]::Min(1048576, [Math]::Max(0, $info.Length - $History.Offset)))
        $read = $stream.Read($buffer, 0, $buffer.Length); $History.Offset += $read
        $text = $History.Pending + [Text.Encoding]::UTF8.GetString($buffer, 0, $read)
        $end = $text.LastIndexOf("`n")
        if ($end -ge 0) {
            $complete = $text.Substring(0, $end + 1); $History.Pending = $text.Substring($end + 1)
            if ($ProcessStartTime -ne [datetime]::MinValue -and -not $History.ProcessBound) {
                $marker = [regex]::Match($complete, '(?m)^\[(\d{4}-\d\d-\d\d \d\d:\d\d:\d\d\.\d{3})\]: Info: Sunshine version: [^\r\n]+\r?$')
                $stamp = [datetime]::MinValue
                if ($marker.Success -and [datetime]::TryParseExact($marker.Groups[1].Value, 'yyyy-MM-dd HH:mm:ss.fff', [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::AssumeLocal, [ref]$stamp)) {
                    $History.ProcessBound = ($stamp -ge $ProcessStartTime.AddSeconds(-1) -and $stamp -le $ProcessStartTime.AddSeconds(35) -and $info.LastWriteTimeUtc -ge $ProcessStartTime.ToUniversalTime())
                }
            }
            foreach ($clientEvent in [regex]::Matches($complete, '(?m)^\[[^\r\n]+\]: Info: CLIENT (CONNECTED|DISCONNECTED)\r?$')) {
                $History.LastEvent = $clientEvent.Groups[1].Value
                if ($History.LastEvent -eq 'CONNECTED') { $History.Count++ }
                elseif ($History.Count -gt 0) { $History.Count-- }
                else { $History.Uncertain = $true }
            }
        } else { $History.Pending = $text }
    } finally { $stream.Dispose() }
    if ($History.Pending.Length -gt 32768) { $History.Uncertain = $true }
    $bound = ($ProcessStartTime -eq [datetime]::MinValue -or $History.ProcessBound)
    return @{ Known = (-not $History.Uncertain -and $History.Offset -ge $info.Length -and $bound); Count = $History.Count; LastEvent = $History.LastEvent }
}

function Test-SessionLogConfiguration {
    <#
    .SYNOPSIS
    Refuses idle evidence when Sunshine redirects logging or excludes Info client events.
       .PARAMETER Configuration Discovered and protected host configuration.
       .PARAMETER ConfigText Optional text injection for offline tests.
    #>
    param($Configuration, [AllowNull()][string]$ConfigText)
    if (-not $PSBoundParameters.ContainsKey('ConfigText')) { $ConfigText = [IO.File]::ReadAllText($Configuration.SunshineConfigPath, [Text.Encoding]::UTF8) }
    $levels = [regex]::Matches($ConfigText, '(?m)^\s*min_log_level\s*=\s*([^\r\n#]+)')
    if ($levels.Count -gt 1) { return $false }
    if ($levels.Count -eq 1 -and $levels[0].Groups[1].Value.Trim().Trim('"').ToLowerInvariant() -notin @('verbose','debug','info','0','1','2')) { return $false }
    $paths = [regex]::Matches($ConfigText, '(?m)^\s*log_path\s*=\s*([^\r\n#]+)')
    if ($paths.Count -gt 1) { return $false }
    $logPath = 'sunshine.log'
    if ($paths.Count -eq 1) { $logPath = $paths[0].Groups[1].Value.Trim().Trim('"') }
    if (-not [IO.Path]::IsPathRooted($logPath)) { $logPath = Join-Path (Join-Path $Configuration.SunshineDirectory 'config') $logPath }
    return ([IO.Path]::GetFullPath($logPath) -ieq [IO.Path]::GetFullPath($Configuration.SunshineLogPath))
}

function Get-SunshineSessionState {
    <#
    .SYNOPSIS
    Protects active streams and capture startup; RTSP is only a startup guard.
    #>
    param($Configuration, [hashtable]$History, [switch]$DrainHistory, [ValidateRange(1,64)][int]$MaximumChunks = 16)
    $processes = @(Get-Process sunshine -ErrorAction SilentlyContinue)
    if ($processes.Count -eq 0) { return @{ Known = $true; Count = 0; Starting = $false; LastEvent = '' } }
    if ($processes.Count -ne 1 -or $processes[0].Path -ne $Configuration.SunshineExe) { return @{ Known = $false; Count = 0; Starting = $true; LastEvent = '' } }
    if (-not (Test-SessionLogConfiguration -Configuration $Configuration)) { return @{ Known = $false; Count = 0; Starting = $true; LastEvent = '' } }
    $chunks = 0
    do {
        $beforeOffset = $History.Offset
        $state = Read-SessionHistory -History $History -LogPath $Configuration.SunshineLogPath -ProcessId $processes[0].Id -ProcessStartTime $processes[0].StartTime
        $chunks++
    } while ($DrainHistory -and -not $state.Known -and -not $History.Uncertain -and $History.Offset -gt $beforeOffset -and $chunks -lt $MaximumChunks)
    $startup = ((Get-Date) - $processes[0].StartTime).TotalSeconds -lt 35
    $rtsp = @((Get-NetTCPConnection -LocalPort $Configuration.RtspPort -State Established -ErrorAction SilentlyContinue) | Where-Object { $_.OwningProcess -eq $processes[0].Id }).Count -gt 0
    $recent = $true
    if (Test-Path -LiteralPath $Configuration.SunshineLogPath) { $recent = ((Get-Date).ToUniversalTime() - (Get-Item -LiteralPath $Configuration.SunshineLogPath).LastWriteTimeUtc).TotalSeconds -lt 5 }
    $state.Starting = ($startup -or $rtsp -or $recent)
    return $state
}

function Test-SafeIdle {
    <#
    .SYNOPSIS
    Requires positively known idle state before parking or restoring any desktop.
    #>
    param($Session)
    return ($Session.Known -and $Session.Count -eq 0 -and -not $Session.Starting)
}

function Get-DisplayDecision {
    <#
    .SYNOPSIS
    Pure policy used by the controller and offline transition tests.
    #>
    param($Session, [int]$ManagedActive, [int]$OtherActive, [bool]$PreferredConnected, [bool]$Settled)
    if (-not $Session.Known -or $Session.Count -gt 0 -or $Session.Starting) { return 'Preserve' }
    if ($ManagedActive -eq 0) { return 'Idle' }
    if (-not $Settled) { return 'Settle' }
    if ($OtherActive -gt 0) { return 'Park' }
    if ($PreferredConnected) { return 'Handoff' }
    return 'KeepLastDesktop'
}
Export-ModuleMember -Function New-SessionHistory, Read-SessionHistory, Get-SunshineSessionState, Test-SessionLogConfiguration, Test-SafeIdle, Get-DisplayDecision
