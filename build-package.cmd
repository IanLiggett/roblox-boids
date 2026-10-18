@echo off
setlocal

pushd "%~dp0" || exit /b 1

set "ROJO_EXE=%~dp0.tools\rojo-7.7.1\rojo.exe"
if not exist "%ROJO_EXE%" set "ROJO_EXE=%~dp0..\..\.tools\rojo-7.7.1\rojo.exe"

if not exist "%ROJO_EXE%" (
    where.exe rojo >nul 2>&1
    if errorlevel 1 (
        echo Rojo 7.7.1 was not found. Install it or add it to PATH.
        popd
        exit /b 1
    )
    set "ROJO_EXE=rojo"
)

if not exist "build\" mkdir "build"
if errorlevel 1 (
    echo Could not create the build directory.
    popd
    exit /b 1
)

call "%ROJO_EXE%" build install.project.json --output build\BoidsSystem.rbxm
set "BUILD_EXIT=%ERRORLEVEL%"

popd
exit /b %BUILD_EXIT%
