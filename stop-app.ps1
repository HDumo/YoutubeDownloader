# Used by the installer/uninstaller: closes a running copy of the app, the phone server and their helpers.
$me = $PID
Get-CimInstance Win32_Process -Filter "Name='powershell.exe' OR Name='python.exe'" -ErrorAction SilentlyContinue |
    Where-Object { $_.ProcessId -ne $me -and ($_.CommandLine -like '*YouTubeMP3.ps1*' -or $_.CommandLine -like '*PhoneServer.ps1*' -or $_.CommandLine -like '*ytdl_server.py*') } |
    ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
Get-Process yt-dlp, ffmpeg -ErrorAction SilentlyContinue |
    Where-Object { $_.Path -like '*YouTubeDownloader*' } |
    ForEach-Object { Stop-Process -Id $_.Id -Force -ErrorAction SilentlyContinue }
exit 0
