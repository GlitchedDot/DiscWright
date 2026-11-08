@echo off
setlocal
rem DiscWright Windows core - Step 1 self-test build and run.
rem
rem Usage (cmd or PowerShell, from anywhere):
rem   build-selftest.cmd [reference-dir]
rem The reference folder defaults to a sibling "reference"
rem folder next to this script's folder (the layout of the
rem delivered zip: DiscWrightWin\ beside reference\).
rem Every path is quoted: build folders may contain spaces.

set "ROOT=%~dp0"
set "REF=%~1"
if "%REF%"=="" set "REF=%ROOT%..\reference"

where dotnet >nul 2>&1
if errorlevel 1 (
    echo .NET 8 SDK not found on PATH.
    echo Install it with:
    echo     winget install Microsoft.DotNet.SDK.8
    echo then close this window, open a new one, and run this script again.
    exit /b 1
)

if not exist "%REF%\fixture.json" (
    echo Reference folder not found or incomplete: "%REF%"
    echo Pass the reference folder explicitly: build-selftest.cmd "C:\path\to\reference"
    exit /b 1
)

set "DOTNET_CLI_TELEMETRY_OPTOUT=1"
set "DOTNET_NOLOGO=1"

echo Building DiscWright.Core + selftest (Release)...
dotnet build -c Release "%ROOT%selftest\DiscWright.SelfTest.csproj"
if errorlevel 1 (
    echo BUILD FAILED - see the errors above.
    exit /b 1
)

echo Running the byte-parity self-test against "%REF%" ...
dotnet "%ROOT%selftest\bin\Release\net8.0\selftest.dll" "%REF%"
set "RC=%ERRORLEVEL%"
if "%RC%"=="0" (
    echo SELF-TEST PASSED: the C# core reproduces the fixture disc byte for byte.
) else (
    echo SELF-TEST FAILED with exit code %RC% - see the output above.
)
exit /b %RC%
