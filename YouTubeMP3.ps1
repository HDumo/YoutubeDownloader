<#
  YouTube MP3 Downloader  (Windows, nothing to install)

  Start it with "Start YouTube MP3 Downloader.bat". On the first run it
  downloads two free helper programs into the "tools" folder next to this file:
    - yt-dlp.exe  (does the YouTube download)
    - ffmpeg.exe  (converts the audio to MP3)

  Closing the window keeps the app working in the background (tray icon,
  usually under the "hidden icons" arrow next to the clock).
#>
param([switch]$SetupOnly, [switch]$StartInTray)

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
        try { Set-Content -Path (Join-Path $AppDir 'setup-error.txt') -Value $_.Exception.Message } catch { }
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

# ------------------------------------------- first-run setup (graphical) ------
function Show-SetupWindow {
    $errFile = Join-Path $AppDir 'setup-error.txt'
    if (Test-Path $errFile) { Remove-Item $errFile -Force -ErrorAction SilentlyContinue }

    $psExe = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    $argText = '-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "' + $PSCommandPath + '" -SetupOnly'
    $script:SetupProc = Start-Process -FilePath $psExe -ArgumentList $argText -WindowStyle Hidden -PassThru
    $null = $script:SetupProc.Handle      # keeps ExitCode readable

    $f = New-Object System.Windows.Forms.Form
    $script:SetupForm = $f
    $f.Text = 'YouTube Downloader - first-time setup'
    $f.FormBorderStyle = 'FixedDialog'
    $f.MaximizeBox = $false; $f.MinimizeBox = $false
    $f.StartPosition = 'CenterScreen'
    $f.ClientSize = New-Object System.Drawing.Size(500, 176)
    $f.Font = New-Object System.Drawing.Font('Segoe UI', 9.5)
    $f.BackColor = [System.Drawing.Color]::White
    try { $f.Icon = New-Object System.Drawing.Icon((Join-Path $AppDir 'app.ico')) } catch { }

    $t = New-Object System.Windows.Forms.Label
    $t.Text = 'Getting ready...'
    $t.Font = New-Object System.Drawing.Font('Segoe UI Semibold', 14)
    $t.AutoSize = $true
    $t.Location = New-Object System.Drawing.Point(20, 16)
    $f.Controls.Add($t)

    $script:SetupDetail = New-Object System.Windows.Forms.Label
    $script:SetupDetail.AutoSize = $false
    $script:SetupDetail.Location = New-Object System.Drawing.Point(22, 52)
    $script:SetupDetail.Size = New-Object System.Drawing.Size(456, 24)
    $script:SetupDetail.Text = 'Downloading the helper programs...'
    $f.Controls.Add($script:SetupDetail)

    $bar = New-Object System.Windows.Forms.ProgressBar
    $bar.Style = 'Marquee'
    $bar.MarqueeAnimationSpeed = 30
    $bar.Location = New-Object System.Drawing.Point(22, 88)
    $bar.Size = New-Object System.Drawing.Size(456, 18)
    $f.Controls.Add($bar)

    $n = New-Object System.Windows.Forms.Label
    $n.Text = 'This happens only once and needs an internet connection (about 150 MB).'
    $n.ForeColor = [System.Drawing.Color]::FromArgb(107, 114, 128)
    $n.AutoSize = $true
    $n.Location = New-Object System.Drawing.Point(22, 122)
    $f.Controls.Add($n)

    $script:SetupZip = Join-Path ([IO.Path]::GetTempPath()) 'ytmp3-ffmpeg.zip'
    $script:SetupTimer = New-Object System.Windows.Forms.Timer
    $script:SetupTimer.Interval = 500
    $script:SetupTimer.Add_Tick({
        try {
            if ($script:SetupProc.HasExited) {
                $script:SetupTimer.Stop()
                $script:SetupForm.Tag = [int]$script:SetupProc.ExitCode
                $script:SetupForm.Close()
                return
            }
            if (Test-Path $script:SetupZip) {
                $mb = [Math]::Round((Get-Item $script:SetupZip).Length / 1MB)
                $script:SetupDetail.Text = "Downloading ffmpeg (audio/video converter): $mb MB so far..."
            } elseif (-not (Test-Path $YtDlp)) {
                $script:SetupDetail.Text = 'Downloading yt-dlp (the YouTube engine)...'
            } else {
                $script:SetupDetail.Text = 'Almost done - unpacking...'
            }
        } catch { }
    })
    $f.Add_FormClosing({
        if ($script:SetupProc -and -not $script:SetupProc.HasExited) {
            try { & taskkill.exe /PID $script:SetupProc.Id /T /F 2>&1 | Out-Null } catch { }
        }
    })
    $script:SetupTimer.Start()
    [void]$f.ShowDialog()
    $script:SetupTimer.Dispose()

    if (($f.Tag -eq 0) -and (Test-Path $YtDlp) -and (Test-Path $Ffmpeg)) { return $true }

    $why = 'The download did not finish.'
    if (Test-Path $errFile) { try { $why = (Get-Content $errFile -Raw).Trim() } catch { } }
    [void][System.Windows.Forms.MessageBox]::Show(
        "Setup could not finish:`r`n`r`n$why`r`n`r`nCheck your internet connection and start the app again.",
        'YouTube Downloader')
    return $false
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

if (-not ((Test-Path $YtDlp) -and (Test-Path $Ffmpeg))) {
    if (-not (Show-SetupWindow)) { exit 1 }
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
    Mp3        = $true
    Mp4        = $false
    Quality    = 'Best'
    PauseAmount1 = 1
    PauseUnit1   = 'Hours'
    PauseAmount2 = 0
    PauseUnit2   = 'Minutes'
    PausedUntil  = ''
}
$QualityNames   = @('Best', '1080p', '720p', '480p', '360p')
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
        if ($null -ne $saved.Mp3)         { $script:Settings['Mp3'] = [bool]$saved.Mp3 }
        if ($null -ne $saved.Mp4)         { $script:Settings['Mp4'] = [bool]$saved.Mp4 }
        if ($QualityNames -contains $saved.Quality) { $script:Settings['Quality'] = [string]$saved.Quality }
        if ($null -ne $saved.PauseAmount1) { $script:Settings['PauseAmount1'] = [int]$saved.PauseAmount1 }
        if ($UnitNames -contains $saved.PauseUnit1) { $script:Settings['PauseUnit1'] = [string]$saved.PauseUnit1 }
        if ($null -ne $saved.PauseAmount2) { $script:Settings['PauseAmount2'] = [int]$saved.PauseAmount2 }
        if ($UnitNames -contains $saved.PauseUnit2) { $script:Settings['PauseUnit2'] = [string]$saved.PauseUnit2 }
        if ($saved.PausedUntil)           { $script:Settings['PausedUntil'] = [string]$saved.PausedUntil }
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
    $n = $n -replace '(?i)\.(mp3|mp4)$', ''
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

function Get-AppIcon {
    $ico = Join-Path $AppDir 'app.ico'
    if (Test-Path $ico) {
        try { return New-Object System.Drawing.Icon($ico) } catch { }
    }
    return New-AppIcon
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
$script:ResumeAt   = $null                                     # when a timed pause ends
$script:WasBusy    = $false
$script:Quitting   = $false
$script:TipShown   = $false
$script:Counter    = 0

function Save-Queue {
    $pending = @($script:Items | Where-Object { $_.Status -eq 'Queued' -or $_.Status -eq 'Downloading' } |
        ForEach-Object { [pscustomobject]@{ Url = $_.Url; Name = $_.Name; Folder = $_.Folder; Kind = $_.Kind; Height = $_.Height } })
    try { ConvertTo-Json -InputObject @($pending) | Set-Content -Path $QueueFile -Encoding UTF8 } catch { }
}

function Get-StatusColor([string]$status) {
    switch ($status) {
        'Done'        { return [System.Drawing.Color]::FromArgb(21, 128, 61) }
        'Failed'      { return [System.Drawing.Color]::FromArgb(185, 28, 28) }
        'Downloading' { return [System.Drawing.Color]::FromArgb(29, 78, 216) }
        'Cancelled'   { return [System.Drawing.Color]::FromArgb(107, 114, 128) }
        default       { return [System.Drawing.Color]::FromArgb(55, 65, 81) }
    }
}

function Update-Row($item) {
    $lvi = $item.Row
    $lvi.ForeColor = Get-StatusColor $item.Status
    $lvi.SubItems[1].Text = $item.Kind
    $lvi.SubItems[2].Text = $item.Url
    $lvi.SubItems[3].Text = $item.Display
    $lvi.SubItems[4].Text = $item.Text
}

function Add-QueueItem([string]$url, [string]$name, [string]$folder, [string]$kind, [int]$height) {
    if ($kind -ne 'MP4') { $kind = 'MP3' }
    $script:Counter++
    $item = [pscustomobject]@{
        Id = $script:Counter; Url = $url; Name = $name; Folder = $folder; Kind = $kind; Height = $height
        Display = $(if ($name) { $name } else { '(original title)' })
        Text = 'Queued'; Status = 'Queued'; Row = $null
        LastError = $null; RemoveWhenDone = $false
    }
    $lvi = New-Object System.Windows.Forms.ListViewItem([string]$item.Id)
    [void]$lvi.SubItems.Add($kind)
    [void]$lvi.SubItems.Add($url)
    [void]$lvi.SubItems.Add($item.Display)
    [void]$lvi.SubItems.Add($item.Text)
    $lvi.Tag = $item.Id
    if ($item.Id % 2 -eq 0) { $lvi.BackColor = [System.Drawing.Color]::FromArgb(249, 250, 251) }
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

        if ($item.Kind -eq 'MP4') {
            # Prefer H.264 + AAC (plays everywhere); fall back to whatever is best.
            $cap = if ($item.Height -gt 0) { '[height<=?' + $item.Height + ']' } else { '' }
            $fmt = 'bv*[vcodec^=avc1]' + $cap + '+ba[acodec^=mp4a]/b[ext=mp4]' + $cap + '/bv*' + $cap + '+ba/b' + $cap
            $argList = @(
                '-f', $fmt, '--merge-output-format', 'mp4'
            )
        } else {
            $argList = @('-x', '--audio-format', 'mp3', '--audio-quality', '0')
        }
        $argList += @(
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
        if (-not $item.Name) { $item.Display = ([IO.Path]::GetFileNameWithoutExtension($Matches[1]) -replace '\.f\d+$', '') }
    } elseif ($line -match '^\[Merger\]') {
        $item.Text = 'Joining video and audio...'
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
    $tip = 'YouTube DL: ' + $text
    if ($tip.Length -gt 63) { $tip = $tip.Substring(0, 60) + '...' }
    $script:Tray.Text = $tip
}

function Tick {
    if ($script:ShowEvent.WaitOne(0)) { Show-Window }

    if ($script:Paused -and $script:ResumeAt -and (Get-Date) -ge $script:ResumeAt) {
        Clear-Pause
        if (-not $form.Visible) {
            $script:Tray.ShowBalloonTip(4000, 'YouTube Downloader', 'The pause is over - downloads are resuming.', [System.Windows.Forms.ToolTipIcon]::Info)
        }
    }

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
                $script:Tray.ShowBalloonTip(4000, 'YouTube Downloader', 'The queue is finished.', [System.Windows.Forms.ToolTipIcon]::Info)
            }
        }
        return
    }
    if ($script:Paused) {
        $until = $(if ($script:ResumeAt) { ' until ' + (Format-Resume $script:ResumeAt) } else { '' })
        Set-Status ("Paused" + $until + " (" + $waiting + " waiting)")
        return
    }

    $allowed = Get-NextAllowedTime
    if ($allowed) {
        Set-Status ("Limit reached - next download at " + (Format-Resume $allowed) + " (" + $waiting + " waiting)")
        return
    }
    Start-Download $next
}

# --------------------------------------------------------------- the GUI ----
$appIcon = Get-AppIcon

# palette
$cBg       = [System.Drawing.Color]::FromArgb(243, 244, 246)
$cInk      = [System.Drawing.Color]::FromArgb(17, 24, 39)
$cMuted    = [System.Drawing.Color]::FromArgb(107, 114, 128)
$cLine     = [System.Drawing.Color]::FromArgb(209, 213, 219)
$cAccent   = [System.Drawing.Color]::FromArgb(220, 38, 38)
$cAccentHi = [System.Drawing.Color]::FromArgb(185, 28, 28)
$cHeader   = [System.Drawing.Color]::FromArgb(31, 41, 55)

$form = New-Object System.Windows.Forms.Form
$form.Text = 'YouTube Downloader'
$form.ClientSize = New-Object System.Drawing.Size(850, 744)
$form.MinimumSize = New-Object System.Drawing.Size(760, 520)
$form.StartPosition = 'CenterScreen'
$form.Font = New-Object System.Drawing.Font('Segoe UI', 9.5)
$form.BackColor = $cBg
$form.ForeColor = $cInk
$form.Icon = $appIcon

# Everything except the header lives in $body (so positions start below the header).
$body = New-Object System.Windows.Forms.Panel
$body.Dock = 'Fill'
$body.BackColor = $cBg
$form.Controls.Add($body)

$header = New-Object System.Windows.Forms.Panel
$header.Dock = 'Top'
$header.Height = 60
$header.BackColor = $cHeader
$form.Controls.Add($header)
$body.BringToFront()

try {
    $hdrIco = New-Object System.Drawing.Icon((Join-Path $AppDir 'app.ico'), 48, 48)
    $hdrBmp = $hdrIco.ToBitmap()
} catch {
    $hdrBmp = $appIcon.ToBitmap()
}
$pic = New-Object System.Windows.Forms.PictureBox
$pic.Image = $hdrBmp
$pic.SizeMode = 'Zoom'
$pic.Location = New-Object System.Drawing.Point(16, 10)
$pic.Size = New-Object System.Drawing.Size(40, 40)
$header.Controls.Add($pic)

$lblTitle = New-Object System.Windows.Forms.Label
$lblTitle.Text = 'YouTube Downloader'
$lblTitle.Font = New-Object System.Drawing.Font('Segoe UI Semibold', 15)
$lblTitle.ForeColor = [System.Drawing.Color]::White
$lblTitle.AutoSize = $true
$lblTitle.Location = New-Object System.Drawing.Point(64, 6)
$header.Controls.Add($lblTitle)

$lblSub = New-Object System.Windows.Forms.Label
$lblSub.Text = 'MP3 and MP4   |   queue   |   limits and pauses   |   keeps working in the background'
$lblSub.Font = New-Object System.Drawing.Font('Segoe UI', 9)
$lblSub.ForeColor = [System.Drawing.Color]::FromArgb(156, 163, 175)
$lblSub.AutoSize = $true
$lblSub.Location = New-Object System.Drawing.Point(66, 35)
$header.Controls.Add($lblSub)

# --- small builders -------------------------------------------------------------
$script:UiParent = $body          # controls are added to whatever panel $script:UiParent points at

function New-Card($y, $h) {
    $c = New-Object System.Windows.Forms.Panel
    $c.BackColor = [System.Drawing.Color]::White
    $c.Location = New-Object System.Drawing.Point(14, $y)
    $c.Size = New-Object System.Drawing.Size(822, $h)
    $c.Anchor = 'Top,Left,Right'
    $body.Controls.Add($c); return $c
}

function Style-Button($b, [string]$kind) {
    $b.FlatStyle = 'Flat'
    $b.Cursor = [System.Windows.Forms.Cursors]::Hand
    $b.FlatAppearance.BorderSize = 1
    if ($kind -eq 'primary') {
        $b.BackColor = $cAccent
        $b.ForeColor = [System.Drawing.Color]::White
        $b.FlatAppearance.BorderColor = $cAccent
        $b.FlatAppearance.MouseOverBackColor = $cAccentHi
        $b.Font = New-Object System.Drawing.Font('Segoe UI Semibold', 10)
    } else {
        $b.BackColor = [System.Drawing.Color]::White
        $b.ForeColor = $cInk
        $b.FlatAppearance.BorderColor = $cLine
        $b.FlatAppearance.MouseOverBackColor = $cBg
    }
}

function New-Caption($text, $x, $y) {
    $l = New-Object System.Windows.Forms.Label
    $l.Text = $text; $l.AutoSize = $true
    $l.Font = New-Object System.Drawing.Font('Segoe UI Semibold', 9)
    $l.ForeColor = $cMuted
    $l.Location = New-Object System.Drawing.Point($x, $y)
    $script:UiParent.Controls.Add($l); return $l
}

function New-Box($x, $y, $w, $h) {
    $t = New-Object System.Windows.Forms.TextBox
    $t.BorderStyle = 'FixedSingle'
    $t.Location = New-Object System.Drawing.Point($x, $y)
    $t.Size = New-Object System.Drawing.Size($w, $h)
    $script:UiParent.Controls.Add($t); return $t
}

function New-Btn($text, $x, $y, $w, $h, $kind) {
    $b = New-Object System.Windows.Forms.Button
    $b.Text = $text
    $b.Location = New-Object System.Drawing.Point($x, $y)
    $b.Size = New-Object System.Drawing.Size($w, $h)
    Style-Button $b $kind
    $script:UiParent.Controls.Add($b); return $b
}

# --- card 1: what to download, where to put it -----------------------------------
$card1 = New-Card 12 198
$script:UiParent = $card1

[void](New-Caption 'PASTE YOUTUBE LINK(S) - ONE PER LINE' 12 8)
$txtUrl = New-Box 12 28 686 52
$txtUrl.Multiline = $true; $txtUrl.ScrollBars = 'Vertical'
$txtUrl.Anchor = 'Top,Left,Right'

$btnAdd = New-Btn 'Add to queue' 706 28 104 52 'primary'
$btnAdd.Anchor = 'Top,Right'

[void](New-Caption 'SAVE AS  (optional - leave empty to keep the original video title)' 12 88)
$txtName = New-Box 12 108 798 26
$txtName.Anchor = 'Top,Left,Right'

[void](New-Caption 'SAVE TO FOLDER' 12 140)
$txtFolder = New-Box 12 160 584 26
$txtFolder.Anchor = 'Top,Left,Right'
$txtFolder.Text = $script:Settings['Folder']

$btnBrowse = New-Btn 'Browse...' 604 158 98 30 'normal'
$btnBrowse.Anchor = 'Top,Right'
$btnOpen = New-Btn 'Open folder' 708 158 102 30 'normal'
$btnOpen.Anchor = 'Top,Right'

# --- card 2: format, limit, pauses --------------------------------------------------
$card2 = New-Card 222 150
$script:UiParent = $card2

function New-FlowPanel($y) {
    $p = New-Object System.Windows.Forms.FlowLayoutPanel
    $p.Location = New-Object System.Drawing.Point(12, $y)
    $p.Size = New-Object System.Drawing.Size(798, 32)
    $p.Anchor = 'Top,Left,Right'
    $p.WrapContents = $false
    $script:UiParent.Controls.Add($p); return $p
}
function New-FlowLabel($panel, $text) {
    $l = New-Object System.Windows.Forms.Label
    $l.Text = $text; $l.AutoSize = $true
    $l.Margin = New-Object System.Windows.Forms.Padding(0, 6, 4, 0)
    $panel.Controls.Add($l); return $l
}
function New-FlowNote($panel, $text) {
    $l = New-FlowLabel $panel $text
    $l.ForeColor = $cMuted
    return $l
}
function New-FlowNumber($panel, $max, $value) {
    $n = New-Object System.Windows.Forms.NumericUpDown
    $n.Minimum = 0; $n.Maximum = $max; $n.Value = [Math]::Min([Math]::Max($value, 0), $max)
    $n.Width = 62
    $n.Margin = New-Object System.Windows.Forms.Padding(0, 2, 8, 0)
    $panel.Controls.Add($n); return $n
}
function New-FlowCombo($panel, $width) {
    $c = New-Object System.Windows.Forms.ComboBox
    $c.DropDownStyle = 'DropDownList'; $c.Width = $width
    $c.FlatStyle = 'Flat'
    $c.Margin = New-Object System.Windows.Forms.Padding(0, 2, 8, 0)
    $panel.Controls.Add($c); return $c
}
function New-FlowButton($panel, $text, $width) {
    $b = New-Object System.Windows.Forms.Button
    $b.Text = $text; $b.Width = $width; $b.Height = 26
    $b.Margin = New-Object System.Windows.Forms.Padding(4, 1, 8, 0)
    Style-Button $b 'normal'
    $panel.Controls.Add($b); return $b
}

# The second dropdown only offers units SMALLER than the first one.
function Fill-SecondUnit($first, $num, $second) {
    $prev = [string]$second.SelectedItem
    $second.Items.Clear()
    $idx = [array]::IndexOf($UnitNames, [string]$first.SelectedItem)
    $smaller = @($UnitNames | Select-Object -Skip ($idx + 1))
    if ($smaller.Count -eq 0) {
        $num.Value = 0
        $num.Enabled = $false
        $second.Enabled = $false
        return
    }
    $num.Enabled = $true
    $second.Enabled = $true
    [void]$second.Items.AddRange([object[]]$smaller)
    if ($prev -and ($smaller -contains $prev)) { $second.SelectedItem = $prev }
    else { $second.SelectedIndex = 0 }
}
function Init-UnitPair($first, $num, $second, $unit1, $unit2) {
    [void]$first.Items.AddRange([object[]]$UnitNames)
    $first.SelectedItem = $unit1
    if (-not $first.SelectedItem) { $first.SelectedItem = 'Hours' }
    Fill-SecondUnit $first $num $second
    if ($second.Enabled -and ($second.Items -contains $unit2)) { $second.SelectedItem = $unit2 }
}

# --- what to download: MP3 and/or MP4 ------------------------------------------
$pnlFormat = New-FlowPanel 6
$chkMp3 = New-Object System.Windows.Forms.CheckBox
$chkMp3.Text = 'MP3 (audio)'; $chkMp3.AutoSize = $true
$chkMp3.Margin = New-Object System.Windows.Forms.Padding(0, 4, 14, 0)
$chkMp3.Checked = [bool]$script:Settings['Mp3']
$pnlFormat.Controls.Add($chkMp3)
$chkMp4 = New-Object System.Windows.Forms.CheckBox
$chkMp4.Text = 'MP4 (video)'; $chkMp4.AutoSize = $true
$chkMp4.Margin = New-Object System.Windows.Forms.Padding(0, 4, 14, 0)
$chkMp4.Checked = [bool]$script:Settings['Mp4']
$pnlFormat.Controls.Add($chkMp4)
[void](New-FlowLabel $pnlFormat 'Video quality up to:')
$cmbQuality = New-FlowCombo $pnlFormat 80
[void]$cmbQuality.Items.AddRange([object[]]$QualityNames)
$cmbQuality.SelectedItem = $script:Settings['Quality']
if (-not $cmbQuality.SelectedItem) { $cmbQuality.SelectedItem = 'Best' }
$cmbQuality.Enabled = $chkMp4.Checked
[void](New-FlowNote $pnlFormat '(tick both to get the audio AND the video of every link)')
$chkMp4.Add_CheckedChanged({ $cmbQuality.Enabled = $chkMp4.Checked })

# --- download limit:  Max [N] downloads per [A] [unit] + [B] [smaller unit] ----
$pnlLimit = New-FlowPanel 40
[void](New-FlowLabel $pnlLimit 'Limit: max')
$numCount = New-FlowNumber $pnlLimit 1000 $script:Settings['LimitCount']
[void](New-FlowLabel $pnlLimit 'downloads per')
$numA = New-FlowNumber $pnlLimit 9999 $script:Settings['Amount1']
$cmbU1 = New-FlowCombo $pnlLimit 90
[void](New-FlowLabel $pnlLimit '+')
$numB = New-FlowNumber $pnlLimit 9999 $script:Settings['Amount2']
$cmbU2 = New-FlowCombo $pnlLimit 90
[void](New-FlowNote $pnlLimit '(0 downloads = no limit)')
Init-UnitPair $cmbU1 $numB $cmbU2 $script:Settings['Unit1'] $script:Settings['Unit2']
$cmbU1.Add_SelectedIndexChanged({ Fill-SecondUnit $cmbU1 $numB $cmbU2 })

# --- pause for a while:  resume in [A] [unit] + [B] [smaller unit] ---------------
$pnlPauseFor = New-FlowPanel 74
[void](New-FlowLabel $pnlPauseFor 'Pause now, resume in')
$numPA = New-FlowNumber $pnlPauseFor 9999 $script:Settings['PauseAmount1']
$cmbPU1 = New-FlowCombo $pnlPauseFor 90
[void](New-FlowLabel $pnlPauseFor '+')
$numPB = New-FlowNumber $pnlPauseFor 9999 $script:Settings['PauseAmount2']
$cmbPU2 = New-FlowCombo $pnlPauseFor 90
$btnPauseFor = New-FlowButton $pnlPauseFor 'Pause for this long' 150
Init-UnitPair $cmbPU1 $numPB $cmbPU2 $script:Settings['PauseUnit1'] $script:Settings['PauseUnit2']
$cmbPU1.Add_SelectedIndexChanged({ Fill-SecondUnit $cmbPU1 $numPB $cmbPU2 })

# --- pause until a date and time ------------------------------------------------
$pnlPauseUntil = New-FlowPanel 108
[void](New-FlowLabel $pnlPauseUntil 'Or pause until')
$dtpUntil = New-Object System.Windows.Forms.DateTimePicker
$dtpUntil.Format = [System.Windows.Forms.DateTimePickerFormat]::Custom
$dtpUntil.CustomFormat = 'ddd MMM d, yyyy   h:mm tt'
$dtpUntil.Width = 270
$dtpUntil.Margin = New-Object System.Windows.Forms.Padding(0, 2, 8, 0)
$now = Get-Date
$dtpUntil.Value = $now.AddHours(1).AddSeconds(-$now.Second)
$pnlPauseUntil.Controls.Add($dtpUntil)
$btnPauseUntil = New-FlowButton $pnlPauseUntil 'Pause until then' 150
[void](New-FlowNote $pnlPauseUntil '(a download already running finishes first)')

# --- the queue ---------------------------------------------------------------------
$list = New-Object System.Windows.Forms.ListView
$list.View = 'Details'; $list.FullRowSelect = $true; $list.GridLines = $false
$list.MultiSelect = $true; $list.HideSelection = $false
$list.BorderStyle = 'FixedSingle'
$list.BackColor = [System.Drawing.Color]::White
$list.Location = New-Object System.Drawing.Point(14, 382)
$list.Size = New-Object System.Drawing.Size(822, 196)
$list.Anchor = 'Top,Bottom,Left,Right'
[void]$list.Columns.Add('#', 36)
[void]$list.Columns.Add('Type', 50)
[void]$list.Columns.Add('Link', 240)
[void]$list.Columns.Add('Save as', 190)
[void]$list.Columns.Add('Status', 270)
$body.Controls.Add($list)

$ctx = New-Object System.Windows.Forms.ContextMenuStrip
$ctxRemove = $ctx.Items.Add('Remove / cancel selected')
$ctxRetry  = $ctx.Items.Add('Retry selected (failed or cancelled)')
$list.ContextMenuStrip = $ctx

$script:UiParent = $body
function New-BottomButton($text, $x, $w) {
    $b = New-Btn $text $x 588 $w 32 'normal'
    $b.Anchor = 'Bottom,Left'
    return $b
}
$btnPause  = New-BottomButton 'Pause' 14 90
$btnRemove = New-BottomButton 'Remove / cancel selected' 112 190
$btnClear  = New-BottomButton 'Clear finished' 310 120
$btnUpdate = New-BottomButton 'Update yt-dlp' 438 130
$btnExit   = New-BottomButton 'Exit app' 576 100
$btnPhone  = New-BottomButton 'Phone / tablet access' 684 152

$chkBg = New-Object System.Windows.Forms.CheckBox
$chkBg.Text = 'When I close this window, keep working in the background (find the icon under the hidden-icons arrow near the clock)'
$chkBg.ForeColor = $cMuted
$chkBg.Location = New-Object System.Drawing.Point(14, 626)
$chkBg.Size = New-Object System.Drawing.Size(822, 24)
$chkBg.Anchor = 'Bottom,Left,Right'
$chkBg.Checked = [bool]$script:Settings['Background']
$body.Controls.Add($chkBg)

$lblStatus = New-Object System.Windows.Forms.Label
$lblStatus.AutoSize = $false
$lblStatus.Font = New-Object System.Drawing.Font('Segoe UI Semibold', 9.5)
$lblStatus.ForeColor = $cInk
$lblStatus.Location = New-Object System.Drawing.Point(14, 654)
$lblStatus.Size = New-Object System.Drawing.Size(822, 24)
$lblStatus.Anchor = 'Bottom,Left,Right'
$lblStatus.Text = 'Idle - add a link above.'
$body.Controls.Add($lblStatus)

# ------------------------------------------------------------ tray icon -----
$script:Tray = New-Object System.Windows.Forms.NotifyIcon
$script:Tray.Icon = $appIcon
$script:Tray.Text = 'YouTube Downloader'
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

function Update-PauseUI {
    $label = $(if ($script:Paused) { 'Resume' } else { 'Pause' })
    $btnPause.Text = $label
    $miPause.Text = $label
}

# $until = $null means "pause until I press Resume".
function Set-Pause($until) {
    $script:Paused = $true
    $script:ResumeAt = $until
    Update-PauseUI
    Save-Settings
}

function Clear-Pause {
    $script:Paused = $false
    $script:ResumeAt = $null
    Update-PauseUI
    Save-Settings
}

function Toggle-Pause {
    if ($script:Paused) { Clear-Pause } else { Set-Pause $null }
}

function Get-PauseSeconds {
    $secs = [double]$numPA.Value * $UnitSeconds[[string]$cmbPU1.SelectedItem]
    if ($cmbPU2.Enabled -and $cmbPU2.SelectedItem) {
        $secs += [double]$numPB.Value * $UnitSeconds[[string]$cmbPU2.SelectedItem]
    }
    return $secs
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
    $s['Mp3']        = [bool]$chkMp3.Checked
    $s['Mp4']        = [bool]$chkMp4.Checked
    $s['Quality']    = [string]$cmbQuality.SelectedItem
    $s['PauseAmount1'] = [int]$numPA.Value
    $s['PauseUnit1']   = [string]$cmbPU1.SelectedItem
    $s['PauseAmount2'] = [int]$numPB.Value
    $s['PauseUnit2']   = $(if ($cmbPU2.Enabled) { [string]$cmbPU2.SelectedItem } else { '' })
    $s['PausedUntil']  = $(if ($script:Paused -and $script:ResumeAt) { $script:ResumeAt.ToString('o') } else { '' })
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
    $dlg.Description = 'Choose where the files are saved'
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

    $kinds = @()
    if ($chkMp3.Checked) { $kinds += 'MP3' }
    if ($chkMp4.Checked) { $kinds += 'MP4' }
    if ($kinds.Count -eq 0) {
        [void][System.Windows.Forms.MessageBox]::Show('Tick MP3, MP4, or both.', 'Nothing to download')
        return
    }
    $height = 0
    if ([string]$cmbQuality.SelectedItem -match '^(\d+)p$') { $height = [int]$Matches[1] }

    foreach ($u in $urls) {
        foreach ($k in $kinds) { Add-QueueItem $u $name $folder $k $height }
    }
    $txtUrl.Clear(); $txtName.Clear()
    Save-Queue
    Save-Settings
})

$btnPause.Add_Click({ Toggle-Pause })
$btnPauseFor.Add_Click({
    $secs = Get-PauseSeconds
    if ($secs -le 0) {
        [void][System.Windows.Forms.MessageBox]::Show('Enter how long to pause, for example 2 Hours + 30 Minutes.', 'Pause for how long?')
        return
    }
    Set-Pause ((Get-Date).AddSeconds($secs))
})
$btnPauseUntil.Add_Click({
    $t = $dtpUntil.Value
    if ($t -le (Get-Date)) {
        [void][System.Windows.Forms.MessageBox]::Show('Pick a date and time in the future.', 'Pause until when?')
        return
    }
    Set-Pause $t
})
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

$btnPhone.Add_Click({
    $ps1 = Join-Path $AppDir 'PhoneServer.ps1'
    if (-not (Test-Path $ps1)) {
        [void][System.Windows.Forms.MessageBox]::Show('PhoneServer.ps1 was not found next to the app. Reinstall the app and keep "Phone and tablet access" ticked.', 'Phone access')
        return
    }
    $psExe = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    Start-Process -FilePath $psExe -ArgumentList ('-NoProfile -ExecutionPolicy Bypass -File "' + $ps1 + '"')
    $lblStatus.Text = 'A phone-server window opened - read the address and PIN there, then enter them on your phone.'
})
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
                if ($s.Url) { Add-QueueItem ([string]$s.Url) ([string]$s.Name) ([string]$s.Folder) ([string]$s.Kind) ([int]$s.Height) }
            }
        } catch { }
    }
    # A timed pause that was still running when the app was closed.
    if ($script:Settings['PausedUntil']) {
        try {
            $t = [datetime]::Parse([string]$script:Settings['PausedUntil'], [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::RoundtripKind)
            if ($t -gt (Get-Date)) { Set-Pause $t }
        } catch { }
    }
    # YouTube changes often; refresh yt-dlp if it has not been updated for a week.
    $stale = $true
    if ($script:Settings['LastUpdate']) {
        try { $stale = ((Get-Date) - [datetime]$script:Settings['LastUpdate']).TotalDays -ge 7 } catch { }
    }
    if ($stale) { Update-YtDlp }
    $timer.Start()
    if ($StartInTray) {
        $script:TipShown = $true
        $form.Hide()
    }
})

# On small screens, make the window shorter (the list shrinks to fit).
$workArea = [System.Windows.Forms.Screen]::PrimaryScreen.WorkingArea
$maxClient = $workArea.Height - 70
if ($form.ClientSize.Height -gt $maxClient) {
    $form.ClientSize = New-Object System.Drawing.Size(850, [Math]::Max($maxClient, 500))
}

# Application.Run (not ShowDialog) so the window can be hidden while the app keeps working.
[System.Windows.Forms.Application]::Run($form)

} catch {
    [void][System.Windows.Forms.MessageBox]::Show(
        "Something went wrong:`r`n`r`n" + $_.Exception.Message + "`r`n`r`n" + $_.ScriptStackTrace,
        'YouTube Downloader')
    exit 1
}
