Unicode True
RequestExecutionLevel user
SetCompressor /SOLID lzma
SetCompressorDictSize 32
CRCCheck force
ShowInstDetails nevershow
ShowUnInstDetails nevershow

!ifndef PayloadDir
  !error "Pass /DPayloadDir=<absolute publish directory>."
!endif
!ifndef OutputPath
  !error "Pass /DOutputPath=<absolute setup executable path>."
!endif
!ifndef AppVersion
  !error "Pass /DAppVersion=<four-part app version>."
!endif
!ifndef Architecture
  !error "Pass /DArchitecture=arm64 or /DArchitecture=x64."
!endif
!ifndef UninstallInclude
  !error "Pass /DUninstallInclude=<generated payload uninstall include>."
!endif

!if "${Architecture}" != "arm64"
  !if "${Architecture}" != "x64"
    !error "Architecture must be arm64 or x64."
  !endif
!endif

!include "MUI2.nsh"
!include "WinMessages.nsh"
!include "x64.nsh"

!define PRODUCT_NAME "Snowy"
!define UNINSTALL_KEY "Software\Microsoft\Windows\CurrentVersion\Uninstall\Snowy"
!define EXPECTED_INSTALL_DIR "$LOCALAPPDATA\Programs\Snowy"
!define PROGRAMS_DIR "$LOCALAPPDATA\Programs"
!define APP_MUTEX "Local\Snowy.Windows"

Name "${PRODUCT_NAME}"
OutFile "${OutputPath}"
InstallDir "${EXPECTED_INSTALL_DIR}"
BrandingText "Snowy"
AutoCloseWindow false
XPStyle on

VIProductVersion "${AppVersion}"
VIAddVersionKey /LANG=1033 "ProductName" "Snowy"
VIAddVersionKey /LANG=1033 "ProductVersion" "${AppVersion}"
VIAddVersionKey /LANG=1033 "FileVersion" "${AppVersion}"
VIAddVersionKey /LANG=1033 "FileDescription" "Snowy desktop snowfall"
VIAddVersionKey /LANG=1033 "CompanyName" "Snowy"
VIAddVersionKey /LANG=1033 "LegalCopyright" "Copyright Snowy"

!define MUI_ABORTWARNING
!define MUI_ICON "${__FILEDIR__}\..\Snowy.Windows\Assets\Snowy.ico"
!define MUI_UNICON "${__FILEDIR__}\..\Snowy.Windows\Assets\Snowy.ico"
!define MUI_WELCOMEFINISHPAGE_BITMAP "${__FILEDIR__}\SetupArtwork.bmp"
!define MUI_WELCOMEPAGE_TITLE "A little snow for your desktop"
!define MUI_WELCOMEPAGE_TEXT "Snowy is ready to install for this Windows account. It will be available from the Start menu."
!define MUI_FINISHPAGE_TITLE "Snowy is ready"
!define MUI_FINISHPAGE_TEXT "Snowy has been installed for this account."
!define MUI_FINISHPAGE_RUN "$INSTDIR\Snowy.exe"
!define MUI_FINISHPAGE_RUN_TEXT "Open Snowy"
!define MUI_PAGE_CUSTOMFUNCTION_SHOW WelcomePageShow
!insertmacro MUI_PAGE_WELCOME
!insertmacro MUI_PAGE_INSTFILES
!insertmacro MUI_PAGE_FINISH
!insertmacro MUI_UNPAGE_CONFIRM
!insertmacro MUI_UNPAGE_INSTFILES
!insertmacro MUI_LANGUAGE "English"

Function WelcomePageShow
  ; The welcome page is the installer's only decision page: its primary action
  ; starts the installation immediately.
  GetDlgItem $0 $HWNDPARENT 1
  SendMessage $0 ${WM_SETTEXT} 0 "STR:Install"
FunctionEnd

Function CheckArchitectureAndWindows
  !if "${Architecture}" == "arm64"
    ${IfNot} ${IsNativeARM64}
      Goto architectureWrong
    ${EndIf}
  !else
    ${IfNot} ${IsNativeAMD64}
      Goto architectureWrong
    ${EndIf}
  !endif
  Goto architectureOK

architectureWrong:
  IfSilent architectureSilent architectureInteractive
architectureSilent:
  SetErrorLevel 2
  Abort
architectureInteractive:
  MessageBox MB_OK|MB_ICONSTOP "This installer is for ${Architecture} PCs. Download the setup that matches this device's processor."
  SetErrorLevel 2
  Abort

architectureOK:
  ReadRegStr $0 HKLM "SOFTWARE\Microsoft\Windows NT\CurrentVersion" "CurrentBuildNumber"
  IntCmp $0 22000 windowsSupported windowsTooOld windowsSupported
  Return

windowsTooOld:
  IfSilent windowsSilent windowsInteractive
windowsSilent:
  SetErrorLevel 2
  Abort
windowsInteractive:
  MessageBox MB_OK|MB_ICONSTOP "Snowy requires Windows 11 (build 22000 or later)."
  SetErrorLevel 2
  Abort
windowsSupported:
  Return
FunctionEnd

Function CheckInstallPathSafety
  StrCpy $R8 "${PROGRAMS_DIR}"
  Call CheckPathNotReparse
  StrCpy $R8 "$INSTDIR"
  Call CheckPathNotReparse
FunctionEnd

Function CheckPathNotReparse
  ; Do not follow a junction or symlink when installing over or removing Snowy.
  System::Call 'kernel32::GetFileAttributesW(w "$R8") i.r7'
  StrCmp $7 -1 pathIsSafe
  IntOp $6 $7 & 0x0400
  StrCmp $6 0 pathIsSafe pathIsReparse

pathIsReparse:
  IfSilent reparseSilent reparseInteractive
reparseSilent:
  SetErrorLevel 2
  Abort
reparseInteractive:
  MessageBox MB_OK|MB_ICONSTOP "Snowy's install folder or its Programs parent is a symbolic link or junction. No files were changed."
  SetErrorLevel 2
  Abort

pathIsSafe:
FunctionEnd

Function CheckInstallLocation
  StrCmp $INSTDIR "${EXPECTED_INSTALL_DIR}" installLocationOK installLocationWrong

installLocationWrong:
  IfSilent locationSilent locationInteractive
locationSilent:
  SetErrorLevel 2
  Abort
locationInteractive:
  MessageBox MB_OK|MB_ICONSTOP "Snowy installs in the current account's Programs folder. Custom install locations are not supported."
  SetErrorLevel 2
  Abort

installLocationOK:
FunctionEnd

Function CheckSnowyRunning
  ; The app owns this named mutex for its entire lifetime. SYNCHRONIZE access
  ; lets setup detect it without enumerating or inspecting other processes.
  System::Call 'kernel32::OpenMutexW(i 0x00100000, i 0, w "${APP_MUTEX}") p.r0'
  StrCmp $0 0 snowyNotRunning
  System::Call 'kernel32::CloseHandle(p r0)'
  Push 1
  Return

snowyNotRunning:
  Push 0
FunctionEnd

Function .onInit
  SetShellVarContext current
  Call CheckArchitectureAndWindows
  Call CheckInstallLocation
  Call CheckInstallPathSafety
  Call CheckSnowyRunning
  Pop $0
  StrCmp $0 0 appNotRunning appRunning

appRunning:
  IfSilent appRunningSilent appRunningInteractive
appRunningSilent:
  SetErrorLevel 2
  Abort
appRunningInteractive:
  MessageBox MB_OK|MB_ICONEXCLAMATION "Quit Snowy from the system tray before installing or updating it. Your settings and scenes will be kept."
  SetErrorLevel 2
  Abort
appNotRunning:
FunctionEnd

Section "Install Snowy"
  Call CheckInstallLocation
  Call CheckInstallPathSafety
  Call CheckSnowyRunning
  Pop $0
  StrCmp $0 0 installAppNotRunning installAppRunning

installAppRunning:
  IfSilent installRunningSilent installRunningInteractive
installRunningSilent:
  SetErrorLevel 2
  Abort
installRunningInteractive:
  MessageBox MB_OK|MB_ICONEXCLAMATION "Quit Snowy from the system tray before installing or updating it."
  SetErrorLevel 2
  Abort

installAppNotRunning:
  SetShellVarContext current
  SetOutPath "$INSTDIR"
  File /r "${PayloadDir}\*"
  WriteUninstaller "$INSTDIR\Uninstall.exe"

  CreateShortcut "$SMPROGRAMS\Snowy.lnk" "$INSTDIR\Snowy.exe"

  WriteRegStr HKCU "${UNINSTALL_KEY}" "DisplayName" "Snowy"
  WriteRegStr HKCU "${UNINSTALL_KEY}" "DisplayVersion" "${AppVersion}"
  WriteRegStr HKCU "${UNINSTALL_KEY}" "Publisher" "Snowy"
  WriteRegStr HKCU "${UNINSTALL_KEY}" "InstallLocation" "$INSTDIR"
  WriteRegStr HKCU "${UNINSTALL_KEY}" "DisplayIcon" "$INSTDIR\Snowy.exe,0"
  WriteRegStr HKCU "${UNINSTALL_KEY}" "UninstallString" '"$INSTDIR\Uninstall.exe"'
  WriteRegStr HKCU "${UNINSTALL_KEY}" "QuietUninstallString" '"$INSTDIR\Uninstall.exe" /S'
  WriteRegDWORD HKCU "${UNINSTALL_KEY}" "NoModify" 1
  WriteRegDWORD HKCU "${UNINSTALL_KEY}" "NoRepair" 1
SectionEnd

Section "Uninstall"
  Call un.CheckInstallLocation
  Call un.CheckInstallPathSafety
  Call un.CheckSnowyRunning
  Pop $0
  StrCmp $0 0 uninstallAppNotRunning uninstallAppRunning

uninstallAppRunning:
  IfSilent uninstallRunningSilent uninstallRunningInteractive
uninstallRunningSilent:
  SetErrorLevel 2
  Abort
uninstallRunningInteractive:
  MessageBox MB_OK|MB_ICONEXCLAMATION "Quit Snowy from the system tray before uninstalling it."
  SetErrorLevel 2
  Abort

uninstallAppNotRunning:
  SetShellVarContext current
  !include "${UninstallInclude}"
  Delete "$INSTDIR\Uninstall.exe"
  RMDir "$INSTDIR"

  Delete "$SMPROGRAMS\Snowy.lnk"
  DeleteRegKey HKCU "${UNINSTALL_KEY}"
SectionEnd

Function un.onInit
  SetShellVarContext current
  Call un.CheckInstallLocation
  Call un.CheckInstallPathSafety
  Call un.CheckSnowyRunning
  Pop $0
  StrCmp $0 0 unAppNotRunning unAppRunning

unAppRunning:
  IfSilent unInitRunningSilent unInitRunningInteractive
unInitRunningSilent:
  SetErrorLevel 2
  Abort
unInitRunningInteractive:
  MessageBox MB_OK|MB_ICONEXCLAMATION "Quit Snowy from the system tray before uninstalling it."
  SetErrorLevel 2
  Abort
unAppNotRunning:
FunctionEnd

Function un.CheckInstallLocation
  StrCmp $INSTDIR "${EXPECTED_INSTALL_DIR}" unInstallLocationOK unInstallLocationWrong

unInstallLocationWrong:
  IfSilent unLocationSilent unLocationInteractive
unLocationSilent:
  SetErrorLevel 2
  Abort
unLocationInteractive:
  MessageBox MB_OK|MB_ICONSTOP "Snowy can only remove files from its current-account Programs folder. No files were changed."
  SetErrorLevel 2
  Abort

unInstallLocationOK:
FunctionEnd

Function un.CheckInstallPathSafety
  StrCpy $R8 "${PROGRAMS_DIR}"
  Call un.CheckPathNotReparse
  StrCpy $R8 "$INSTDIR"
  Call un.CheckPathNotReparse
FunctionEnd

Function un.CheckPathNotReparse
  System::Call 'kernel32::GetFileAttributesW(w "$R8") i.r7'
  StrCmp $7 -1 unPathIsSafe
  IntOp $6 $7 & 0x0400
  StrCmp $6 0 unPathIsSafe unPathIsReparse

unPathIsReparse:
  IfSilent unReparseSilent unReparseInteractive
unReparseSilent:
  SetErrorLevel 2
  Abort
unReparseInteractive:
  MessageBox MB_OK|MB_ICONSTOP "Snowy's install folder or its Programs parent is a symbolic link or junction. No files were changed."
  SetErrorLevel 2
  Abort

unPathIsSafe:
FunctionEnd

Function un.CheckSnowyRunning
  System::Call 'kernel32::OpenMutexW(i 0x00100000, i 0, w "${APP_MUTEX}") p.r0'
  StrCmp $0 0 unSnowyNotRunning
  System::Call 'kernel32::CloseHandle(p r0)'
  Push 1
  Return

unSnowyNotRunning:
  Push 0
FunctionEnd
