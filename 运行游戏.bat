@echo off
rem QinMo 209BC - run the game directly, no editor.
rem Change GODOT if your Godot path differs.
set GODOT=C:\Program Files (x86)\Steam\steamapps\common\Godot Engine\godot.windows.opt.tools.64.exe

if not exist "%GODOT%" goto nogodot
if not exist "%~dp0godot\project.godot" goto noproject

start "" "%GODOT%" --path "%~dp0godot" res://scenes/main.tscn
exit /b 0

:nogodot
echo [ERROR] Godot not found:
echo   %GODOT%
pause
exit /b 1

:noproject
echo [ERROR] project not found:
echo   %~dp0godot
pause
exit /b 1
