@echo off
rem Windows build: find a Visual Studio with C++ tools, build with CMake + Ninja, then windeployqt.
rem Usage: build.bat [Qt dir]  (default D:\soft\Qt\6.11.2\msvc2022_64). Keep this file ASCII + CRLF for cmd.exe.
setlocal
set QT_DIR=%~1
if "%QT_DIR%"=="" set QT_DIR=D:\soft\Qt\6.11.2\msvc2022_64
set SRC=%~dp0..\..
for /f "usebackq delims=" %%i in (`"C:\Program Files (x86)\Microsoft Visual Studio\Installer\vswhere.exe" -latest -products * -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath`) do set VS=%%i
echo Using %VS%
call "%VS%\VC\Auxiliary\Build\vcvars64.bat" >nul || exit /b 1
cmake -S "%SRC%" -B "%SRC%\build" -G Ninja -DCMAKE_BUILD_TYPE=Release -DCMAKE_PREFIX_PATH="%QT_DIR%" || exit /b 1
cmake --build "%SRC%\build" || exit /b 1
"%QT_DIR%\bin\windeployqt.exe" --release --no-translations --qmldir "%SRC%\qml" "%SRC%\build\CodexTopQt.exe" || exit /b 1
echo BUILD_OK
