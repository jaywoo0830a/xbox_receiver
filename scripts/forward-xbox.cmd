@echo off
rem Convenience wrapper for forward-xbox.ps1 (bypasses execution policy, no profile)
rem Usage:
rem   forward-xbox.cmd                  (attach first Xbox controller to default distro)
rem   forward-xbox.cmd -List            (list only)
rem   forward-xbox.cmd -All -AutoAttach
rem   forward-xbox.cmd -Detach
rem Prefer PowerShell 7 (pwsh) if available, else Windows PowerShell
set "PS=powershell"
where pwsh >nul 2>nul && set "PS=pwsh"
%PS% -NoProfile -ExecutionPolicy Bypass -File "%~dp0forward-xbox.ps1" %*
