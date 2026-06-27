@echo off
REM Lanceur (passe par le .vbs pour n'avoir AUCUNE fenetre console).
cd /d "%~dp0"
start "" wscript.exe "%~dp0Start-ArriveeCollab.vbs"
