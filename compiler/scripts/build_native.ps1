# Build the Vorton compiler from the tracked C bootstrap anchor.
# Usage: .\compiler\scripts\build_native.ps1 [-Stats]

param([switch]$Stats)

$ErrorActionPreference = "Stop"

$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot "..\..")).Path
$anchorPath = Join-Path $repoRoot "compiler\dist-c\main.c"
$compilerObject = Join-Path $repoRoot "vorton_compiler_lto.o"
$runtimeSource = Join-Path $repoRoot "vorton_runtime.cpp"
$runtimeObject = Join-Path $repoRoot "vorton_runtime_lto.o"
$outputPath = Join-Path $repoRoot "vorton.exe"
$ltoCache = Join-Path ([System.IO.Path]::GetTempPath()) "vorton-lang-thinlto-cache"
$compileOptimizationFlags = @("-O3", "-flto=thin")
$linkOptimizationFlags = @(
    "-flto=thin",
    "-fuse-ld=lld",
    "-Wl,/lldltocache:$ltoCache",
    "-Wl,/lldltocachepolicy:cache_size_bytes=1073741824:cache_size_files=4096:prune_after=168h"
)

if (-not (Test-Path -LiteralPath $anchorPath -PathType Leaf)) {
    throw "Tracked compiler anchor not found: $anchorPath"
}

$clang = Get-Command clang -CommandType Application -ErrorAction SilentlyContinue |
    Select-Object -First 1
if ($null -eq $clang) {
    throw "clang was not found on PATH"
}

$clangxx = Get-Command clang++ -CommandType Application -ErrorAction SilentlyContinue |
    Select-Object -First 1
if ($null -eq $clangxx) {
    throw "clang++ was not found on PATH"
}

New-Item -ItemType Directory -Path $ltoCache -Force | Out-Null

Write-Host "Step 1/3: Compiling tracked C bootstrap with clang (O3 + ThinLTO) ..."
& $clang.Source -c $anchorPath -o $compilerObject -std=c11 @compileOptimizationFlags
if ($LASTEXITCODE -ne 0) {
    throw "clang compiler-anchor compilation failed with exit code $LASTEXITCODE"
}

Write-Host "Step 2/3: Compiling native runtime with clang++ (O3 + ThinLTO) ..."
$runtimeFlags = @(
    "-c",
    $runtimeSource,
    "-o",
    $runtimeObject,
    "-std=c++17",
    "-D_CRT_SECURE_NO_WARNINGS"
)
$runtimeFlags += $compileOptimizationFlags
if ($Stats) { $runtimeFlags += "-DVORTON_ALLOC_STATS" }
& $clangxx.Source @runtimeFlags
if ($LASTEXITCODE -ne 0) {
    throw "clang++ runtime compilation failed with exit code $LASTEXITCODE"
}

Write-Host "Step 3/3: Linking compiler from tracked C anchor ..."
& $clang.Source $compilerObject $runtimeObject -o $outputPath -lmsvcrt "-Wl,/STACK:536870912" "-Wl,/MANIFEST:EMBED" "-Wl,/MANIFESTUAC:level='asInvoker'" @linkOptimizationFlags
if ($LASTEXITCODE -ne 0) {
    throw "clang link failed with exit code $LASTEXITCODE"
}

Write-Host "Built: $outputPath"
