@echo off
chcp 65001 >nul
setlocal
set PY=C:\Users\12980\.dsh\dsh-runtimes\dsh-primary-runtime\dependencies\python\python.exe
if not exist "%PY%" set PY=python
"%PY%" -X utf8 "%~dp0..\tools\map\config_compile.py"
echo.
pause
