@echo off
setlocal
rem Run in a Visual Studio 2022 x64 developer shell.
rem Arguments: path to libvterm checkout, directory containing nlohmann json.hpp
if "%~2"=="" (
  echo Usage: build.cmd libvterm-directory json-single-header-directory
  exit /b 1
)
set "vtermDir=%~f1"
set "jsonDir=%~f2"
if not exist "%vtermDir%\include\vterm.h" exit /b 2
if not exist "%jsonDir%\json.hpp" exit /b 2
if not exist "%~dp0build" mkdir "%~dp0build" || exit /b 3
pushd "%~dp0build" || exit /b 3
cl /nologo /c /std:c11 /O2 /MD /I"%vtermDir%\include" "%vtermDir%\src\*.c" || exit /b 4
lib /nologo /out:vterm.lib encoding.obj keyboard.obj mouse.obj parser.obj pen.obj screen.obj state.obj unicode.obj vterm.obj || exit /b 5
cl /nologo /std:c++17 /utf-8 /DUNICODE /D_UNICODE /O2 /MD /EHsc /I"%vtermDir%\include" /I"%jsonDir%" /c "%~dp0host.cpp" || exit /b 6
link /nologo host.obj vterm.lib ws2_32.lib user32.lib gdi32.lib gdiplus.lib ole32.lib comdlg32.lib /OUT:"%~dp0omp-terminal-quiet.exe" /SUBSYSTEM:WINDOWS /ENTRY:mainCRTStartup || exit /b 6
link /nologo host.obj vterm.lib ws2_32.lib user32.lib gdi32.lib gdiplus.lib ole32.lib comdlg32.lib /OUT:"%~dp0omp-terminal-worker.exe" /SUBSYSTEM:CONSOLE || exit /b 6
popd
