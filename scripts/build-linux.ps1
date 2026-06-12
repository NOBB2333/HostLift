$ErrorActionPreference = "Stop"

$RootDir = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
$DistDir = Join-Path $RootDir "dist"
$Optimize = if ($env:OPTIMIZE) { $env:OPTIMIZE } else { "ReleaseSafe" }
$Targets = $args

if ($Targets.Count -eq 0) {
    $Targets = @("x86_64-linux-musl", "aarch64-linux-musl")
}

Set-Location $RootDir
New-Item -ItemType Directory -Force -Path $DistDir | Out-Null

function Invoke-Zig {
    param([string[]]$ZigArgs)

    if (Get-Command mise -ErrorAction SilentlyContinue) {
        & mise exec -- zig @ZigArgs
    } else {
        & zig @ZigArgs
    }

    if ($LASTEXITCODE -ne 0) {
        throw "zig command failed: zig $($ZigArgs -join ' ')"
    }
}

Invoke-Zig @("build", "test")

foreach ($Target in $Targets) {
    $OutDir = Join-Path $DistDir $Target
    if (Test-Path $OutDir) {
        Remove-Item -Recurse -Force $OutDir
    }
    New-Item -ItemType Directory -Force -Path $OutDir | Out-Null

    Invoke-Zig @(
        "build",
        "-Dtarget=$Target",
        "-Doptimize=$Optimize",
        "--prefix",
        $OutDir
    )

    $Binary = Join-Path $OutDir "bin/hostlift"
    $Hash = Get-FileHash -Algorithm SHA256 $Binary
    "$($Hash.Hash.ToLowerInvariant())  $Binary" | Set-Content "$Binary.sha256"

    Write-Host "built $Binary"
}
