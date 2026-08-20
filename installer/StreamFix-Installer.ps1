<#
    StreamFix - instalador automatico

    Encontra sozinho o Equicord ou o Vencord que voce tem, instala o plugin, compila e
    injeta. Se voce nao tiver nenhum dos dois, pergunta qual quer e instala junto.

    Uso:
      .\StreamFix-Installer.ps1
      .\StreamFix-Installer.ps1 -Source "C:\caminho\do\Equicord"
      .\StreamFix-Installer.ps1 -Mod Equicord -Yes
      .\StreamFix-Installer.ps1 -Mode Uninstall

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

    [switch] $Yes,

    # Deixa a GUI carregar so as funcoes via dot-sourcing, sem disparar o menu de terminal.
    [switch] $NoAutoRun,

    # Passado por quem baixou este script (o .bat ou o StreamFix-Installer-GUI.ps1), que ja
    # resolveu a ultima release estavel pela API do GitHub para se baixar. Reaproveitar essa
    # mesma tag aqui, em vez de consultar a API de novo, e o que garante que o motor do
    # instalador e os arquivos que ele baixa (Resolve-RepoRaw) vem sempre da mesma revisao --
    # uma segunda consulta independente correria o risco de pegar uma release mais nova que
    # saiu no meio do caminho.
    [string] $ResolvedTag = ''
)

$ErrorActionPreference = 'Stop'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

# Libera a execucao so para este processo; se a politica de dominio recusar, o .bat ja abre
# com -ExecutionPolicy Bypass.
try { Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass -Force } catch { }

# Alguns antivirus/EDR rodam um .exe novo e desconhecido numa primeira passada de sandbox com
# o ambiente do processo raspado (sem USERPROFILE/TEMP), antes de liberar a execucao de
# verdade. Sem essa checagem, isso vira la na frente um erro criptico do .NET tentando montar
# um caminho vazio -- "nao e possivel associar o argumento ao parametro 'Path'". Falhar aqui,
# cedo e com uma mensagem que aponta o antivirus, poupa uma investigacao as cegas depois.
foreach ($envVar in @('USERPROFILE', 'TEMP')) {
    if (-not [Environment]::GetEnvironmentVariable($envVar)) {
        throw "A variavel de ambiente $envVar veio vazia para este processo. Isso costuma acontecer quando um antivirus roda o instalador numa sandbox restrita antes de liberar de verdade -- confirme que o .exe/.ps1 esta liberado no seu antivirus e tente de novo."
    }
}

# Resolvida a ultima release estavel (nao "main"): evita execucao remota de codigo via um push
# nao revisado, sem precisar editar isto a cada release -- Resolve-RepoRaw consulta a API do
# GitHub e resolve uma vez por execucao, memoizando o resultado.
$script:RepoRaw = $null
$PluginFiles = @('streamFix/index.tsx', 'streamFix/native.ts')
$PluginDirName = 'streamFix'
$LegacyPluginDirName = 'goLiveBypass'
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
    Write-Host '  StreamFix' -ForegroundColor Cyan
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

function Resolve-RepoRaw {
    if ($script:RepoRaw) { return $script:RepoRaw }

    if ($ResolvedTag) {
        $script:RepoRaw = "https://raw.githubusercontent.com/EduardoVasconceloss/StreamFix/$ResolvedTag"
        return $script:RepoRaw
    }

    try {
        $release = Invoke-RestMethod -UseBasicParsing -Headers @{ 'User-Agent' = 'StreamFix-Installer' } `
            -Uri 'https://api.github.com/repos/EduardoVasconceloss/StreamFix/releases/latest'
    } catch {
        throw 'Nao consegui descobrir a ultima release estavel do StreamFix pela API do GitHub. Verifique sua conexao e tente de novo.'
    }

    if (-not $release.tag_name) { throw 'A API do GitHub nao devolveu uma tag de release valida.' }

    $script:RepoRaw = "https://raw.githubusercontent.com/EduardoVasconceloss/StreamFix/$($release.tag_name)"
    return $script:RepoRaw
}

function Get-RepoFile($relativePath) {
    # Split-Path -Parent devolve vazio na raiz de um disco, e Join-Path com Path vazio lanca
    # excecao -- o if aninhado evita isso.
    if ($PSScriptRoot) {
        $repoRoot = Split-Path -Parent $PSScriptRoot
        if ($repoRoot) {
            $local = Join-Path $repoRoot ($relativePath -replace '/', '\')
            if (Test-Path -LiteralPath $local) { return [IO.File]::ReadAllText($local) }
        }
    }

    try {
        return (Invoke-WebRequest -UseBasicParsing -Uri "$(Resolve-RepoRaw)/$relativePath").Content
    } catch {
        throw "Nao consegui baixar $relativePath. Verifique sua conexao."
    }
}

# stderr de um comando externo vira NativeCommandError fatal com ErrorActionPreference=Stop,
# mesmo sendo so aviso (ex: pnpm avisando a propria versao). Quem diz se falhou de verdade e o
# $LASTEXITCODE, checado depois de cada chamada -- aqui so relaxamos a checagem do PowerShell.
#
# A saida vai por Write-Host, NUNCA pro stream de sucesso. Emitir no stream de sucesso fazia a
# saida do comando virar parte do valor de retorno de quem chamou: Install-Mod devolvia
# ["Cloning into 'C:\...'", "C:\...\Equicord"] em vez do caminho, e o primeiro Join-Path
# reclamava que nao existe drive chamado "Cloning into 'C". Mesma armadilha que ja tinha
# derrubado o log da GUI -- ver o Write-Host redefinido em StreamFix-Installer-GUI.ps1.
function Invoke-Native([ScriptBlock] $Command) {
    $previous = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        # 2>&1 mistura stderr no stream; o ForEach devolve o texto puro em vez do ErrorRecord,
        # senao toda linha aparece em vermelho como "ERROR:" mesmo sendo saida normal.
        & $Command 2>&1 | ForEach-Object {
            $line = if ($_ -is [Management.Automation.ErrorRecord]) { $_.Exception.Message } else { $_ }
            Write-Host "    $line" -ForegroundColor DarkGray
        }
    } finally {
        $ErrorActionPreference = $previous
    }
}

function Test-Tool($name) {
    return [bool] (Get-Command $name -ErrorAction SilentlyContinue)
}

# O corepack cria o atalho do pnpm antes de saber que versao usar. Na primeira execucao ele
# busca essa versao no registro do npm e confere a assinatura com chaves embutidas nele; as
# chaves do corepack que vem no Node 22 estao velhas, entao o atalho existe e mesmo assim
# quebra com "Cannot find matching keyid". So testar se o comando existe nao prova nada.
function Test-Pnpm($expectedVersion = $null) {
    if (-not (Test-Tool 'pnpm')) { return $false }

    # 2>$null para o erro do corepack nao assustar quem so vai ver a instalacao seguir.
    $version = & pnpm --version 2>$null
    if ($LASTEXITCODE -ne 0) { return $false }

    # Versao errada tambem conta como "nao esta pronto": pnpm avisa a cada comando quando
    # difere da que o package.json pede, mesmo funcionando -- reinstalar a certa cala o aviso.
    if ($expectedVersion -and $version -ne $expectedVersion) { return $false }

    Write-Step "pnpm encontrado: $version"
    return $true
}

function Get-PinnedPnpmVersion($root) {
    if (-not $root) { return $null }
    $manifest = Join-Path $root 'package.json'
    if (-not (Test-Path -LiteralPath $manifest)) { return $null }

    try {
        $pm = (Get-Content -LiteralPath $manifest -Raw | ConvertFrom-Json).packageManager
        if ($pm -match '^pnpm@([\d.]+)') { return $Matches[1] }
    } catch { }
    return $null
}

function Update-PathFromEnvironment {
    $machine = [Environment]::GetEnvironmentVariable('Path', 'Machine')
    $user = [Environment]::GetEnvironmentVariable('Path', 'User')
    $fresh = @($machine, $user | Where-Object { $_ }) -join ';'

    # Mescla no PATH atual, nunca substitui: descartaria entradas que so existem no processo
    # (wrapper, shell de dev, instalacao portatil) e nao estao no registro.
    $existing = @($env:Path -split ';' | Where-Object { $_ })
    $newEntries = @($fresh -split ';' | Where-Object { $_ -and ($existing -notcontains $_) })
    $env:Path = ($existing + $newEntries) -join ';'
}

function Test-ModCheckout($path) {
    if (-not $path) { return $false }
    if (-not (Test-Path -LiteralPath (Join-Path $path 'package.json'))) { return $false }
    if (-not (Test-Path -LiteralPath (Join-Path $path 'src\utils\types.ts'))) { return $false }

    # O build roda "git rev-parse" pra gravar o hash na versao compilada; uma pasta sem clone
    # git de verdade (ZIP baixado, clone interrompido) so quebraria mais tarde, sem contexto.
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
    # O stub que o Equicord/Vencord deixa no lugar do app.asar so faz require da pasta de
    # build -- aponta direto pro checkout, forma mais confiavel de acha-lo.

    $candidates = @()

    $stub = Join-Path $resources 'app.asar'
    if (Test-Path -LiteralPath $stub) {
        $item = Get-Item -LiteralPath $stub
        # app.asar pode ser pasta (.Length viraria 1, nao o tamanho real).
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

function Install-Toolchain($root = $null) {
    # Relê o PATH antes do primeiro Test-Tool: quem instala o Node e abre o instalador sem
    # reiniciar o terminal (ou clica no .exe pelo Explorer) herda um PATH de antes do registro
    # atualizar, e a ferramenta parece "faltando" mesmo estando la.
    Update-PathFromEnvironment

    # git e sempre necessario, mesmo quando ja existe um checkout: o build roda "git
    # rev-parse" pra gravar o hash na versao compilada (ver Test-ModCheckout). $needGit so
    # controlava a mensagem/fluxo de clone, e por isso um checkout ja existente sem git
    # instalado passava direto por essa checagem e so quebrava mais tarde, com "pnpm build
    # falhou" sem contexto nenhum.
    $missing = @()
    if (-not (Test-Tool 'git')) { $missing += 'git' }
    if (-not (Test-Tool 'node')) { $missing += 'node' }

    if ($missing.Count -gt 0) {
        Write-Warn "Faltando no seu PATH: $($missing -join ', ')"

        if (Test-Tool 'winget') {
            if (-not (Confirm-Action 'Instalar agora com o winget?')) {
                throw "Instale $($missing -join ' e ') e rode de novo."
            }

            foreach ($tool in $missing) {
                $id = if ($tool -eq 'git') { 'Git.Git' } else { 'OpenJS.NodeJS.LTS' }
                Write-Step "winget install $id"
                Invoke-Native { winget install --id $id --accept-source-agreements --accept-package-agreements --silent }
            }
        } else {
            # Sem winget: cai pro instalador oficial de cada ferramenta (Install-ToolDirect).
            Write-Warn 'Sem winget nesta maquina.'
            if (-not (Confirm-Action "Baixar e instalar $($missing -join ' e ') pelo instalador oficial de cada um?")) {
                throw "Instale $($missing -join ' e ') manualmente e rode de novo."
            }

            foreach ($tool in $missing) {
                Install-ToolDirect $tool
            }
        }

        # O winget grava o PATH novo no registro (Machine/User), e da pra reler isso no mesmo
        # processo sem reabrir o terminal -- e a mesma tecnica ja usada pra pegar o pnpm
        # recem-instalado logo abaixo. Antes o instalador sempre pedia pra fechar e abrir de
        # novo aqui, e como este mesmo Install-Toolchain roda de novo mais adiante no fluxo
        # (para o mod, e depois para o resto), isso virava um ciclo de fechar/reabrir varias
        # vezes numa instalacao do zero. So pede reabrir se, mesmo depois de reler, a
        # ferramenta continuar faltando -- caso raro de instalador do winget que precisa
        # mesmo de uma sessao nova.
        Update-PathFromEnvironment
        $stillMissing = $missing | Where-Object { -not (Test-Tool $_) }

        if ($stillMissing.Count -gt 0) {
            Write-Host ''
            Write-Warn "Ainda faltando depois de instalar: $($stillMissing -join ', '). Feche este terminal, abra outro e rode o instalador de novo."
            exit 0
        }

        Write-Ok 'Instalado. Seguindo sem precisar reabrir o terminal.'
    }

    $pinnedPnpm = Get-PinnedPnpmVersion $root
    if (Test-Pnpm $pinnedPnpm) { return }

    # O Corepack cria um atalho do pnpm antes de saber que versao usar, e na primeira
    # execucao ele confere a assinatura contra chaves embutidas que no Node 22 estao
    # vencidas: o atalho existe e mesmo assim quebra com "Cannot find matching keyid".
    # O npm instala o pnpm direto, sem essa etapa, entao vamos direto por ele.
    $pnpmSpec = if ($pinnedPnpm) { "pnpm@$pinnedPnpm" } else { 'pnpm' }
    Write-Step "Instalando o $pnpmSpec pelo npm"
    Invoke-Native { npm install -g $pnpmSpec }
    Update-PathFromEnvironment

    if (-not (Test-Pnpm $pinnedPnpm)) {
        throw "Nao consegui deixar o pnpm funcionando. Abra um terminal e rode: npm install -g $pnpmSpec"
    }
}

function Install-Mod($choice) {
    $info = $Mods[$choice]
    $target = Join-Path $env:USERPROFILE $info.Label

    Write-Host ''
    Write-Host '  Vou fazer:' -ForegroundColor White
    Write-Host "    1. Baixar o $($info.Label) em $target" -ForegroundColor DarkGray
    Write-Host '    2. Instalar as dependencias' -ForegroundColor DarkGray
    Write-Host '    3. Compilar junto com o StreamFix' -ForegroundColor DarkGray
    Write-Host '    4. Injetar no Discord (o Discord vai fechar)' -ForegroundColor DarkGray
    Write-Host ''
    if (-not (Confirm-Action 'Pode seguir?')) { throw 'Cancelado.' }

    Install-Toolchain

    if (Test-Path -LiteralPath $target) {
        if (-not (Test-ModCheckout $target)) {
            throw "$target ja existe e nao parece um checkout. Apague a pasta ou use -Source."
        }
        Write-Step "Ja existe um checkout em $target, reaproveitando"
        return $target
    }

    Write-Step "git clone $($info.Git)"
    Invoke-Native { git clone --depth 1 $info.Git $target }
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
    $legacy = Join-Path $root "src\userplugins\$LegacyPluginDirName"

    # Evita pasta duplicada/orfa pra quem ja tinha o plugin instalado sob o nome antigo.
    if ((Test-Path -LiteralPath $legacy) -and -not (Test-Path -LiteralPath $target)) {
        Write-Step "Removendo a instalacao antiga do plugin em $legacy"
        Remove-Item -LiteralPath $legacy -Recurse -Force
    }

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
            Invoke-Native { pnpm install }
            if ($LASTEXITCODE -ne 0) { throw 'pnpm install falhou' }
        }

        Write-Step 'Compilando'
        Invoke-Native { pnpm build }
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
        # --branch auto: sem isso, o instalador do mod pergunta com um menu de setinhas qual
        # Discord usar mesmo com --install ja passado -- na GUI (sem console de verdade) essa
        # pergunta trava para sempre, sem jeito de responder. auto pega Stable > Canary > PTB.
        Invoke-Native { pnpm inject -- --branch auto }
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

    # Um comando nativo escreve na saida da funcao que o chama, e Select-Target chama outras que
    # rodam npm e git. O Invoke-Native ja contem isso, mas se qualquer nativo novo escapar dele
    # o $root volta a chegar como array, e o Test-Path quebra ao ligar um elemento vazio -- com
    # uma mensagem sobre parametro que nao diz nada a quem esta instalando.
    #
    # Ficar com a ultima linha e o que resolve: o caminho de verdade sai do "return" no fim da
    # funcao, depois de toda a saida que vazou. E nao esconde erro nenhum, porque a checagem
    # logo abaixo continua valendo.
    $root = @($root) | Where-Object { $_ } | Select-Object -Last 1

    # Checar que a pasta existe, e nao so que a variavel tem algo: um checkout que nao ficou
    # pronto (clone interrompido, permissao negada) passaria pela checagem de vazio e so
    # apareceria muito depois, como erro do .NET sobre o parametro 'Path'.
    if (-not $root -or -not (Test-Path -LiteralPath $root)) {
        throw 'Nao consegui determinar a pasta de instalacao. Tente de novo, ou aponte com -Source.'
    }

    Remove-LegacyTor

    $proxy = Select-Proxy
    $permanent = Select-Persistence

    Install-Toolchain $root
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
            Write-Host '  Para remover depois: .\StreamFix-Installer.ps1 -Mode Uninstall' -ForegroundColor DarkGray
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
        Write-Warn 'Ative o StreamFix na mao em Configuracoes > Plugins.'
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
        Write-Host '  Ative o StreamFix na mao em Configuracoes > Plugins.' -ForegroundColor DarkGray
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
# Tor em vez de proxy gratuita: mais estavel numa sessao longa (gateway fica fixo numa saida
# so; uma proxy que degrada no meio deixa o WebSocket meio-morto). Sem bridge/pluggable
# transport: e so o Go Live do Discord que esta bloqueado, nao a rede Tor em si no Brasil.

$TorRoot = Join-Path $env:LOCALAPPDATA 'StreamFix\Tor'
$LegacyTorRoot = Join-Path $env:LOCALAPPDATA 'GoLiveBypass\Tor'
$TorExe = Join-Path $TorRoot 'tor\tor.exe'
$TorRc = Join-Path $TorRoot 'torrc'
$TorSocksPort = 9050

# Limpa uma instalacao anterior do Tor sob o nome antigo (GoLiveBypass), atalho de autostart
# incluso -- so remove; quem quiser o Tor de volta ganha um novo em $TorRoot na proxima vez
# que escolher essa opcao.
function Remove-LegacyTor {
    if (-not (Test-Path -LiteralPath $LegacyTorRoot)) { return }

    Write-Step 'Removendo a instalacao antiga do Tor (GoLiveBypass -> StreamFix)'

    try {
        $legacyExe = Join-Path $LegacyTorRoot 'tor\tor.exe'
        Get-Process -Name 'tor' -ErrorAction SilentlyContinue |
            Where-Object { $_.Path -and $_.Path.Equals($legacyExe, [StringComparison]::OrdinalIgnoreCase) } |
            Stop-Process -Force -ErrorAction SilentlyContinue
    } catch { }

    $legacyShortcut = Join-Path ([Environment]::GetFolderPath('Startup')) 'GoLiveBypass Tor.lnk'
    Remove-Item -LiteralPath $legacyShortcut -Force -ErrorAction SilentlyContinue

    Start-Sleep -Milliseconds 300
    Remove-Item -LiteralPath $LegacyTorRoot -Recurse -Force -ErrorAction SilentlyContinue
}

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

# Fallback sem winget: instalador oficial de cada ferramenta, versao e hash fixos (mesma logica
# do Tor acima). Trocar a versao aqui exige conferir o hash de novo contra a fonte oficial.
$NodeVersion = '24.19.0'
$NodeMsiUrl = "https://nodejs.org/dist/v$NodeVersion/node-v$NodeVersion-x64.msi"
$NodeMsiSha256 = 'f0f66c2a80c08a30a5ab5179ee9ea9e45f9b46289436a8cc87ff833b852db351'

$GitTag = 'v2.55.0.windows.4'
$GitExeVersion = '2.55.0.4'
$GitExeUrl = "https://github.com/git-for-windows/git/releases/download/$GitTag/Git-$GitExeVersion-64-bit.exe"
$GitExeSha256 = '0cbc0b34a74b3aff3ace0910328549155a770e228331b19cb1498218a120e7ff'

function Install-ToolDirect($tool) {
    $spec = if ($tool -eq 'git') {
        @{ Url = $GitExeUrl; Sha256 = $GitExeSha256; File = 'StreamFix-git-installer.exe' }
    } else {
        @{ Url = $NodeMsiUrl; Sha256 = $NodeMsiSha256; File = 'StreamFix-node-installer.msi' }
    }

    $installerPath = Join-Path $env:TEMP $spec.File
    Write-Step "Baixando o instalador oficial do $tool"
    Invoke-WebRequest -UseBasicParsing -Uri $spec.Url -OutFile $installerPath

    Write-Step 'Conferindo o hash do download'
    $actualHash = (Get-FileHash -LiteralPath $installerPath -Algorithm SHA256).Hash.ToLowerInvariant()
    if ($actualHash -ne $spec.Sha256) {
        Remove-Item -LiteralPath $installerPath -Force -ErrorAction SilentlyContinue
        throw "O hash do instalador do $tool baixado nao bate com o hash fixo no instalador. Abortando: o arquivo pode ter sido adulterado no caminho."
    }

    Write-Step "Instalando o $tool (instalador oficial, silencioso -- pode levar um minuto)"
    # -Wait: msiexec e o instalador do git voltam pro prompt na hora se so chamados com "&".
    $proc = if ($tool -eq 'git') {
        Start-Process -FilePath $installerPath -ArgumentList '/VERYSILENT', '/NORESTART', '/NOCANCEL', '/SP-', '/SUPPRESSMSGBOXES', '/CLOSEAPPLICATIONS', '/RESTARTAPPLICATIONS' -Wait -PassThru
    } else {
        Start-Process -FilePath 'msiexec.exe' -ArgumentList '/i', "`"$installerPath`"", '/quiet', '/norestart' -Wait -PassThru
    }
    Remove-Item -LiteralPath $installerPath -Force -ErrorAction SilentlyContinue

    if ($proc.ExitCode -ne 0) {
        throw "O instalador do $tool terminou com codigo de erro $($proc.ExitCode)."
    }
}

# CONNECT SOCKS5 real ate um host HTTPS, com autenticacao TLS -- so a porta TCP aberta nao
# prova que o Tor ja carrega trafego (o listener sobe bem antes do circuito ficar pronto).
function Test-SocksHttpsConnect($socksPort, $targetHost, $targetPort, $timeoutMs) {
    $client = $null
    try {
        $client = New-Object System.Net.Sockets.TcpClient
        $connectTask = $client.ConnectAsync('127.0.0.1', $socksPort)
        if (-not $connectTask.Wait($timeoutMs) -or -not $client.Connected) { return $false }

        $stream = $client.GetStream()
        $stream.ReadTimeout = $timeoutMs
        $stream.WriteTimeout = $timeoutMs

        # Saudacao SOCKS5: versao 5, 1 metodo oferecido, metodo 0 (sem autenticacao)
        $stream.Write([byte[]](5, 1, 0), 0, 3)
        $greeting = New-Object byte[] 2
        if ($stream.Read($greeting, 0, 2) -ne 2 -or $greeting[0] -ne 5 -or $greeting[1] -ne 0) { return $false }

        # Pedido CONNECT por nome de dominio (tipo 3), formato TLV do proprio SOCKS5
        $hostBytes = [Text.Encoding]::ASCII.GetBytes($targetHost)
        $request = [Collections.Generic.List[byte]]::new()
        $request.AddRange([byte[]](5, 1, 0, 3, [byte]$hostBytes.Length))
        $request.AddRange($hostBytes)
        $request.Add([byte](($targetPort -shr 8) -band 0xFF))
        $request.Add([byte]($targetPort -band 0xFF))
        $requestBytes = $request.ToArray()
        $stream.Write($requestBytes, 0, $requestBytes.Length)

        $reply = New-Object byte[] 10
        $read = $stream.Read($reply, 0, 10)
        if ($read -lt 2 -or $reply[1] -ne 0) { return $false }

        # Protocolo TLS explicito: sem isso, o SChannel falha ("Falha a uma chamada a SSPI")
        # rodando de dentro do .exe compilado, mesmo funcionando normal via powershell.exe puro.
        $ssl = New-Object System.Net.Security.SslStream($stream, $false)
        $ssl.AuthenticateAsClient($targetHost, $null, [System.Security.Authentication.SslProtocols]::Tls12, $false)
        return $ssl.IsAuthenticated
    } catch {
        return $false
    } finally {
        if ($client) { $client.Close() }
    }
}

function Test-TorCircuit($timeoutMs) {
    $deadline = (Get-Date).AddMilliseconds($timeoutMs)
    do {
        if (Test-SocksHttpsConnect $TorSocksPort 'www.torproject.org' 443 5000) { return $true }
        Start-Sleep -Milliseconds 1000
    } while ((Get-Date) -lt $deadline)

    return $false
}

function Start-TorDaemon {
    if (-not (Test-PortOpen $TorSocksPort)) {
        if (-not (Test-Path -LiteralPath $TorExe)) { return $false }

        Start-Process -FilePath $TorExe -ArgumentList @('-f', $TorRc) -WorkingDirectory $TorRoot -WindowStyle Hidden

        $portReady = $false
        for ($i = 0; $i -lt 20; $i++) {
            if (Test-PortOpen $TorSocksPort) { $portReady = $true; break }
            Start-Sleep -Milliseconds 500
        }
        if (-not $portReady) { return $false }
    }

    # 45s de folga: o circuito real pode levar 15-20s num boot frio, e 30s as vezes nao bastou.
    return Test-TorCircuit 45000
}

# Atalho na pasta Inicializar em vez de Tarefa Agendada: Register-ScheduledTask (e schtasks.exe
# cru) deram "Acesso negado" numa conta administradora comum, sem elevar nada.
function Register-TorAutostart {
    try {
        $startup = [Environment]::GetFolderPath('Startup')
        $vbsPath = Join-Path $TorRoot 'start-hidden.vbs'
        $shortcutPath = Join-Path $startup 'StreamFix Tor.lnk'

        # wscript.exe + Run(...,0,...) sobe o tor.exe sem console nenhum no login. VBScript nao
        # escapa "\": aspas duplas precisam virar "" pra sobreviver dentro da string.
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
        $shortcut.Description = 'Sobe o Tor local do StreamFix antes do Discord abrir.'
        $shortcut.Save()

        return $true
    } catch {
        Write-Warn "Nao consegui deixar o Tor iniciando sozinho no login: $($_.Exception.Message)"
        Write-Host '  Vai continuar funcionando nesta sessao; para as proximas, rode o instalador de novo.' -ForegroundColor DarkGray
        return $false
    }
}

function Install-TorDaemon {
    # Nao basta a porta estar aberta: pode ser um Tor de outra origem sem circuito pronto, ou
    # o nosso travado. Start-TorDaemon confere trafego real antes de devolver sucesso.
    if (Test-PortOpen $TorSocksPort) {
        Write-Step 'Ja tem algo escutando na porta 9050, confirmando que carrega trafego de verdade'
        if (Start-TorDaemon) {
            Write-Ok 'Tor ja estava rodando e respondendo, nada para instalar.'
            return $true
        }
        Write-Warn 'Tem algo na porta 9050, mas nao parece um Tor funcional. Tentando reinstalar.'
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

    # Contra o hash fixo no script (conferido a mao antes de publicar), nao um hash buscado
    # agora da mesma origem que serviu o binario -- isso nao provaria nada contra origem comprometida.
    Write-Step 'Conferindo o hash do download'
    $actualHash = (Get-FileHash -LiteralPath $archivePath -Algorithm SHA256).Hash.ToLowerInvariant()
    if ($actualHash -ne $TorArchiveSha256) {
        Remove-Item -LiteralPath $archivePath -Force -ErrorAction SilentlyContinue
        throw 'O hash do Tor baixado nao bate com o hash fixo no instalador. Abortando: o arquivo pode ter sido adulterado no caminho.'
    }

    New-Item -ItemType Directory -Path $TorRoot -Force | Out-Null
    Write-Step 'Extraindo'
    Invoke-Native { tar -xzf $archivePath -C $TorRoot }
    Remove-Item -LiteralPath $archivePath -Force -ErrorAction SilentlyContinue

    if (-not (Test-Path -LiteralPath $TorExe)) { throw 'O pacote baixado do Tor nao trouxe o tor.exe esperado.' }

    # O parser do torrc trata "\" entre aspas como escape de string C e quebra num path do
    # Windows; barra normal funciona sem esse problema.
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

# So mexe no Tor que o proprio StreamFix instalou (path exato), nunca num tor.exe de outra
# origem -- a pessoa pode ter Tor Browser aberto por outro motivo.
function Remove-TorDaemon {
    if (-not (Test-Path -LiteralPath $TorRoot)) { return }

    Write-Step 'Removendo o Tor que o StreamFix instalou'

    try {
        Get-Process -Name 'tor' -ErrorAction SilentlyContinue |
            Where-Object { $_.Path -and $_.Path.Equals($TorExe, [StringComparison]::OrdinalIgnoreCase) } |
            Stop-Process -Force -ErrorAction SilentlyContinue
    } catch { }

    $shortcutPath = Join-Path ([Environment]::GetFolderPath('Startup')) 'StreamFix Tor.lnk'
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

            # Vazio significaria "automatico" pro plugin, que podia acabar saindo por outra
            # proxy sem avisar. Endereco explicito forca o uso do Tor que acabamos de subir.
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
    Write-Ok 'Discord aberto com o StreamFix.'
    Write-Warn 'Deixe esta janela aberta. Quando voce fechar o Discord, eu desfaco a injecao.'
    Write-Host '  Se fechar esta janela antes, rode: .\StreamFix-Installer.ps1 -Mode Uninstall' -ForegroundColor DarkGray

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
            Invoke-Native { pnpm uninject -- --branch auto }
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
            Invoke-Native { pnpm uninject -- --branch auto }
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
    Write-Host '    [1] Instalar ou atualizar o StreamFix' -ForegroundColor Green
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

if (-not $NoAutoRun) {
    # Start-Transcript grava a tela num arquivo no Desktop mesmo que a janela feche rapido
    # demais pra ler. So pausa quando NAO e -Yes -- automacao passa -Yes sem stdin pra responder.
    $logPath = $null
    try {
        $logPath = Join-Path ([Environment]::GetFolderPath('Desktop')) "StreamFix-log-$(Get-Date -Format 'yyyyMMdd-HHmmss').txt"
        Start-Transcript -Path $logPath -Append | Out-Null
    } catch {
        $logPath = $null
    }

    Show-Banner

    $failed = $false
    try {
        switch ($Mode) {
            'Install' { Invoke-Install (Find-Checkout) }
            'Uninstall' { Invoke-Uninstall }
            'Restore' { Invoke-RestoreEverything }
            default { Show-MainMenu }
        }
    } catch {
        $failed = $true
        Write-Host ''
        Write-Err $_.Exception.Message
    }

    if ($logPath) {
        try { Stop-Transcript | Out-Null } catch { }
        Write-Host ''
        Write-Host "  Log completo desta instalacao: $logPath" -ForegroundColor DarkGray
    }

    Write-Host ''

    if (-not $Yes) {
        Write-Host '  Pressione Enter para fechar...' -ForegroundColor DarkGray
        try { Read-Host | Out-Null } catch { }
    }

    if ($failed) { exit 1 }
}
