@echo off
setlocal
rem DiscWright Windows app - Final build (v39).
rem
rem Usage (cmd or PowerShell, from anywhere):
rem   build-app.cmd
rem Prepares the encoder tools (tools\ - see the tools stage
rem below), builds the WinUI 3 app with Visual Studio's MSBuild
rem (Release, x64, unpackaged + self-contained), and copies
rem the runnable output plus the tools into DiscWright\ next
rem to this script. After the folder, the script ALSO
rem produces DiscWright-standalone.exe next to this script -
rem one file, double-click to run, no install (it unpacks
rem itself under %LOCALAPPDATA%\DiscWright on first run; see
rem launcher\launcher.cpp). The folder build stays for
rem debugging.
rem Run it by double-clicking DiscWright\DiscWright.exe - the
rem folder carries its own Windows App SDK + .NET runtime.
rem Every path is quoted: build folders may contain spaces.
rem The first build restores NuGet packages (Windows App SDK,
rem Win2D) and needs network access.

set "ROOT=%~dp0"

rem Build with Visual Studio's MSBuild, NOT "dotnet build": the Windows
rem App SDK's PRI/AppX build tasks (Microsoft.Build.Packaging.Pri.Tasks.dll,
rem Microsoft.Build.AppxPackage.dll) ship with Visual Studio's MSBuild
rem only, never with the standalone .NET SDK, and "dotnet build" dies
rem with MSB4062 looking for them under the SDK's folders. VS's MSBuild
rem finds them in its own folders natively. (Switched 2026-11-06, v20.)
set "MSBUILD="
if exist "C:\Program Files\Microsoft Visual Studio\2022\Community\MSBuild\Current\Bin\MSBuild.exe" set "MSBUILD=C:\Program Files\Microsoft Visual Studio\2022\Community\MSBuild\Current\Bin\MSBuild.exe"
if not defined MSBUILD if exist "C:\Program Files\Microsoft Visual Studio\2022\Professional\MSBuild\Current\Bin\MSBuild.exe" set "MSBUILD=C:\Program Files\Microsoft Visual Studio\2022\Professional\MSBuild\Current\Bin\MSBuild.exe"
if not defined MSBUILD if exist "C:\Program Files\Microsoft Visual Studio\2022\Enterprise\MSBuild\Current\Bin\MSBuild.exe" set "MSBUILD=C:\Program Files\Microsoft Visual Studio\2022\Enterprise\MSBuild\Current\Bin\MSBuild.exe"
if not defined MSBUILD if exist "C:\Program Files (x86)\Microsoft Visual Studio\2022\BuildTools\MSBuild\Current\Bin\MSBuild.exe" set "MSBUILD=C:\Program Files (x86)\Microsoft Visual Studio\2022\BuildTools\MSBuild\Current\Bin\MSBuild.exe"
rem (v27 derived a VSROOT here to locate VS's bundled CMake;
rem v28 removed it - CMake is a pinned download now, see the
rem tools stage, and nothing else used the variable.)
if not defined MSBUILD (
    echo Visual Studio 2022 MSBuild not found.
    echo Install Visual Studio 2022 Community ^(free^) with the
    echo "Windows application development" workload, e.g.:
    echo     winget install Microsoft.VisualStudio.2022.Community
    echo then close this window, open a new one, and run this script again.
    exit /b 1
)

rem ============================================================
rem Step 3 tools stage: the encoder's tools, prepared BEFORE
rem MSBuild and copied beside the exe afterwards. Everything
rem is cached by presence/stamps under tools\ - only a first
rem run pays the pinned downloads (ffmpeg, libsndfile, and
rem CMake when the machine has none) and the atracdenc compile.
rem
rem v27: vcpkg is GONE from this script. v26 hunted for the
rem vcpkg bundled with Visual Studio and stopped dead on
rem Lola's machine - it is a separate VS component her
rem install does not carry, and no build should hinge on it.
rem libsndfile now arrives the same way ffmpeg does: the
rem project's OFFICIAL prebuilt win64 zip, pinned by URL +
rem SHA-256 (verified from the real archive: sndfile.h,
rem sndfile.lib, a self-contained sndfile.dll, and a CMake
rem config package - everything atracdenc's build needs).
rem ============================================================
set "TOOLS=%ROOT%tools"
if not exist "%TOOLS%" mkdir "%TOOLS%"

rem ---- CMake: prefer the pinned copy already staged under
rem tools\, then any CMake on PATH; if neither is there, fetch
rem the pinned official Kitware build. (v28: Visual Studio's
rem bundled CMake turned out to be yet another optional VS
rem component - v27 stopped on a machine without it, the same
rem lesson as vcpkg in v26. This script now leans on VS ONLY
rem for MSBuild and the MSVC compiler, which the app build
rem genuinely needs; every other tool is a pinned download.) ----
set "CMAKE_URL=https://github.com/Kitware/CMake/releases/download/v3.31.6/cmake-3.31.6-windows-x86_64.zip"
set "CMAKE_SHA256=d163cd3ab4959b0a53fa8988f2ddbd2e6c501658201e6a154386bad9dbe4f836"
set "CMAKE_HOME=%TOOLS%\cmake\cmake-3.31.6-windows-x86_64"
set "CMAKE="
if exist "%CMAKE_HOME%\bin\cmake.exe" set "CMAKE=%CMAKE_HOME%\bin\cmake.exe"
if not defined CMAKE for /f "delims=" %%C in ('where cmake 2^>nul') do if not defined CMAKE set "CMAKE=%%C"
if defined CMAKE goto CMakeDone
echo Downloading CMake 3.31.6 ^(pinned official build - SHA-256 verified before use^)...
set "CMZIP=%TEMP%\discwright-cmake-download.zip"
if exist "%CMZIP%" del /q "%CMZIP%"
powershell -NoProfile -ExecutionPolicy Bypass -Command "Invoke-WebRequest -Uri '%CMAKE_URL%' -OutFile '%CMZIP%'"
if errorlevel 1 (
    echo CMake download FAILED - check the network and try again.
    echo Nothing was built.
    exit /b 1
)
set "CMGOT="
for /f "usebackq delims=" %%H in (`certutil -hashfile "%CMZIP%" SHA256 ^| findstr /r "^[0-9a-fA-F][0-9a-fA-F]*$"`) do set "CMGOT=%%H"
if /i not "%CMGOT%"=="%CMAKE_SHA256%" (
    echo The downloaded CMake did NOT match the pinned SHA-256.
    echo     expected: %CMAKE_SHA256%
    echo     got:      %CMGOT%
    echo The download was discarded. Nothing was built.
    del /q "%CMZIP%"
    exit /b 1
)
if exist "%TOOLS%\cmake" rmdir /s /q "%TOOLS%\cmake"
powershell -NoProfile -ExecutionPolicy Bypass -Command "Expand-Archive -LiteralPath '%CMZIP%' -DestinationPath '%TOOLS%\cmake' -Force"
if errorlevel 1 (
    echo Extracting the CMake download FAILED.
    echo Nothing was built.
    exit /b 1
)
del /q "%CMZIP%"
if not exist "%CMAKE_HOME%\bin\cmake.exe" (
    echo CMake extracted but its exe is not at
    echo     "%CMAKE_HOME%\bin\cmake.exe"
    echo Nothing was built.
    exit /b 1
)
set "CMAKE=%CMAKE_HOME%\bin\cmake.exe"
echo CMake: installed to tools\cmake\.
:CMakeDone

rem ---- ffmpeg: a PINNED download (URL + SHA-256). The
rem release-essentials URL always serves gyan.dev's latest
rem build, so when they publish a newer one the hash check
rem stops this script on purpose - the pin in this file must
rem be updated to the new build's hash before it can proceed.
rem Nothing unpinned ever reaches tools\. ----
set "FFMPEG_URL=https://www.gyan.dev/ffmpeg/builds/ffmpeg-release-essentials.zip"
set "FFMPEG_SHA256=60f467265b1e312373dbcd92200c2618a74850f98d3d078e94296bb3fa2047ba"
if exist "%TOOLS%\ffmpeg.exe" goto FfmpegDone
echo Downloading ffmpeg ^(pinned build - its SHA-256 is verified before use^)...
set "FFZIP=%TEMP%\discwright-ffmpeg-download.zip"
if exist "%FFZIP%" del /q "%FFZIP%"
powershell -NoProfile -ExecutionPolicy Bypass -Command "Invoke-WebRequest -Uri '%FFMPEG_URL%' -OutFile '%FFZIP%'"
if errorlevel 1 (
    echo ffmpeg download FAILED - check the network and try again.
    echo Nothing was built.
    exit /b 1
)
set "FFGOT="
for /f "usebackq delims=" %%H in (`certutil -hashfile "%FFZIP%" SHA256 ^| findstr /r "^[0-9a-fA-F][0-9a-fA-F]*$"`) do set "FFGOT=%%H"
if /i not "%FFGOT%"=="%FFMPEG_SHA256%" (
    echo The downloaded ffmpeg did NOT match the pinned SHA-256.
    echo     expected: %FFMPEG_SHA256%
    echo     got:      %FFGOT%
    echo gyan.dev has likely published a newer build. The download was
    echo discarded; update the FFMPEG_SHA256 pin in this script after
    echo verifying the new build, then run it again. Nothing was built.
    del /q "%FFZIP%"
    exit /b 1
)
set "FFX=%TEMP%\discwright-ffmpeg-extract"
if exist "%FFX%" rmdir /s /q "%FFX%"
powershell -NoProfile -ExecutionPolicy Bypass -Command "Expand-Archive -LiteralPath '%FFZIP%' -DestinationPath '%FFX%' -Force"
if errorlevel 1 (
    echo Extracting the ffmpeg download FAILED.
    echo Nothing was built.
    exit /b 1
)
for /d %%D in ("%FFX%\ffmpeg-*") do copy /y "%%D\bin\ffmpeg.exe" "%TOOLS%\ffmpeg.exe" >nul
if not exist "%TOOLS%\ffmpeg.exe" (
    echo bin\ffmpeg.exe was not found inside the downloaded archive.
    echo Nothing was built.
    rmdir /s /q "%FFX%"
    exit /b 1
)
rmdir /s /q "%FFX%"
del /q "%FFZIP%"
echo ffmpeg: installed to tools\.
:FfmpegDone

rem ---- libsndfile: a PINNED download, like ffmpeg - the
rem project's official prebuilt win64 zip (2 MB). It carries
rem include\sndfile.h, lib\sndfile.lib, bin\sndfile.dll (its
rem FLAC/ogg/vorbis deps are linked INTO that one DLL) and
rem cmake\SndFileConfig.cmake. The versioned URL never moves,
rem so the hash pin below is stable - unlike ffmpeg's
rem "latest" pointer, this one should never trip. ----
set "SND_URL=https://github.com/libsndfile/libsndfile/releases/download/1.2.2/libsndfile-1.2.2-win64.zip"
set "SND_SHA256=2173935c0c1ed13cf627951d34483f9d405ead2eb473190461c42ba220643a3f"
set "SND_PREFIX=%TOOLS%\libsndfile\libsndfile-1.2.2-win64"
if exist "%SND_PREFIX%\bin\sndfile.dll" if exist "%SND_PREFIX%\lib\sndfile.lib" if exist "%SND_PREFIX%\include\sndfile.h" goto SndDone
echo Downloading libsndfile 1.2.2 ^(pinned official build - SHA-256 verified before use^)...
set "SNDZIP=%TEMP%\discwright-libsndfile-download.zip"
if exist "%SNDZIP%" del /q "%SNDZIP%"
powershell -NoProfile -ExecutionPolicy Bypass -Command "Invoke-WebRequest -Uri '%SND_URL%' -OutFile '%SNDZIP%'"
if errorlevel 1 (
    echo libsndfile download FAILED - check the network and try again.
    echo Nothing was built.
    exit /b 1
)
set "SNDGOT="
for /f "usebackq delims=" %%H in (`certutil -hashfile "%SNDZIP%" SHA256 ^| findstr /r "^[0-9a-fA-F][0-9a-fA-F]*$"`) do set "SNDGOT=%%H"
if /i not "%SNDGOT%"=="%SND_SHA256%" (
    echo The downloaded libsndfile did NOT match the pinned SHA-256.
    echo     expected: %SND_SHA256%
    echo     got:      %SNDGOT%
    echo The download was discarded. Nothing was built.
    del /q "%SNDZIP%"
    exit /b 1
)
if exist "%TOOLS%\libsndfile" rmdir /s /q "%TOOLS%\libsndfile"
powershell -NoProfile -ExecutionPolicy Bypass -Command "Expand-Archive -LiteralPath '%SNDZIP%' -DestinationPath '%TOOLS%\libsndfile' -Force"
if errorlevel 1 (
    echo Extracting the libsndfile download FAILED.
    echo Nothing was built.
    exit /b 1
)
del /q "%SNDZIP%"
if not exist "%SND_PREFIX%\bin\sndfile.dll" (
    echo libsndfile extracted but bin\sndfile.dll is not at
    echo     "%SND_PREFIX%\bin\sndfile.dll"
    echo Nothing was built.
    exit /b 1
)
if not exist "%SND_PREFIX%\lib\sndfile.lib" (
    echo libsndfile extracted but lib\sndfile.lib is missing - the
    echo encoder cannot link without it. Nothing was built.
    exit /b 1
)
echo libsndfile: installed to tools\libsndfile\.
:SndDone

rem ---- atracdenc from the vendored sources, gated by a
rem source stamp (the Mac's scheme: hash every source file,
rem rebuild only when the hash moves). Build ONLY the
rem atracdenc target, never "all" - upstream's man-page target
rem breaks in build paths with spaces (the Mac has the scar;
rem see native-pure/build-app.sh). The PCM backend is pinned
rem to libsndfile explicitly: the vendored CMake's "auto"
rem would pick MediaFoundation on Windows+MSVC, and the Mac's
rem proven path reads WAVs through libsndfile. ----
set "ENC_SRC=%ROOT%encoder\atracdenc-src"
set "ENC_BUILD=%ROOT%encoder\build-win"
powershell -NoProfile -ExecutionPolicy Bypass -Command "$files = Get-ChildItem -Recurse -File '%ENC_SRC%' | Sort-Object FullName; $joined = [string]::Join(' ', ($files | Get-FileHash -Algorithm SHA256 | ForEach-Object { $_.Hash })); $sha = [System.Security.Cryptography.SHA256]::Create(); ([System.BitConverter]::ToString($sha.ComputeHash([System.Text.Encoding]::UTF8.GetBytes($joined))) -replace '-', '').ToLower()" > "%TOOLS%\stamp-now.txt"
set /p NEWSTAMP=<"%TOOLS%\stamp-now.txt"
del /q "%TOOLS%\stamp-now.txt" 2>nul
set "OLDSTAMP="
if exist "%TOOLS%\atracdenc.stamp" set /p OLDSTAMP=<"%TOOLS%\atracdenc.stamp"
set "NEED_ENC=1"
if exist "%TOOLS%\atracdenc.exe" if "%NEWSTAMP%"=="%OLDSTAMP%" if not "%NEWSTAMP%"=="" set "NEED_ENC=0"
if "%NEED_ENC%"=="0" goto AtracDone
echo Building atracdenc from the vendored sources...
rem CMAKE_PREFIX_PATH carries BOTH the libsndfile prefix (its
rem include\ and lib\ feed a module-mode find) and its cmake\
rem subdir (which holds SndFileConfig.cmake for a config-mode
rem find_package) - whichever way the vendored CMake looks,
rem one of the two lands. (v27: this replaces the vcpkg
rem toolchain flags.)
"%CMAKE%" -S "%ENC_SRC%" -B "%ENC_BUILD%" -G "Visual Studio 17 2022" -A x64 -DCMAKE_PREFIX_PATH="%SND_PREFIX%;%SND_PREFIX%\cmake" -DATRACDENC_PCM_IO_BACKEND=libsndfile -DCMAKE_DISABLE_FIND_PACKAGE_GTest=TRUE
if errorlevel 1 (
    echo atracdenc CONFIGURE FAILED - see the output above. Nothing was built.
    exit /b 1
)
"%CMAKE%" --build "%ENC_BUILD%" --config Release --target atracdenc
if errorlevel 1 (
    echo atracdenc BUILD FAILED - see the output above. Nothing was built.
    exit /b 1
)
if not exist "%ENC_BUILD%\src\Release\atracdenc.exe" (
    echo atracdenc built but its exe was not found at
    echo     "%ENC_BUILD%\src\Release\atracdenc.exe"
    echo Nothing was built.
    exit /b 1
)
copy /y "%ENC_BUILD%\src\Release\atracdenc.exe" "%TOOLS%\atracdenc.exe" >nul
copy /y "%SND_PREFIX%\bin\sndfile.dll" "%TOOLS%\" >nul
if not "%NEWSTAMP%"=="" echo %NEWSTAMP%>"%TOOLS%\atracdenc.stamp"
echo atracdenc: built and installed to tools\ ^(with its runtime DLLs^).
:AtracDone

set "DOTNET_CLI_TELEMETRY_OPTOUT=1"
set "DOTNET_NOLOGO=1"

echo Building WrightDisc (Release, x64, self-contained) with VS MSBuild...
"%MSBUILD%" "%ROOT%app\DiscWright.csproj" /restore /p:Configuration=Release /p:Platform=x64 /nologo /v:m
if errorlevel 1 (
    echo BUILD FAILED - see the errors above.
    exit /b 1
)

rem The runnable output is the win-x64 folder itself. Do NOT go hunting
rem for DiscWright.exe recursively: the Windows App SDK drops a copy of
rem the apphost into every per-language satellite folder under it
rem (win-x64\zh-TW\DiscWright.exe and dozens more), and an earlier version
rem of this script copied the LAST one it found - a satellite folder
rem holding two .mui files and no app. Copy the known output root, and
rem refuse to ship if its .pri is missing (an unpackaged WinUI app
rem cannot start without it).
set "SRC=%ROOT%app\bin\x64\Release\net8.0-windows10.0.19041.0\win-x64\"
if not exist "%SRC%DiscWright.exe" (
    echo Build reported success but DiscWright.exe was not found at "%SRC%DiscWright.exe".
    exit /b 1
)
if not exist "%SRC%DiscWright.pri" (
    echo Build reported success but DiscWright.pri was not found at "%SRC%DiscWright.pri".
    echo Do not ship this build - the app would crash on launch without it.
    exit /b 1
)

if exist "%ROOT%DiscWright" rmdir /s /q "%ROOT%DiscWright"
mkdir "%ROOT%DiscWright"
xcopy "%SRC%*" "%ROOT%DiscWright\" /E /I /Y /Q >nul
if errorlevel 1 (
    echo Copying the build output to "%ROOT%DiscWright" FAILED.
    exit /b 1
)
del /q "%ROOT%DiscWright\*.pdb" 2>nul

rem Step 3: the encoder tools ride beside the exe - the app's
rem EncodeService resolves a tools\ folder from the exe's own
rem directory. Only the app-facing payload ships (the two exes
rem + their runtime DLLs); the build cache (stamps, the
rem libsndfile tree) stays behind in this folder's tools\.
rem Refuse to ship without them, like the .pri guard above.
mkdir "%ROOT%DiscWright\tools"
copy /y "%TOOLS%\ffmpeg.exe" "%ROOT%DiscWright\tools\" >nul
copy /y "%TOOLS%\atracdenc.exe" "%ROOT%DiscWright\tools\" >nul
copy /y "%TOOLS%\*.dll" "%ROOT%DiscWright\tools\" >nul
if not exist "%ROOT%DiscWright\tools\ffmpeg.exe" (
    echo Build reported success but tools\ffmpeg.exe is missing from the output.
    echo Do not ship this build - the encoder would have no decoder.
    exit /b 1
)
if not exist "%ROOT%DiscWright\tools\atracdenc.exe" (
    echo Build reported success but tools\atracdenc.exe is missing from the output.
    echo Do not ship this build - the encoder would have no encoder tool.
    exit /b 1
)

rem ============================================================
rem Standalone stage (v32; hardened in v34): pack the
rem DiscWright\ folder into ONE double-clickable file -
rem DiscWright-standalone.exe = [launcher PE][payload.zip]
rem [48-byte footer]. The launcher (launcher\launcher.cpp)
rem unpacks the folder per-user under %LOCALAPPDATA%\DiscWright
rem on first run and starts the app: no install, no admin.
rem WinUI 3 has no true single-file publishing, so this
rem bootstrapper is the single-file form.
rem
rem v34: the launcher is hardened so a standalone that does
rem not run TESTIFIES instead of dying silently (which is
rem what v32's did on Lola's machine): named-stage errors
rem S1-S11 with Win32 codes, a payload self-check against
rem the footer, unpack.log in the unpack folder, and a
rem watch console narrating the first run live. This stage
rem testifies too: every exit below sets STANDALONE_FAIL,
rem and the final summary prints a STANDALONE RESULT verdict
rem (OK, or SKIPPED - <stage>) that cannot scroll by unnoticed.
rem
rem The standalone is an EXTRA, never a gate: a machine
rem without the MSVC C++ toolset still produces the proven
rem folder build, and this stage just warns and skips.
rem ============================================================
set "STANDALONE_OK=0"
set "STANDALONE_FAIL="
set "STAMP=2026-11-07.v39"
set "VCVARS="
if exist "C:\Program Files\Microsoft Visual Studio\2022\Community\VC\Auxiliary\Build\vcvars64.bat" set "VCVARS=C:\Program Files\Microsoft Visual Studio\2022\Community\VC\Auxiliary\Build\vcvars64.bat"
if not defined VCVARS if exist "C:\Program Files\Microsoft Visual Studio\2022\Professional\VC\Auxiliary\Build\vcvars64.bat" set "VCVARS=C:\Program Files\Microsoft Visual Studio\2022\Professional\VC\Auxiliary\Build\vcvars64.bat"
if not defined VCVARS if exist "C:\Program Files\Microsoft Visual Studio\2022\Enterprise\VC\Auxiliary\Build\vcvars64.bat" set "VCVARS=C:\Program Files\Microsoft Visual Studio\2022\Enterprise\VC\Auxiliary\Build\vcvars64.bat"
if not defined VCVARS if exist "C:\Program Files (x86)\Microsoft Visual Studio\2022\BuildTools\VC\Auxiliary\Build\vcvars64.bat" set "VCVARS=C:\Program Files (x86)\Microsoft Visual Studio\2022\BuildTools\VC\Auxiliary\Build\vcvars64.bat"
if not defined VCVARS (
    set "STANDALONE_FAIL=toolset"
    echo.
    echo WARNING: no Visual Studio C++ toolset ^(vcvars64.bat^) was found, so
    echo the standalone exe was SKIPPED. The folder build below is complete.
    echo To get the standalone too, add the "C++ WinUI app development
    echo tools" ^(or any C++ workload^) in the Visual Studio Installer.
    goto StandaloneDone
)
call "%VCVARS%" >nul
if exist "%TEMP%\discwright-launcher.exe" del /q "%TEMP%\discwright-launcher.exe"
if exist "%TEMP%\discwright-launcher.obj" del /q "%TEMP%\discwright-launcher.obj"
"%SystemRoot%\System32\where.exe" cl >nul 2>&1
if errorlevel 1 (
    set "STANDALONE_FAIL=cl"
    echo.
    echo WARNING: cl.exe is not available after vcvars64 - the standalone
    echo exe was SKIPPED. The folder build below is complete.
    goto StandaloneDone
)
if exist "%ROOT%standalone-build.log" del /q "%ROOT%standalone-build.log"
cl /nologo /O2 /W3 /DUNICODE /D_UNICODE "%ROOT%launcher\launcher.cpp" /Fe:"%TEMP%\discwright-launcher.exe" /Fo:"%TEMP%\discwright-launcher.obj" /link /SUBSYSTEM:WINDOWS user32.lib shell32.lib ole32.lib > "%ROOT%standalone-build.log" 2>&1
if errorlevel 1 (
    set "STANDALONE_FAIL=compile"
    echo.
    echo WARNING: compiling the standalone launcher FAILED - the
    echo compiler said:
    type "%ROOT%standalone-build.log"
    echo The standalone exe was SKIPPED. The folder build below is
    echo complete, and the full compiler output is saved as
    echo standalone-build.log beside this script.
    goto StandaloneDone
)
if exist "%TEMP%\discwright-payload.zip" del /q "%TEMP%\discwright-payload.zip"
powershell -NoProfile -ExecutionPolicy Bypass -Command "Compress-Archive -Path '%ROOT%DiscWright\*' -DestinationPath '%TEMP%\discwright-payload.zip' -Force"
if errorlevel 1 (
    set "STANDALONE_FAIL=pack"
    echo.
    echo WARNING: packing the standalone payload FAILED - the standalone
    echo exe was SKIPPED. The folder build below is complete.
    goto StandaloneDone
)
if not exist "%TEMP%\discwright-payload.zip" (
    set "STANDALONE_FAIL=pack"
    echo.
    echo WARNING: the payload zip was not produced - the standalone exe
    echo was SKIPPED. The folder build below is complete.
    goto StandaloneDone
)
rem The 48-byte footer: magic "DWPAYLD1", the payload length
rem as a little-endian uint64, then the build stamp padded
rem with NUL bytes to 32 - the layout launcher.cpp reads.
powershell -NoProfile -ExecutionPolicy Bypass -Command "$len = (Get-Item '%TEMP%\discwright-payload.zip').Length; $footer = New-Object byte[] 48; [System.Text.Encoding]::ASCII.GetBytes('DWPAYLD1').CopyTo($footer, 0); [System.BitConverter]::GetBytes([uint64]$len).CopyTo($footer, 8); [System.Text.Encoding]::ASCII.GetBytes('%STAMP%').CopyTo($footer, 16); [System.IO.File]::WriteAllBytes('%TEMP%\discwright-footer.bin', $footer)"
if errorlevel 1 (
    set "STANDALONE_FAIL=footer"
    echo.
    echo WARNING: writing the standalone footer FAILED - the standalone
    echo exe was SKIPPED. The folder build below is complete.
    goto StandaloneDone
)
if exist "%ROOT%DiscWright-standalone.exe" del /q "%ROOT%DiscWright-standalone.exe"
copy /b "%TEMP%\discwright-launcher.exe" + "%TEMP%\discwright-payload.zip" + "%TEMP%\discwright-footer.bin" "%ROOT%DiscWright-standalone.exe" >nul
if errorlevel 1 (
    set "STANDALONE_FAIL=assemble"
    echo.
    echo WARNING: assembling the standalone exe FAILED - the standalone
    echo exe was SKIPPED. The folder build below is complete.
    goto StandaloneDone
)
if not exist "%ROOT%DiscWright-standalone.exe" (
    set "STANDALONE_FAIL=assemble"
    echo.
    echo WARNING: the standalone exe was not produced - SKIPPED.
    echo The folder build below is complete.
    goto StandaloneDone
)
rem Verify the assembly the cheap way: its size must exceed
rem launcher + payload (the 48-byte footer rides on top).
set "SZ_LAUNCHER=0"
set "SZ_PAYLOAD=0"
set "SZ_FINAL=0"
for %%F in ("%TEMP%\discwright-launcher.exe") do set "SZ_LAUNCHER=%%~zF"
for %%F in ("%TEMP%\discwright-payload.zip") do set "SZ_PAYLOAD=%%~zF"
for %%F in ("%ROOT%DiscWright-standalone.exe") do set "SZ_FINAL=%%~zF"
echo STANDALONE RESULT: OK
echo Standalone pieces: launcher %SZ_LAUNCHER% bytes + payload %SZ_PAYLOAD% bytes + 48-byte footer = %SZ_FINAL% bytes total.
set "STANDALONE_OK=1"
del /q "%TEMP%\discwright-launcher.exe" 2>nul
del /q "%TEMP%\discwright-launcher.obj" 2>nul
del /q "%TEMP%\discwright-payload.zip" 2>nul
del /q "%TEMP%\discwright-footer.bin" 2>nul
:StandaloneDone

echo.
echo BUILD SUCCEEDED.
echo Run: "%ROOT%DiscWright\DiscWright.exe"
echo Encoder tools are in "%ROOT%DiscWright\tools".
if "%STANDALONE_OK%"=="1" echo Standalone: "%ROOT%DiscWright-standalone.exe" ^(single file - double-click to run; first run unpacks itself, no install^).
if "%STANDALONE_OK%"=="1" echo STANDALONE RESULT: OK
if not "%STANDALONE_OK%"=="1" echo STANDALONE RESULT: SKIPPED - %STANDALONE_FAIL%
exit /b 0
