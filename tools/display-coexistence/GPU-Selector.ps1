<# .SYNOPSIS Shows discovered physical GPUs and the status of automatic display ownership. #>
param([switch]$Preview)
$ErrorActionPreference='Stop'
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
$configuration=Get-Content -LiteralPath (Join-Path $PSScriptRoot 'host.json') -Raw -Encoding UTF8 | ConvertFrom-Json
Add-Type -Path (Join-Path $PSScriptRoot 'DisplayTools.cs')
$runtime=Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
$codeRoot=$PSScriptRoot
$form=New-Object Windows.Forms.Form
$form.Text='Sunshine GPU and automatic displays';$form.ClientSize=New-Object Drawing.Size(620,270)
$form.StartPosition='CenterScreen';$form.FormBorderStyle='FixedDialog';$form.MaximizeBox=$false
$label=New-Object Windows.Forms.Label;$label.Location=New-Object Drawing.Point(20,18);$label.Size=New-Object Drawing.Size(580,70);$form.Controls.Add($label)
$select=New-Object Windows.Forms.ComboBox;$select.Location=New-Object Drawing.Point(20,100);$select.Size=New-Object Drawing.Size(580,26);$select.DropDownStyle='DropDownList'
$cards=@(Get-CimInstance Win32_VideoController | Where-Object {$_.PNPDeviceID -like 'PCI\*'})
foreach($card in $cards){[void]$select.Items.Add($card.Name)}
if($select.Items.Count -gt 0){$select.SelectedIndex=0};$form.Controls.Add($select)
$apply=New-Object Windows.Forms.Button;$apply.Text='Use selected GPU';$apply.Location=New-Object Drawing.Point(20,143);$apply.Size=New-Object Drawing.Size(285,36);$form.Controls.Add($apply)
$refresh=New-Object Windows.Forms.Button;$refresh.Text='Refresh status';$refresh.Location=New-Object Drawing.Point(315,143);$refresh.Size=New-Object Drawing.Size(285,36);$form.Controls.Add($refresh)
$note=New-Object Windows.Forms.Label;$note.Location=New-Object Drawing.Point(20,197);$note.Size=New-Object Drawing.Size(580,58);$form.Controls.Add($note)
function Show-SelectorStatus {
    $taskState='not installed';try{$taskState=(Get-ScheduledTask -TaskName $configuration.TaskName -ErrorAction Stop).State.ToString()}catch{$taskState='unavailable'}
    $running=(Get-Service SunshineService -ErrorAction SilentlyContinue).Status -eq 'Running'
    $adapter='not selected';$text=[IO.File]::ReadAllText($configuration.SunshineConfigPath,[Text.Encoding]::UTF8)
    if($text -match '(?m)^adapter_name\s*=\s*(.+)$'){$adapter=$Matches[1].Trim()}
    $alternate=@([SunshineDisplays]::List() | Where-Object {$_.Active -and -not $_.Virtual}).Count -gt 0
    $apply.Enabled=$running -and $alternate -and $select.SelectedIndex -ge 0 -and [bool]$configuration.VddSettingsPath
    $label.Text='Sunshine: '+$(if($running){'running'}else{'stopped'})+"`r`nStreaming GPU: "+$adapter+"`r`nAutomatic display controller: "+$taskState
    $note.Text='Open streaming apps normally. GPU changes restart Sunshine and need administrator approval; close Moonlight first.'
    if(-not $alternate){$note.Text='Open Virtual Desktop or Meta with its own display before changing GPUs. Normal streaming remains automatic.'}
    if(-not $configuration.VddSettingsPath){$note.Text='Coordinated GPU selection requires the existing MikeTheTech settings XML. Display ownership remains automatic.'}
}
$refresh.Add_Click({Show-SelectorStatus})
$apply.Add_Click({
    $apply.Enabled=$false;$form.UseWaitCursor=$true
    try{
        $name=[string]$select.SelectedItem
        if($name -match '[\r\n"]' -or @($cards | Where-Object Name -eq $name).Count -ne 1){throw 'The selected adapter must have a unique, supported name.'}
        $arguments='-NoProfile -ExecutionPolicy Bypass -File "{0}" -AdapterName "{1}"' -f (Join-Path $codeRoot 'Select-StreamingGPU.ps1'),$name
        $process=Start-Process -FilePath $runtime -ArgumentList $arguments -Verb RunAs -WindowStyle Hidden -PassThru
        $process.WaitForExit();$process.Refresh()
        if($process.ExitCode -ne 0){throw 'GPU selection failed; see the protected gpu-error.json and gpu-rollback.json reports.'}
    }catch{[void][Windows.Forms.MessageBox]::Show($_.Exception.Message,'Sunshine GPU')}
    finally{$form.UseWaitCursor=$false;Show-SelectorStatus}
})
Show-SelectorStatus
if($Preview){
    $form.StartPosition='Manual';$form.Location=New-Object Drawing.Point(-10000,-10000);$form.ShowInTaskbar=$false
    $form.Show();[Windows.Forms.Application]::DoEvents()
    $bitmap=New-Object Drawing.Bitmap($form.Width,$form.Height)
    $form.DrawToBitmap($bitmap,(New-Object Drawing.Rectangle(0,0,$form.Width,$form.Height)))
    # Diagnostics are written only to a new per-user temporary file, never to privileged code.
    $path=Join-Path ([IO.Path]::GetTempPath()) ('sunshine-display-selector-'+[guid]::NewGuid().ToString('N')+'.png')
    $bitmap.Save($path,[Drawing.Imaging.ImageFormat]::Png);$bitmap.Dispose();$form.Dispose();$path;exit
}
[void]$form.ShowDialog()
