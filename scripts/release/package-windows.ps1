#requires -Version 7.0
[CmdletBinding()]
param(
    # Optional override for nonstandard installations; no download or extra module is needed.
    [string]$IsccPath = $env:ISCC_PATH
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
# Check native exit codes ourselves, including when the caller enables PS 7.3's preference.
$PSNativeCommandUseErrorActionPreference = $false
if (!$IsWindows) { throw 'Windows packaging must run with pwsh on Windows.' }

function Find-InnoCompiler {
    if (![string]::IsNullOrWhiteSpace($IsccPath)) {
        if (!(Test-Path -LiteralPath $IsccPath -PathType Leaf)) {
            throw "Inno Setup compiler not found at '$IsccPath' (IsccPath/ISCC_PATH override)."
        }
        return (Resolve-Path -LiteralPath $IsccPath).Path
    }

    $command = Get-Command ISCC.exe -CommandType Application -ErrorAction SilentlyContinue |
        Select-Object -First 1
    if ($null -ne $command) { return $command.Source }

    # Hosted windows-2022 installs Inno Setup here, but also support per-user/custom installs.
    $candidates = @(
        foreach ($directory in @(${env:ProgramFiles(x86)}, $env:ProgramFiles, "$env:LOCALAPPDATA\Programs")) {
            if (![string]::IsNullOrWhiteSpace($directory)) {
                Join-Path $directory 'Inno Setup 6/ISCC.exe'
            }
        }
        foreach ($hive in @('HKEY_CURRENT_USER', 'HKEY_LOCAL_MACHINE')) {
            foreach ($software in @('Software', 'Software\WOW6432Node')) {
                $key = "Registry::${hive}\$software\Microsoft\Windows\CurrentVersion\Uninstall\Inno Setup 6_is1"
                $directory = Get-ItemPropertyValue -LiteralPath $key -Name InstallLocation -ErrorAction SilentlyContinue
                if (![string]::IsNullOrWhiteSpace($directory)) {
                    Join-Path $directory 'ISCC.exe'
                }
            }
        }
    )
    foreach ($candidate in $candidates) {
        if (Test-Path -LiteralPath $candidate -PathType Leaf) { return $candidate }
    }
    throw 'Inno Setup 6.3+ ISCC.exe was not found. Install Inno Setup or specify -IsccPath / ISCC_PATH.'
}

$root = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../..'))
$bundle = Join-Path $root 'build/windows/x64/runner/Release'
$dist = Join-Path $root 'dist'
$installer = Join-Path $dist 'yun-windows-x64-unsigned.exe'
$stage = $null
try {
    # Never leave an older installer looking like the result of a failed rebuild.
    if (Test-Path -LiteralPath $installer) { Remove-Item -LiteralPath $installer -Force }
    $compiler = Find-InnoCompiler
    foreach ($file in @('yun.exe', 'flutter_windows.dll', 'data/icudtl.dat')) {
        $path = Join-Path $bundle $file
        if (!(Test-Path -LiteralPath $path -PathType Leaf)) { throw "Missing Flutter bundle file: $path" }
    }
    if (!(Test-Path -LiteralPath (Join-Path $bundle 'data/flutter_assets') -PathType Container)) {
        throw "Missing Flutter assets: $bundle/data/flutter_assets"
    }

    # Read the top-level Flutter version without requiring a PowerShell YAML module.
    # Keep the full version for display; PE version fields require four 16-bit numbers.
    $pubspec = Get-Content -LiteralPath (Join-Path $root 'pubspec.yaml') -Raw
    $versions = [regex]::Matches($pubspec, '(?m)^version:[ \t]*(?<value>[^\r\n]*)\r?$')
    if ($versions.Count -ne 1) { throw 'Expected exactly one top-level version in pubspec.yaml.' }
    $versionMatch = [regex]::Match($versions[0].Groups['value'].Value,
        '^(?<quote>[''"]?)(?<version>(?<major>0|[1-9][0-9]*)\.(?<minor>0|[1-9][0-9]*)\.(?<patch>0|[1-9][0-9]*)(?:-[0-9A-Za-z-]+(?:\.[0-9A-Za-z-]+)*)?(?:\+(?<build>[0-9]+))?)\k<quote>[ \t]*(?:#.*)?$')
    if (!$versionMatch.Success) { throw 'Expected a Flutter version such as 1.2.3[-prerelease][+build] in pubspec.yaml.' }
    $version = $versionMatch.Groups['version'].Value
    $parts = foreach ($name in @('major', 'minor', 'patch', 'build')) {
        $value = $versionMatch.Groups[$name].Value
        if ($value -eq '') { $value = '0' }
        [uint16]$number = 0
        if (![uint16]::TryParse($value, [ref]$number)) {
            throw "Windows version component '$name' must be between 0 and 65535: $version"
        }
        $number
    }
    $fileVersion = $parts -join '.'

    $stage = Join-Path ([IO.Path]::GetTempPath()) ("yun-windows-" + [Guid]::NewGuid().ToString('N'))
    $payload = Join-Path $stage 'Yun'
    $output = Join-Path $stage 'output'
    New-Item -ItemType Directory -Path $payload, $output -Force | Out-Null
    # Enumerate with -Force and use literal paths: preserve hidden files, empty directories,
    # every plugin/media DLL, and all Flutter data, including names containing brackets.
    Get-ChildItem -LiteralPath $bundle -Force | ForEach-Object {
        Copy-Item -LiteralPath $_.FullName -Destination $payload -Recurse -Force
    }
    foreach ($file in @('docs/RELEASE.md', 'docs/VALIDATION.md', 'scripts/release/NOTICES.txt',
            'dist/flutter-dependencies.txt', 'dist/pubspec.lock', 'dist/BUILD.txt', 'LICENSE')) {
        Copy-Item -LiteralPath (Join-Path $root $file) -Destination $payload -Force
    }

    # Inno wildcard sources skip Hidden/System entries. Include their bytes too by
    # clearing only these attributes on the disposable staging copy, never the build.
    Get-ChildItem -LiteralPath $payload -Recurse -Force | ForEach-Object {
        $_.Attributes = $_.Attributes -band (-bnot ([IO.FileAttributes]::Hidden -bor [IO.FileAttributes]::System))
    }

    $arguments = @(
        '/Qp'
        "/DAppVersion=$version"
        "/DFileVersion=$fileVersion"
        "/DBundleDir=$payload"
        "/DInstallerOutputDir=$output"
        (Join-Path $PSScriptRoot 'yun-windows.iss')
    )
    & $compiler @arguments
    if ($LASTEXITCODE -ne 0) { throw "Inno Setup compilation failed with exit code $LASTEXITCODE." }
    $compiled = Join-Path $output 'yun-windows-x64-unsigned.exe'
    if (!(Test-Path -LiteralPath $compiled -PathType Leaf) -or (Get-Item -LiteralPath $compiled).Length -eq 0) {
        throw 'Inno Setup reported success but did not produce a nonempty installer.'
    }
    New-Item -ItemType Directory -Path $dist -Force | Out-Null
    Copy-Item -LiteralPath $compiled -Destination $installer -Force
    Write-Host "Created unsigned installer: $installer (Yun $version; Windows version $fileVersion)"
} catch {
    if (Test-Path -LiteralPath $installer) { Remove-Item -LiteralPath $installer -Force }
    throw
} finally {
    if ($null -ne $stage -and (Test-Path -LiteralPath $stage)) {
        Remove-Item -LiteralPath $stage -Recurse -Force
    }
}
