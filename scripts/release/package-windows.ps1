$ErrorActionPreference = 'Stop'
$bundle = 'build/windows/x64/runner/Release'
if (!(Test-Path "$bundle/yun.exe")) { throw "Missing $bundle/yun.exe" }
$stage = Join-Path ([IO.Path]::GetTempPath()) ([Guid]::NewGuid().ToString())
try {
    New-Item -ItemType Directory -Path "$stage/Yun" -Force | Out-Null
    # Preserve ALL DLLs, data, plugins, and media runtime files beside the executable.
    Copy-Item "$bundle/*" "$stage/Yun/" -Recurse -Force
    Copy-Item 'docs/RELEASE.md', 'docs/VALIDATION.md', 'scripts/release/NOTICES.txt', 'dist/flutter-dependencies.txt', 'dist/pubspec.lock', 'dist/BUILD.txt' "$stage/Yun/"
    New-Item -ItemType Directory -Path dist -Force | Out-Null
    Compress-Archive -Path "$stage/Yun" -DestinationPath dist/yun-windows-x64-unsigned.zip -Force
} finally {
    Remove-Item $stage -Recurse -Force
}
