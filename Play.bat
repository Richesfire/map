@echo off
rem Launch the game. Messages are ASCII on purpose: cmd on zh-CN runs in GBK and
rem would show UTF-8 Chinese as mojibake.
rem   Play.bat            - start the game
rem   Play.bat --check    - only print the resolved Godot / data paths
setlocal enableextensions

if not exist "%~dp0game\data\dem2k.bin" (
    echo [Play] %~dp0game\data\dem2k.bin not found.
    echo        Run from the repo root first:  python tools\get_data.py
    pause
    exit /b 1
)

rem Godot: %GODOT_EXE% wins, then the usual install locations.
rem (a "for ... in (...)" list breaks here: the "(x86)" in the path closes the list)
if not "%GODOT_EXE%"=="" if exist "%GODOT_EXE%" goto run
set "GODOT_EXE="
call :try "C:\Program Files (x86)\Steam\steamapps\common\Godot Engine\godot.windows.opt.tools.64.exe"
call :try "C:\Program Files\Steam\steamapps\common\Godot Engine\godot.windows.opt.tools.64.exe"
call :try "C:\Program Files\Godot\godot.exe"
call :try "C:\Program Files (x86)\Godot\godot.exe"
if "%GODOT_EXE%"=="" goto nogodot

:run
rem NOTE: keep "echo %GODOT_EXE%" out of any ( ) block - the ")" in "(x86)"
rem would close the block early. That is why --check uses goto, not an if-block.
if /i "%~1"=="--check" goto check
start "" "%GODOT_EXE%" --path "%~dp0game" --resolution 1600x900
exit /b 0

:check
echo Godot: %GODOT_EXE%
echo Data : %~dp0game\data
exit /b 0

:nogodot
echo [Play] Godot 4.7 not found. Set GODOT_EXE to your godot.exe path.
pause
exit /b 1

:try
if "%GODOT_EXE%"=="" if exist %1 set "GODOT_EXE=%~1"
goto :eof

