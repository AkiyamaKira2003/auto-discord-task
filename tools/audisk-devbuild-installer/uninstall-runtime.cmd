@echo off
setlocal
set "AUDISK_ROOT=%~dp0"
powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -Command "$request=Join-Path $env:AUDISK_ROOT '.audisk-uninstall-request.json'; $remove=$false; if(Test-Path -LiteralPath $request){try{$data=Get-Content -LiteralPath $request -Raw|ConvertFrom-Json;$remove=[bool]$data.removeVencord}catch{}}; & (Join-Path $env:AUDISK_ROOT '.audisk-uninstall.ps1') -RemoveVencord:$remove"
exit /b %ERRORLEVEL%
