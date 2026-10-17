#requires -Version 7.0
<#
Standalone smoke test (no Flutter build, Pester, downloads, or signing credentials):
  pwsh -NoProfile -File scripts/release/test-windows-packaging.ps1
Requires Windows x64 and Inno Setup 6.3+ (already installed on windows-2022).
Uses a copied packaging script, fake bundle, unique AppId/name, and temporary files.
Compiles, silently installs, upgrades, and uninstalls WITHOUT executing the fake app.
#>
[CmdletBinding()]
param([string]$IsccPath = $env:ISCC_PATH)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$PSNativeCommandUseErrorActionPreference = $false
if (!$IsWindows -or [Runtime.InteropServices.RuntimeInformation]::OSArchitecture -ne 'X64') {
    throw 'Run this smoke test with pwsh on Windows x64.'
}

function Assert-True([bool]$Condition, [string]$Message) {
    if (!$Condition) { throw "Assertion failed: $Message" }
}

function Write-Fixture([string]$Path, [string]$Content) {
    New-Item -ItemType Directory -Path (Split-Path -Parent $Path) -Force | Out-Null
    [IO.File]::WriteAllText($Path, $Content, [Text.UTF8Encoding]::new($false))
}

function Invoke-Package([string]$Failure = '', [string]$Compiler = $IsccPath) {
    $arguments = @('-NoProfile', '-File', $package)
    if (![string]::IsNullOrWhiteSpace($Compiler)) { $arguments += @('-IsccPath', $Compiler) }
    $oldTemp = $env:TEMP
    $oldTmp = $env:TMP
    try {
        $env:TEMP = $scratch
        $env:TMP = $scratch
        # Exercise actual pwsh/native exit propagation, not a dot-sourced mock.
        $output = & (Join-Path $PSHOME 'pwsh.exe') @arguments 2>&1 | Out-String
        $code = $LASTEXITCODE
    } finally {
        $env:TEMP = $oldTemp
        $env:TMP = $oldTmp
    }
    if ($Failure -eq '') {
        Assert-True ($code -eq 0) "packaging exited ${code}: $output"
        Assert-True (Test-Path -LiteralPath $installer -PathType Leaf) 'installer was produced'
        Assert-True (!(Test-Path -LiteralPath (Join-Path $fixture 'dist/yun-windows-x64-unsigned.zip'))) 'no ZIP was produced'
    } else {
        Assert-True ($code -ne 0) "packaging should fail ($Failure): $output"
        Assert-True ($output.Contains($Failure)) "expected failure '$Failure': $output"
        Assert-True (!(Test-Path -LiteralPath $installer)) 'a failed build must not leave an old/partial installer'
    }
    $leftovers = @(Get-ChildItem -LiteralPath $scratch -Filter 'yun-windows-*' -Force)
    Assert-True ($leftovers.Count -eq 0) 'packaging staging directories were cleaned'
}

function Invoke-Installer([string]$Path, [string[]]$Options) {
    # Start-Process joins ArgumentList: quote the path-valued options explicitly below.
    # -Wait waits for Inno's child process too (calling Setup directly does not).
    $process = Start-Process -FilePath $Path -ArgumentList $Options -Wait -PassThru
    Assert-True ($process.ExitCode -eq 0) "installer/uninstaller exited $($process.ExitCode); logs: $fixture"
}

function Assert-Payload {
    foreach ($file in Get-ChildItem -LiteralPath $bundle -Recurse -Force -File) {
        $relative = [IO.Path]::GetRelativePath($bundle, $file.FullName)
        $installed = Join-Path $installDir $relative
        Assert-True (Test-Path -LiteralPath $installed -PathType Leaf) "installed bundle file: $relative"
        Assert-True ((Get-FileHash -LiteralPath $installed).Hash -eq (Get-FileHash -LiteralPath $file.FullName).Hash) "bundle bytes preserved: $relative"
    }
    foreach ($relative in $inventory) {
        $source = Join-Path $fixture $relative
        $installed = Join-Path $installDir (Split-Path -Leaf $source)
        Assert-True (Test-Path -LiteralPath $installed -PathType Leaf) "installed inventory: $relative"
        Assert-True ((Get-FileHash -LiteralPath $installed).Hash -eq (Get-FileHash -LiteralPath $source).Hash) "inventory bytes preserved: $relative"
    }
    Assert-True (Test-Path -LiteralPath (Join-Path $installDir 'empty directory') -PathType Container) 'empty bundle directories preserved'
}

function Assert-Shortcut([string]$Path) {
    Assert-True (Test-Path -LiteralPath $Path -PathType Leaf) "shortcut exists: $Path"
    $shell = New-Object -ComObject WScript.Shell
    try {
        $shortcut = $shell.CreateShortcut($Path)
        Assert-True ($shortcut.TargetPath -eq (Join-Path $installDir 'yun.exe')) 'shortcut targets installed executable'
        Assert-True ($shortcut.WorkingDirectory -eq $installDir) 'shortcut working directory is the bundle'
    } finally {
        [void][Runtime.InteropServices.Marshal]::FinalReleaseComObject($shell)
    }
}

$id = [Guid]::NewGuid().ToString().ToUpperInvariant()
$appName = "Yun packaging smoke $id"
$fixture = Join-Path ([IO.Path]::GetTempPath()) $appName
$release = Join-Path $fixture 'scripts/release'
$package = Join-Path $release 'package-windows.ps1'
$bundle = Join-Path $fixture 'build/windows/x64/runner/Release'
$installer = Join-Path $fixture 'dist/yun-windows-x64-unsigned.exe'
$scratch = Join-Path $fixture 'compiler temp with spaces'
$pubspec = Join-Path $fixture 'pubspec.yaml'
$installDir = Join-Path $env:LOCALAPPDATA "Programs/$appName"
$startGroup = Join-Path ([Environment]::GetFolderPath('Programs')) $appName
$startShortcut = Join-Path $startGroup "$appName.lnk"
$desktopShortcut = Join-Path ([Environment]::GetFolderPath('DesktopDirectory')) "$appName.lnk"
$registrySuffix = "Software\Microsoft\Windows\CurrentVersion\Uninstall\{${id}}_is1"
$uninstallKey = "Registry::HKEY_CURRENT_USER\$registrySuffix"
$uninstaller = Join-Path $installDir 'unins000.exe'
$inventory = @('docs/RELEASE.md', 'docs/VALIDATION.md', 'scripts/release/NOTICES.txt',
    'dist/flutter-dependencies.txt', 'dist/pubspec.lock', 'dist/BUILD.txt', 'LICENSE')
$quiet = @('/VERYSILENT', '/SUPPRESSMSGBOXES', '/NORESTART', '/SP-')

try {
    New-Item -ItemType Directory -Path $release, $scratch -Force | Out-Null
    Copy-Item -LiteralPath (Join-Path $PSScriptRoot 'package-windows.ps1') -Destination $package
    $definition = Get-Content -LiteralPath (Join-Path $PSScriptRoot 'yun-windows.iss') -Raw
    # NEVER install using Yun's production identity or overwrite an existing user's shortcuts.
    $nameDefinition = '#define YunAppName "Yun"'
    $idDefinition = '#define YunAppId "{{7E108AAF-AB6F-4DA1-99CC-72234C9AE25D}"'
    Assert-True ($definition.Contains($nameDefinition) -and $definition.Contains($idDefinition)) 'expected stable production installer identity'
    $definition = $definition.Replace($nameDefinition, "#define YunAppName `"$appName`"")
    $definition = $definition.Replace($idDefinition, "#define YunAppId `"{{${id}}`"")
    Write-Fixture (Join-Path $release 'yun-windows.iss') $definition
    Assert-True (!(Test-Path -LiteralPath $installDir)) 'unique install directory does not exist yet'
    Assert-True (!(Test-Path -LiteralPath $uninstallKey)) 'unique AppId is not registered yet'

    foreach ($relative in @('yun.exe', 'flutter_windows.dll', 'libmpv-2.dll',
            'media_kit_libs_windows_audio_plugin.dll', 'plugins/nested/runtime.dll',
            'data/icudtl.dat', 'data/flutter_assets/AssetManifest.bin',
            'data/flutter_assets/韵 music.txt', 'payload [keep].bin', '.hidden-runtime.dll')) {
        Write-Fixture (Join-Path $bundle $relative) "fake bundle bytes: $relative"
    }
    $hidden = Get-Item -LiteralPath (Join-Path $bundle '.hidden-runtime.dll') -Force
    $hidden.Attributes = $hidden.Attributes -bor [IO.FileAttributes]::Hidden
    New-Item -ItemType Directory -Path (Join-Path $bundle 'empty directory') -Force | Out-Null
    foreach ($relative in $inventory) { Write-Fixture (Join-Path $fixture $relative) "fixture inventory: $relative" }
    Write-Fixture $pubspec "name: yun`nversion: 1.2.3`n"

    # Invalid/missing inputs fail closed, before any installer is published.
    foreach ($relative in @('yun.exe', 'flutter_windows.dll', 'data/icudtl.dat')) {
        $source = Join-Path $bundle $relative
        Move-Item -LiteralPath $source -Destination "$source.saved"
        try { Invoke-Package -Failure 'Missing Flutter bundle file' }
        finally { Move-Item -LiteralPath "$source.saved" -Destination $source }
    }
    $assets = Join-Path $bundle 'data/flutter_assets'
    Move-Item -LiteralPath $assets -Destination "$assets.saved"
    try { Invoke-Package -Failure 'Missing Flutter assets' }
    finally { Move-Item -LiteralPath "$assets.saved" -Destination $assets }
    $buildInventory = Join-Path $fixture 'dist/BUILD.txt'
    Move-Item -LiteralPath $buildInventory -Destination "$buildInventory.saved"
    try { Invoke-Package -Failure 'BUILD.txt' }
    finally { Move-Item -LiteralPath "$buildInventory.saved" -Destination $buildInventory }
    foreach ($case in @(
        @{ Text = "name: yun`n"; Error = 'exactly one top-level version' },
        @{ Text = "version: 1.2.3`nversion: 1.2.4`n"; Error = 'exactly one top-level version' },
        @{ Text = "version: invalid`n"; Error = 'Expected a Flutter version' },
        @{ Text = "version: 1.2.3+not-a-number`n"; Error = 'Expected a Flutter version' },
        @{ Text = "version: 1.2.3+65536`n"; Error = 'between 0 and 65535' },
        @{ Text = "version: 65536.2.3`n"; Error = 'between 0 and 65535' }
    )) {
        Write-Fixture $pubspec $case.Text
        Invoke-Package -Failure $case.Error
    }
    Write-Fixture $pubspec "version: 1.2.3`n"
    Invoke-Package -Compiler (Join-Path $fixture 'missing ISCC.exe') -Failure 'compiler not found'
    $fakeCompiler = Join-Path $fixture 'fake compiler.cmd'
    Write-Fixture $fakeCompiler "@echo off`r`nexit /b 23`r`n"
    Write-Fixture $installer 'stale installer must be removed'
    Invoke-Package -Compiler $fakeCompiler -Failure 'exit code 23'
    Write-Fixture $fakeCompiler "@echo off`r`nexit /b 0`r`n"
    Write-Fixture $installer 'stale installer must not count as successful output'
    Invoke-Package -Compiler $fakeCompiler -Failure 'did not produce a nonempty installer'

    # Compile without build metadata, then with a quoted prerelease/build version.
    Invoke-Package
    $info = [Diagnostics.FileVersionInfo]::GetVersionInfo($installer)
    # FileVersion is display text and need not format all four numeric words.
    # Check the numeric PE version words rather than its independent text field.
    $numericVersion = @($info.FileMajorPart, $info.FileMinorPart, $info.FileBuildPart, $info.FilePrivatePart) -join '.'
    Assert-True ($numericVersion -eq '1.2.3.0') "a missing build number becomes .0 (got $numericVersion)"
    Write-Fixture $pubspec "name: yun`nversion: '1.2.3-rc.1+45' # Flutter version`n"
    Invoke-Package
    $info = [Diagnostics.FileVersionInfo]::GetVersionInfo($installer)
    $numericVersion = @($info.FileMajorPart, $info.FileMinorPart, $info.FileBuildPart, $info.FilePrivatePart) -join '.'
    Assert-True ($numericVersion -eq '1.2.3.45') "PE version comes from pubspec (got $numericVersion)"
    Assert-True ($info.ProductVersion -eq '1.2.3-rc.1+45') 'the full version is preserved as display text'
    Assert-True ((Get-AuthenticodeSignature -LiteralPath $installer).Status -eq 'NotSigned') 'Setup remains unsigned'

    # No /DIR override: test the real default per-user destination and optional task default.
    Invoke-Installer $installer ($quiet + @("/LOG=`"$(Join-Path $fixture 'install.log')`""))
    Assert-Payload
    Assert-Shortcut $startShortcut
    Assert-True (!(Test-Path -LiteralPath $desktopShortcut)) 'desktop shortcut is opt-in'
    Assert-True ((Get-ItemPropertyValue -LiteralPath $uninstallKey -Name DisplayVersion) -eq '1.2.3-rc.1+45') 'full pubspec version appears in the per-user uninstall entry'
    Assert-True (!(Test-Path -LiteralPath "Registry::HKEY_LOCAL_MACHINE\$registrySuffix")) 'no machine-wide uninstall entry'
    Assert-True (!(Test-Path -LiteralPath "Registry::HKEY_LOCAL_MACHINE\Software\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\{${id}}_is1")) 'no 32-bit machine-wide uninstall entry'
    Assert-True ((Get-AuthenticodeSignature -LiteralPath $uninstaller).Status -eq 'NotSigned') 'uninstaller remains unsigned'

    # Upgrade with the same AppId, update media DLLs, and explicitly opt into desktop shortcut.
    $keptFile = Join-Path $installDir 'user-kept.txt'
    Write-Fixture $keptFile 'unrelated user data must survive uninstall'
    Write-Fixture (Join-Path $bundle 'libmpv-2.dll') 'updated media DLL bytes'
    Write-Fixture (Join-Path $bundle 'plugins/new-runtime.dll') 'new plugin bytes'
    Write-Fixture $pubspec "version: 1.2.4+46`n"
    Invoke-Package
    Invoke-Installer $installer ($quiet + @('/TASKS=desktopicon', "/LOG=`"$(Join-Path $fixture 'upgrade.log')`""))
    Assert-Payload
    Assert-Shortcut $startShortcut
    Assert-Shortcut $desktopShortcut
    Assert-True ((Get-ItemPropertyValue -LiteralPath $uninstallKey -Name DisplayVersion) -eq '1.2.4+46') 'upgrade reuses the AppId and updates version'
    Assert-True ((Get-Content -LiteralPath $keptFile -Raw) -eq 'unrelated user data must survive uninstall') 'upgrade preserves unrelated user data'

    Invoke-Installer $uninstaller @('/VERYSILENT', '/SUPPRESSMSGBOXES', '/NORESTART', "/LOG=`"$(Join-Path $fixture 'uninstall.log')`"")
    foreach ($file in Get-ChildItem -LiteralPath $bundle -Recurse -Force -File) {
        $relative = [IO.Path]::GetRelativePath($bundle, $file.FullName)
        Assert-True (!(Test-Path -LiteralPath (Join-Path $installDir $relative))) "uninstall removes bundle file: $relative"
    }
    foreach ($relative in $inventory) {
        Assert-True (!(Test-Path -LiteralPath (Join-Path $installDir (Split-Path -Leaf $relative)))) "uninstall removes inventory: $relative"
    }
    Assert-True (!(Test-Path -LiteralPath $uninstaller)) 'uninstaller removes itself'
    Assert-True (!(Test-Path -LiteralPath $startShortcut)) 'uninstall removes Start Menu shortcut'
    Assert-True (!(Test-Path -LiteralPath $desktopShortcut)) 'uninstall removes opted-in desktop shortcut'
    Assert-True (!(Test-Path -LiteralPath $uninstallKey)) 'uninstall removes registration'
    Assert-True ((Get-Content -LiteralPath $keptFile -Raw) -eq 'unrelated user data must survive uninstall') 'uninstall preserves unrelated user data'
    Write-Host 'Windows packaging smoke tests passed (fixture only; no Flutter/runtime execution).'
} catch {
    # Keep diagnostic content in the CI log before removing the isolated fixture.
    Get-ChildItem -LiteralPath $fixture -Filter '*.log' -ErrorAction SilentlyContinue | ForEach-Object {
        Write-Host "--- $($_.Name) ---"
        Get-Content -LiteralPath $_.FullName -Tail 60 | ForEach-Object { Write-Host $_ }
    }
    throw
} finally {
    if (Test-Path -LiteralPath $uninstaller) {
        try { Invoke-Installer $uninstaller @('/VERYSILENT', '/SUPPRESSMSGBOXES', '/NORESTART') }
        catch { Write-Warning "Fixture uninstall failed: $_" }
    }
    # These paths and registration use a unique test-only GUID, never Yun's identity.
    foreach ($path in @($desktopShortcut, $startGroup, $installDir, $uninstallKey, $fixture)) {
        if (Test-Path -LiteralPath $path) { Remove-Item -LiteralPath $path -Recurse -Force }
    }
}
