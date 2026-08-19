@echo off
setlocal

rem GoLiveBypass - atalho para quem nao quer mexer no PowerShell.
rem Basta dar dois cliques neste arquivo.
rem
rem O caminho nunca e embutido: %~dp0 e resolvido na hora, entao funciona em pastas com
rem espaco e com acento no nome de usuario.

set "GLB_SCRIPT=%~dp0GoLiveBypass-Installer.ps1"
set "GLB_URL=https://raw.githubusercontent.com/EduardoVasconceloss/GoLiveBypass/main/installer/GoLiveBypass-Installer.ps1"

if not exist "%GLB_SCRIPT%" (
    echo.
    echo   Baixando o instalador...
    powershell -NoProfile -ExecutionPolicy Bypass -Command "[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12; Invoke-WebRequest -UseBasicParsing -Uri $env:GLB_URL -OutFile $env:GLB_SCRIPT"
    if not exist "%GLB_SCRIPT%" (
        echo.
        echo   Nao consegui baixar o instalador. Verifique sua conexao.
        echo.
        pause
        exit /b 1
    )
)

powershell -NoProfile -ExecutionPolicy Bypass -File "%GLB_SCRIPT%" %*

set "GLB_EXIT=%ERRORLEVEL%"
echo.
pause
exit /b %GLB_EXIT%
