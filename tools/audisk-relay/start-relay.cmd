@echo off
title Audisk Relay
cd /d "%~dp0"
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0audisk-relay.ps1"
pause
