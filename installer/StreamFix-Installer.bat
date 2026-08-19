@echo off
setlocal

rem StreamFix - atalho para quem nao quer mexer no PowerShell.
rem Basta dar dois cliques neste arquivo.
rem
rem O caminho nunca e embutido: %~dp0 e resolvido na hora, entao funciona em pastas com
rem espaco e com acento no nome de usuario.

set "GLB_SCRIPT=%~dp0StreamFix-Installer.ps1"
set "GLB_TMP=%~dp0StreamFix-Installer.ps1.tmp"
set "GLB_TAGFILE=%~dp0StreamFix-Installer.ps1.tag.tmp"

rem Sempre para um arquivo temporario, nunca por cima do que ja existe -- senao uma correcao
rem de bug nunca chega em quem ja tem um .ps1 velho e quebrado do lado deste .bat.
echo.
echo   Baixando a versao mais recente do instalador...
del /f /q "%GLB_TMP%" "%GLB_TAGFILE%" >nul 2>&1

rem Resolvido pela API do GitHub (ultima release estavel), nao "main": evita execucao remota de
rem codigo via um push nao revisado, sem precisar editar isto a cada release. So aspas simples
rem no script embutido -- aspas duplas fechariam o argumento -Command mais cedo. A tag resolvida
rem tambem e gravada num arquivo, pra repassar pro .ps1 com -ResolvedTag mais abaixo -- sem
rem isso, o .ps1 consultaria a API de novo por conta propria, e uma release nova saindo entre as
rem duas consultas deixaria o motor baixado aqui e os arquivos que ele baixa depois vindo de
rem revisoes diferentes.
powershell -NoProfile -ExecutionPolicy Bypass -Command "[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12; try { $r = Invoke-RestMethod -UseBasicParsing -Headers @{'User-Agent'='StreamFix-Installer'} -Uri 'https://api.github.com/repos/EduardoVasconceloss/StreamFix/releases/latest'; if (-not $r.tag_name) { exit 1 }; $u = 'https://raw.githubusercontent.com/EduardoVasconceloss/StreamFix/' + $r.tag_name + '/installer/StreamFix-Installer.ps1'; Invoke-WebRequest -UseBasicParsing -Uri $u -OutFile $env:GLB_TMP; Set-Content -NoNewline -Path $env:GLB_TAGFILE -Value $r.tag_name } catch { exit 1 }" >nul 2>&1

rem "arquivo existe" sozinho nao prova que o download deu certo (pode ter truncado no meio) --
rem so confia se o powershell terminou ok, o arquivo tem tamanho e comeca com o texto certo.
set "GLB_DL_OK=0"
if %ERRORLEVEL% EQU 0 if exist "%GLB_TMP%" (
    for %%A in ("%GLB_TMP%") do if %%~zA GTR 0 set "GLB_DL_OK=1"
)
rem O texto buscado e o header do proprio StreamFix-Installer.ps1, entao continua valendo
rem qualquer que seja a release resolvida acima.
if "%GLB_DL_OK%"=="1" (
    findstr /c:"StreamFix - instalador automatico" "%GLB_TMP%" >nul || set "GLB_DL_OK=0"
)

set "GLB_TAG="
if "%GLB_DL_OK%"=="1" if exist "%GLB_TAGFILE%" (
    set /p GLB_TAG=<"%GLB_TAGFILE%"
)
del /f /q "%GLB_TAGFILE%" >nul 2>&1

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

if "%GLB_TAG%"=="" (
    powershell -NoProfile -ExecutionPolicy Bypass -File "%GLB_SCRIPT%" %*
) else (
    powershell -NoProfile -ExecutionPolicy Bypass -File "%GLB_SCRIPT%" -ResolvedTag "%GLB_TAG%" %*
)

set "GLB_EXIT=%ERRORLEVEL%"
echo.
pause
exit /b %GLB_EXIT%
