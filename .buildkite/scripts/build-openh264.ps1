# Requires Visual Studio 2022 Build Tools with the x86/x64 C++ tools.
# arm64 also requires the ARM64 tools and "C++ Clang tools for Windows".
# GNU make requires POSIX sh and rm, available in Git's usr\bin.

param(
  [ValidateSet('x86', 'arm64', 'all')]
  [string]$Arch = 'all',
  [string]$Out = '',
  [string]$ExtraPath = '',
  [int]$Jobs = 8
)

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

$Source = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
if (-not $Out) { $Out = Join-Path $Source 'out' }

function Stop-Build([string]$message) {
  Write-Host "build-openh264: $message"
  exit 1
}

# Separate processes keep each architecture's vcvarsall environment isolated.
if ($Arch -eq 'all') {
  foreach ($one in @('x86', 'arm64')) {
    # Windows PowerShell drops empty arguments passed to native commands.
    $childArgs = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $PSCommandPath, '-Arch', $one, '-Out', $Out, '-Jobs', $Jobs)
    if ($ExtraPath) { $childArgs += '-ExtraPath', $ExtraPath }
    & powershell @childArgs
    if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
  }
  exit 0
}

$useAsm = if ($Arch -eq 'arm64') { 'Yes' } else { 'No' }
$makeArch = if ($Arch -eq 'arm64') { 'arm64' } else { 'i386' }

echo "--- :windows: locate Visual Studio for $Arch"
$vswhere = "${env:ProgramFiles(x86)}\Microsoft Visual Studio\Installer\vswhere.exe"
if (-not (Test-Path $vswhere)) { Stop-Build "vswhere.exe is not at $vswhere" }
$requires = @('Microsoft.VisualStudio.Component.VC.Tools.x86.x64')
if ($Arch -eq 'arm64') {
  $requires += 'Microsoft.VisualStudio.Component.VC.Tools.ARM64', 'Microsoft.VisualStudio.Component.VC.Llvm.Clang'
}
$vs = & $vswhere -latest -products * -requires $requires -property installationPath
if (-not $vs) { Stop-Build "no Visual Studio install has all of: $($requires -join ', ')" }
echo "Visual Studio: $vs"

$vcvarsArch = if ($Arch -eq 'arm64') { 'amd64_arm64' } else { 'x86' }
$vcvars = Join-Path $vs 'VC\Auxiliary\Build\vcvarsall.bat'
cmd /c "`"$vcvars`" $vcvarsArch >nul && set" | ForEach-Object {
  if ($_ -match '^([^=]+)=(.*)$') { Set-Item -Path "env:$($Matches[1])" -Value $Matches[2] }
}
if ($LASTEXITCODE -ne 0) { Stop-Build "vcvarsall $vcvarsArch failed" }

# OpenH264 assembles its arm64 NEON sources with clang-cl.
if ($Arch -eq 'arm64') { $env:Path = (Join-Path $vs 'VC\Tools\Llvm\x64\bin') + ';' + $env:Path }
if ($ExtraPath) { $env:Path = $ExtraPath + ';' + $env:Path }

echo "--- :hammer: check tools"
# GNU make invokes rm directly, so rm must be on PATH.
$tools = @('cl', 'lib', 'make', 'sh', 'rm', 'git')
if ($Arch -eq 'arm64') { $tools += 'clang-cl' }
foreach ($tool in $tools) {
  # PowerShell aliases rm to Remove-Item, which make cannot run.
  $cmd = Get-Command $tool -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
  if (-not $cmd) { Stop-Build "$tool is not on PATH" }
  echo "$tool -> $($cmd.Source)"
}
$clVersion = (cmd /c "cl 2>&1" | Select-Object -First 1)
echo $clVersion

echo "--- :building_construction: make openh264.lib for $Arch"
$makeArgs = @('OS=msvc', "ARCH=$makeArch", "USE_ASM=$useAsm")
Push-Location $Source
try {
  # `make clean` fails for ARCH=i386 with OS=msvc, so git removes the ignored build outputs.
  # *.lib is ignored, so out\ needs an explicit exclusion from git clean.
  & git clean -fdXq -e '!/out/**'
  if ($LASTEXITCODE -ne 0) { Stop-Build 'git clean failed' }
  & make @makeArgs "-j$Jobs" openh264.lib
  if ($LASTEXITCODE -ne 0) { Stop-Build "make $($makeArgs -join ' ') openh264.lib failed" }
  $commit = (& git rev-parse HEAD)
  $dirty = (& git status --porcelain --untracked-files=no)
} finally {
  Pop-Location
}

echo "--- :package: collect"
$dir = Join-Path $Out $Arch
New-Item -ItemType Directory -Path $dir -Force > $null
$lib = Join-Path $dir 'openh264.lib'
Copy-Item (Join-Path $Source 'openh264.lib') $lib -Force
$hash = (Get-FileHash $lib -Algorithm SHA256).Hash.ToLower()
$size = (Get-Item $lib).Length
@(
  "arch: $Arch"
  "source commit: $commit$(if ($dirty) { ' (with uncommitted changes)' })"
  "compiler: $clVersion"
  "command: make $($makeArgs -join ' ') openh264.lib"
  "size: $size"
  "sha256: $hash"
) | Out-File -Encoding utf8 (Join-Path $dir 'openh264.lib.txt')
Get-Content (Join-Path $dir 'openh264.lib.txt')
