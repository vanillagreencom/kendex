; What the Windows setup does beyond Tauri's own template, through the
; hook macros that template inserts: the kendex command ships as
; bin\kendex.exe under the install directory (bundle.resources in
; release/windows.json, which also names this file), so the install puts
; that directory on the user's PATH, the uninstall takes it off again when
; the install put it there, and a command still running when the setup
; writes the new one is moved aside first. The file itself is written and
; removed by the template's resource steps.
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

; ErrorActionPreference Stop turns a failed registry call into a nonzero
; exit, which the macro above reports, instead of a printed error beside 0.
!define KENDEX_PATH_OPEN "$$ErrorActionPreference = 'Stop'; $$k = [Microsoft.Win32.Registry]::CurrentUser.OpenSubKey('Environment', $$true); $$p = [string]$$k.GetValue('Path', '', [Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames); $$d = $$env:KENDEX_BIN_DIR; $$r = 'Software\ai.kendex.app';"

; The PATH entry is the setup's to remove only when the setup added it. A
; directory already on the PATH before the install stays there after the
; uninstall, so the install records what it added under the app's own key
; (the template deletes the uninstall key before this hook runs) and the
; uninstall reads that record back.
!macro NSIS_HOOK_POSTINSTALL
  !insertmacro KENDEX_EDIT_USER_PATH "${KENDEX_PATH_OPEN} $$parts = @($$p -split ';' | Where-Object { $$_ -ne '' }); if ($$parts -notcontains $$d) { $$k.SetValue('Path', (($$parts + $$d) -join ';'), [Microsoft.Win32.RegistryValueKind]::ExpandString); $$a = [Microsoft.Win32.Registry]::CurrentUser.CreateSubKey($$r); $$a.SetValue('CommandPathAdded', $$d); $$a.Close() }" "added to"
!macroend

!macro NSIS_HOOK_POSTUNINSTALL
  !insertmacro KENDEX_EDIT_USER_PATH "${KENDEX_PATH_OPEN} $$a = [Microsoft.Win32.Registry]::CurrentUser.OpenSubKey($$r, $$true); $$added = if ($$a) { [string]$$a.GetValue('CommandPathAdded', '') } else { '' }; if ($$added -eq $$d) { $$parts = @($$p -split ';' | Where-Object { $$_ -ne '' -and $$_ -ne $$d }); if ($$parts.Count -eq 0) { $$k.DeleteValue('Path', $$false) } else { $$k.SetValue('Path', ($$parts -join ';'), [Microsoft.Win32.RegistryValueKind]::ExpandString) }; $$a.DeleteValue('CommandPathAdded', $$false); $$a.Close() }" "removed from"
  ; The record was the key's only value, so the key goes with it; a key
  ; something else has since written to is left alone.
  DeleteRegKey /ifempty HKCU "Software\ai.kendex.app"
!macroend

; Tauri's template checks only kendex-app.exe for a running process before
; it writes bin\kendex.exe, so a kendex.exe still running (a refresh the
; session hook spawned, say) would make that write fail. Windows lets a
; running image be renamed, so the old command is moved aside first. A
; per-user setup cannot schedule a delete for the next reboot, so the moved
; file is deleted where it can be, here and again on uninstall.
!macro NSIS_HOOK_PREINSTALL
  ${If} ${FileExists} "$INSTDIR\bin\kendex.exe"
    Delete "$INSTDIR\bin\kendex.exe.old"
    Rename "$INSTDIR\bin\kendex.exe" "$INSTDIR\bin\kendex.exe.old"
    Delete "$INSTDIR\bin\kendex.exe.old"
  ${EndIf}
!macroend

; Ahead of the template's own removal, which deletes bin\kendex.exe and
; then removes bin only where it is empty: a command moved aside by an
; earlier update would keep the directory, and the install directory with
; it.
!macro NSIS_HOOK_PREUNINSTALL
  Delete "$INSTDIR\bin\kendex.exe.old"
!macroend
