# SPDX-License-Identifier: MIT
# Clone and compile the Windows native libs vibe-0 links
# (OpenSSL, brotli, SQLite). Outputs into ../lib/{openssl-win64-x64,
# brotli-win64-x64, sqlite3_x64.lib} so dub.json $PACKAGE_DIR paths resolve.
#
#   cd riscv-dev
#   . .\setenv.ps1
#   .\vibe.0\scripts\build-windows-libs.ps1
#
# -UseBundled   only check that the shipped lib/ blobs exist (skip compile)
# -SkipOpenSSL  sqlite + brotli only (OpenSSL needs perl + long nmake)
# -X86          also build 32-bit (needs vcvars32)
#
# Does not commit foundry/PDK content. Third-party checkouts stay in
# vibe.0/third-party/ (gitignored).
param(
  [switch]$UseBundled,
  [switch]$SkipOpenSSL,
  [switch]$X86
)

$ErrorActionPreference = 'Stop'
$VibeRoot = Split-Path $PSScriptRoot -Parent
$LibDir = Join-Path $VibeRoot 'lib'
$Tp = Join-Path $VibeRoot 'third-party'
$Arch = if ($X86) { 'x86' } else { 'x64' }

function Get-VsVcvars {
  $vswhere = "${env:ProgramFiles(x86)}\Microsoft Visual Studio\Installer\vswhere.exe"
  if (-not (Test-Path $vswhere)) { throw "vswhere.exe missing — install Visual Studio C++ tools" }
  $vs = & $vswhere -latest -products * -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath
  if (-not $vs) { throw "Visual Studio with VC tools not found" }
  $bat = if ($X86) { Join-Path $vs 'VC\Auxiliary\Build\vcvars32.bat' } else { Join-Path $vs 'VC\Auxiliary\Build\vcvars64.bat' }
  if (-not (Test-Path $bat)) { throw "vcvars missing: $bat" }
  return $bat
}

function Get-Cmake {
  $candidates = @(
    "${env:ProgramFiles}\Microsoft Visual Studio\18\Community\Common7\IDE\CommonExtensions\Microsoft\CMake\CMake\bin\cmake.exe",
    "${env:ProgramFiles}\Microsoft Visual Studio\17\Community\Common7\IDE\CommonExtensions\Microsoft\CMake\CMake\bin\cmake.exe",
    "${env:ProgramFiles}\CMake\bin\cmake.exe"
  )
  foreach ($c in $candidates) { if (Test-Path $c) { return $c } }
  $onPath = Get-Command cmake -ErrorAction SilentlyContinue
  if ($onPath) { return $onPath.Source }
  throw "cmake.exe not found (VS CMake component or standalone CMake)"
}

function Get-Perl {
  $candidates = @(
    'C:\Program Files\Git\usr\bin\perl.exe',
    'C:\Strawberry\perl\bin\perl.exe'
  )
  foreach ($c in $candidates) { if (Test-Path $c) { return $c } }
  $onPath = Get-Command perl -ErrorAction SilentlyContinue
  if ($onPath) { return $onPath.Source }
  return $null
}

function Invoke-NativeBuild {
  param([string]$Vcvars, [string]$Body)
  $bat = Join-Path $env:TEMP ("vibe0-nativelibs-{0}.bat" -f [guid]::NewGuid().ToString('N'))
  @(
    '@echo off'
    "call `"$Vcvars`" || exit /b 1"
    $Body
  ) | Set-Content -Encoding oem $bat
  try {
    & cmd.exe /c $bat
    if ($LASTEXITCODE -ne 0) { throw "native build failed ($LASTEXITCODE)`n$Body" }
  }
  finally { Remove-Item -Force $bat -ErrorAction SilentlyContinue }
}

function Ensure-Clone {
  param([string]$Url, [string]$Dest, [string]$Ref)
  if (-not (Test-Path (Join-Path $Dest '.git'))) {
    New-Item -ItemType Directory -Force -Path (Split-Path $Dest) | Out-Null
    Write-Host "git clone --depth 1 $Url ($Ref) -> $Dest"
    & git clone --depth 1 --branch $Ref $Url $Dest
    if ($LASTEXITCODE -ne 0) { throw "git clone failed: $Url" }
  }
  else {
    Write-Host "reuse clone $Dest"
  }
}

function Test-Bundled {
  $need = if ($X86) {
    @(
      (Join-Path $LibDir 'openssl-win32-x86\libssl.lib'),
      (Join-Path $LibDir 'openssl-win32-x86\libcrypto.lib'),
      (Join-Path $LibDir 'sqlite3_x86.lib'),
      (Join-Path $LibDir 'brotli-win32-x86\brotlicommon.lib')
    )
  }
  else {
    @(
      (Join-Path $LibDir 'openssl-win64-x64\libssl.lib'),
      (Join-Path $LibDir 'openssl-win64-x64\libcrypto.lib'),
      (Join-Path $LibDir 'sqlite3_x64.lib'),
      (Join-Path $LibDir 'brotli-win64-x64\brotlicommon.lib')
    )
  }
  $missing = @($need | Where-Object { -not (Test-Path $_) })
  if ($missing.Count) {
    throw "bundled libs missing:`n$($missing -join "`n")"
  }
  Write-Host "bundled Windows $Arch libs present under $LibDir"
}

if ($UseBundled) {
  Test-Bundled
  Write-Host "OK  using bundled lib/ (dub.json `$PACKAGE_DIR paths)"
  exit 0
}

New-Item -ItemType Directory -Force -Path $Tp, $LibDir | Out-Null
$vcvars = Get-VsVcvars
$cmake = Get-Cmake
Write-Host "vcvars  $vcvars"
Write-Host "cmake   $cmake"

# --- SQLite amalgamation ---
$sqliteVer = '3450300'
$sqliteZip = Join-Path $Tp "sqlite-amalgamation-$sqliteVer.zip"
$sqliteDir = Join-Path $Tp "sqlite-amalgamation-$sqliteVer"
if (-not (Test-Path (Join-Path $sqliteDir 'sqlite3.c'))) {
  $url = "https://www.sqlite.org/2024/sqlite-amalgamation-$sqliteVer.zip"
  Write-Host "download $url"
  Invoke-WebRequest -Uri $url -OutFile $sqliteZip
  Expand-Archive -Force $sqliteZip -DestinationPath $Tp
}
$sqliteOut = if ($X86) { Join-Path $LibDir 'sqlite3_x86.lib' } else { Join-Path $LibDir 'sqlite3_x64.lib' }
Write-Host "compile sqlite -> $sqliteOut"
$obj = Join-Path $sqliteDir 'sqlite3.obj'
Invoke-NativeBuild -Vcvars $vcvars -Body @"
cd /d `"$sqliteDir`"
cl /nologo /c /O2 /DSQLITE_API= sqlite3.c || exit /b 1
lib /nologo /OUT:`"$sqliteOut`" sqlite3.obj || exit /b 1
"@

# --- brotli ---
$brotliDir = Join-Path $Tp 'brotli'
Ensure-Clone -Url 'https://github.com/google/brotli.git' -Dest $brotliDir -Ref 'v1.1.0'
$brotliOutDir = if ($X86) { Join-Path $LibDir 'brotli-win32-x86' } else { Join-Path $LibDir 'brotli-win64-x64' }
New-Item -ItemType Directory -Force -Path $brotliOutDir | Out-Null
$brotliBuild = Join-Path $brotliDir ("out-" + $Arch)
Write-Host "cmake brotli -> $brotliOutDir"
$gen = 'Visual Studio 18 2026'
# Fall back to VS 17 if 18 generator is unknown.
Invoke-NativeBuild -Vcvars $vcvars -Body @"
`"$cmake`" -S `"$brotliDir`" -B `"$brotliBuild`" -G `"$gen`" -A $(if ($X86) { 'Win32' } else { 'x64' }) -DBUILD_SHARED_LIBS=OFF -DCMAKE_BUILD_TYPE=Release
if errorlevel 1 `"$cmake`" -S `"$brotliDir`" -B `"$brotliBuild`" -A $(if ($X86) { 'Win32' } else { 'x64' }) -DBUILD_SHARED_LIBS=OFF
if errorlevel 1 exit /b 1
`"$cmake`" --build `"$brotliBuild`" --config Release --target brotlicommon brotlidec brotlienc
if errorlevel 1 exit /b 1
"@
$built = @(
  Get-ChildItem $brotliBuild -Recurse -Filter 'brotlicommon.lib' | Select-Object -First 1
  Get-ChildItem $brotliBuild -Recurse -Filter 'brotlidec.lib' | Select-Object -First 1
  Get-ChildItem $brotliBuild -Recurse -Filter 'brotlienc.lib' | Select-Object -First 1
)
if ($built -contains $null -or $built.Count -lt 3) { throw "brotli .lib not found under $brotliBuild" }
foreach ($f in $built) { Copy-Item -Force $f.FullName $brotliOutDir }

# --- OpenSSL (static, TLS 1.3-oriented flags from lib/openssl-build-flags.txt) ---
if (-not $SkipOpenSSL) {
  $perl = Get-Perl
  if (-not $perl) {
    Write-Warning "perl not found (Git usr/bin or Strawberry). Skipping OpenSSL compile; keeping bundled lib/openssl-win*."
  }
  else {
    $osslDir = Join-Path $Tp 'openssl'
    Ensure-Clone -Url 'https://github.com/openssl/openssl.git' -Dest $osslDir -Ref 'openssl-3.3.2'
    $osslInst = if ($X86) { Join-Path $LibDir 'openssl-win32-x86' } else { Join-Path $LibDir 'openssl-win64-x64' }
    New-Item -ItemType Directory -Force -Path $osslInst | Out-Null
    $flagsFile = Join-Path $LibDir 'openssl-build-flags.txt'
    $extra = if (Test-Path $flagsFile) { (Get-Content $flagsFile -Raw).Trim() } else { 'no-shared enable-tls1_3 no-sock' }
    $target = if ($X86) { 'VC-WIN32' } else { 'VC-WIN64A' }
    $perlDir = Split-Path $perl -Parent
    Write-Host "configure+build OpenSSL $target -> $osslInst"
    Invoke-NativeBuild -Vcvars $vcvars -Body @"
set PATH=$perlDir;%PATH%
cd /d `"$osslDir`"
perl Configure $target no-asm --prefix=`"$osslInst`" --openssldir=`"$osslInst\ssl`" $extra
if errorlevel 1 exit /b 1
nmake
if errorlevel 1 exit /b 1
nmake install_sw
if errorlevel 1 exit /b 1
"@
    # nmake install_sw puts libs under lib/ or lib64/
    foreach ($name in @('libssl.lib', 'libcrypto.lib')) {
      $found = Get-ChildItem $osslInst -Recurse -Filter $name | Select-Object -First 1
      if (-not $found) { $found = Get-ChildItem $osslDir -Recurse -Filter $name | Select-Object -First 1 }
      if (-not $found) { throw "OpenSSL $name not produced" }
      Copy-Item -Force $found.FullName (Join-Path $osslInst $name)
    }
    Set-Content -Encoding ascii (Join-Path $osslInst 'version.txt') "built-by scripts/build-windows-libs.ps1 $(Get-Date -Format o)"
  }
}

Test-Bundled
Write-Host "OK  Windows $Arch native libs ready. dub.json uses `$PACKAGE_DIR/lib/..."
Write-Host "    next:  cd $($VibeRoot); dub build --compiler=ldc2"
exit 0
