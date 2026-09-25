; What the Windows setup does beyond Tauri's own template, through the
; hook macros that template inserts: the kendex command ships as
; bin\kendex.exe under the install directory (bundle.resources in
; release/windows.json, which also names this file), so the install puts
; that directory on the user's PATH and the uninstall takes it off again.
; The file itself is written and removed by the template's resource steps.
;
; The user's PATH, because the setup installs per user: Tauri's default
; installMode is currentUser and $INSTDIR sits under %LOCALAPPDATA%.
;
; PowerShell edits the value rather than NSIS reading it into a string:
; an NSIS string holds 1024 bytes, and a PATH longer than that read into
; one is written back cut short. The script reads the raw value with
; DoNotExpandEnvironmentNames and writes it back as REG_EXPAND_SZ, so an
; entry spelled with %VAR% survives the round trip unexpanded. The
; directory reaches the script through the environment, never spelled into
; the command line, so a quote or an apostrophe in a profile path cannot
; end the string early. Every `$$` below is a literal `$` for PowerShell.

!define KENDEX_POWERSHELL "$SYSDIR\WindowsPowerShell\v1.0\powershell.exe"
; WM_SETTINGCHANGE to every top-level window: a terminal opened after
; the install reads the new PATH without a sign-out.
!define KENDEX_HWND_BROADCAST 0xFFFF
!define KENDEX_WM_SETTINGCHANGE 0x001A

; Run one PowerShell edit of the user PATH with KENDEX_BIN_DIR naming the
; command's directory. A failed edit is said, in the log and to the
; person, and does not undo the install: the command is on disk, and the
; setup is what a person re-runs to try the PATH again.
!macro KENDEX_EDIT_USER_PATH SCRIPT WHAT
  System::Call 'kernel32::SetEnvironmentVariable(t "KENDEX_BIN_DIR", t "$INSTDIR\bin")'
  nsExec::ExecToLog `"${KENDEX_POWERSHELL}" -NoProfile -NonInteractive -ExecutionPolicy Bypass -Command "${SCRIPT}"`
  Pop $0
  ${If} $0 != 0
    DetailPrint "kendex: ${WHAT} the user PATH failed (${KENDEX_POWERSHELL} answered $0)"
    MessageBox MB_ICONEXCLAMATION|MB_OK "The kendex command's directory could not be ${WHAT} your PATH ($INSTDIR\bin). Windows PowerShell answered: $0" /SD IDOK
  ${EndIf}
  SendMessage ${KENDEX_HWND_BROADCAST} ${KENDEX_WM_SETTINGCHANGE} 0 "STR:Environment" /TIMEOUT=5000
!macroend

!define KENDEX_PATH_OPEN "$$k = [Microsoft.Win32.Registry]::CurrentUser.OpenSubKey('Environment', $$true); $$p = [string]$$k.GetValue('Path', '', [Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames); $$d = $$env:KENDEX_BIN_DIR;"

!macro NSIS_HOOK_POSTINSTALL
  !insertmacro KENDEX_EDIT_USER_PATH "${KENDEX_PATH_OPEN} $$parts = @($$p -split ';' | Where-Object { $$_ -ne '' }); if ($$parts -notcontains $$d) { $$k.SetValue('Path', (($$parts + $$d) -join ';'), [Microsoft.Win32.RegistryValueKind]::ExpandString) }" "added to"
!macroend

!macro NSIS_HOOK_POSTUNINSTALL
  !insertmacro KENDEX_EDIT_USER_PATH "${KENDEX_PATH_OPEN} $$parts = @($$p -split ';' | Where-Object { $$_ -ne '' -and $$_ -ne $$d }); if ($$parts.Count -eq 0) { $$k.DeleteValue('Path', $$false) } else { $$k.SetValue('Path', ($$parts -join ';'), [Microsoft.Win32.RegistryValueKind]::ExpandString) }" "removed from"
!macroend
