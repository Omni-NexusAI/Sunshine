<# .SYNOPSIS Builds a standalone opt-in companion ZIP and SHA-256 manifest from this Sunshine fork. #>
param([Parameter(Mandatory=$true)][string]$OutputDirectory,[switch]$BundleSunshine,[string]$SunshineInstallerPath)
$ErrorActionPreference='Stop'
$packageVersion='0.1.0-preview'
$name='Sunshine-Display-Coexistence-Windows-'+$packageVersion
if(-not (Test-Path -LiteralPath $OutputDirectory)){New-Item -ItemType Directory -Path $OutputDirectory | Out-Null}
$destination=Join-Path $OutputDirectory ($name+'.zip')
if(Test-Path -LiteralPath $destination){throw 'Output already exists; choose a new build directory.'}
$files=@('README.md','LICENSE','Start-Install.ps1','Install-DisplayCoexistence.ps1','Uninstall-DisplayCoexistence.ps1','HostDiscovery.psm1','Watch-StreamingDisplays.ps1','SessionPolicy.psm1','DisplayTools.cs','Control-DisplayCoexistence.ps1','GPU-Selector.ps1','Select-StreamingGPU.ps1','upstream.json','Install.cmd','Inspect.cmd')
$paths=@();$manifest=@()
foreach($file in $files){
    $path=Join-Path $PSScriptRoot $file
    if(-not (Test-Path -LiteralPath $path -PathType Leaf)){throw "Required package file missing: $file"}
    $paths+=$path;$manifest+=[pscustomobject]@{File=$file;Sha256=(Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash.ToLowerInvariant()}
}
$manifestPath=Join-Path $OutputDirectory ($name+'.files.json')
$manifest | ConvertTo-Json | Set-Content -LiteralPath $manifestPath -Encoding UTF8
Compress-Archive -LiteralPath $paths -DestinationPath $destination -CompressionLevel Optimal
$hash=(Get-FileHash -LiteralPath $destination -Algorithm SHA256).Hash.ToLowerInvariant()
($hash+'  '+[IO.Path]::GetFileName($destination)) | Set-Content -LiteralPath ($destination+'.sha256') -Encoding ASCII
[pscustomobject]@{Package=$destination;Sha256=$hash;Version=$packageVersion}
if($BundleSunshine){
    $upstream=Get-Content -LiteralPath (Join-Path $PSScriptRoot 'upstream.json') -Raw | ConvertFrom-Json
    $bundleName='Sunshine-Headless-Bundle-Windows-AMD64-'+$packageVersion
    $stage=Join-Path $OutputDirectory $bundleName
    if(Test-Path -LiteralPath $stage){throw 'Bundle staging exists; choose a new build directory.'}
    New-Item -ItemType Directory -Path $stage | Out-Null
    $controller=Join-Path $stage 'display-coexistence';New-Item -ItemType Directory -Path $controller | Out-Null
    foreach($path in $paths){Copy-Item -LiteralPath $path -Destination $controller}
    $installer=Join-Path $stage 'Sunshine-Windows-AMD64-installer.msi'
    if($SunshineInstallerPath){Copy-Item -LiteralPath $SunshineInstallerPath -Destination $installer}
    else{Invoke-WebRequest -Uri $upstream.windowsAmd64InstallerUrl -OutFile $installer -UseBasicParsing -TimeoutSec 180}
    if((Get-FileHash -LiteralPath $installer -Algorithm SHA256).Hash.ToLowerInvariant() -ne $upstream.windowsAmd64InstallerSha256){throw 'Official Sunshine installer checksum mismatch; bundle was not produced.'}
    @('This bundle contains the unmodified official stable Sunshine Windows AMD64 MSI and the opt-in display controller from this fork.',
      'On a new host, install Sunshine using the MSI, install/configure your existing supported virtual display driver, and pair Moonlight normally.',
      'Then run display-coexistence\Inspect.cmd and display-coexistence\Install.cmd. See that directory''s README for configuration or migration options.',
      'On an already working host, use the companion installer without replacing Sunshine. This is a preview; cross-host and reboot validation remain required.') | Set-Content -LiteralPath (Join-Path $stage 'READ-ME-FIRST.txt') -Encoding UTF8
    $bundle=Join-Path $OutputDirectory ($bundleName+'.zip')
    Compress-Archive -LiteralPath $stage -DestinationPath $bundle -CompressionLevel Optimal
    $bundleHash=(Get-FileHash -LiteralPath $bundle -Algorithm SHA256).Hash.ToLowerInvariant()
    ($bundleHash+'  '+[IO.Path]::GetFileName($bundle)) | Set-Content -LiteralPath ($bundle+'.sha256') -Encoding ASCII
    [pscustomobject]@{Bundle=$bundle;Sha256=$bundleHash;Sunshine=$upstream.sunshineRelease;OfficialBinaryUnmodified=$true}
}
