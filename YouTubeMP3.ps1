<#
  YouTube MP3 Downloader  (Windows, nothing to install)

  Start it with "Start YouTube MP3 Downloader.bat". On the first run it
  downloads two free helper programs into the "tools" folder next to this file:
    - yt-dlp.exe  (does the YouTube download)
    - ffmpeg.exe  (converts the audio to MP3)
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

# -------------------------------------------------------------- settings ----
$script:Settings = [ordered]@{
    Folder      = [Environment]::GetFolderPath('MyMusic')
    MaxPerHour  = 0
    LastUpdate  = ''
}
if (-not $script:Settings.Folder) { $script:Settings.Folder = [Environment]::GetFolderPath('Desktop') }

if (Test-Path $SettingsFile) {
    try {
        $saved = Get-Content $SettingsFile -Raw | ConvertFrom-Json
        if ($saved.Folder)     { $script:Settings.Folder = [string]$saved.Folder }
        if ($saved.MaxPerHour) { $script:Settings.MaxPerHour = [int]$saved.MaxPerHour }
        if ($saved.LastUpdate) { $script:Settings.LastUpdate = [string]$saved.LastUpdate }
    } catch { }
}

function Save-Settings {
    try { $script:Settings | ConvertTo-Json | Set-Content -Path $SettingsFile -Encoding UTF8 } catch { }
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

# ---------------------------------------------------------------- queue -----
$script:Items      = New-Object System.Collections.ArrayList   # all queue items
$script:Current    = $null                                      # item being downloaded
$script:Proc       = $null
$script:OutTask    = $null
$script:ErrTask    = $null
$script:StartTimes = New-Object System.Collections.ArrayList   # for the per-hour limit
$script:Paused     = $false
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
        Text = 'Queued'; Status = 'Queued'; Row = $null; LastError = $null
    }
    $lvi = New-Object System.Windows.Forms.ListViewItem([string]$item.Id)
    [void]$lvi.SubItems.Add($url)
    [void]$lvi.SubItems.Add($item.Display)
    [void]$lvi.SubItems.Add($item.Text)
    $lvi.Tag = $item
    $item.Row = $lvi
    [void]$script:Items.Add($item)
    [void]$list.Items.Add($lvi)
}

function Set-ItemState($item, [string]$status, [string]$text) {
    $item.Status = $status
    $item.Text = $text
    Update-Row $item
}

function Get-HourSlots {
    $cutoff = (Get-Date).AddHours(-1)
    for ($i = $script:StartTimes.Count - 1; $i -ge 0; $i--) {
        if ($script:StartTimes[$i] -lt $cutoff) { $script:StartTimes.RemoveAt($i) }
    }
}

function Start-Download($item) {
    $folder = $item.Folder
    if (-not (Test-Path $folder)) { New-Item -ItemType Directory -Path $folder -Force | Out-Null }

    if ($item.Name) {
        $leaf = ($item.Name -replace '%', '%%') + '.%(ext)s'
    } else {
        $leaf = '%(title)s.%(ext)s'
    }
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

    try {
        $script:Proc = [System.Diagnostics.Process]::Start($psi)
    } catch {
        Set-ItemState $item 'Failed' ('Failed: could not start yt-dlp - ' + $_.Exception.Message)
        Save-Queue
        return
    }
    $script:OutTask = $script:Proc.StandardOutput.ReadLineAsync()
    $script:ErrTask = $script:Proc.StandardError.ReadLineAsync()
    $script:Current = $item
    $item.LastError = $null
    [void]$script:StartTimes.Add((Get-Date))
    Set-ItemState $item 'Downloading' 'Starting...'
    Save-Queue
}

function Handle-Line($line, $item, [bool]$isErr) {
    if (-not $line) { return }
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

    if ($script:Proc.HasExited -and -not $script:OutTask -and -not $script:ErrTask) {
        $code = $script:Proc.ExitCode
        $script:Proc.Dispose()
        $script:Proc = $null
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
        Save-Queue
    }
}

function Tick {
    if ($script:Current) {
        Pump-Process
        $lblStatus.Text = 'Downloading...'
        return
    }

    $next = $script:Items | Where-Object { $_.Status -eq 'Queued' } | Select-Object -First 1
    if (-not $next) { $lblStatus.Text = 'Idle - add a link above.'; return }
    if ($script:Paused) { $lblStatus.Text = 'Paused.'; return }

    $limit = [int]$numLimit.Value
    if ($limit -gt 0) {
        Get-HourSlots
        if ($script:StartTimes.Count -ge $limit) {
            $resume = ($script:StartTimes | Sort-Object | Select-Object -First 1).AddHours(1)
            $lblStatus.Text = 'Hourly limit reached - next download at ' + $resume.ToString('h:mm tt')
            return
        }
    }
    Start-Download $next
}

# --------------------------------------------------------------- the GUI ----
$form = New-Object System.Windows.Forms.Form
$form.Text = 'YouTube MP3 Downloader'
$form.Size = New-Object System.Drawing.Size(860, 620)
$form.MinimumSize = New-Object System.Drawing.Size(720, 520)
$form.StartPosition = 'CenterScreen'
$form.Font = New-Object System.Drawing.Font('Segoe UI', 9.5)

function New-Label($text, $x, $y) {
    $l = New-Object System.Windows.Forms.Label
    $l.Text = $text; $l.Location = New-Object System.Drawing.Point($x, $y); $l.AutoSize = $true
    $form.Controls.Add($l); return $l
}

[void](New-Label 'Paste YouTube link(s) - one per line:' 14 10)
$txtUrl = New-Object System.Windows.Forms.TextBox
$txtUrl.Multiline = $true; $txtUrl.ScrollBars = 'Vertical'
$txtUrl.Location = New-Object System.Drawing.Point(14, 32)
$txtUrl.Size = New-Object System.Drawing.Size(690, 62)
$txtUrl.Anchor = 'Top,Left,Right'
$form.Controls.Add($txtUrl)

$btnAdd = New-Object System.Windows.Forms.Button
$btnAdd.Text = 'Add to queue'
$btnAdd.Location = New-Object System.Drawing.Point(714, 32)
$btnAdd.Size = New-Object System.Drawing.Size(120, 62)
$btnAdd.Anchor = 'Top,Right'
$form.Controls.Add($btnAdd)

[void](New-Label 'Save as (optional - leave empty to keep the original video title):' 14 102)
$txtName = New-Object System.Windows.Forms.TextBox
$txtName.Location = New-Object System.Drawing.Point(14, 124)
$txtName.Size = New-Object System.Drawing.Size(820, 26)
$txtName.Anchor = 'Top,Left,Right'
$form.Controls.Add($txtName)

[void](New-Label 'Save to folder:' 14 158)
$txtFolder = New-Object System.Windows.Forms.TextBox
$txtFolder.Location = New-Object System.Drawing.Point(14, 180)
$txtFolder.Size = New-Object System.Drawing.Size(600, 26)
$txtFolder.Anchor = 'Top,Left,Right'
$txtFolder.Text = $script:Settings.Folder
$form.Controls.Add($txtFolder)

$btnBrowse = New-Object System.Windows.Forms.Button
$btnBrowse.Text = 'Browse...'
$btnBrowse.Location = New-Object System.Drawing.Point(624, 178)
$btnBrowse.Size = New-Object System.Drawing.Size(100, 28)
$btnBrowse.Anchor = 'Top,Right'
$form.Controls.Add($btnBrowse)

$btnOpen = New-Object System.Windows.Forms.Button
$btnOpen.Text = 'Open folder'
$btnOpen.Location = New-Object System.Drawing.Point(734, 178)
$btnOpen.Size = New-Object System.Drawing.Size(100, 28)
$btnOpen.Anchor = 'Top,Right'
$form.Controls.Add($btnOpen)

[void](New-Label 'Max downloads per hour (0 = no limit):' 14 220)
$numLimit = New-Object System.Windows.Forms.NumericUpDown
$numLimit.Minimum = 0; $numLimit.Maximum = 500
$numLimit.Value = [Math]::Min([Math]::Max($script:Settings.MaxPerHour, 0), 500)
$numLimit.Location = New-Object System.Drawing.Point(290, 217)
$numLimit.Size = New-Object System.Drawing.Size(70, 26)
$form.Controls.Add($numLimit)

$list = New-Object System.Windows.Forms.ListView
$list.View = 'Details'; $list.FullRowSelect = $true; $list.GridLines = $true
$list.MultiSelect = $true; $list.HideSelection = $false
$list.Location = New-Object System.Drawing.Point(14, 252)
$list.Size = New-Object System.Drawing.Size(820, 260)
$list.Anchor = 'Top,Bottom,Left,Right'
[void]$list.Columns.Add('#', 36)
[void]$list.Columns.Add('Link', 270)
[void]$list.Columns.Add('Save as', 210)
[void]$list.Columns.Add('Status', 280)
$form.Controls.Add($list)

function New-BottomButton($text, $x, $w) {
    $b = New-Object System.Windows.Forms.Button
    $b.Text = $text
    $b.Location = New-Object System.Drawing.Point($x, 522)
    $b.Size = New-Object System.Drawing.Size($w, 30)
    $b.Anchor = 'Bottom,Left'
    $form.Controls.Add($b); return $b
}
$btnPause  = New-BottomButton 'Pause' 14 90
$btnRemove = New-BottomButton 'Remove / cancel selected' 112 190
$btnClear  = New-BottomButton 'Clear finished' 310 120
$btnUpdate = New-BottomButton 'Update yt-dlp' 438 120

$lblStatus = New-Object System.Windows.Forms.Label
$lblStatus.AutoSize = $false
$lblStatus.Location = New-Object System.Drawing.Point(14, 558)
$lblStatus.Size = New-Object System.Drawing.Size(820, 24)
$lblStatus.Anchor = 'Bottom,Left,Right'
$lblStatus.Text = 'Idle - add a link above.'
$form.Controls.Add($lblStatus)

# ------------------------------------------------------------- behaviour ----
$btnBrowse.Add_Click({
    $dlg = New-Object System.Windows.Forms.FolderBrowserDialog
    $dlg.Description = 'Choose where the MP3 files are saved'
    if (Test-Path $txtFolder.Text) { $dlg.SelectedPath = $txtFolder.Text }
    if ($dlg.ShowDialog() -eq 'OK') { $txtFolder.Text = $dlg.SelectedPath }
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
})

$btnPause.Add_Click({
    $script:Paused = -not $script:Paused
    $btnPause.Text = $(if ($script:Paused) { 'Resume' } else { 'Pause' })
})

$btnRemove.Add_Click({
    foreach ($lvi in @($list.SelectedItems)) {
        $item = $lvi.Tag
        if ($item -eq $script:Current) {
            Set-ItemState $item 'Cancelled' 'Cancelled'
            try { $script:Proc.Kill() } catch { }
        } elseif ($item.Status -eq 'Queued') {
            [void]$script:Items.Remove($item)
            $list.Items.Remove($lvi)
        }
    }
    Save-Queue
})

$btnClear.Add_Click({
    foreach ($lvi in @($list.Items)) {
        $s = $lvi.Tag.Status
        if ($s -eq 'Done' -or $s -eq 'Failed' -or $s -eq 'Cancelled') {
            [void]$script:Items.Remove($lvi.Tag)
            $list.Items.Remove($lvi)
        }
    }
})

function Update-YtDlp {
    $lblStatus.Text = 'Updating yt-dlp...'
    $form.Refresh()
    try {
        $p = Start-Process -FilePath $YtDlp -ArgumentList '-U' -WindowStyle Hidden -Wait -PassThru
        if ($p.ExitCode -eq 0) {
            $script:Settings.LastUpdate = (Get-Date).ToString('yyyy-MM-dd')
            Save-Settings
        }
        $lblStatus.Text = $(if ($p.ExitCode -eq 0) { 'yt-dlp is up to date.' } else { 'Update finished with a warning (are you online?).' })
    } catch {
        $lblStatus.Text = 'Could not update yt-dlp: ' + $_.Exception.Message
    }
}
$btnUpdate.Add_Click({ if (-not $script:Current) { Update-YtDlp } else { $lblStatus.Text = 'Wait for the current download to finish first.' } })

$timer = New-Object System.Windows.Forms.Timer
$timer.Interval = 500
$timer.Add_Tick({
    try { Tick } catch { $lblStatus.Text = 'Error: ' + $_.Exception.Message }
})

$form.Add_FormClosing({
    if ($script:Current) {
        $answer = [System.Windows.Forms.MessageBox]::Show(
            'A download is still running. Close anyway? It will be stopped and put back in the queue for next time.',
            'Still downloading', 'YesNo')
        if ($answer -ne 'Yes') { $_.Cancel = $true; return }
        try { $script:Proc.Kill() } catch { }
    }
    $script:Settings.Folder = $txtFolder.Text.Trim()
    $script:Settings.MaxPerHour = [int]$numLimit.Value
    Save-Settings
    Save-Queue
})

$form.Add_Shown({
    # Restore links that were still waiting when the app was last closed.
    if (Test-Path $QueueFile) {
        try {
            $saved = Get-Content $QueueFile -Raw | ConvertFrom-Json
            foreach ($s in @($saved)) {
                if ($s.Url) { Add-QueueItem ([string]$s.Url) ([string]$s.Name) ([string]$s.Folder) }
            }
        } catch { }
    }
    # YouTube changes often; refresh yt-dlp if it has not been updated for a week.
    $stale = $true
    if ($script:Settings.LastUpdate) {
        try { $stale = ((Get-Date) - [datetime]$script:Settings.LastUpdate).TotalDays -ge 7 } catch { }
    }
    if ($stale) { Update-YtDlp }
    $timer.Start()
})

[void]$form.ShowDialog()

} catch {
    [void][System.Windows.Forms.MessageBox]::Show(
        "Something went wrong:`r`n`r`n" + $_.Exception.Message + "`r`n`r`n" + $_.ScriptStackTrace,
        'YouTube MP3 Downloader')
    exit 1
}
