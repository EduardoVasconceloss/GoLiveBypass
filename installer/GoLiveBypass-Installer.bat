@echo off
setlocal

rem GoLiveBypass - atalho para quem nao quer mexer no PowerShell.
rem Basta dar dois cliques neste arquivo.
rem
rem O caminho nunca e embutido: %~dp0 e resolvido na hora, entao funciona em pastas com
rem espaco e com acento no nome de usuario.

set "GLB_SCRIPT=%~dp0GoLiveBypass-Installer.ps1"
set "GLB_TMP=%~dp0GoLiveBypass-Installer.ps1.tmp"
rem Fixo num commit especifico, nao "main": a URL de /main serve o que quer que esteja no
rem branch a qualquer momento, entao qualquer push (conta comprometida, erro de quem tem
rem acesso) vira execucao remota de codigo no proximo instalador rodado, sem revisao nenhuma
rem no meio. Um commit especifico e enderecado pelo hash, entao o conteudo nesse caminho nunca
rem muda.
rem
rem TEM QUE ser um commit onde o .ps1 baixado JA TENHA o RepoRaw dele proprio fixo (nao
rem "main"): apontar para um commit anterior a essa correcao baixaria um .ps1 que ainda busca
rem o codigo do plugin em main, reabrindo o mesmo buraco um passo adiante. Atualizar isto para
rem o HEAD atual faz parte de cortar uma release nova do instalador.
set "GLB_URL=https://raw.githubusercontent.com/EduardoVasconceloss/GoLiveBypass/bb2e102/installer/GoLiveBypass-Installer.ps1"

rem Baixa sempre para um arquivo temporario, nunca por cima do que ja existe: uma correcao de
rem bug publicada no fork so vale de algo se quem ja tentou instalar antes (e tem um .ps1
rem velho do lado deste .bat) receber a versao nova, em vez de reaproveitar a copia quebrada
rem que causou a tentativa anterior falhar.
echo.
echo   Baixando a versao mais recente do instalador...
del /f /q "%GLB_TMP%" >nul 2>&1
powershell -NoProfile -ExecutionPolicy Bypass -Command "[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12; Invoke-WebRequest -UseBasicParsing -Uri $env:GLB_URL -OutFile $env:GLB_TMP" >nul 2>&1

if exist "%GLB_TMP%" (
    move /y "%GLB_TMP%" "%GLB_SCRIPT%" >nul
) else if exist "%GLB_SCRIPT%" (
    echo.
    echo   Nao consegui baixar a versao mais recente, usando a copia local que ja estava aqui.
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
