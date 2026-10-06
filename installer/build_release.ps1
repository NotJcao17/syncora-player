# Genera los dos archivos que se suben a GitHub Releases:
#   build\release\Syncora.apk        (Android)
#   build\release\SyncoraSetup.exe   (Windows)
#
# Uso, desde la raiz del repo:
#   powershell -ExecutionPolicy Bypass -File installer\build_release.ps1
#   ... -SkipAndroid    solo Windows
#   ... -SkipWindows    solo Android
#
# La version sale de pubspec.yaml (linea "version: 1.2.3+4"): no hay que
# escribirla en ningun otro lado.

param(
  [switch]$SkipAndroid,
  [switch]$SkipWindows
)

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
Set-Location $root

$line = Select-String -Path 'pubspec.yaml' -Pattern '^version:\s*(\S+)' | Select-Object -First 1
if (-not $line) { throw 'No encontre la linea "version:" en pubspec.yaml' }
$full = $line.Matches[0].Groups[1].Value          # 1.0.0+1
$version = $full.Split('+')[0]                    # 1.0.0
Write-Host "Version: $version (pubspec: $full)" -ForegroundColor Cyan

$out = Join-Path $root 'build\release'
New-Item -ItemType Directory -Force $out | Out-Null

# Nunca en paralelo: flutter build colisiona por un lock sobre sqlite3.dll.
if (-not $SkipAndroid) {
  Write-Host 'Compilando APK...' -ForegroundColor Cyan
  flutter build apk --release --no-tree-shake-icons
  if ($LASTEXITCODE -ne 0) { throw 'Fallo flutter build apk' }
  Copy-Item 'build\app\outputs\flutter-apk\app-release.apk' (Join-Path $out 'Syncora.apk') -Force
}

if (-not $SkipWindows) {
  Write-Host 'Compilando Windows...' -ForegroundColor Cyan
  flutter build windows --release --no-tree-shake-icons
  if ($LASTEXITCODE -ne 0) { throw 'Fallo flutter build windows' }

  # Flutter no incluye el runtime de Visual C++; sin estas DLL la app no abre
  # en equipos que no lo tengan. Se copian las de 64 bits (este PowerShell es
  # de 64 bits, asi que System32 es el real).
  foreach ($dll in 'msvcp140.dll', 'vcruntime140.dll', 'vcruntime140_1.dll') {
    Copy-Item (Join-Path $env:WINDIR "System32\$dll") 'build\windows\x64\runner\Release\' -Force
  }

  $iscc = 'C:\Program Files (x86)\Inno Setup 6\ISCC.exe'
  if (-not (Test-Path $iscc)) { throw "No encontre Inno Setup en $iscc" }
  Write-Host 'Armando el instalador...' -ForegroundColor Cyan
  & $iscc "/DMyAppVersion=$version" 'installer\syncora.iss'
  if ($LASTEXITCODE -ne 0) { throw 'Fallo Inno Setup' }
  Copy-Item 'build\installer\SyncoraSetup.exe' (Join-Path $out 'SyncoraSetup.exe') -Force
}

Write-Host ''
Write-Host "Listo. Archivos en $out" -ForegroundColor Green
Get-ChildItem $out | ForEach-Object { '{0,-20} {1,8:N1} MB' -f $_.Name, ($_.Length / 1MB) }
Write-Host ''
Write-Host "Para publicar:  gh release create v$version build\release\Syncora.apk build\release\SyncoraSetup.exe --title `"Syncora $version`" --generate-notes"
