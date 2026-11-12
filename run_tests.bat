@echo off
rem One-click self test (needs Godot 4.7). Set GODOT_EXE if not in a default path.
setlocal
set SCRIPT=%~dp0tools\run_tests.ps1
powershell -NoProfile -ExecutionPolicy Bypass -File "%SCRIPT%"
if errorlevel 1 (
    echo.
    echo Some tests FAILED.
) else (
    echo.
    echo All tests passed.
)
pause
