@echo off
title IOI Tools v7.2
cd /d "%~dp0"
start "" powershell.exe -NoProfile -STA -ExecutionPolicy Bypass -WindowStyle Hidden -File "%~dp0Scripts\IOI_GUI_v7.ps1"
exit