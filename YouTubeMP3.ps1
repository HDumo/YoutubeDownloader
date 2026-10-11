<#
  YouTube MP3 Downloader  (Windows, nothing to install)

  Start it with "Start YouTube MP3 Downloader.bat". On the first run it
  downloads two free helper programs into the "tools" folder next to this file:
    - yt-dlp.exe  (does the YouTube download)
    - ffmpeg.exe  (converts the audio to MP3)

  Closing the window keeps the app working in the background (tray icon,
  usually under the "hidden icons" arrow next to the clock).
#>
param([switch]$SetupOnly)

$ErrorActionPreference = 'Stop'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
$ProgressPreference = 'SilentlyContinue'

$AppDir       = $PSScriptRoot
$ToolsDir     = Join-Path $AppDir 'tools'
$YtDlp        = Join-Path $ToolsDir 'yt-dlp.exe'
$Ffmpeg       = Join-Path $ToolsDir 'ffmpeg.exe'
$SettingsFile = Join-Path $AppDir 'settings.json'
$QueueFile    = Join-Path $AppDir 'queue.json'

$YtDlpUrl  = 'https://github.com/yt-dlp/yt-dlp/releases/latest/download/yt-dlp.exe'
$FfmpegUrl = 'https://github.com/yt-dlp/FFmpeg-Builds/releases/latest/download/ffmpeg-master-latest-win64-gpl.zip'

# ----------------------------------------------------------------- setup ----
function Get-File($url, $dest) {
    $curl = Get-Command curl.exe -ErrorAction SilentlyContinue
    if ($curl) {
        & $curl.Source -L --fail -o $dest $url
        if ($LASTEXITCODE -ne 0) { throw "Download failed: $url" }
    } else {
        Invoke-WebRequest -Uri $url -OutFile $dest -UseBasicParsing
    }
}

function Install-Tools {
    if (-not (Test-Path $ToolsDir)) { New-Item -ItemType Directory -Path $ToolsDir | Out-Null }

    if (-not (Test-Path $YtDlp)) {
        Write-Host 'Downloading yt-dlp (one time only)...'
        Get-File $YtDlpUrl $YtDlp
    }

    if (-not (Test-Path $Ffmpeg)) {
        Write-Host 'Downloading ffmpeg (about 100+ MB, one time only - please wait)...'
        $zip = Join-Path ([IO.Path]::GetTempPath()) 'ytmp3-ffmpeg.zip'
        $tmp = Join-Path ([IO.Path]::GetTempPath()) 'ytmp3-ffmpeg'
        if (Test-Path $tmp) { Remove-Item $tmp -Recurse -Force }
        Get-File $FfmpegUrl $zip
        Write-Host 'Unpacking ffmpeg...'
        Expand-Archive -Path $zip -DestinationPath $tmp -Force
        $found = Get-ChildItem -Path $tmp -Recurse -Filter ffmpeg.exe | Select-Object -First 1
        if (-not $found) { throw 'ffmpeg.exe was not found inside the download.' }
        Copy-Item $found.FullName $Ffmpeg -Force
        Remove-Item $zip -Force -ErrorAction SilentlyContinue
        Remove-Item $tmp -Recurse -Force -ErrorAction SilentlyContinue
    }
}

if ($SetupOnly) {
    try {
        Install-Tools
        Write-Host 'Setup finished.'
        exit 0
    } catch {
        Write-Host ''
        Write-Host "Setup failed: $($_.Exception.Message)" -ForegroundColor Red
        Write-Host 'Check your internet connection and try again.'
        exit 1
    }
}

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
[System.Windows.Forms.Application]::EnableVisualStyles()

# Everything below runs inside try/catch so a hidden console never hides an error.
try {

if (-not ((Test-Path $YtDlp) -and (Test-Path $Ffmpeg))) {
    [void][System.Windows.Forms.MessageBox]::Show(
        "The helper programs are missing.`r`nPlease start the tool with 'Start YouTube MP3 Downloader.bat' - it downloads them automatically.",
        'YouTube MP3 Downloader')
    exit 1
}

# ---------------------------------------------- only one copy at a time ------
# If the app is already running (maybe hidden in the tray), just show that one.
$createdNew = $false
$script:Mutex = New-Object System.Threading.Mutex($true, 'Local\YouTubeMP3Downloader_Instance', [ref]$createdNew)
$script:ShowEvent = New-Object System.Threading.EventWaitHandle($false, [System.Threading.EventResetMode]::AutoReset, 'Local\YouTubeMP3Downloader_Show')
if (-not $createdNew) {
    [void]$script:ShowEvent.Set()
    exit 0
}

# -------------------------------------------------------------- settings ----
$UnitNames   = @('Days', 'Hours', 'Minutes', 'Seconds')
$UnitSeconds = @{ Days = 86400; Hours = 3600; Minutes = 60; Seconds = 1 }

$script:Settings = [ordered]@{
    Folder     = [Environment]::GetFolderPath('MyMusic')
    LimitCount = 0          # 0 = no limit
    Amount1    = 1
    Unit1      = 'Hours'
    Amount2    = 0
    Unit2      = 'Minutes'
    Background = $true
    LastUpdate = ''
    StartTimes = @()
}
if (-not $script:Settings['Folder']) { $script:Settings['Folder'] = [Environment]::GetFolderPath('Desktop') }

$script:StartTimes = New-Object System.Collections.ArrayList   # when downloads began (for the limit)

if (Test-Path $SettingsFile) {
    try {
        $saved = Get-Content $SettingsFile -Raw | ConvertFrom-Json
        if ($saved.Folder)                { $script:Settings['Folder'] = [string]$saved.Folder }
        if ($null -ne $saved.LimitCount)  { $script:Settings['LimitCount'] = [int]$saved.LimitCount }
        if ($null -ne $saved.Amount1)     { $script:Settings['Amount1'] = [int]$saved.Amount1 }
        if ($UnitNames -contains $saved.Unit1) { $script:Settings['Unit1'] = [string]$saved.Unit1 }
        if ($null -ne $saved.Amount2)     { $script:Settings['Amount2'] = [int]$saved.Amount2 }
        if ($UnitNames -contains $saved.Unit2) { $script:Settings['Unit2'] = [string]$saved.Unit2 }
        if ($null -ne $saved.Background)  { $script:Settings['Background'] = [bool]$saved.Background }
        if ($saved.LastUpdate)            { $script:Settings['LastUpdate'] = [string]$saved.LastUpdate }
        $inv = [Globalization.CultureInfo]::InvariantCulture
        foreach ($t in @($saved.StartTimes)) {
            try {
                $d = [datetime]::Parse([string]$t, $inv, [Globalization.DateTimeStyles]::RoundtripKind)
                [void]$script:StartTimes.Add($d)
            } catch { }
        }
    } catch { }
}

# ------------------------------------------------------------- helpers ------
function Quote-Arg([string]$a) {
    '"' + ($a -replace '(\\*)"', '$1$1\"' -replace '(\\+)$', '$1$1') + '"'
}

function Clean-Name([string]$name) {
    $n = $name.Trim()
    $n = $n -replace '(?i)\.mp3$', ''
    $n = $n -replace '[\\/:*?"<>|]', '_'
    $n = $n.Trim(' ', '.')
    return $n
}

function Normalize-Url([string]$u) {
    $u = $u.Trim()
    if ($u -match '^(?i)(www\.|m\.|music\.)?(youtube\.com|youtu\.be)/') { $u = "https://$u" }
    if ($u -match '^(?i)https?://\S+$') { return $u }
    return $null
}

function Format-Resume([datetime]$t) {
    if ($t.Date -eq (Get-Date).Date) { return $t.ToString('h:mm:ss tt') }
    return $t.ToString('ddd MMM d, h:mm tt')
}

# Stops yt-dlp AND the ffmpeg it started.
function Stop-ProcessTree($proc) {
    if (-not $proc) { return }
    try {
        & taskkill.exe /PID $proc.Id /T /F 2>&1 | Out-Null
    } catch { }
    try { if (-not $proc.HasExited) { $proc.Kill() } } catch { }
}

function New-AppIcon {
    try {
        $bmp = New-Object System.Drawing.Bitmap 32, 32
        $g = [System.Drawing.Graphics]::FromImage($bmp)
        $g.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
        $g.Clear([System.Drawing.Color]::Transparent)
        $red   = New-Object System.Drawing.SolidBrush ([System.Drawing.Color]::FromArgb(204, 24, 24))
        $white = New-Object System.Drawing.SolidBrush ([System.Drawing.Color]::White)
        $g.FillEllipse($red, 1, 1, 30, 30)
        $g.FillRectangle($white, 13, 7, 6, 10)
        $tri = [System.Drawing.Point[]]@(
            (New-Object System.Drawing.Point 8, 15),
            (New-Object System.Drawing.Point 24, 15),
            (New-Object System.Drawing.Point 16, 25))
        $g.FillPolygon($white, $tri)
        $g.Dispose()
        return [System.Drawing.Icon]::FromHandle($bmp.GetHicon())
    } catch {
        return [System.Drawing.SystemIcons]::Application
    }
}

# ---------------------------------------------------------------- queue -----
$script:Items      = New-Object System.Collections.ArrayList   # all queue items
$script:Current    = $null                                      # item being downloaded
$script:Proc       = $null
$script:OutTask    = $null
$script:ErrTask    = $null
$script:ExitSeen   = $null
$script:Paused     = $false
$script:WasBusy    = $false
$script:Quitting   = $false
$script:TipShown   = $false
$script:Counter    = 0

function Save-Queue {
    $pending = @($script:Items | Where-Object { $_.Status -eq 'Queued' -or $_.Status -eq 'Downloading' } |
        ForEach-Object { [pscustomobject]@{ Url = $_.Url; Name = $_.Name; Folder = $_.Folder } })
    try { ConvertTo-Json -InputObject @($pending) | Set-Content -Path $QueueFile -Encoding UTF8 } catch { }
}

function Update-Row($item) {
    $lvi = $item.Row
    $lvi.SubItems[1].Text = $item.Url
    $lvi.SubItems[2].Text = $item.Display
    $lvi.SubItems[3].Text = $item.Text
}

function Add-QueueItem([string]$url, [string]$name, [string]$folder) {
    $script:Counter++
    $item = [pscustomobject]@{
        Id = $script:Counter; Url = $url; Name = $name; Folder = $folder
        Display = $(if ($name) { $name } else { '(original title)' })
        Text = 'Queued'; Status = 'Queued'; Row = $null
        LastError = $null; RemoveWhenDone = $false
    }
    $lvi = New-Object System.Windows.Forms.ListViewItem([string]$item.Id)
    [void]$lvi.SubItems.Add($url)
    [void]$lvi.SubItems.Add($item.Display)
    [void]$lvi.SubItems.Add($item.Text)
    $lvi.Tag = $item.Id
    $item.Row = $lvi
    [void]$script:Items.Add($item)
    [void]$list.Items.Add($lvi)
}

function Find-Item([int]$id) {
    foreach ($i in $script:Items) { if ($i.Id -eq $id) { return $i } }
    return $null
}

function Remove-Row($item) {
    [void]$script:Items.Remove($item)
    if ($item.Row -and $item.Row.ListView) { $item.Row.Remove() }
}

function Set-ItemState($item, [string]$status, [string]$text) {
    $item.Status = $status
    $item.Text = $text
    Update-Row $item
}

function Stop-Current {
    if (-not $script:Current) { return }
    Set-ItemState $script:Current 'Cancelled' 'Cancelled'
    Stop-ProcessTree $script:Proc
}

# Removes the selected rows. A row that is downloading is cancelled first.
function Remove-Selected {
    $rows = @($list.SelectedItems)
    if ($rows.Count -eq 0) { $lblStatus.Text = 'Click one or more rows in the list first, then press Remove.'; return }
    foreach ($lvi in $rows) {
        $item = Find-Item ([int]$lvi.Tag)
        if (-not $item) { $lvi.Remove(); continue }
        if ($script:Current -and $item.Id -eq $script:Current.Id) {
            $item.RemoveWhenDone = $true
            Stop-Current
        } else {
            Remove-Row $item
        }
    }
    Save-Queue
}

function Retry-Selected {
    foreach ($lvi in @($list.SelectedItems)) {
        $item = Find-Item ([int]$lvi.Tag)
        if (-not $item) { continue }
        if ($script:Current -and $item.Id -eq $script:Current.Id) { continue }
        if ($item.Status -eq 'Failed' -or $item.Status -eq 'Cancelled') {
            $item.LastError = $null
            Set-ItemState $item 'Queued' 'Queued'
        }
    }
    Save-Queue
}

# ------------------------------------------------------ the download limit --
function Get-WindowSeconds {
    $secs = [double]$numA.Value * $UnitSeconds[[string]$cmbU1.SelectedItem]
    if ($cmbU2.Enabled -and $cmbU2.SelectedItem) {
        $secs += [double]$numB.Value * $UnitSeconds[[string]$cmbU2.SelectedItem]
    }
    return $secs
}

function Trim-StartTimes([double]$windowSeconds) {
    $cutoff = (Get-Date).AddSeconds(-$windowSeconds)
    for ($i = $script:StartTimes.Count - 1; $i -ge 0; $i--) {
        if ($script:StartTimes[$i] -lt $cutoff) { $script:StartTimes.RemoveAt($i) }
    }
}

# Returns $null when a download may start now, otherwise the time it may start.
function Get-NextAllowedTime {
    $limit = [int]$numCount.Value
    $win = Get-WindowSeconds
    if ($limit -le 0 -or $win -le 0) { return $null }
    Trim-StartTimes $win
    if ($script:StartTimes.Count -lt $limit) { return $null }
    $sorted = @($script:StartTimes | Sort-Object)
    return $sorted[$sorted.Count - $limit].AddSeconds($win)
}

# ------------------------------------------------------------- downloading --
function Start-Download($item) {
    $folder = $item.Folder
    if ($item.Name) {
        $leaf = ($item.Name -replace '%', '%%') + '.%(ext)s'
    } else {
        $leaf = '%(title)s.%(ext)s'
    }

    try {
        if (-not (Test-Path $folder)) { New-Item -ItemType Directory -Path $folder -Force | Out-Null }
        $template = Join-Path $folder $leaf

        $argList = @(
            '-x', '--audio-format', 'mp3', '--audio-quality', '0',
            '--no-playlist', '--newline', '--windows-filenames', '--embed-metadata',
            '--ffmpeg-location', $ToolsDir,
            '-o', $template,
            $item.Url
        )

        $psi = New-Object System.Diagnostics.ProcessStartInfo
        $psi.FileName = $YtDlp
        $psi.Arguments = ($argList | ForEach-Object { Quote-Arg $_ }) -join ' '
        $psi.UseShellExecute = $false
        $psi.CreateNoWindow = $true
        $psi.RedirectStandardOutput = $true
        $psi.RedirectStandardError = $true
        $psi.StandardOutputEncoding = [Text.Encoding]::UTF8
        $psi.StandardErrorEncoding = [Text.Encoding]::UTF8
        $psi.EnvironmentVariables['PYTHONIOENCODING'] = 'utf-8'

        $script:Proc = [System.Diagnostics.Process]::Start($psi)
    } catch {
        Set-ItemState $item 'Failed' ('Failed: could not start - ' + $_.Exception.Message)
        Save-Queue
        return
    }
    $script:OutTask = $script:Proc.StandardOutput.ReadLineAsync()
    $script:ErrTask = $script:Proc.StandardError.ReadLineAsync()
    $script:ExitSeen = $null
    $script:Current = $item
    $script:WasBusy = $true
    $item.LastError = $null
    [void]$script:StartTimes.Add((Get-Date))
    Set-ItemState $item 'Downloading' 'Starting...'
    Save-Queue
    Save-Settings      # remembers when this download started (for the limit)
}

function Handle-Line($line, $item, [bool]$isErr) {
    if (-not $line) { return }
    if ($item.Status -eq 'Cancelled') { return }
    if ($isErr -or $line -match '^ERROR') {
        if ($line -match '^ERROR') { $item.LastError = ($line -replace '^ERROR:\s*', '') }
        return
    }
    if ($line -match '^\[download\]\s+([\d\.]+)%') {
        $item.Text = 'Downloading ' + $Matches[1] + '%'
    } elseif ($line -match '^\[download\] Destination: (.+)$') {
        if (-not $item.Name) { $item.Display = [IO.Path]::GetFileNameWithoutExtension($Matches[1]) }
    } elseif ($line -match '^\[ExtractAudio\]') {
        $item.Text = 'Converting to MP3...'
        if ($line -match 'Destination: (.+)$' -and -not $item.Name) {
            $item.Display = [IO.Path]::GetFileNameWithoutExtension($Matches[1])
        }
    } elseif ($line -match 'has already been downloaded') {
        $item.Text = 'Already downloaded'
    }
    Update-Row $item
}

function Pump-Process {
    $item = $script:Current
    # Read whatever lines are ready (never blocks).
    for ($n = 0; $n -lt 200; $n++) {
        $moved = $false
        if ($script:OutTask -and $script:OutTask.IsCompleted) {
            $line = $script:OutTask.Result
            if ($null -eq $line) { $script:OutTask = $null }
            else { Handle-Line $line $item $false; $script:OutTask = $script:Proc.StandardOutput.ReadLineAsync() }
            $moved = $true
        }
        if ($script:ErrTask -and $script:ErrTask.IsCompleted) {
            $line = $script:ErrTask.Result
            if ($null -eq $line) { $script:ErrTask = $null }
            else { Handle-Line $line $item $true; $script:ErrTask = $script:Proc.StandardError.ReadLineAsync() }
            $moved = $true
        }
        if (-not $moved) { break }
    }

    if (-not $script:Proc.HasExited) { return }
    if (-not $script:ExitSeen) { $script:ExitSeen = Get-Date }
    $drained = (-not $script:OutTask) -and (-not $script:ErrTask)
    # If a stray child keeps the pipes open, do not wait for them forever.
    if (-not $drained -and ((Get-Date) - $script:ExitSeen).TotalSeconds -lt 3) { return }

    $code = $script:Proc.ExitCode
    $script:Proc.Dispose()
    $script:Proc = $null
    $script:OutTask = $null
    $script:ErrTask = $null
    $script:ExitSeen = $null
    $script:Current = $null

    if ($item.Status -ne 'Cancelled') {
        if ($code -eq 0) {
            Set-ItemState $item 'Done' 'Done'
        } else {
            $why = if ($item.LastError) { $item.LastError } else { "exit code $code" }
            if ($why.Length -gt 90) { $why = $why.Substring(0, 90) + '...' }
            Set-ItemState $item 'Failed' ("Failed: $why")
        }
    }
    if ($item.RemoveWhenDone) { Remove-Row $item }
    Save-Queue
}

function Set-Status([string]$text) {
    $lblStatus.Text = $text
    $tip = 'YouTube MP3: ' + $text
    if ($tip.Length -gt 63) { $tip = $tip.Substring(0, 60) + '...' }
    $script:Tray.Text = $tip
}

function Tick {
    if ($script:ShowEvent.WaitOne(0)) { Show-Window }

    $waiting = @($script:Items | Where-Object { $_.Status -eq 'Queued' }).Count

    if ($script:Current) {
        Pump-Process
        if ($script:Current) {
            $c = $script:Current
            Set-Status ("Downloading " + $c.Display + " - " + $c.Text + " (" + $waiting + " waiting)")
        }
        return
    }

    $next = $script:Items | Where-Object { $_.Status -eq 'Queued' } | Select-Object -First 1
    if (-not $next) {
        Set-Status 'Idle - add a link above.'
        if ($script:WasBusy) {
            $script:WasBusy = $false
            if (-not $form.Visible) {
                $script:Tray.ShowBalloonTip(4000, 'YouTube MP3 Downloader', 'The queue is finished.', [System.Windows.Forms.ToolTipIcon]::Info)
            }
        }
        return
    }
    if ($script:Paused) { Set-Status ("Paused (" + $waiting + " waiting)"); return }

    $allowed = Get-NextAllowedTime
    if ($allowed) {
        Set-Status ("Limit reached - next download at " + (Format-Resume $allowed) + " (" + $waiting + " waiting)")
        return
    }
    Start-Download $next
}

# --------------------------------------------------------------- the GUI ----
$appIcon = New-AppIcon

$form = New-Object System.Windows.Forms.Form
$form.Text = 'YouTube MP3 Downloader'
$form.ClientSize = New-Object System.Drawing.Size(850, 620)
$form.MinimumSize = New-Object System.Drawing.Size(740, 560)
$form.StartPosition = 'CenterScreen'
$form.Font = New-Object System.Drawing.Font('Segoe UI', 9.5)
$form.Icon = $appIcon

function New-Label($text, $x, $y) {
    $l = New-Object System.Windows.Forms.Label
    $l.Text = $text; $l.Location = New-Object System.Drawing.Point($x, $y); $l.AutoSize = $true
    $form.Controls.Add($l); return $l
}

[void](New-Label 'Paste YouTube link(s) - one per line:' 14 10)
$txtUrl = New-Object System.Windows.Forms.TextBox
$txtUrl.Multiline = $true; $txtUrl.ScrollBars = 'Vertical'
$txtUrl.Location = New-Object System.Drawing.Point(14, 32)
$txtUrl.Size = New-Object System.Drawing.Size(700, 62)
$txtUrl.Anchor = 'Top,Left,Right'
$form.Controls.Add($txtUrl)

$btnAdd = New-Object System.Windows.Forms.Button
$btnAdd.Text = 'Add to queue'
$btnAdd.Location = New-Object System.Drawing.Point(724, 32)
$btnAdd.Size = New-Object System.Drawing.Size(112, 62)
$btnAdd.Anchor = 'Top,Right'
$form.Controls.Add($btnAdd)

[void](New-Label 'Save as (optional - leave empty to keep the original video title):' 14 102)
$txtName = New-Object System.Windows.Forms.TextBox
$txtName.Location = New-Object System.Drawing.Point(14, 124)
$txtName.Size = New-Object System.Drawing.Size(822, 26)
$txtName.Anchor = 'Top,Left,Right'
$form.Controls.Add($txtName)

[void](New-Label 'Save to folder:' 14 158)
$txtFolder = New-Object System.Windows.Forms.TextBox
$txtFolder.Location = New-Object System.Drawing.Point(14, 180)
$txtFolder.Size = New-Object System.Drawing.Size(606, 26)
$txtFolder.Anchor = 'Top,Left,Right'
$txtFolder.Text = $script:Settings['Folder']
$form.Controls.Add($txtFolder)

$btnBrowse = New-Object System.Windows.Forms.Button
$btnBrowse.Text = 'Browse...'
$btnBrowse.Location = New-Object System.Drawing.Point(630, 178)
$btnBrowse.Size = New-Object System.Drawing.Size(100, 28)
$btnBrowse.Anchor = 'Top,Right'
$form.Controls.Add($btnBrowse)

$btnOpen = New-Object System.Windows.Forms.Button
$btnOpen.Text = 'Open folder'
$btnOpen.Location = New-Object System.Drawing.Point(736, 178)
$btnOpen.Size = New-Object System.Drawing.Size(100, 28)
$btnOpen.Anchor = 'Top,Right'
$form.Controls.Add($btnOpen)

# --- download limit:  Max [N] downloads per [A] [unit] + [B] [smaller unit] ---
$pnlLimit = New-Object System.Windows.Forms.FlowLayoutPanel
$pnlLimit.Location = New-Object System.Drawing.Point(14, 212)
$pnlLimit.Size = New-Object System.Drawing.Size(822, 34)
$pnlLimit.Anchor = 'Top,Left,Right'
$pnlLimit.WrapContents = $false
$form.Controls.Add($pnlLimit)

function New-FlowLabel($text) {
    $l = New-Object System.Windows.Forms.Label
    $l.Text = $text; $l.AutoSize = $true
    $l.Margin = New-Object System.Windows.Forms.Padding(0, 6, 4, 0)
    $pnlLimit.Controls.Add($l); return $l
}
function New-FlowNumber($max, $value) {
    $n = New-Object System.Windows.Forms.NumericUpDown
    $n.Minimum = 0; $n.Maximum = $max; $n.Value = [Math]::Min([Math]::Max($value, 0), $max)
    $n.Width = 62
    $n.Margin = New-Object System.Windows.Forms.Padding(0, 2, 8, 0)
    $pnlLimit.Controls.Add($n); return $n
}
function New-FlowUnit {
    $c = New-Object System.Windows.Forms.ComboBox
    $c.DropDownStyle = 'DropDownList'; $c.Width = 90
    $c.Margin = New-Object System.Windows.Forms.Padding(0, 2, 8, 0)
    $pnlLimit.Controls.Add($c); return $c
}

[void](New-FlowLabel 'Limit: max')
$numCount = New-FlowNumber 1000 $script:Settings['LimitCount']
[void](New-FlowLabel 'downloads per')
$numA = New-FlowNumber 9999 $script:Settings['Amount1']
$cmbU1 = New-FlowUnit
[void](New-FlowLabel '+')
$numB = New-FlowNumber 9999 $script:Settings['Amount2']
$cmbU2 = New-FlowUnit
[void](New-FlowLabel '(0 downloads = no limit)')

[void]$cmbU1.Items.AddRange([object[]]$UnitNames)
$cmbU1.SelectedItem = $script:Settings['Unit1']
if (-not $cmbU1.SelectedItem) { $cmbU1.SelectedItem = 'Hours' }

# The second dropdown only offers units SMALLER than the first one.
function Fill-Unit2 {
    $prev = [string]$cmbU2.SelectedItem
    $cmbU2.Items.Clear()
    $idx = [array]::IndexOf($UnitNames, [string]$cmbU1.SelectedItem)
    $smaller = @($UnitNames | Select-Object -Skip ($idx + 1))
    if ($smaller.Count -eq 0) {
        $numB.Value = 0
        $numB.Enabled = $false
        $cmbU2.Enabled = $false
        return
    }
    $numB.Enabled = $true
    $cmbU2.Enabled = $true
    [void]$cmbU2.Items.AddRange([object[]]$smaller)
    if ($prev -and ($smaller -contains $prev)) { $cmbU2.SelectedItem = $prev }
    else { $cmbU2.SelectedIndex = 0 }
}
Fill-Unit2
if ($cmbU2.Enabled -and ($cmbU2.Items -contains $script:Settings['Unit2'])) {
    $cmbU2.SelectedItem = $script:Settings['Unit2']
}
$cmbU1.Add_SelectedIndexChanged({ Fill-Unit2 })

$list = New-Object System.Windows.Forms.ListView
$list.View = 'Details'; $list.FullRowSelect = $true; $list.GridLines = $true
$list.MultiSelect = $true; $list.HideSelection = $false
$list.Location = New-Object System.Drawing.Point(14, 254)
$list.Size = New-Object System.Drawing.Size(822, 258)
$list.Anchor = 'Top,Bottom,Left,Right'
[void]$list.Columns.Add('#', 36)
[void]$list.Columns.Add('Link', 270)
[void]$list.Columns.Add('Save as', 210)
[void]$list.Columns.Add('Status', 282)
$form.Controls.Add($list)

$ctx = New-Object System.Windows.Forms.ContextMenuStrip
$ctxRemove = $ctx.Items.Add('Remove / cancel selected')
$ctxRetry  = $ctx.Items.Add('Retry selected (failed or cancelled)')
$list.ContextMenuStrip = $ctx

function New-BottomButton($text, $x, $w) {
    $b = New-Object System.Windows.Forms.Button
    $b.Text = $text
    $b.Location = New-Object System.Drawing.Point($x, 520)
    $b.Size = New-Object System.Drawing.Size($w, 30)
    $b.Anchor = 'Bottom,Left'
    $form.Controls.Add($b); return $b
}
$btnPause  = New-BottomButton 'Pause' 14 90
$btnRemove = New-BottomButton 'Remove / cancel selected' 112 190
$btnClear  = New-BottomButton 'Clear finished' 310 120
$btnUpdate = New-BottomButton 'Update yt-dlp' 438 120
$btnExit   = New-BottomButton 'Exit app' 566 100

$chkBg = New-Object System.Windows.Forms.CheckBox
$chkBg.Text = 'When I close this window, keep working in the background (find the icon under the hidden-icons arrow near the clock)'
$chkBg.Location = New-Object System.Drawing.Point(14, 558)
$chkBg.Size = New-Object System.Drawing.Size(822, 24)
$chkBg.Anchor = 'Bottom,Left,Right'
$chkBg.Checked = [bool]$script:Settings['Background']
$form.Controls.Add($chkBg)

$lblStatus = New-Object System.Windows.Forms.Label
$lblStatus.AutoSize = $false
$lblStatus.Location = New-Object System.Drawing.Point(14, 588)
$lblStatus.Size = New-Object System.Drawing.Size(822, 24)
$lblStatus.Anchor = 'Bottom,Left,Right'
$lblStatus.Text = 'Idle - add a link above.'
$form.Controls.Add($lblStatus)

# ------------------------------------------------------------ tray icon -----
$script:Tray = New-Object System.Windows.Forms.NotifyIcon
$script:Tray.Icon = $appIcon
$script:Tray.Text = 'YouTube MP3 Downloader'
$trayMenu = New-Object System.Windows.Forms.ContextMenuStrip
$miOpen  = $trayMenu.Items.Add('Open window')
$miPause = $trayMenu.Items.Add('Pause')
[void]$trayMenu.Items.Add((New-Object System.Windows.Forms.ToolStripSeparator))
$miExit  = $trayMenu.Items.Add('Exit (stop everything)')
$script:Tray.ContextMenuStrip = $trayMenu
$script:Tray.Visible = $true

function Show-Window {
    $form.Show()
    if ($form.WindowState -eq [System.Windows.Forms.FormWindowState]::Minimized) {
        $form.WindowState = [System.Windows.Forms.FormWindowState]::Normal
    }
    $form.Activate()
}

function Hide-ToTray {
    Save-Settings
    $form.Hide()
    if (-not $script:TipShown) {
        $script:TipShown = $true
        $script:Tray.ShowBalloonTip(5000, 'Still running in the background',
            'Downloads continue. Click the ^ arrow near the clock to find this icon; double-click it to open the window.',
            [System.Windows.Forms.ToolTipIcon]::Info)
    }
}

function Toggle-Pause {
    $script:Paused = -not $script:Paused
    $label = $(if ($script:Paused) { 'Resume' } else { 'Pause' })
    $btnPause.Text = $label
    $miPause.Text = $label
}

function Exit-App {
    if ($script:Current) {
        Show-Window
        $answer = [System.Windows.Forms.MessageBox]::Show(
            'A download is still running. Exit anyway? It will be stopped and kept in the queue for next time.',
            'Still downloading', 'YesNo')
        if ($answer -ne 'Yes') { return }
    }
    $script:Quitting = $true
    $form.Close()
}

# ------------------------------------------------------------- behaviour ----
function Sync-Settings {
    $s = $script:Settings
    $s['Folder']     = $txtFolder.Text.Trim()
    $s['LimitCount'] = [int]$numCount.Value
    $s['Amount1']    = [int]$numA.Value
    $s['Unit1']      = [string]$cmbU1.SelectedItem
    $s['Amount2']    = [int]$numB.Value
    $s['Unit2']      = $(if ($cmbU2.Enabled) { [string]$cmbU2.SelectedItem } else { '' })
    $s['Background'] = [bool]$chkBg.Checked
    $s['StartTimes'] = @($script:StartTimes | ForEach-Object { $_.ToString('o') })
}

function Save-Settings {
    try {
        Sync-Settings
        ConvertTo-Json -InputObject $script:Settings | Set-Content -Path $SettingsFile -Encoding UTF8
    } catch { }
}

$btnBrowse.Add_Click({
    $dlg = New-Object System.Windows.Forms.FolderBrowserDialog
    $dlg.Description = 'Choose where the MP3 files are saved'
    if (Test-Path $txtFolder.Text) { $dlg.SelectedPath = $txtFolder.Text }
    if ($dlg.ShowDialog() -eq 'OK') { $txtFolder.Text = $dlg.SelectedPath; Save-Settings }
})

$btnOpen.Add_Click({
    if (Test-Path $txtFolder.Text) { Start-Process explorer.exe -ArgumentList (Quote-Arg $txtFolder.Text) }
})

$btnAdd.Add_Click({
    $urls = @()
    $bad = @()
    foreach ($line in ($txtUrl.Text -split '\s+')) {
        if (-not $line.Trim()) { continue }
        $u = Normalize-Url $line
        if ($u) { $urls += $u } else { $bad += $line }
    }
    if ($bad.Count -gt 0) {
        [void][System.Windows.Forms.MessageBox]::Show(
            "These do not look like links and were skipped:`r`n`r`n" + ($bad -join "`r`n"), 'Check the link')
    }
    if ($urls.Count -eq 0) { return }

    $name = Clean-Name $txtName.Text
    if ($name -and $urls.Count -gt 1) {
        [void][System.Windows.Forms.MessageBox]::Show(
            'A custom name can only be used with one link at a time. Clear the "Save as" box, or add the links one by one.',
            'One name, many links')
        return
    }

    $folder = $txtFolder.Text.Trim()
    if (-not $folder) { [void][System.Windows.Forms.MessageBox]::Show('Please choose a folder first.', 'No folder'); return }

    foreach ($u in $urls) { Add-QueueItem $u $name $folder }
    $txtUrl.Clear(); $txtName.Clear()
    Save-Queue
    Save-Settings
})

$btnPause.Add_Click({ Toggle-Pause })
$miPause.Add_Click({ Toggle-Pause })

$btnRemove.Add_Click({
    try { Remove-Selected } catch { $lblStatus.Text = 'Could not remove: ' + $_.Exception.Message }
})
$ctxRemove.Add_Click({
    try { Remove-Selected } catch { $lblStatus.Text = 'Could not remove: ' + $_.Exception.Message }
})
$ctxRetry.Add_Click({
    try { Retry-Selected } catch { $lblStatus.Text = 'Could not retry: ' + $_.Exception.Message }
})
$list.Add_KeyDown({
    if ($_.KeyCode -eq [System.Windows.Forms.Keys]::Delete) {
        try { Remove-Selected } catch { $lblStatus.Text = 'Could not remove: ' + $_.Exception.Message }
    }
})

$btnClear.Add_Click({
    foreach ($item in @($script:Items)) {
        $s = $item.Status
        if ($s -eq 'Done' -or $s -eq 'Failed' -or $s -eq 'Cancelled') {
            if ($script:Current -and $item.Id -eq $script:Current.Id) { continue }
            Remove-Row $item
        }
    }
})

function Update-YtDlp {
    $lblStatus.Text = 'Updating yt-dlp...'
    $form.Refresh()
    try {
        $p = Start-Process -FilePath $YtDlp -ArgumentList '-U' -WindowStyle Hidden -Wait -PassThru
        if ($p.ExitCode -eq 0) {
            $script:Settings['LastUpdate'] = (Get-Date).ToString('yyyy-MM-dd')
            Save-Settings
            $lblStatus.Text = 'yt-dlp is up to date.'
        } else {
            $lblStatus.Text = 'Update finished with a warning (are you online?).'
        }
    } catch {
        $lblStatus.Text = 'Could not update yt-dlp: ' + $_.Exception.Message
    }
}
$btnUpdate.Add_Click({ if (-not $script:Current) { Update-YtDlp } else { $lblStatus.Text = 'Wait for the current download to finish first.' } })

$btnExit.Add_Click({ Exit-App })
$miExit.Add_Click({ Exit-App })
$miOpen.Add_Click({ Show-Window })
$script:Tray.Add_DoubleClick({ Show-Window })

$timer = New-Object System.Windows.Forms.Timer
$timer.Interval = 500
$timer.Add_Tick({
    try { Tick } catch { $lblStatus.Text = 'Error: ' + $_.Exception.Message }
})

$form.Add_FormClosing({
    $e = $_
    if (-not $script:Quitting -and $e.CloseReason -eq [System.Windows.Forms.CloseReason]::UserClosing) {
        if ($chkBg.Checked) {
            $e.Cancel = $true
            Hide-ToTray
            return
        }
        if ($script:Current) {
            $answer = [System.Windows.Forms.MessageBox]::Show(
                'A download is still running. Close anyway? It will be stopped and kept in the queue for next time.',
                'Still downloading', 'YesNo')
            if ($answer -ne 'Yes') { $e.Cancel = $true; return }
        }
    }
    # Really closing.
    if ($script:Proc) { Stop-ProcessTree $script:Proc }
    Save-Settings
    Save-Queue
    $timer.Stop()
    $script:Tray.Visible = $false
    $script:Tray.Dispose()
})

$form.Add_Shown({
    # Restore links that were still waiting when the app was last closed.
    if (Test-Path $QueueFile) {
        try {
            $savedQ = Get-Content $QueueFile -Raw | ConvertFrom-Json
            foreach ($s in @($savedQ)) {
                if ($s.Url) { Add-QueueItem ([string]$s.Url) ([string]$s.Name) ([string]$s.Folder) }
            }
        } catch { }
    }
    # YouTube changes often; refresh yt-dlp if it has not been updated for a week.
    $stale = $true
    if ($script:Settings['LastUpdate']) {
        try { $stale = ((Get-Date) - [datetime]$script:Settings['LastUpdate']).TotalDays -ge 7 } catch { }
    }
    if ($stale) { Update-YtDlp }
    $timer.Start()
})

# Application.Run (not ShowDialog) so the window can be hidden while the app keeps working.
[System.Windows.Forms.Application]::Run($form)

} catch {
    [void][System.Windows.Forms.MessageBox]::Show(
        "Something went wrong:`r`n`r`n" + $_.Exception.Message + "`r`n`r`n" + $_.ScriptStackTrace,
        'YouTube MP3 Downloader')
    exit 1
}
