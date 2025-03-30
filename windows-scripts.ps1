#!/usr/bin/env pwsh
# cspell:ignore psise,nupkgs,nugets,vswhere

function Get-ScriptDirectory {
    if ($psise) {
        Split-Path $psise.CurrentFile.FullPath
    }
    else {
        $global:PSScriptRoot
    }
}

function PackAllNugets([Parameter(Mandatory = $true)] [string]$Version, [Parameter(Mandatory = $false)] [string]$Configuration = "Release") {
    New-Item -ItemType Directory -Force -Path "nupkgs"
    nuget pack Whisper.net.Runtime.nuspec -Version $Version -OutputDirectory ./nupkgs
    dotnet pack Whisper.net/Whisper.net.csproj -p:Version=$Version -o ./nupkgs -c $Configuration
    nuget pack Whisper.net.Runtime.CoreML.nuspec -Version $Version -OutputDirectory ./nupkgs
    nuget pack Whisper.net.Runtime.Cublas.nuspec -Version $Version -OutputDirectory ./nupkgs
    nuget pack Whisper.net.Runtime.Clblast.nuspec -Version $Version -OutputDirectory ./nupkgs
}

function Get-VisualStudioCMakePath() {
    $vsWherePath = Join-Path ${env:ProgramFiles(x86)} 'Microsoft Visual Studio\Installer\vswhere.exe'
    if (-not (Test-Path $vsWherePath)) {
        return $null
    }

    $vsWhereOutput = & $vsWherePath -latest -requires Microsoft.Component.MSBuild -property installationPath
    if (-not ([string]::IsNullOrEmpty($vsWhereOutput))) {
        $cmakePath = Join-Path $vsWhereOutput 'Common7\IDE\CommonExtensions\Microsoft\CMake\CMake\bin'
        if (Test-Path $cmakePath) {
            return $cmakePath
        }
    }

    return $null
}

function Get-MSBuildPlatform($Arch) {
    $platforms = @{
        "x64"   = "x64"
        "x86"   = "Win32"
    }

    if ($platforms.ContainsKey($Arch)) {
        return $platforms[$Arch]
    }

    return $null
}

function BuildWindows() {
    param(
        [Parameter(Mandatory = $true)] [string]$Arch,
        [Parameter(Mandatory = $false)] [bool]$Cuda = $false,
        [Parameter(Mandatory = $false)] [bool]$Vulkan = $false,
        [Parameter(Mandatory = $false)] [bool]$OpenVino = $false,
        [Parameter(Mandatory = $false)] [bool]$NoAvx = $false,
        [Parameter(Mandatory = $false)] [string]$Configuration = "Release"
    )
    $scriptDirectory = Get-ScriptDirectory
    $buildDirectoryRoot = "$scriptDirectory/.build"

    if (!(Test-Path $buildDirectoryRoot)) {
        New-Item -ItemType Directory -Force -Path $buildDirectoryRoot
    }

    Write-Host "Building Windows binaries for $Arch (using Clang + Ninja) with cuda: $Cuda"


    $platform = Get-MSBuildPlatform $Arch
    if ([string]::IsNullOrEmpty($platform)) {
        Write-Host "Unknown architecture $Arch"
        return
    }

    $buildDirectory = "$buildDirectoryRoot/win-$Arch"
    $options = @("-S", $scriptDirectory)
    $options += @("-G", "Visual Studio 17 2022")

    $avxOptions = @("-DGGML_AVX=ON", "-DGGML_AVX2=ON", "-DGGML_FMA=ON", "-DGGML_F16C=ON")

    if ($NoAvx) {
        $avxOptions = @("-DGGML_AVX=OFF", "-DGGML_AVX2=OFF", "-DGGML_FMA=OFF", "-DGGML_F16C=OFF")
        $buildDirectory += "-noavx"
        $runtimePath += ".NoAvx"
    }

    if($Arch -eq "arm64") {
        $options += "-G"
        $options += "Ninja Multi-Config"
        $options += "-DCMAKE_TOOLCHAIN_FILE=cmake/$Arch-windows-llvm.cmake"
    }
    else {
        $platform = Get-MSBuildPlatform $Arch
        $options += "-A"
        $options += $platform

        # Add AVX flags
        $options += $avxOptions

        if ($platform -eq "Win32")
        {
            $options += "-DGGML_BMI2=OFF";
        }
    }

    if ($Cuda) {
        $options += "-DGGML_CUDA=1"
        $buildDirectory += "-cuda"
        $runtimePath += ".Cuda.Windows"
    }

    if ($Vulkan) {
        $options += "-DGGML_VULKAN=1"
        $options += "-DGGML_VULKAN_COOPMAT_GLSLC_SUPPORT=ON"
        $buildDirectory += "-vulkan"
        $runtimePath += ".Vulkan"
    }

    if ($OpenVino) {
        $options += "-DWHISPER_OPENVINO=1"
        $buildDirectory += "-openvino"
        $runtimePath += ".OpenVino"
    }


    # Specify the out-of-source build directory
    $options += "-B"
    $options += $buildDirectory

    if ((Test-Path $buildDirectory)) {
        Write-Host "Deleting old build files for $buildDirectory";
        Remove-Item -Force -Recurse -Path $buildDirectory | out-null
    }

    # Ensure CMake is available. This part is optional if you already have cmake in your PATH.
    $cmakePath = (Get-Command cmake -ErrorAction SilentlyContinue).Source
    if ([string]::IsNullOrEmpty($cmakePath)) {
        # Attempt to locate CMake in Visual Studio
        $visualStudioPath = Get-VisualStudioCMakePath
        if ([string]::IsNullOrEmpty($visualStudioPath)) {
            Write-Host "CMake is not found in the system or Visual Studio."
            return
        }
        $env:Path += ";$visualStudioPath"
    }

    New-Item -ItemType Directory -Force -Path $buildDirectory | out-null

    # call CMake to generate the makefiles
    Write-Host "Configuring CMake. 'cmake $options'"
    cmake $options

    Write-Host "Running CMake build..."
    cmake --build $buildDirectory --config $Configuration

    $runtimePath = "./Whisper.net.Runtime"
    if ($Cublas) {
        $runtimePath += ".Cublas"
    }
    if ($Clblast) {
        $runtimePath += ".Clblast"
    }

    if (-not(Test-Path $runtimePath)) {
        New-Item -ItemType Directory -Force -Path $runtimePath
    }
    $runtimePath += "/win-$Arch"

    if (-not(Test-Path $runtimePath)) {
        New-Item -ItemType Directory -Force -Path $runtimePath
    }

    # Copy the generated DLLs (assuming same folder structure/names)
    Move-Item "$buildDirectory/bin/Release/whisper.dll" "$runtimePath/whisper.dll" -Force
    Move-Item "$buildDirectory/bin/Release/ggml-whisper.dll" "$runtimePath/ggml-whisper.dll" -Force
    Move-Item "$buildDirectory/bin/Release/ggml-base-whisper.dll" "$runtimePath/ggml-base-whisper.dll" -Force
    Move-Item "$buildDirectory/bin/Release/ggml-cpu-whisper.dll" "$runtimePath/ggml-cpu-whisper.dll" -Force

    if ($Cuda) {
        Move-Item "$buildDirectory/bin/Release/ggml-cuda-whisper.dll" "$runtimePath/ggml-cuda-whisper.dll" -Force
    }

    if ($Vulkan) {
        Move-Item "$buildDirectory/bin/Release/ggml-vulkan-whisper.dll" "$runtimePath/ggml-vulkan-whisper.dll" -Force
    }
}

function BuildWindowsArm([Parameter(Mandatory = $false)] [string]$Configuration = "Release") {
    BuildWindows -Arch "arm64" -Configuration $Configuration
}

function BuildWindowsIntel([Parameter(Mandatory = $false)] [string]$Configuration = "Release") {
    BuildWindows -Arch "x64" -Configuration $Configuration
    BuildWindows -Arch "x86" -Configuration $Configuration
}

function BuildWindowsAll([Parameter(Mandatory = $false)] [string]$Configuration = "Release") {
    BuildWindowsBase -Arch "x64" -Configuration $Configuration;
    BuildWindowsBase -Arch "x86" -Configuration $Configuration;
    BuildWindowsBase -Arch "arm64" -Configuration $Configuration;
    BuildWindowsBase -Arch "arm" -Configuration $Configuration;
    BuildWindowsBase -Arch "x64" -Cublas $true -Configuration $Configuration;
    BuildWindowsBase -Arch "x64" -Clblast $true -Configuration $Configuration;
}

BuildWindowsAll
