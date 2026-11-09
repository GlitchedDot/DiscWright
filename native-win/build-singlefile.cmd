@echo off
setlocal
rem DiscWright Windows app - native single-file publish (v33).
rem
rem Usage (cmd or PowerShell, from anywhere):
rem   build-singlefile.cmd
rem Publishes the WinUI 3 app as ONE file -
rem DiscWright-singlefile.exe next to this script - using
rem Microsoft's own PublishSingleFile for unpackaged
rem self-contained WinUI 3 apps (supported since Windows
rem App SDK 1.5; the build target
rem WindowsAppSDKSingleFileVerifyConfiguration checks the
rem configuration as it goes). The exe is not zero-file at
rem runtime: it extracts its dependencies to a temp dir at
rem first launch and runs from there.
rem
rem This is an ALTERNATIVE to build-app.cmd, not a
rem replacement: build-app.cmd (v32) builds the runnable
rem folder AND wraps it in DiscWright-standalone.exe via the
rem custom launcher - also one double-clickable file. Both
rem routes stand on their own; build-app.cmd is UNTOUCHED by
rem this script and remains the fallback if the native
rem publish misbehaves on a given machine.
rem
rem This script layers on the SAME prepared encoder tools
rem build-app.cmd's tools stage produces under tools\ - it
rem does NOT prepare them itself. Run build-app.cmd once
rem first; if tools\ffmpeg.exe, tools\atracdenc.exe or
rem tools\sndfile.dll is missing, this script stops and says
rem so before anything is built.
rem Every path is quoted: build folders may contain spaces.

set "ROOT=%~dp0"

rem Build with Visual Studio's MSBuild, NOT the "dotnet"
rem command: the Windows App SDK's PRI/AppX build tasks
rem (Microsoft.Build.Packaging.Pri.Tasks.dll,
rem Microsoft.Build.AppxPackage.dll) ship with Visual Studio's
rem MSBuild only, never with the standalone .NET SDK, and a
rem publish driven from the SDK's own MSBuild dies with
rem MSB4062 looking for them under the SDK's folders. VS's
rem MSBuild finds them in its own folders natively.
rem (Same rule as build-app.cmd, switched 2026-11-06, v20.)
set "MSBUILD="
if exist "C:\Program Files\Microsoft Visual Studio\2022\Community\MSBuild\Current\Bin\MSBuild.exe" set "MSBUILD=C:\Program Files\Microsoft Visual Studio\2022\Community\MSBuild\Current\Bin\MSBuild.exe"
if not defined MSBUILD if exist "C:\Program Files\Microsoft Visual Studio\2022\Professional\MSBuild\Current\Bin\MSBuild.exe" set "MSBUILD=C:\Program Files\Microsoft Visual Studio\2022\Professional\MSBuild\Current\Bin\MSBuild.exe"
if not defined MSBUILD if exist "C:\Program Files\Microsoft Visual Studio\2022\Enterprise\MSBuild\Current\Bin\MSBuild.exe" set "MSBUILD=C:\Program Files\Microsoft Visual Studio\2022\Enterprise\MSBuild\Current\Bin\MSBuild.exe"
if not defined MSBUILD if exist "C:\Program Files (x86)\Microsoft Visual Studio\2022\BuildTools\MSBuild\Current\Bin\MSBuild.exe" set "MSBUILD=C:\Program Files (x86)\Microsoft Visual Studio\2022\BuildTools\MSBuild\Current\Bin\MSBuild.exe"
if not defined MSBUILD (
    echo Visual Studio 2022 MSBuild not found.
    echo Install Visual Studio 2022 Community ^(free^) with the
    echo "WinUI application development" workload, e.g.:
    echo     winget install Microsoft.VisualStudio.2022.Community
    echo then close this window, open a new one, and run this script again.
    exit /b 1
)

rem ============================================================
rem The encoder tools, checked BEFORE MSBuild: the v33
rem csproj items link these three files from tools\ into the
rem publish as loose content (the app's EncodeService looks
rem for them under ^<base^>\tools\ at runtime). If they are
rem not project content, the single-file bundle silently
rem omits them and every encode fails "ffmpeg was not
rem found" - so their absence stops the publish here, with
rem the fix named, instead of shipping a quietly broken exe.
rem build-app.cmd's tools stage prepares all three.
rem ============================================================
set "TOOLS=%ROOT%tools"
set "TOOLS_MISSING="
if not exist "%TOOLS%\ffmpeg.exe" set "TOOLS_MISSING=1"
if not exist "%TOOLS%\atracdenc.exe" set "TOOLS_MISSING=1"
if not exist "%TOOLS%\sndfile.dll" set "TOOLS_MISSING=1"
if defined TOOLS_MISSING (
    echo The encoder tools are not all prepared under "%TOOLS%":
    if not exist "%TOOLS%\ffmpeg.exe" echo     missing: "%TOOLS%\ffmpeg.exe"
    if not exist "%TOOLS%\atracdenc.exe" echo     missing: "%TOOLS%\atracdenc.exe"
    if not exist "%TOOLS%\sndfile.dll" echo     missing: "%TOOLS%\sndfile.dll"
    echo Run build-app.cmd once first, then run this again.
    echo Nothing was published.
    exit /b 1
)

set "DOTNET_CLI_TELEMETRY_OPTOUT=1"
set "DOTNET_NOLOGO=1"

echo Publishing WrightDisc as a native single file (Release, x64) with VS MSBuild...
"%MSBUILD%" "%ROOT%app\DiscWright.csproj" /restore /t:Publish /p:Configuration=Release /p:Platform=x64 /p:DiscWrightSingleFile=true /p:PublishDir="%ROOT%SingleFile\\" /nologo /v:m
if errorlevel 1 (
    echo PUBLISH FAILED - see the errors above.
    exit /b 1
)

rem "Publish succeeded" is not "shippable" until the
rem DELIVERABLE is checked (the v20 lesson: a build once
rem reported success while the copied folder held two .mui
rem stubs and no app). The publish folder must hold the exe;
rem its size and the folder's file count are reported, not
rem assumed - for a true single-file publish the count is a
rem handful: the exe itself plus the loose content the
rem self-extract configuration carries beside it (the three
rem tools\ items among them). The count is echoed for the
rem record; it does not gate the ship.
set "PUB=%ROOT%SingleFile"
if not exist "%PUB%\DiscWright.exe" (
    echo Publish reported success but DiscWright.exe was not found at "%PUB%\DiscWright.exe".
    echo Do not ship this build.
    exit /b 1
)
set "SZ=0"
for %%F in ("%PUB%\DiscWright.exe") do set "SZ=%%~zF"
echo DiscWright.exe: %SZ% bytes.
set "SFCOUNT=0"
for /f %%N in ('dir /b /a-d "%PUB%" 2^>nul ^| find /c /v ""') do set "SFCOUNT=%%N"
echo Files beside it in "%PUB%": %SFCOUNT% ^(the exe itself plus loose content; the tools ride in "%PUB%\tools"^).

copy /y "%PUB%\DiscWright.exe" "%ROOT%DiscWright-singlefile.exe" >nul
if errorlevel 1 (
    echo Copying the published exe to "%ROOT%DiscWright-singlefile.exe" FAILED.
    exit /b 1
)
if not exist "%ROOT%DiscWright-singlefile.exe" (
    echo The copy reported success but "%ROOT%DiscWright-singlefile.exe" is not there.
    echo Do not ship this build.
    exit /b 1
)

echo.
echo PUBLISH SUCCEEDED.
echo Single file: "%ROOT%DiscWright-singlefile.exe"
echo First launch extracts its dependencies to a temp dir and may take a moment; later launches reuse the extraction.
echo If this exe misbehaves, build-app.cmd's DiscWright-standalone.exe is the fallback - nothing here changes it.
exit /b 0
