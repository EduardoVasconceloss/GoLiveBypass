<#
    GoLiveBypass - instalador automatico

    Encontra sozinho o Equicord ou o Vencord que voce tem, instala o plugin, compila e
    injeta. Se voce nao tiver nenhum dos dois, pergunta qual quer e instala junto.

    Uso:
      .\GoLiveBypass-Installer.ps1
      .\GoLiveBypass-Installer.ps1 -Source "C:\caminho\do\Equicord"
      .\GoLiveBypass-Installer.ps1 -Mod Equicord -Yes
      .\GoLiveBypass-Installer.ps1 -Mode Uninstall

    Obrigado ao Vithor (https://github.com/Vith0r), que escreveu o primeiro instalador do
    GoLiveBypass e abriu o caminho para este aqui.
#>

[CmdletBinding()]
param(
    [ValidateSet('Menu', 'Install', 'Uninstall', 'Restore')]
    [string] $Mode = 'Menu',

    [ValidateSet('Equicord', 'Vencord')]
    [string] $Mod = '',

    [string] $Source = '',

    [switch] $Yes
)

$ErrorActionPreference = 'Stop'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

# Libera a execucao so para este processo. Em maquina com politica de dominio isso pode ser
# recusado, e nesse caso nao ha o que fazer aqui: o proprio .bat ja abre com -ExecutionPolicy Bypass.
try { Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass -Force } catch { }

# Fixo num commit especifico, nao "main": raw.githubusercontent.com/<repo>/main serve o que
# quer que esteja no branch a qualquer momento, entao qualquer push (uma conta comprometida,
# um erro de quem tem acesso) vira execucao remota de codigo no proximo instalador rodado, sem
# nenhuma revisao no meio. Um commit especifico e enderecado pelo hash: o conteudo nesse
# caminho nunca muda. Atualizar isto para o HEAD atual faz parte de cortar uma release nova
# do instalador (junto com git tag installer-vN e a recompilacao do .exe).
$RepoRaw = 'https://raw.githubusercontent.com/EduardoVasconceloss/GoLiveBypass/0ebc1d7'
$PluginFiles = @('goLiveBypass/index.tsx', 'goLiveBypass/native.ts')
$PluginDirName = 'goLiveBypass'
$DiscordNames = @('Discord', 'DiscordCanary', 'DiscordPTB')

$Mods = @{
    Equicord = @{ Git = 'https://github.com/Equicord/Equicord'; Label = 'Equicord'; Note = 'recomendado, inclui tudo do Vencord e mais plugins' }
    Vencord  = @{ Git = 'https://github.com/Vendicated/Vencord'; Label = 'Vencord'; Note = 'o original, mais enxuto' }
}

function Write-Step($text) { Write-Host "  [*] $text" -ForegroundColor DarkGray }
function Write-Ok($text) { Write-Host "  [OK] $text" -ForegroundColor Green }
function Write-Warn($text) { Write-Host "  [!] $text" -ForegroundColor Yellow }
function Write-Err($text) { Write-Host "  [X] $text" -ForegroundColor Red }

function Show-Banner {
    Write-Host ''
    Write-Host '  GoLiveBypass' -ForegroundColor Cyan
    Write-Host '  Go Live e camera de volta no Discord' -ForegroundColor DarkGray
    Write-Host '  https://github.com/EduardoVasconceloss/GoLiveBypass (fork de bezumiya/GoLiveBypass)' -ForegroundColor DarkGray
    Write-Host ''
}

function Confirm-Action($question) {
    if ($Yes) { return $true }
    return (Read-Host "  $question [s/N]") -match '^[sSyY]'
}

function Save-Text($path, $text) {
    $dir = Split-Path -Parent $path
    if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    [IO.File]::WriteAllText($path, $text, (New-Object System.Text.UTF8Encoding($false)))
}

function Get-RepoFile($relativePath) {
    # Split-Path -Parent devolve string vazia quando $PSScriptRoot e a raiz de um disco
    # (instalador salvo direto em C:\ ou na raiz de um pendrive), e Join-Path com Path vazio
    # lanca "Nao e possivel associar o argumento ao parametro 'Path'". O if aninhado evita
    # cair nesse caso em vez de so pular a otimizacao do arquivo local.
    if ($PSScriptRoot) {
        $repoRoot = Split-Path -Parent $PSScriptRoot
        if ($repoRoot) {
            $local = Join-Path $repoRoot ($relativePath -replace '/', '\')
            if (Test-Path -LiteralPath $local) { return [IO.File]::ReadAllText($local) }
        }
    }

    try {
        return (Invoke-WebRequest -UseBasicParsing -Uri "$RepoRaw/$relativePath").Content
    } catch {
        throw "Nao consegui baixar $relativePath. Verifique sua conexao."
    }
}

function Test-Tool($name) {
    return [bool] (Get-Command $name -ErrorAction SilentlyContinue)
}

# O corepack cria o atalho do pnpm antes de saber que versao usar. Na primeira execucao ele
# busca essa versao no registro do npm e confere a assinatura com chaves embutidas nele; as
# chaves do corepack que vem no Node 22 estao velhas, entao o atalho existe e mesmo assim
# quebra com "Cannot find matching keyid". So testar se o comando existe nao prova nada.
function Test-Pnpm {
    if (-not (Test-Tool 'pnpm')) { return $false }

    # 2>$null para o erro do corepack nao assustar quem so vai ver a instalacao seguir.
    $version = & pnpm --version 2>$null
    if ($LASTEXITCODE -ne 0) { return $false }

    Write-Step "pnpm encontrado: $version"
    return $true
}

function Update-PathFromEnvironment {
    $machine = [Environment]::GetEnvironmentVariable('Path', 'Machine')
    $user = [Environment]::GetEnvironmentVariable('Path', 'User')
    $env:Path = @($machine, $user | Where-Object { $_ }) -join ';'
}

function Test-ModCheckout($path) {
    if (-not $path) { return $false }
    if (-not (Test-Path -LiteralPath (Join-Path $path 'package.json'))) { return $false }
    if (-not (Test-Path -LiteralPath (Join-Path $path 'src\utils\types.ts'))) { return $false }

    # O build roda "git rev-parse --short HEAD" para gravar o hash na versao compilada. Uma
    # pasta que tem os arquivos certos mas nao e um clone git de verdade (ZIP baixado do
    # GitHub, ou um "git clone" que foi interrompido no meio) passa nos dois testes acima e
    # so quebra mais tarde, no meio do pnpm build, com "not a git repository" sem contexto
    # nenhum. Melhor recusar aqui, onde a mensagem aponta a pasta errada na hora certa.
    return Test-Path -LiteralPath (Join-Path $path '.git')
}

function Get-DiscordResources {
    $found = @()
    foreach ($name in $DiscordNames) {
        $root = Join-Path $env:LOCALAPPDATA $name
        if (-not (Test-Path -LiteralPath $root)) { continue }

        $apps = Get-ChildItem -LiteralPath $root -Directory -ErrorAction SilentlyContinue |
            Where-Object {
                $_.Name -match '^app-[0-9]' -and
                (Test-Path -LiteralPath (Join-Path $_.FullName 'resources'))
            } |
            Sort-Object -Descending -Property @{ Expression = {
                try { [version]($_.Name -replace '^app-', '') } catch { [version]'0.0.0' }
            } }

        foreach ($app in $apps) { $found += (Join-Path $app.FullName 'resources') }
    }
    return $found
}

function Get-InjectedPath($resources) {
    # O instalador do Equicord e o do Vencord trocam o app.asar por um stub cujo index.js so
    # faz require da pasta de build. Numa instalacao a partir do fonte esse require aponta
    # direto para <checkout>\dist\desktop, que e a forma mais confiavel de achar o checkout.

    $candidates = @()

    $stub = Join-Path $resources 'app.asar'
    if (Test-Path -LiteralPath $stub) {
        $item = Get-Item -LiteralPath $stub
        # app.asar pode ser uma pasta; nesse caso .Length devolve 1 e nao o tamanho do arquivo.
        # E a leitura precisa ser UTF-8: em ASCII um caminho com acento vira "Jo??o".
        if ($item -is [IO.FileInfo] -and $item.Length -lt 65536) {
            $candidates += [IO.File]::ReadAllText($stub)
        }
    }

    $index = Join-Path $resources 'app\index.js'
    if (Test-Path -LiteralPath $index) {
        $candidates += Get-Content -LiteralPath $index -Raw -ErrorAction SilentlyContinue
    }

    foreach ($text in $candidates) {
        if (-not $text) { continue }
        $match = [regex]::Match($text, 'require\("(.+?)"\)')
        if ($match.Success) { return $match.Groups[1].Value -replace '\\\\', '\' }
    }

    return $null
}

function Get-InstalledMod {
    foreach ($resources in Get-DiscordResources) {
        $injected = Get-InjectedPath $resources
        if (-not $injected) { continue }
        if ($injected -match 'equibop') { return 'Equibop' }
        if ($injected -match 'equicord') { return 'Equicord' }
        if ($injected -match 'vesktop') { return 'Vesktop' }
        if ($injected -match 'vencord') { return 'Vencord' }
    }
    return $null
}

function Find-CheckoutFromInjection {
    foreach ($resources in Get-DiscordResources) {
        $injected = Get-InjectedPath $resources
        if (-not $injected) { continue }

        # <checkout>\dist\desktop -> <checkout>
        $root = Split-Path -Parent (Split-Path -Parent $injected)
        if (Test-ModCheckout $root) { return $root }
    }
    return $null
}

function Find-CheckoutOnDisk {
    $roots = @($env:USERPROFILE)
    foreach ($sub in @('Documents', 'Desktop', 'Downloads', 'dev', 'repos', 'projects', 'git', 'source', 'source\repos')) {
        $roots += (Join-Path $env:USERPROFILE $sub)
    }
    foreach ($drive in (Get-PSDrive -PSProvider FileSystem -ErrorAction SilentlyContinue)) {
        if ($drive.Root -and $drive.Root -match '^[A-Za-z]:\\$') { $roots += $drive.Root }
    }

    $seen = @{}
    foreach ($root in $roots) {
        if (-not $root -or $seen.ContainsKey($root) -or -not (Test-Path -LiteralPath $root)) { continue }
        $seen[$root] = $true

        $candidates = Get-ChildItem -LiteralPath $root -Directory -ErrorAction SilentlyContinue |
            Where-Object { $_.Name -match '^(Equicord|Vencord)$' }

        foreach ($dir in $candidates) {
            if (Test-ModCheckout $dir.FullName) { return $dir.FullName }
        }
    }

    Write-Step 'Procurando um pouco mais fundo no seu perfil'
    $deep = Get-ChildItem -LiteralPath $env:USERPROFILE -Directory -Recurse -Depth 3 -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -match '^(Equicord|Vencord)$' } |
        Select-Object -First 20

    foreach ($dir in $deep) {
        if (Test-ModCheckout $dir.FullName) { return $dir.FullName }
    }

    return $null
}

function Find-Checkout {
    if ($Source) {
        if (Test-ModCheckout $Source) { return $Source }
        throw "Nao encontrei um checkout do Equicord ou Vencord em $Source"
    }

    $root = Find-CheckoutFromInjection
    if ($root) {
        Write-Ok "Achei pelo Discord: $root"
        return $root
    }

    $root = Find-CheckoutOnDisk
    if ($root) {
        Write-Ok "Achei no disco: $root"
        return $root
    }

    return $null
}

function Test-InjectedFromCheckout($root) {
    foreach ($resources in Get-DiscordResources) {
        $injected = Get-InjectedPath $resources
        if ($injected -and $injected.StartsWith($root, [StringComparison]::OrdinalIgnoreCase)) { return $true }
    }
    return $false
}

function Show-ModChoice {
    if ($Mod) { return $Mod }

    $installed = Get-InstalledMod

    Write-Host ''
    if ($installed) {
        Write-Warn "Voce tem o $installed instalado, mas nao achei o codigo fonte dele."
        Write-Host '  Plugins de usuario so existem compilando do fonte, entao preciso baixar o repositorio.' -ForegroundColor DarkGray
    } else {
        Write-Warn 'Nao encontrei Equicord nem Vencord no seu computador.'
        Write-Host '  Posso baixar e instalar um dos dois junto com o plugin.' -ForegroundColor DarkGray
    }

    Write-Host ''
    Write-Host '  Qual voce quer instalar?' -ForegroundColor White
    Write-Host ''
    Write-Host "    [1] Equicord    $($Mods.Equicord.Note)" -ForegroundColor Green
    Write-Host "    [2] Vencord     $($Mods.Vencord.Note)" -ForegroundColor Cyan
    Write-Host '    [0] Cancelar' -ForegroundColor Gray
    Write-Host ''

    switch (Read-Host '  Escolha') {
        '1' { return 'Equicord' }
        '2' { return 'Vencord' }
        default { throw 'Cancelado.' }
    }
}

function Install-Toolchain($needGit) {
    $missing = @()
    if ($needGit -and -not (Test-Tool 'git')) { $missing += 'git' }
    if (-not (Test-Tool 'node')) { $missing += 'node' }

    if ($missing.Count -gt 0) {
        Write-Warn "Faltando no seu PATH: $($missing -join ', ')"

        if (-not (Test-Tool 'winget')) {
            throw "Instale $($missing -join ' e ') manualmente e rode de novo."
        }

        if (-not (Confirm-Action 'Instalar agora com o winget?')) {
            throw "Instale $($missing -join ' e ') e rode de novo."
        }

        foreach ($tool in $missing) {
            $id = if ($tool -eq 'git') { 'Git.Git' } else { 'OpenJS.NodeJS.LTS' }
            Write-Step "winget install $id"
            & winget install --id $id --accept-source-agreements --accept-package-agreements --silent
        }

        Write-Host ''
        Write-Warn 'Feche este terminal, abra outro e rode o instalador de novo para o PATH atualizar.'
        exit 0
    }

    if (Test-Pnpm) { return }

    # O Corepack cria um atalho do pnpm antes de saber que versao usar, e na primeira
    # execucao ele confere a assinatura contra chaves embutidas que no Node 22 estao
    # vencidas: o atalho existe e mesmo assim quebra com "Cannot find matching keyid".
    # O npm instala o pnpm direto, sem essa etapa, entao vamos direto por ele.
    Write-Step 'Instalando o pnpm pelo npm'
    & npm install -g pnpm
    Update-PathFromEnvironment

    if (-not (Test-Pnpm)) {
        throw 'Nao consegui deixar o pnpm funcionando. Abra um terminal e rode: npm install -g pnpm'
    }
}

function Install-Mod($choice) {
    $info = $Mods[$choice]
    $target = Join-Path $env:USERPROFILE $info.Label

    Write-Host ''
    Write-Host '  Vou fazer:' -ForegroundColor White
    Write-Host "    1. Baixar o $($info.Label) em $target" -ForegroundColor DarkGray
    Write-Host '    2. Instalar as dependencias' -ForegroundColor DarkGray
    Write-Host '    3. Compilar junto com o GoLiveBypass' -ForegroundColor DarkGray
    Write-Host '    4. Injetar no Discord (o Discord vai fechar)' -ForegroundColor DarkGray
    Write-Host ''
    if (-not (Confirm-Action 'Pode seguir?')) { throw 'Cancelado.' }

    Install-Toolchain $true

    if (Test-Path -LiteralPath $target) {
        if (-not (Test-ModCheckout $target)) {
            throw "$target ja existe e nao parece um checkout. Apague a pasta ou use -Source."
        }
        Write-Step "Ja existe um checkout em $target, reaproveitando"
        return $target
    }

    Write-Step "git clone $($info.Git)"
    & git clone --depth 1 $info.Git $target
    if ($LASTEXITCODE -ne 0) { throw 'git clone falhou' }

    return $target
}

function Stop-Discord {
    if (-not (Get-Process -Name $DiscordNames -ErrorAction SilentlyContinue)) { return }

    Write-Step 'Fechando o Discord'
    Get-Process -Name $DiscordNames -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue

    for ($i = 0; $i -lt 30; $i++) {
        Start-Sleep -Milliseconds 300
        if (-not (Get-Process -Name $DiscordNames -ErrorAction SilentlyContinue)) { return }
    }

    throw 'O Discord nao fechou. Feche pelo icone na bandeja e rode de novo.'
}

function Copy-Plugin($root) {
    $target = Join-Path $root "src\userplugins\$PluginDirName"
    Write-Step "Instalando o plugin em $target"

    if (-not (Test-Path -LiteralPath $target)) { New-Item -ItemType Directory -Path $target -Force | Out-Null }

    # versoes antigas usavam index.ts; deixar os dois quebra o build
    $stale = Join-Path $target 'index.ts'
    if (Test-Path -LiteralPath $stale) { Remove-Item -LiteralPath $stale -Force }

    foreach ($file in $PluginFiles) {
        Save-Text (Join-Path $target (Split-Path -Leaf $file)) (Get-RepoFile $file)
    }
}

function Build-Mod($root) {
    Push-Location -LiteralPath $root
    try {
        if (-not (Test-Path -LiteralPath (Join-Path $root 'node_modules'))) {
            Write-Step 'Instalando dependencias (na primeira vez demora alguns minutos)'
            & pnpm install
            if ($LASTEXITCODE -ne 0) { throw 'pnpm install falhou' }
        }

        Write-Step 'Compilando'
        & pnpm build
        if ($LASTEXITCODE -ne 0) { throw 'pnpm build falhou' }
    } finally {
        Pop-Location
    }
}

function Invoke-Injection($root) {
    Push-Location -LiteralPath $root
    try {
        Stop-Discord
        Write-Step 'Injetando no Discord'
        & pnpm inject
        if ($LASTEXITCODE -ne 0) { throw 'pnpm inject falhou' }
    } finally {
        Pop-Location
    }
}

function Start-Discord {
    foreach ($name in $DiscordNames) {
        $exe = Join-Path $env:LOCALAPPDATA "$name\Update.exe"
        if (Test-Path -LiteralPath $exe) {
            Start-Process -FilePath $exe -ArgumentList '--processStart', "$name.exe"
            return
        }
    }
}

function Invoke-Install($root) {
    $root = Select-Target $root
    $proxy = Select-Proxy
    $permanent = Select-Persistence

    Install-Toolchain $false
    Copy-Plugin $root
    Build-Mod $root

    $weInjected = -not (Test-InjectedFromCheckout $root)
    if ($weInjected) {
        Invoke-Injection $root
    } else {
        Write-Step 'O Discord ja carrega deste checkout, so reiniciando'
        Stop-Discord
    }

    # Com o Discord fechado: aberto, ele regrava o settings.json a partir da memoria e
    # apaga o que escrevemos aqui.
    Set-PluginSettings $root $proxy

    Start-Discord

    Write-Host ''
    Write-Ok 'Pronto. O plugin ja vem ativado, nao precisa mexer em nada.'
    if ($proxy) {
        Write-Host "  Proxy: $proxy" -ForegroundColor DarkGray
    } else {
        Write-Host '  Proxy: gratuita, escolhida e testada sozinha a cada abertura' -ForegroundColor DarkGray
    }
    Write-Host '  Entre numa call e use Go Live ou a camera.' -ForegroundColor DarkGray

    if (-not $permanent) {
        if ($weInjected) {
            Wait-DiscordExit $root
        } else {
            Write-Warn 'O Discord ja estava injetado antes de eu rodar, entao nao vou desfazer isso.'
            Write-Host '  Para remover depois: .\GoLiveBypass-Installer.ps1 -Mode Uninstall' -ForegroundColor DarkGray
        }
    }
}

function Invoke-Uninstall {
    $root = Find-Checkout
    if (-not $root) { throw 'Nao encontrei o checkout do Equicord/Vencord. Use -Source.' }

    $target = Join-Path $root "src\userplugins\$PluginDirName"
    if (Test-Path -LiteralPath $target) {
        Write-Step "Removendo $target"
        Remove-Item -LiteralPath $target -Recurse -Force
    } else {
        Write-Warn 'O plugin nao estava instalado nesse checkout.'
    }

    Build-Mod $root
    Stop-Discord
    Start-Discord
    Remove-TorDaemon

    Write-Host ''
    Write-Ok 'Plugin removido. Seu Equicord/Vencord continua funcionando.'
}

# =============================================================================== interface

function Get-CheckoutMod($root) {
    # A identidade vem do package.json, nao do nome da pasta: quem baixou o ZIP tem o repo
    # numa pasta chamada Equicord-main, e ai o nome da pasta nao diz nada.
    $manifest = Join-Path $root 'package.json'
    if (Test-Path -LiteralPath $manifest) {
        try {
            $name = (Get-Content -LiteralPath $manifest -Raw | ConvertFrom-Json).name
            if ($name -match 'equicord') { return 'Equicord' }
            if ($name -match 'vencord') { return 'Vencord' }
        } catch { }
    }

    if ((Split-Path -Leaf $root) -match 'vencord') { return 'Vencord' }
    return 'Equicord'
}

function Get-ModSettingsFile($root) {
    # Mesma regra do proprio mod (src/main/utils/constants.ts):
    #   DATA_DIR = <MOD>_USER_DATA_DIR ?? %APPDATA%\<Mod>
    #   SETTINGS_FILE = DATA_DIR\settings\settings.json
    $mod = Get-CheckoutMod $root

    $override = [Environment]::GetEnvironmentVariable("$($mod.ToUpper())_USER_DATA_DIR")
    if ($override) { return (Join-Path $override 'settings\settings.json') }

    return (Join-Path $env:APPDATA "$mod\settings\settings.json")
}

function Set-PluginSettings($root, $proxy) {
    $file = Get-ModSettingsFile $root

    $settings = $null
    if (Test-Path -LiteralPath $file) {
        try { $settings = Get-Content -LiteralPath $file -Raw | ConvertFrom-Json } catch { $settings = 'ilegivel' }
    }

    # Nunca reescrever por cima de um arquivo que nao deu para ler: isso apagaria todos os
    # plugins da pessoa. Melhor guardar uma copia e deixar ela ativar o plugin na mao.
    if ($settings -is [string]) {
        $backup = "$file.bak-$(Get-Date -Format yyyyMMdd-HHmmss)"
        Copy-Item -LiteralPath $file -Destination $backup -Force
        Write-Warn "Nao consegui ler $file, entao nao mexi nele. Copia em $backup"
        Write-Warn 'Ative o GoLiveBypass na mao em Configuracoes > Plugins.'
        return
    }

    if ($null -eq $settings) { $settings = [pscustomobject]@{} }

    if (-not $settings.PSObject.Properties['plugins']) {
        $settings | Add-Member -NotePropertyName plugins -NotePropertyValue ([pscustomobject]@{}) -Force
    }

    $existing = $settings.plugins.PSObject.Properties['GoLiveBypass']
    $plugin = if ($existing) { $existing.Value } else { [pscustomobject]@{} }

    $plugin | Add-Member -NotePropertyName enabled -NotePropertyValue $true -Force
    $plugin | Add-Member -NotePropertyName proxy -NotePropertyValue $proxy -Force
    if (-not $plugin.PSObject.Properties['excludedCountries']) {
        $plugin | Add-Member -NotePropertyName excludedCountries -NotePropertyValue 'BR' -Force
    }

    $settings.plugins | Add-Member -NotePropertyName GoLiveBypass -NotePropertyValue $plugin -Force

    Save-Text $file ($settings | ConvertTo-Json -Depth 10)

    $written = $null
    try { $written = (Get-Content -LiteralPath $file -Raw | ConvertFrom-Json).plugins.GoLiveBypass } catch { }
    if ($written -and $written.enabled) {
        Write-Step "Plugin ativado em $file"
    } else {
        Write-Warn "Nao consegui confirmar a escrita em $file"
        Write-Host '  Ative o GoLiveBypass na mao em Configuracoes > Plugins.' -ForegroundColor DarkGray
    }
}

function Show-Status($root) {
    $discord = (Get-DiscordResources).Count
    $mod = Get-InstalledMod

    Write-Host '  Detectado:' -ForegroundColor White
    if ($discord -gt 0) { Write-Host "    Discord   instalado ($discord versao(oes))" -ForegroundColor DarkGray }
    else { Write-Host '    Discord   nao encontrado' -ForegroundColor Yellow }

    if ($mod) { Write-Host "    Mod       $mod" -ForegroundColor DarkGray }
    else { Write-Host '    Mod       nenhum' -ForegroundColor DarkGray }

    if ($root) {
        Write-Host "    Fonte     $root" -ForegroundColor DarkGray
        $plugin = Join-Path $root "src\userplugins\$PluginDirName"
        if (Test-Path -LiteralPath $plugin) { Write-Host '    Plugin    ja instalado' -ForegroundColor Green }
        else { Write-Host '    Plugin    nao instalado' -ForegroundColor DarkGray }
    } else {
        Write-Host '    Fonte     nao encontrado' -ForegroundColor DarkGray
    }
    Write-Host ''
}

function Select-Target($root) {
    if (-not $root) { return (Install-Mod (Show-ModChoice)) }
    if ($Yes) { return $root }

    $name = Split-Path -Leaf $root
    Write-Host '  Onde instalar?' -ForegroundColor White
    Write-Host ''
    Write-Host "    [1] Usar o $name que ja esta aqui" -ForegroundColor Green
    Write-Host "        $root" -ForegroundColor DarkGray
    Write-Host '    [2] Baixar e usar outro (Equicord ou Vencord)' -ForegroundColor Cyan
    Write-Host ''

    switch (Read-Host '  Escolha') {
        '2' { return (Install-Mod (Show-ModChoice)) }
        default { return $root }
    }
}

# =============================================================================== tor local
#
# O gateway fica fixado numa saida so, para sempre, enquanto a sessao dura (e assim que o
# roteamento por host do plugin funciona). Uma proxy gratuita que degrade no meio do caminho
# --- sem cair de vez, so travando --- deixa o WebSocket do gateway meio-morto: quem assiste
# para de receber os eventos de "fulano comecou a transmitir" ate alguem dar Ctrl+R. O Tor
# nao elimina esse risco, mas e ordens de grandeza mais estavel que uma lista de proxy publica
# desconhecida, e o circuito de uma conexao ja aberta nao muda no meio do caminho.
#
# Sem bridge nem pluggable transport: eles servem para atravessar rede onde a propria rede
# Tor esta bloqueada, que nao e o caso do Brasil hoje. O que esta bloqueado e so o Go Live do
# Discord. Bridge seria complexidade a mais (baixar meek-client.exe, manter uma linha de
# bridge que pode expirar) sem ganho nenhum pra esse cenario.

$TorRoot = Join-Path $env:LOCALAPPDATA 'GoLiveBypass\Tor'
$TorExe = Join-Path $TorRoot 'tor\tor.exe'
$TorRc = Join-Path $TorRoot 'torrc'
$TorSocksPort = 9050

function Test-PortOpen($port, $timeoutMs = 500) {
    $client = New-Object System.Net.Sockets.TcpClient
    try {
        $result = $client.BeginConnect('127.0.0.1', $port, $null, $null)
        return ($result.AsyncWaitHandle.WaitOne($timeoutMs) -and $client.Connected)
    } catch {
        return $false
    } finally {
        $client.Close()
    }
}

# Fixos, nao descobertos em tempo real. dist.torproject.org serve tanto o binario quanto o
# sha256sums-signed-build.txt do mesmo jeito (HTTPS simples, sem checagem de chave PGP): um
# review adversarial apontou certo que buscar o hash "esperado" da mesma origem que o binario
# nao prova nada contra uma origem comprometida, porque as duas respostas vem do mesmo lugar
# nao confiavel. Conferimos este hash a mao, uma vez, contra o sha256sums-signed-build.txt de
# https://dist.torproject.org/torbrowser/15.0.20/ antes de publicar. Trocar a versao aqui
# exige repetir essa conferencia manual e faz parte de cortar uma release nova do instalador.
$TorVersion = '15.0.20'
$TorArchiveSha256 = 'd59bff934e3ad876e1623e24ae60c19aeea56f50178093b9f86fba230639f949'

function Start-TorDaemon {
    if (-not (Test-Path -LiteralPath $TorExe)) { return $false }
    if (Test-PortOpen $TorSocksPort) { return $true }

    Start-Process -FilePath $TorExe -ArgumentList @('-f', $TorRc) -WorkingDirectory $TorRoot -WindowStyle Hidden

    # O SOCKS listener abre quase na hora, bem antes do Tor terminar de montar os primeiros
    # circuitos (medido: listener de pe no mesmo segundo, bootstrap 100% uns 15s depois). Nao
    # precisamos esperar o bootstrap inteiro aqui, so confirmar que a porta respondeu.
    for ($i = 0; $i -lt 20; $i++) {
        if (Test-PortOpen $TorSocksPort) { return $true }
        Start-Sleep -Milliseconds 500
    }

    return $false
}

# So para a sessao atual: sem isso, o Tor so voltaria a existir na proxima vez que alguem
# rodasse o instalador. Tarefa Agendada seria o jeito "oficial", mas Register-ScheduledTask
# (e ate o schtasks.exe cru, testado direto) deu "Acesso negado" numa conta administradora
# comum, sem elevar nada -- alguma politica ou software de seguranca bloqueia a criacao de
# tarefa mesmo sem precisar de admin. Um atalho na pasta Inicializar do proprio usuario e um
# simples arquivo, sem precisar de nenhum servico do Windows, e funciona onde a Tarefa
# Agendada nao funcionou.
function Register-TorAutostart {
    try {
        $startup = [Environment]::GetFolderPath('Startup')
        $vbsPath = Join-Path $TorRoot 'start-hidden.vbs'
        $shortcutPath = Join-Path $startup 'GoLiveBypass Tor.lnk'

        # wscript.exe nao abre janela nenhuma, e Run(...,0,...) pede janela escondida para o
        # processo filho -- e assim que o tor.exe sobe sem nem um pisca de console no login.
        # VBScript nao trata "\" como escape (path do Windows entra cru), so "\"\"" precisa
        # virar "" (aspas dobradas) para sobreviver dentro de outra string. Montado com
        # concatenacao de strings de aspas simples em vez de escapar tudo numa string so, que
        # e ilegivel e facil de errar a contagem de aspas.
        $runLine = 'shell.Run """' + $TorExe + '"" -f ""' + $TorRc + '""", 0, False'
        $vbsLines = @(
            'Set shell = CreateObject("WScript.Shell")'
            $runLine
        )
        Save-Text $vbsPath ($vbsLines -join "`n")

        $shell = New-Object -ComObject WScript.Shell
        $shortcut = $shell.CreateShortcut($shortcutPath)
        $shortcut.TargetPath = 'wscript.exe'
        $shortcut.Arguments = "`"$vbsPath`""
        $shortcut.WorkingDirectory = $TorRoot
        $shortcut.Description = 'Sobe o Tor local do GoLiveBypass antes do Discord abrir.'
        $shortcut.Save()

        return $true
    } catch {
        Write-Warn "Nao consegui deixar o Tor iniciando sozinho no login: $($_.Exception.Message)"
        Write-Host '  Vai continuar funcionando nesta sessao; para as proximas, rode o instalador de novo.' -ForegroundColor DarkGray
        return $false
    }
}

function Install-TorDaemon {
    if (Test-PortOpen $TorSocksPort) {
        Write-Ok 'Ja tem um Tor rodando na porta 9050, nada para instalar.'
        return $true
    }

    if (Test-Path -LiteralPath $TorExe) {
        Write-Step 'Tor ja baixado, so iniciando'
        if (Start-TorDaemon) {
            Register-TorAutostart | Out-Null
            return $true
        }
        Write-Warn 'O Tor nao respondeu na porta 9050 a tempo.'
        return $false
    }

    if (-not (Test-Tool 'tar')) {
        throw 'Falta o tar.exe (vem com o Windows 10 versao 1803 ou mais nova). Atualize o Windows, ou use Proxy minha com um Tor instalado a mao.'
    }

    $archiveFileName = "tor-expert-bundle-windows-x86_64-$TorVersion.tar.gz"
    $archiveUrl = "https://dist.torproject.org/torbrowser/$TorVersion/$archiveFileName"
    $archivePath = Join-Path $env:TEMP $archiveFileName

    Write-Step "Baixando o Tor $TorVersion (uns 20 MB)"
    Invoke-WebRequest -UseBasicParsing -Uri $archiveUrl -OutFile $archivePath

    # Contra $TorArchiveSha256, fixo no script e conferido a mao antes de publicar -- nao
    # contra um hash buscado agora do mesmo dist.torproject.org que serviu o binario. Um hash
    # "esperado" vindo da mesma origem nao prova nada: uma origem comprometida serviria os
    # dois, binario e checksum, coerentes entre si. O hash fixo aqui e a ancora de confianca
    # independente -- foi conferido de um lugar e num momento diferentes do download real.
    Write-Step 'Conferindo o hash do download'
    $actualHash = (Get-FileHash -LiteralPath $archivePath -Algorithm SHA256).Hash.ToLowerInvariant()
    if ($actualHash -ne $TorArchiveSha256) {
        Remove-Item -LiteralPath $archivePath -Force -ErrorAction SilentlyContinue
        throw 'O hash do Tor baixado nao bate com o hash fixo no instalador. Abortando: o arquivo pode ter sido adulterado no caminho.'
    }

    New-Item -ItemType Directory -Path $TorRoot -Force | Out-Null
    Write-Step 'Extraindo'
    & tar -xzf $archivePath -C $TorRoot
    Remove-Item -LiteralPath $archivePath -Force -ErrorAction SilentlyContinue

    if (-not (Test-Path -LiteralPath $TorExe)) { throw 'O pacote baixado do Tor nao trouxe o tor.exe esperado.' }

    # O parser do torrc trata "\" dentro de aspas como escape de string C ("\U" nao e valido),
    # entao um DataDirectory absoluto do Windows entre aspas quebra com "Invalid escape
    # sequence". Barra normal funciona em qualquer path no Windows e nao tem esse problema.
    $dataDir = (Join-Path $TorRoot 'data') -replace '\\', '/'
    $torrcLines = @(
        "SocksPort 127.0.0.1:$TorSocksPort"
        "DataDirectory `"$dataDir`""
        'AvoidDiskWrites 1'
    )
    Save-Text $TorRc ($torrcLines -join "`n")

    if (-not (Start-TorDaemon)) { throw 'O Tor nao respondeu na porta 9050 a tempo depois de instalado.' }

    Register-TorAutostart | Out-Null
    Write-Ok 'Tor instalado e rodando. Vai subir sozinho a cada login, antes do Discord abrir.'
    return $true
}

# So mexe no Tor que o proprio GoLiveBypass instalou (path exato em $TorExe), nunca num
# tor.exe de outra origem -- a pessoa pode ter Tor Browser aberto por outro motivo, e matar
# esse por engano seria pior que deixar o nosso sobrando.
function Remove-TorDaemon {
    if (-not (Test-Path -LiteralPath $TorRoot)) { return }

    Write-Step 'Removendo o Tor que o GoLiveBypass instalou'

    try {
        Get-Process -Name 'tor' -ErrorAction SilentlyContinue |
            Where-Object { $_.Path -and $_.Path.Equals($TorExe, [StringComparison]::OrdinalIgnoreCase) } |
            Stop-Process -Force -ErrorAction SilentlyContinue
    } catch { }

    $shortcutPath = Join-Path ([Environment]::GetFolderPath('Startup')) 'GoLiveBypass Tor.lnk'
    Remove-Item -LiteralPath $shortcutPath -Force -ErrorAction SilentlyContinue

    # Da um instante para o processo morto soltar o arquivo de lock antes de apagar a pasta.
    Start-Sleep -Milliseconds 300
    Remove-Item -LiteralPath $TorRoot -Recurse -Force -ErrorAction SilentlyContinue
}

function Select-Proxy {
    if ($Yes) { return '' }

    Write-Host ''
    Write-Host '  Como o bypass vai sair para fora do Brasil?' -ForegroundColor White
    Write-Host ''
    Write-Host '    [1] Proxy gratuita, escolhida e testada sozinha' -ForegroundColor Green
    Write-Host '        Nao precisa instalar nada. O plugin testa varias e usa a que passar.' -ForegroundColor DarkGray
    Write-Host '    [2] Tor (instalo e deixo rodando sozinho)' -ForegroundColor Cyan
    Write-Host '        Bem mais estavel que proxy gratuita. Baixo e configuro o Tor puro, sem navegador.' -ForegroundColor DarkGray
    Write-Host '    [3] Proxy minha' -ForegroundColor Cyan
    Write-Host '        Voce informa o endereco, no formato socks5://host:porta.' -ForegroundColor DarkGray
    Write-Host ''

    switch (Read-Host '  Escolha') {
        '2' {
            if (-not (Install-TorDaemon)) { throw 'Nao consegui deixar o Tor pronto. Tente de novo, ou use outra opcao.' }

            # Devolver vazio aqui significaria "automatico" para o plugin, que prefere uma
            # saida ja guardada no pote antes mesmo de tentar o Tor -- ai quem escolheu Tor
            # explicitamente podia acabar saindo por uma proxy gratuita de uma instalacao
            # anterior, sem aviso nenhum. O endereco explicito forca o plugin a usar
            # exatamente o Tor que acabamos de deixar de pe.
            return "socks5://127.0.0.1:$TorSocksPort"
        }
        '3' {
            $manual = (Read-Host '  Endereco da proxy').Trim()
            if ($manual -notmatch '^(socks5|https?)://[a-z0-9.-]{1,253}:\d{1,5}$') {
                throw 'Formato invalido. Use socks5://host:porta.'
            }
            return $manual
        }
        default { return '' }
    }
}

function Select-Persistence {
    if ($Yes) { return $true }

    Write-Host ''
    Write-Host '  Como voce quer deixar o Discord?' -ForegroundColor White
    Write-Host ''
    Write-Host '    [1] Permanente' -ForegroundColor Green
    Write-Host '        O Discord abre com o mod toda vez, ate voce remover.' -ForegroundColor DarkGray
    Write-Host '    [2] Temporario' -ForegroundColor Yellow
    Write-Host '        Vale so nesta sessao. Quando voce fechar o Discord, a injecao e desfeita.' -ForegroundColor DarkGray
    Write-Host ''

    return (Read-Host '  Escolha') -ne '2'
}

function Wait-DiscordExit($root) {
    Write-Host ''
    Write-Ok 'Discord aberto com o GoLiveBypass.'
    Write-Warn 'Deixe esta janela aberta. Quando voce fechar o Discord, eu desfaco a injecao.'
    Write-Host '  Se fechar esta janela antes, rode: .\GoLiveBypass-Installer.ps1 -Mode Uninstall' -ForegroundColor DarkGray

    try {
        # Esperar o Discord APARECER antes de esperar ele sumir. Sem isso, o Update.exe ainda
        # nao trocou de processo e o laco acha que ja fechou, desfazendo tudo em 5 segundos.
        for ($i = 0; $i -lt 90; $i++) {
            if (Get-Process -Name $DiscordNames -ErrorAction SilentlyContinue) { break }
            Start-Sleep -Seconds 1
        }

        if (-not (Get-Process -Name $DiscordNames -ErrorAction SilentlyContinue)) {
            Write-Warn 'O Discord nao abriu em 90s. Vou desfazer a injecao agora.'
        } else {
            while (Get-Process -Name $DiscordNames -ErrorAction SilentlyContinue) { Start-Sleep -Seconds 2 }
            Write-Host ''
            Write-Step 'Discord fechado, desfazendo a injecao'
        }
    } finally {
        # finally para que Ctrl+C tambem desfaca, em vez de deixar o Discord injetado.
        Push-Location -LiteralPath $root
        try {
            & pnpm uninject
            if ($LASTEXITCODE -ne 0) { Write-Warn 'O pnpm uninject falhou. Rode "pnpm uninject" na pasta do mod.' }
            else { Write-Ok 'Discord restaurado.' }
        } finally { Pop-Location }
    }
}

function Invoke-RestoreEverything {
    $root = Find-Checkout
    if ($root) {
        $target = Join-Path $root "src\userplugins\$PluginDirName"
        if (Test-Path -LiteralPath $target) {
            Write-Step "Removendo $target"
            Remove-Item -LiteralPath $target -Recurse -Force
        }

        Stop-Discord
        Push-Location -LiteralPath $root
        try {
            Write-Step 'Desfazendo a injecao'
            & pnpm uninject
        } finally { Pop-Location }
    } else {
        Write-Warn 'Nao achei o fonte do mod, entao so posso parar por aqui.'
    }

    Remove-TorDaemon

    Write-Host ''
    Write-Ok 'Tudo restaurado. Seu Discord voltou ao normal.'
}

function Show-MainMenu {
    $root = Find-Checkout
    Show-Status $root

    Write-Host '  O que voce quer fazer?' -ForegroundColor White
    Write-Host ''
    Write-Host '    [1] Instalar ou atualizar o GoLiveBypass' -ForegroundColor Green
    Write-Host '    [2] Remover so o plugin (o mod continua)' -ForegroundColor Yellow
    Write-Host '    [3] Restaurar tudo (remove o plugin e desfaz a injecao)' -ForegroundColor Red
    Write-Host '    [0] Sair' -ForegroundColor Gray
    Write-Host ''

    switch (Read-Host '  Escolha') {
        '1' { Invoke-Install $root }
        '2' { Invoke-Uninstall }
        '3' { Invoke-RestoreEverything }
        default { Write-Host '  Ate mais.' -ForegroundColor DarkGray }
    }
}

Show-Banner

try {
    switch ($Mode) {
        'Install' { Invoke-Install (Find-Checkout) }
        'Uninstall' { Invoke-Uninstall }
        'Restore' { Invoke-RestoreEverything }
        default { Show-MainMenu }
    }
} catch {
    Write-Host ''
    Write-Err $_.Exception.Message
    exit 1
}

Write-Host ''
