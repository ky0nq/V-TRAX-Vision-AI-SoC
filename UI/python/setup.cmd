@echo off
setlocal
cd /d "%~dp0"

if not exist ".venv\Scripts\python.exe" (
    py -3 -m venv ".venv"
    if errorlevel 1 goto :error
)

".venv\Scripts\python.exe" -m pip install -r requirements.txt
if errorlevel 1 goto :error

echo Setup complete. Run run_ui.cmd.
pause
exit /b 0

:error
echo Setup failed. Check Python installation and internet connection.
pause
exit /b 1