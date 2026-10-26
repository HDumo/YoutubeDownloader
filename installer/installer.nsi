; YouTube Downloader - Windows installer (NSIS 3, builds on Linux or Windows)
;   makensis installer/installer.nsi        ->  dist/YouTubeDownloader-Setup.exe
Unicode True
!define APPNAME   "YouTube Downloader"
!define APPKEY    "YouTubeDownloader"
!define VERSION   "2.0.0"
!define PUBLISHER "HDumo"
!define PSEXE     "$SYSDIR\WindowsPowerShell\v1.0\powershell.exe"
!define PSARGS    '-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -STA -File "$INSTDIR\YouTubeMP3.ps1"'

Name "${APPNAME}"
OutFile "..\dist\YouTubeDownloader-Setup.exe"
InstallDir "$LOCALAPPDATA\Programs\${APPKEY}"
InstallDirRegKey HKCU "Software\${APPKEY}" "InstallDir"
RequestExecutionLevel user            ; no administrator rights needed
SetCompressor /SOLID lzma
BrandingText "${APPNAME} ${VERSION}"

VIProductVersion "${VERSION}.0"
VIAddVersionKey "ProductName"     "${APPNAME}"
VIAddVersionKey "FileDescription" "${APPNAME} installer"
VIAddVersionKey "CompanyName"     "${PUBLISHER}"
VIAddVersionKey "FileVersion"     "${VERSION}"
VIAddVersionKey "LegalCopyright"  "Free to use"

!include "MUI2.nsh"
!include "LogicLib.nsh"

!define MUI_ICON   "..\assets\app.ico"
!define MUI_UNICON "..\assets\app.ico"
!define MUI_ABORTWARNING
!define MUI_HEADERIMAGE
!define MUI_HEADERIMAGE_BITMAP "wizard-header.bmp"
!define MUI_WELCOMEFINISHPAGE_BITMAP "wizard-side.bmp"
!define MUI_UNWELCOMEFINISHPAGE_BITMAP "wizard-side.bmp"

!define MUI_WELCOMEPAGE_TITLE "Welcome to ${APPNAME}"
!define MUI_WELCOMEPAGE_TEXT "This installs ${APPNAME} for your Windows account.$\r$\n$\r$\nPaste YouTube links, pick MP3 and/or MP4, and let the queue do the work - even in the background. Includes phone and tablet access for Android and iPhone.$\r$\n$\r$\nNo administrator rights are needed. The first time you start it, it downloads two free helper programs (yt-dlp and ffmpeg, about 150 MB)."
!define MUI_COMPONENTSPAGE_SMALLDESC
!define MUI_FINISHPAGE_TITLE "${APPNAME} is installed"
!define MUI_FINISHPAGE_RUN
!define MUI_FINISHPAGE_RUN_FUNCTION LaunchApp
!define MUI_FINISHPAGE_RUN_TEXT "Start ${APPNAME} now"

!insertmacro MUI_PAGE_WELCOME
!insertmacro MUI_PAGE_COMPONENTS
!insertmacro MUI_PAGE_DIRECTORY
!insertmacro MUI_PAGE_INSTFILES
!insertmacro MUI_PAGE_FINISH

!insertmacro MUI_UNPAGE_CONFIRM
!insertmacro MUI_UNPAGE_INSTFILES

!insertmacro MUI_LANGUAGE "English"

Function LaunchApp
  SetOutPath "$INSTDIR"
  Exec '"${PSEXE}" ${PSARGS}'
FunctionEnd

; ------------------------------------------------------------------ install ---
Section "${APPNAME} (required)" SecMain
  SectionIn RO
  SetShellVarContext current

  ; If an older copy is running (maybe hidden in the tray), close it first.
  IfFileExists "$INSTDIR\stop-app.ps1" 0 +2
    nsExec::Exec '"${PSEXE}" -NoProfile -ExecutionPolicy Bypass -File "$INSTDIR\stop-app.ps1"'

  SetOutPath "$INSTDIR"
  File "..\YouTubeMP3.ps1"
  File "..\stop-app.ps1"
  File "..\assets\app.ico"
  File "..\README.md"
  ; settings.json, queue.json and the tools folder are left alone, so updating keeps your queue.

  WriteUninstaller "$INSTDIR\Uninstall.exe"
  WriteRegStr HKCU "Software\${APPKEY}" "InstallDir" "$INSTDIR"

  ; Entry in "Apps & features"
  WriteRegStr   HKCU "Software\Microsoft\Windows\CurrentVersion\Uninstall\${APPKEY}" "DisplayName"     "${APPNAME}"
  WriteRegStr   HKCU "Software\Microsoft\Windows\CurrentVersion\Uninstall\${APPKEY}" "DisplayVersion"  "${VERSION}"
  WriteRegStr   HKCU "Software\Microsoft\Windows\CurrentVersion\Uninstall\${APPKEY}" "Publisher"       "${PUBLISHER}"
  WriteRegStr   HKCU "Software\Microsoft\Windows\CurrentVersion\Uninstall\${APPKEY}" "InstallLocation" "$INSTDIR"
  WriteRegStr   HKCU "Software\Microsoft\Windows\CurrentVersion\Uninstall\${APPKEY}" "DisplayIcon"     "$INSTDIR\app.ico"
  WriteRegStr   HKCU "Software\Microsoft\Windows\CurrentVersion\Uninstall\${APPKEY}" "UninstallString" '"$INSTDIR\Uninstall.exe"'
  WriteRegDWORD HKCU "Software\Microsoft\Windows\CurrentVersion\Uninstall\${APPKEY}" "NoModify" 1
  WriteRegDWORD HKCU "Software\Microsoft\Windows\CurrentVersion\Uninstall\${APPKEY}" "NoRepair" 1
SectionEnd

Section "Phone and tablet access (Android / iPhone)" SecPhone
  SetShellVarContext current
  SetOutPath "$INSTDIR"
  File "..\PhoneServer.ps1"
  File "..\Start Phone Server.bat"
  SetOutPath "$INSTDIR\mobile\server"
  File "..\mobile\server\ytdl_server.py"
  SetOutPath "$INSTDIR\mobile\server\web"
  File "..\mobile\server\web\*.*"
  SetOutPath "$INSTDIR"
  CreateDirectory "$SMPROGRAMS\${APPNAME}"
  CreateShortCut "$SMPROGRAMS\${APPNAME}\${APPNAME} - Phone Server.lnk" "${PSEXE}" '-NoProfile -ExecutionPolicy Bypass -File "$INSTDIR\PhoneServer.ps1"' "$INSTDIR\app.ico" 0 SW_SHOWNORMAL "" "Use this PC as the server for your Android phone or iPhone"
SectionEnd

Section "Desktop shortcut" SecDesktop
  SetShellVarContext current
  SetOutPath "$INSTDIR"
  CreateShortCut "$DESKTOP\${APPNAME}.lnk" "${PSEXE}" '${PSARGS}' "$INSTDIR\app.ico" 0 SW_SHOWMINIMIZED "" "Download YouTube videos as MP3 or MP4"
SectionEnd

Section "Start Menu shortcut" SecStart
  SetShellVarContext current
  SetOutPath "$INSTDIR"
  CreateDirectory "$SMPROGRAMS\${APPNAME}"
  CreateShortCut "$SMPROGRAMS\${APPNAME}\${APPNAME}.lnk" "${PSEXE}" '${PSARGS}' "$INSTDIR\app.ico" 0 SW_SHOWMINIMIZED "" "Download YouTube videos as MP3 or MP4"
  CreateShortCut "$SMPROGRAMS\${APPNAME}\Uninstall ${APPNAME}.lnk" "$INSTDIR\Uninstall.exe"
SectionEnd

Section /o "Start with Windows (quietly, in the tray)" SecAutostart
  WriteRegStr HKCU "Software\Microsoft\Windows\CurrentVersion\Run" "${APPKEY}" '"${PSEXE}" ${PSARGS} -StartInTray'
SectionEnd

!insertmacro MUI_FUNCTION_DESCRIPTION_BEGIN
  !insertmacro MUI_DESCRIPTION_TEXT ${SecMain}      "The program itself."
  !insertmacro MUI_DESCRIPTION_TEXT ${SecPhone}     "Lets your Android phone, iPhone or iPad queue downloads on this PC (adds a Phone Server item to the Start menu)."
  !insertmacro MUI_DESCRIPTION_TEXT ${SecDesktop}   "Puts a ${APPNAME} icon on your desktop."
  !insertmacro MUI_DESCRIPTION_TEXT ${SecStart}     "Adds ${APPNAME} to the Start menu."
  !insertmacro MUI_DESCRIPTION_TEXT ${SecAutostart} "Starts ${APPNAME} hidden in the system tray whenever you sign in to Windows, so queued downloads keep going."
!insertmacro MUI_FUNCTION_DESCRIPTION_END

; ----------------------------------------------------------------- uninstall ---
Section "Uninstall"
  SetShellVarContext current
  IfFileExists "$INSTDIR\stop-app.ps1" 0 +2
    nsExec::Exec '"${PSEXE}" -NoProfile -ExecutionPolicy Bypass -File "$INSTDIR\stop-app.ps1"'

  Delete "$DESKTOP\${APPNAME}.lnk"
  RMDir /r "$SMPROGRAMS\${APPNAME}"
  DeleteRegValue HKCU "Software\Microsoft\Windows\CurrentVersion\Run" "${APPKEY}"
  DeleteRegKey HKCU "Software\Microsoft\Windows\CurrentVersion\Uninstall\${APPKEY}"
  DeleteRegKey HKCU "Software\${APPKEY}"
  RMDir /r "$INSTDIR"      ; includes the downloaded helper programs, settings and queue
SectionEnd
