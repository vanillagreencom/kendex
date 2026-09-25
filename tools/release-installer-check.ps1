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
<install dir>\bin\kendex.exe has to answer --version with the line the built
command answers and, run as `kendex update`, answer that it is part of the
app and exit 0 without reading any feed; the app's own kendex-app.exe has to
sit in the install directory; and the user PATH has to carry that bin
directory as a REG_EXPAND_SZ value. Then the uninstaller runs silently, and
both have to be gone: the command from disk, the directory from the PATH.

The PATH is seeded before the install with a REG_EXPAND_SZ value longer than
an NSIS string holds (1024 bytes), carrying %USERPROFILE% entries past that
byte, and read raw with environment names unexpanded, the way the hook
writes it: after the install and after the uninstall the kind is still
ExpandString and every seeded entry is still there, unexpanded. A hook that
read the value through an NSIS string, or expanded it, or wrote REG_SZ,
fails here. A second cycle seeds the bin directory itself onto the PATH
before the install, and the uninstall has to leave it there: the entry is
the setup's to remove only when the setup added it.

A refusal prints one stable line, `release-installer-check: <key>=<value>`,
then one `::error::` annotation carrying the English, and exits 1. Each
passing stage prints `checked=<what>`. The user PATH the runner started
with is put back whatever the outcome, so a refusal does not leave the
runner's environment carrying the install or the seed.
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

function WriteUserPath([string]$Kind, [string]$Raw) {
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

function UserPathEntries {
  return @((UserPathRaw) -split ';' | Where-Object { $_ -ne '' })
}

# The seeded PATH survived a hook's rewrite: still REG_EXPAND_SZ, every
# seeded entry still present and unexpanded.
function AssertSeedIntact([string[]]$Seed, [string]$Stage) {
  $kind = UserPathKind
  if ($kind -ne 'ExpandString') {
    Refuse 'path-kind' "$kind ($Stage)" "the user PATH is $kind after the $Stage; the setup has to write it as REG_EXPAND_SZ."
  }
  $entries = UserPathEntries
  foreach ($entry in $Seed) {
    if ($entries -cnotcontains $entry) {
      Refuse 'path-lost' "$entry ($Stage)" "the user PATH lost or rewrote the entry $entry on $Stage; the setup rewrote the value short or expanded it."
    }
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

# One install and uninstall over a seeded user PATH. $Seed is what the PATH
# holds before the install; $BinSeeded says whether the bin directory is
# among it, which decides whether the uninstall may remove it.
function Cycle([string[]]$Seed, [bool]$BinSeeded) {
  WriteUserPath 'ExpandString' ($Seed -join ';')
  $install = Start-Process -FilePath $setup -ArgumentList @('/S', "/D=$installDir") -Wait -PassThru
  if ($install.ExitCode -ne 0) {
    Refuse 'install' $install.ExitCode "$setup exited $($install.ExitCode) on a silent install into $installDir."
  }
  $command = Join-Path $binDir 'kendex.exe'
  if (-not (Test-Path -LiteralPath $command -PathType Leaf)) {
    Refuse 'absent' $command "$setup installs no kendex command at $command; the download would install the app alone."
  }
  $app = Join-Path $installDir 'kendex-app.exe'
  if (-not (Test-Path -LiteralPath $app -PathType Leaf)) {
    Refuse 'no-app' $app "$setup installs no desktop app at $app, which is what makes the command beside it the app's own."
  }
  $answer = & $command --version
  if ($LASTEXITCODE -ne 0) {
    Refuse 'unrunnable' $command "the kendex command $setup installed does not run; an install from it would have a command that fails on first use."
  }
  if ($answer -ne $expected) {
    Refuse 'version-mismatch' $answer "the kendex command $setup installed answers `"$answer`" and the command this lane built answers `"$expected`"; the setup carries another build."
  }
  # The real judge over the real layout: a command inside the app answers
  # that it updates with the app, before any feed is read, and exits 0.
  $update = & $command update 2>&1 | Out-String
  if ($LASTEXITCODE -ne 0 -or $update -notmatch 'kendex desktop app') {
    Refuse 'update-inside-the-app' $LASTEXITCODE "kendex update from $command did not stop as a command inside the app (exit $LASTEXITCODE): $update"
  }
  Write-Output "checked=$setup"

  AssertSeedIntact $Seed 'install'
  if ((UserPathEntries) -notcontains $binDir) {
    Refuse 'path-missing' $binDir "the user PATH does not carry $binDir after the install."
  }
  Write-Output "checked=user-path-after-install"

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
  AssertSeedIntact $Seed 'uninstall'
  $after = UserPathEntries
  if ($BinSeeded) {
    if ($after -notcontains $binDir) {
      Refuse 'path-taken' $binDir "the uninstall removed $binDir from the user PATH, which was there before the install."
    }
  } elseif ($after -contains $binDir) {
    Refuse 'path-left' $binDir "the uninstall left $binDir on the user PATH."
  }
  if (Test-Path -LiteralPath 'HKCU:\Software\ai.kendex.app') {
    Refuse 'record-left' 'HKCU:\Software\ai.kendex.app' "the uninstall left the setup's PATH record key behind."
  }
  Write-Output "checked=user-path-after-uninstall"
}

try {
  # Longer than an NSIS string, with unexpanded entries past that length.
  $seed = @('%USERPROFILE%\seed-first')
  $i = 0
  while (($seed -join ';').Length -le 1100) {
    $i += 1
    $seed += "C:\kendex-installer-check\seed-$i"
  }
  $seed += '%USERPROFILE%\seed-last'
  Cycle $seed $false
  Cycle ($seed + $binDir) $true
} finally {
  WriteUserPath $pathKindBefore $pathBefore
  if (Test-Path -LiteralPath $installDir) {
    Remove-Item -LiteralPath $installDir -Recurse -Force -ErrorAction SilentlyContinue
  }
}
