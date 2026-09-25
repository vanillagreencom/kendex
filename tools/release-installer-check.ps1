<#
release-installer-check.ps1 — the Windows setup one release lane built
installs a working kendex command, puts its directory on the user PATH, and
takes both away again on uninstall. The companion of release-installer-check,
which checks the Linux and macOS installers by taking them apart; a setup
cannot be taken apart into what its hooks do, so this one runs it.

usage: tools/release-installer-check.ps1 -Target <triple> -Out <dir>

  Target  the Rust target triple this lane built
  Out     the lane's output directory, target/<triple>/release: the command
          at Out\kendex.exe and the setup under Out\bundle\nsis

The setup is run silently into a directory of its own (/S, and /D= names
the directory; NSIS reads it as the last argument, unquoted). Afterwards
Out\bin\kendex.exe has to answer --version with the line the built command
answers, and the user PATH has to carry that bin directory as a REG_EXPAND_SZ
value. Then the uninstaller runs silently, and both have to be gone: the
command from disk, the directory from the PATH. The PATH is read raw, with
environment names unexpanded, the way the hook writes it.

A refusal prints one stable line, `release-installer-check: <key>=<value>`,
then one `::error::` annotation carrying the English, and exits 1. Each
passing stage prints `checked=<what>`. The user PATH the runner started
with is put back whatever the outcome, so a refusal does not leave the
runner's environment carrying the install.
#>
param(
  [Parameter(Mandatory = $true)][string]$Target,
  [Parameter(Mandatory = $true)][string]$Out
)

$ErrorActionPreference = 'Stop'

function Refuse([string]$Key, [string]$Value, [string]$English) {
  [Console]::Error.WriteLine("release-installer-check: $Key=$Value")
  [Console]::Error.WriteLine("::error::$English")
  exit 1
}

function UserPathRaw {
  $key = [Microsoft.Win32.Registry]::CurrentUser.OpenSubKey('Environment')
  try {
    return [string]$key.GetValue('Path', '', [Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames)
  } finally {
    $key.Close()
  }
}

function UserPathKind {
  $key = [Microsoft.Win32.Registry]::CurrentUser.OpenSubKey('Environment')
  try {
    if ($null -eq $key.GetValue('Path')) { return 'absent' }
    return [string]$key.GetValueKind('Path')
  } finally {
    $key.Close()
  }
}

function RestoreUserPath([string]$Kind, [string]$Raw) {
  $key = [Microsoft.Win32.Registry]::CurrentUser.OpenSubKey('Environment', $true)
  try {
    if ($Kind -eq 'absent') {
      $key.DeleteValue('Path', $false)
    } else {
      $key.SetValue('Path', $Raw, [Microsoft.Win32.RegistryValueKind]::$Kind)
    }
  } finally {
    $key.Close()
  }
}

if ($Target -ne 'x86_64-pc-windows-msvc') {
  Refuse 'target' $Target "'$Target' is not a target this script checks; the Linux and macOS installers are release-installer-check's."
}
if (-not (Test-Path -LiteralPath $Out -PathType Container)) {
  Refuse 'not-a-directory' $Out "$Out is not a directory, so this lane built nothing to check."
}
$built = Join-Path $Out 'kendex.exe'
if (-not (Test-Path -LiteralPath $built -PathType Leaf)) {
  Refuse 'no-command' $built "$built is not a command this lane built, so there is no version to hold the setup to."
}
$expected = & $built --version
if ($LASTEXITCODE -ne 0) {
  Refuse 'version-unreadable' $built "$built did not answer --version, so nothing here can say what this release was built as."
}
$setups = @(Get-ChildItem -LiteralPath (Join-Path $Out 'bundle\nsis') -Filter '*-setup.exe' -File -ErrorAction SilentlyContinue)
if ($setups.Count -eq 0) {
  Refuse 'missing' '*-setup.exe' "$Out\bundle\nsis holds no file matching *-setup.exe; this lane stopped building the setup."
}
if ($setups.Count -gt 1) {
  Refuse 'ambiguous' '*-setup.exe' "$Out\bundle\nsis holds more than one file matching *-setup.exe ($($setups[0].Name) and $($setups[1].Name)); this lane cannot say which one it built."
}
$setup = $setups[0].FullName

$installDir = Join-Path ([System.IO.Path]::GetTempPath()) ("kendex-installer-check-" + [System.IO.Path]::GetRandomFileName())
$binDir = Join-Path $installDir 'bin'
$pathKindBefore = UserPathKind
$pathBefore = UserPathRaw

try {
  $install = Start-Process -FilePath $setup -ArgumentList @('/S', "/D=$installDir") -Wait -PassThru
  if ($install.ExitCode -ne 0) {
    Refuse 'install' $install.ExitCode "$setup exited $($install.ExitCode) on a silent install into $installDir."
  }
  $command = Join-Path $binDir 'kendex.exe'
  if (-not (Test-Path -LiteralPath $command -PathType Leaf)) {
    Refuse 'absent' $command "$setup installs no kendex command at $command; the download would install the app alone."
  }
  $answer = & $command --version
  if ($LASTEXITCODE -ne 0) {
    Refuse 'unrunnable' $command "the kendex command $setup installed does not run; an install from it would have a command that fails on first use."
  }
  if ($answer -ne $expected) {
    Refuse 'version-mismatch' $answer "the kendex command $setup installed answers `"$answer`" and the command this lane built answers `"$expected`"; the setup carries another build."
  }
  Write-Output "checked=$setup"

  $kind = UserPathKind
  if ($kind -ne 'ExpandString') {
    Refuse 'path-kind' $kind "the user PATH is $kind after the install; the setup has to write it as REG_EXPAND_SZ."
  }
  $entries = @((UserPathRaw) -split ';' | Where-Object { $_ -ne '' })
  if ($entries -notcontains $binDir) {
    Refuse 'path-missing' $binDir "the user PATH does not carry $binDir after the install."
  }
  if ($pathBefore -ne '') {
    foreach ($entry in @($pathBefore -split ';' | Where-Object { $_ -ne '' })) {
      if ($entries -notcontains $entry) {
        Refuse 'path-lost' $entry "the user PATH lost the entry $entry on install; the setup rewrote the value short."
      }
    }
  }
  Write-Output "checked=user-path-added"

  $uninstaller = Join-Path $installDir 'uninstall.exe'
  if (-not (Test-Path -LiteralPath $uninstaller -PathType Leaf)) {
    Refuse 'no-uninstaller' $uninstaller "$setup left no uninstaller at $uninstaller."
  }
  # NSIS copies the uninstaller and runs the copy, so -Wait returns before
  # the copy finishes; _?= keeps it running in place, which is what makes
  # the wait mean anything.
  $uninstall = Start-Process -FilePath $uninstaller -ArgumentList @('/S', "_?=$installDir") -Wait -PassThru
  if ($uninstall.ExitCode -ne 0) {
    Refuse 'uninstall' $uninstall.ExitCode "$uninstaller exited $($uninstall.ExitCode) on a silent uninstall."
  }
  if (Test-Path -LiteralPath $command) {
    Refuse 'left-behind' $command "the uninstall left the kendex command at $command."
  }
  $entriesAfter = @((UserPathRaw) -split ';' | Where-Object { $_ -ne '' })
  if ($entriesAfter -contains $binDir) {
    Refuse 'path-left' $binDir "the uninstall left $binDir on the user PATH."
  }
  Write-Output "checked=user-path-removed"
} finally {
  RestoreUserPath $pathKindBefore $pathBefore
  if (Test-Path -LiteralPath $installDir) {
    Remove-Item -LiteralPath $installDir -Recurse -Force -ErrorAction SilentlyContinue
  }
}
