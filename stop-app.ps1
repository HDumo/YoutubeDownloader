# Used by the installer/uninstaller: closes a running copy of the app (and its helper programs).
$me = $PID
Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" -ErrorAction SilentlyContinue |
    Where-Object { $_.ProcessId -ne $me -and $_.CommandLine -like '*YouTubeMP3.ps1*' } |
    ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
Get-Process yt-dlp, ffmpeg -ErrorAction SilentlyContinue |
    Where-Object { $_.Path -like '*YouTubeDownloader*' } |
    ForEach-Object { Stop-Process -Id $_.Id -Force -ErrorAction SilentlyContinue }
exit 0
