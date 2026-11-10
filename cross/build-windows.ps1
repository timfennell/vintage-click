<#
  Builds Vintage Click for Windows: the Spirula renderer DLL and VintageClick.exe.
  Mirrors .github/workflows/cross.yml.

  Needs: Git, CMake, Ninja, Python 3, the Vulkan SDK, and Visual Studio 2022
  (or its Build Tools) with the "Desktop development with C++" workload.

    powershell -ExecutionPolicy Bypass -File cross\build-windows.ps1            # build
    powershell -ExecutionPolicy Bypass -File cross\build-windows.ps1 -Package   # build + zip

  The renderer source is cloned next to this repo, in ..\spirula (override with -Spirula).
#>
param(
  [string]$Spirula = (Join-Path (Split-Path -Parent (Split-Path -Parent $PSScriptRoot)) 'spirula'),
  [switch]$Package
)
$ErrorActionPreference = 'Stop'
$repo = Split-Path -Parent $PSScriptRoot

function Run([string]$exe) {
  & $exe @args
  if ($LASTEXITCODE -ne 0) { throw "$exe $args failed ($LASTEXITCODE)" }
}

# Fresh PATH (tools installed after this shell started) and the Vulkan SDK.
$env:Path = [Environment]::GetEnvironmentVariable('Path','Machine') + ';' + [Environment]::GetEnvironmentVariable('Path','User') + ';' + $env:Path
if (-not $env:VULKAN_SDK) { $env:VULKAN_SDK = [Environment]::GetEnvironmentVariable('VULKAN_SDK','Machine') }
if (-not $env:VULKAN_SDK) { throw 'The Vulkan SDK is not installed (VULKAN_SDK is not set).' }

# The MSVC x64 developer environment.
if (-not (Get-Command cl.exe -ErrorAction SilentlyContinue)) {
  $vswhere = "${env:ProgramFiles(x86)}\Microsoft Visual Studio\Installer\vswhere.exe"
  $vs = & $vswhere -latest -products * -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath
  if (-not $vs) { throw 'Visual Studio C++ build tools not found.' }
  cmd /c "`"$vs\VC\Auxiliary\Build\vcvars64.bat`" >nul && set" | ForEach-Object {
    if ($_ -match '^([^=]+)=(.*)$') { Set-Item "env:$($matches[1])" $matches[2] }
  }
}

# Renderer source: Spirula Studio at the pinned commit, plus our patch.
$base = (Get-Content "$repo\renderer\UPSTREAM_BASE.txt" -Raw).Trim()
if (-not (Test-Path "$Spirula\.git")) {
  Run git clone https://github.com/harry7557558/spirula-studio $Spirula
}
Push-Location $Spirula
try {
  $head = (git rev-parse HEAD).Trim()
  $dirty = git status --porcelain --untracked-files=no
  if ($head -ne $base -or -not $dirty) {
    Run git checkout --quiet -f $base
    Run git apply "$repo\renderer\spirula-vintage-click.patch"
  }

  Run python -m pip install --quiet --disable-pip-version-check numpy

  $env:SS_SKIP_COMMENT_CHECK = '1'
  Run cmake -G Ninja -B build -DCMAKE_BUILD_TYPE=Release -DCMAKE_POSITION_INDEPENDENT_CODE=ON -DSS_BACKEND=vulkan -DSS_ENABLE_PATENTED=ON
  Run cmake --build build --target spirula_render
} finally { Pop-Location }

# The app.
Run cmake -S "$repo\cross" -B "$repo\cross\build" -G Ninja -DCMAKE_BUILD_TYPE=Release
Run cmake --build "$repo\cross\build"
Copy-Item "$Spirula\build\spirula_render.dll" "$repo\cross\build\" -Force
Write-Host "Built $repo\cross\build\VintageClick.exe"

if ($Package) {
  $out = "$repo\cross\dist\VintageClick-windows-x64"
  if (Test-Path $out) { Remove-Item -Recurse -Force $out }
  New-Item -ItemType Directory -Force $out | Out-Null
  Copy-Item "$repo\cross\build\VintageClick.exe", "$repo\cross\build\spirula_render.dll" $out
  Copy-Item -Recurse "$repo\cross\build\assets" $out
  # The Visual C++ runtime, app-local, so nothing else needs installing.
  $crt = Get-ChildItem -Recurse "$env:VCToolsRedistDir\x64" -Filter '*.CRT' -Directory | Select-Object -First 1
  Copy-Item "$($crt.FullName)\msvcp140*.dll", "$($crt.FullName)\vcruntime140*.dll", "$($crt.FullName)\concrt140.dll" $out
  Copy-Item "$repo\cross\README-Windows.txt" "$out\READ ME.txt"
  Copy-Item "$repo\LICENSE" "$out\LICENSE.txt"
  $zip = "$repo\cross\dist\VintageClick-windows-x64.zip"
  if (Test-Path $zip) { Remove-Item -Force $zip }
  Compress-Archive -Path $out -DestinationPath $zip
  Write-Host "Packaged $zip"
}
