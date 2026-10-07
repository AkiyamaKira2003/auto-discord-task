@echo off
title Audisk Quests - Vencord auto-update edition
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0install-autoupdate.ps1" %*
