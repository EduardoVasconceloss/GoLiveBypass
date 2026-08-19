@echo off
setlocal

rem StreamFix - atalho para quem nao quer mexer no PowerShell.
rem Basta dar dois cliques neste arquivo.
rem
rem O caminho nunca e embutido: %~dp0 e resolvido na hora, entao funciona em pastas com
rem espaco e com acento no nome de usuario.

set "GLB_SCRIPT=%~dp0StreamFix-Installer.ps1"
set "GLB_TMP=%~dp0StreamFix-Installer.ps1.tmp"
rem Fixo num commit especifico, nao "main": evita execucao remota de codigo via um push nao
rem revisado. TEM QUE ser um commit onde o .ps1 baixado ja tenha o RepoRaw dele proprio fixo,
rem senao reabre o mesmo buraco um passo adiante. Bump faz parte de cortar release nova.
rem O path abaixo aponta pro nome que o arquivo tinha naquele commit pinado (GoLiveBypass),
rem nao pro nome atual -- por isso nao muda so por causa deste rename.
set "GLB_URL=https://raw.githubusercontent.com/EduardoVasconceloss/GoLiveBypass/0811e86/installer/GoLiveBypass-Installer.ps1"

rem Sempre para um arquivo temporario, nunca por cima do que ja existe -- senao uma correcao
rem de bug nunca chega em quem ja tem um .ps1 velho e quebrado do lado deste .bat.
echo.
echo   Baixando a versao mais recente do instalador...
del /f /q "%GLB_TMP%" >nul 2>&1
powershell -NoProfile -ExecutionPolicy Bypass -Command "[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12; Invoke-WebRequest -UseBasicParsing -Uri $env:GLB_URL -OutFile $env:GLB_TMP" >nul 2>&1

rem "arquivo existe" sozinho nao prova que o download deu certo (pode ter truncado no meio) --
rem so confia se o powershell terminou ok, o arquivo tem tamanho e comeca com o texto certo.
set "GLB_DL_OK=0"
if %ERRORLEVEL% EQU 0 if exist "%GLB_TMP%" (
    for %%A in ("%GLB_TMP%") do if %%~zA GTR 0 set "GLB_DL_OK=1"
)
rem O texto buscado e o header do commit pinado acima (ainda "GoLiveBypass"), nao do arquivo
rem local -- muda junto se o GLB_URL acima for atualizado para um commit pos-rename.
if "%GLB_DL_OK%"=="1" (
    findstr /c:"GoLiveBypass - instalador automatico" "%GLB_TMP%" >nul || set "GLB_DL_OK=0"
)

if "%GLB_DL_OK%"=="1" (
    move /y "%GLB_TMP%" "%GLB_SCRIPT%" >nul
) else if exist "%GLB_SCRIPT%" (
    echo.
    echo   Nao consegui baixar a versao mais recente, usando a copia local que ja estava aqui.
    del /f /q "%GLB_TMP%" >nul 2>&1
) else (
    echo.
    echo   Nao consegui baixar o instalador. Verifique sua conexao.
    echo.
    pause
    exit /b 1
)

powershell -NoProfile -ExecutionPolicy Bypass -File "%GLB_SCRIPT%" %*

set "GLB_EXIT=%ERRORLEVEL%"
echo.
pause
exit /b %GLB_EXIT%
