<#
  YouTube Downloader - phone / tablet access (Windows)

  Starts the phone-edition server on this PC so an Android phone, iPhone or iPad on the same Wi-Fi
  can queue downloads from its browser (or the Android app). Files are saved on this PC.

  Nothing to install: the first start downloads a small private copy of Python (about 10 MB) into
  the "tools" folder, plus the same yt-dlp/ffmpeg helpers the desktop app uses.
#>
param(
    [int]$Port = 8765,
    [string]$Out = ''
)

$ErrorActionPreference = 'Stop'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
$ProgressPreference = 'SilentlyContinue'

$AppDir    = $PSScriptRoot
$ToolsDir  = Join-Path $AppDir 'tools'
$YtDlp     = Join-Path $ToolsDir 'yt-dlp.exe'
$Ffmpeg    = Join-Path $ToolsDir 'ffmpeg.exe'
$PyDir     = Join-Path $ToolsDir 'python'
$PyExe     = Join-Path $PyDir 'python.exe'
$Server    = Join-Path (Join-Path (Join-Path $AppDir 'mobile') 'server') 'ytdl_server.py'
$MainApp   = Join-Path $AppDir 'YouTubeMP3.ps1'
$PythonUrl = 'https://www.python.org/ftp/python/3.12.8/python-3.12.8-embed-amd64.zip'

function Get-File($url, $dest) {
    $curl = Get-Command curl.exe -ErrorAction SilentlyContinue
    if ($curl) {
        & $curl.Source -L --fail -o $dest $url
        if ($LASTEXITCODE -ne 0) { throw "Download failed: $url" }
    } else {
        Invoke-WebRequest -Uri $url -OutFile $dest -UseBasicParsing
    }
}

try {
    Write-Host ''
    Write-Host '  YouTube Downloader - phone / tablet access' -ForegroundColor Cyan
    Write-Host ''

    if (-not (Test-Path $Server)) { throw "Server files are missing: $Server" }

    # 1) yt-dlp + ffmpeg (shared with the desktop app)
    if (-not ((Test-Path $YtDlp) -and (Test-Path $Ffmpeg))) {
        Write-Host '  Getting yt-dlp and ffmpeg (one time)...'
        $psExe = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
        if (-not (Test-Path $psExe)) { $psExe = 'powershell' }
        & $psExe -NoProfile -ExecutionPolicy Bypass -File $MainApp -SetupOnly
        if (-not ((Test-Path $YtDlp) -and (Test-Path $Ffmpeg))) { throw 'Could not download yt-dlp / ffmpeg.' }
    }

    # 2) a private copy of Python (embeddable zip - no installer, no admin rights)
    if (-not (Test-Path $PyExe)) {
        Write-Host '  Getting Python (about 10 MB, one time)...'
        $zip = Join-Path ([IO.Path]::GetTempPath()) 'ytdl-python-embed.zip'
        Get-File $PythonUrl $zip
        if (Test-Path $PyDir) { Remove-Item $PyDir -Recurse -Force }
        Expand-Archive -Path $zip -DestinationPath $PyDir -Force
        Remove-Item $zip -Force -ErrorAction SilentlyContinue
        if (-not (Test-Path $PyExe)) { throw 'python.exe was not found inside the download.' }
    }

    # 3) where to save: same folder as the desktop app uses, unless -Out is given
    if (-not $Out) {
        $settings = Join-Path $AppDir 'settings.json'
        if (Test-Path $settings) {
            try { $Out = [string](Get-Content $settings -Raw | ConvertFrom-Json).Folder } catch { }
        }
    }
    if (-not $Out) {
        $home = if ($env:USERPROFILE) { $env:USERPROFILE } else { [Environment]::GetFolderPath('UserProfile') }
        $Out = Join-Path (Join-Path $home 'Downloads') 'YouTubeDownloader'
    }

    if ($env:LOCALAPPDATA) { $dataDir = Join-Path (Join-Path $env:LOCALAPPDATA 'YouTubeDownloader') 'phone' }
    else { $dataDir = Join-Path $AppDir 'phone-data' }

    Write-Host ''
    Write-Host '  Starting the server. If Windows asks about the firewall, choose "Private networks" > Allow access.' -ForegroundColor Yellow
    Write-Host ''
    & $PyExe $Server --port $Port --out $Out --data $dataDir --yt-dlp $YtDlp --ffmpeg-location $ToolsDir
    $code = $LASTEXITCODE
    if ($code -ne 0) { throw "The server stopped with exit code $code." }
} catch {
    Write-Host ''
    Write-Host "  Problem: $($_.Exception.Message)" -ForegroundColor Red
    Write-Host '  Check your internet connection and try again.'
    Write-Host ''
    Read-Host '  Press Enter to close'
    exit 1
}
