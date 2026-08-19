<#
    GoLiveBypass - instalador com janela (GUI)

    Faz exatamente o que o GoLiveBypass-Installer.ps1/.bat de terminal faz -- mesmo motor,
    mesmas funcoes, mesmo Tor/pnpm/git por baixo -- so trocando as perguntas de terminal por
    uma tela com opcoes e um botao "Instalar", e o texto que rolava no console por uma caixa
    de log dentro da janela. Quem prefere ver tudo em texto puro continua usando o .bat ou o
    .ps1 direto; esta janela e so uma segunda forma de chegar no mesmo lugar.

    Uso:
      .\GoLiveBypass-Installer-GUI.ps1
#>

[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
try { Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass -Force } catch { }

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

# Mesmo commit fixo que installer/GoLiveBypass-Installer.ps1 usa, pelo mesmo motivo (ver o
# comentario de $RepoRaw la): raw.githubusercontent.com/<repo>/main serve o que estiver no
# branch a qualquer momento, e um commit especifico e imutavel. Atualizar isto para o HEAD
# atual faz parte de cortar uma release nova do instalador, junto com o pin do .ps1/.bat e a
# recompilacao dos dois .exe.
$CoreRepoRaw = 'https://raw.githubusercontent.com/EduardoVasconceloss/GoLiveBypass/f83f305'
$CoreUrl = "$CoreRepoRaw/installer/GoLiveBypass-Installer.ps1"

function Resolve-CoreScript {
    if ($PSScriptRoot) {
        $local = Join-Path $PSScriptRoot 'GoLiveBypass-Installer.ps1'
        if (Test-Path -LiteralPath $local) { return (Get-Content -LiteralPath $local -Raw) }
    }

    try {
        return (Invoke-WebRequest -UseBasicParsing -Uri $CoreUrl).Content
    } catch {
        throw 'Nao consegui baixar o motor de instalacao. Verifique sua conexao.'
    }
}

$coreContent = Resolve-CoreScript
$coreTempPath = Join-Path $env:TEMP 'GoLiveBypass-Installer-Core.ps1'
[IO.File]::WriteAllText($coreTempPath, $coreContent, (New-Object Text.UTF8Encoding($false)))

# Carrega as funcoes de deteccao (nao as de instalacao) na thread da UI, so para achar um
# checkout existente antes de desenhar a tela -- e rapido, nao mexe em nada. As funcoes de
# Write-* do core viram no-op aqui: elas escrevem com Write-Host, e nesta janela (compilada
# com -noConsole) nao ha console nenhum ouvindo.
. $coreTempPath -NoAutoRun
function Write-Step($text) { }
function Write-Ok($text) { }
function Write-Warn($text) { }
function Write-Err($text) { }

$detectedRoot = $null
try { $detectedRoot = Find-Checkout } catch { $detectedRoot = $null }

# =============================================================================== janela

$form = New-Object System.Windows.Forms.Form
$form.Text = 'GoLiveBypass'
$form.Size = New-Object System.Drawing.Size(560, 560)
$form.StartPosition = 'CenterScreen'
$form.FormBorderStyle = 'FixedDialog'
$form.MaximizeBox = $false
$form.Font = New-Object System.Drawing.Font('Segoe UI', 9)

$titleLabel = New-Object System.Windows.Forms.Label
$titleLabel.Text = 'GoLiveBypass'
$titleLabel.Font = New-Object System.Drawing.Font('Segoe UI', 14, [System.Drawing.FontStyle]::Bold)
$titleLabel.Location = New-Object System.Drawing.Point(20, 15)
$titleLabel.AutoSize = $true
$form.Controls.Add($titleLabel)

$subtitleLabel = New-Object System.Windows.Forms.Label
$subtitleLabel.Text = 'Go Live e camera de volta no Discord'
$subtitleLabel.ForeColor = [System.Drawing.Color]::Gray
$subtitleLabel.Location = New-Object System.Drawing.Point(20, 45)
$subtitleLabel.AutoSize = $true
$form.Controls.Add($subtitleLabel)

# --------------------------------------------------------------------- pagina 1: opcoes

$optionsPage = New-Object System.Windows.Forms.Panel
$optionsPage.Location = New-Object System.Drawing.Point(20, 75)
$optionsPage.Size = New-Object System.Drawing.Size(505, 400)
$form.Controls.Add($optionsPage)

# --- onde instalar ---
$targetBox = New-Object System.Windows.Forms.GroupBox
$targetBox.Text = 'Onde instalar'
$targetBox.Location = New-Object System.Drawing.Point(0, 0)
$targetBox.Size = New-Object System.Drawing.Size(505, 95)
$optionsPage.Controls.Add($targetBox)

$radioUseExisting = New-Object System.Windows.Forms.RadioButton
$radioDownloadEquicord = New-Object System.Windows.Forms.RadioButton
$radioDownloadVencord = New-Object System.Windows.Forms.RadioButton

if ($detectedRoot) {
    $name = Split-Path -Leaf $detectedRoot
    $radioUseExisting.Text = "Usar o $name que ja esta em $detectedRoot"
    $radioUseExisting.Location = New-Object System.Drawing.Point(15, 22)
    $radioUseExisting.AutoSize = $true
    $radioUseExisting.Checked = $true
    $targetBox.Controls.Add($radioUseExisting)

    $radioDownloadEquicord.Text = 'Baixar e usar outro: Equicord (recomendado)'
    $radioDownloadEquicord.Location = New-Object System.Drawing.Point(15, 46)
    $radioDownloadEquicord.AutoSize = $true
    $targetBox.Controls.Add($radioDownloadEquicord)

    $radioDownloadVencord.Text = 'Baixar e usar outro: Vencord'
    $radioDownloadVencord.Location = New-Object System.Drawing.Point(15, 68)
    $radioDownloadVencord.AutoSize = $true
    $targetBox.Controls.Add($radioDownloadVencord)
} else {
    $noneLabel = New-Object System.Windows.Forms.Label
    $noneLabel.Text = 'Nao encontrei Equicord nem Vencord no seu computador. Qual instalar?'
    $noneLabel.Location = New-Object System.Drawing.Point(15, 20)
    $noneLabel.AutoSize = $true
    $targetBox.Controls.Add($noneLabel)

    $radioDownloadEquicord.Text = 'Equicord (recomendado, inclui tudo do Vencord e mais plugins)'
    $radioDownloadEquicord.Location = New-Object System.Drawing.Point(15, 44)
    $radioDownloadEquicord.AutoSize = $true
    $radioDownloadEquicord.Checked = $true
    $targetBox.Controls.Add($radioDownloadEquicord)

    $radioDownloadVencord.Text = 'Vencord (o original, mais enxuto)'
    $radioDownloadVencord.Location = New-Object System.Drawing.Point(15, 66)
    $radioDownloadVencord.AutoSize = $true
    $targetBox.Controls.Add($radioDownloadVencord)
}

# --- saida de rede ---
$proxyBox = New-Object System.Windows.Forms.GroupBox
$proxyBox.Text = 'Como o bypass vai sair para fora do Brasil'
$proxyBox.Location = New-Object System.Drawing.Point(0, 105)
$proxyBox.Size = New-Object System.Drawing.Size(505, 165)
$optionsPage.Controls.Add($proxyBox)

$radioProxyFree = New-Object System.Windows.Forms.RadioButton
$radioProxyFree.Text = 'Proxy gratuita, escolhida e testada sozinha'
$radioProxyFree.Location = New-Object System.Drawing.Point(15, 22)
$radioProxyFree.AutoSize = $true
$radioProxyFree.Checked = $true
$proxyBox.Controls.Add($radioProxyFree)

$freeHintLabel = New-Object System.Windows.Forms.Label
$freeHintLabel.Text = 'Nao precisa instalar nada. O plugin testa varias e usa a que passar.'
$freeHintLabel.ForeColor = [System.Drawing.Color]::Gray
$freeHintLabel.Location = New-Object System.Drawing.Point(33, 42)
$freeHintLabel.AutoSize = $true
$proxyBox.Controls.Add($freeHintLabel)

$radioProxyTor = New-Object System.Windows.Forms.RadioButton
$radioProxyTor.Text = 'Tor (instalo e deixo rodando sozinho)'
$radioProxyTor.Location = New-Object System.Drawing.Point(15, 62)
$radioProxyTor.AutoSize = $true
$proxyBox.Controls.Add($radioProxyTor)

$torHintLabel = New-Object System.Windows.Forms.Label
$torHintLabel.Text = 'Bem mais estavel que proxy gratuita. Baixo e configuro o Tor puro, sem navegador.'
$torHintLabel.ForeColor = [System.Drawing.Color]::Gray
$torHintLabel.Location = New-Object System.Drawing.Point(33, 82)
$torHintLabel.AutoSize = $true
$proxyBox.Controls.Add($torHintLabel)

$radioProxyManual = New-Object System.Windows.Forms.RadioButton
$radioProxyManual.Text = 'Proxy minha:'
$radioProxyManual.Location = New-Object System.Drawing.Point(15, 106)
$radioProxyManual.AutoSize = $true
$proxyBox.Controls.Add($radioProxyManual)

$manualProxyBox = New-Object System.Windows.Forms.TextBox
$manualProxyBox.Location = New-Object System.Drawing.Point(120, 104)
$manualProxyBox.Size = New-Object System.Drawing.Size(280, 22)
$manualProxyBox.Enabled = $false
$manualProxyBox.Text = 'socks5://host:porta'
$manualProxyBox.ForeColor = [System.Drawing.Color]::Gray
$proxyBox.Controls.Add($manualProxyBox)

$manualProxyBox.Add_Enter({
    if ($manualProxyBox.Text -eq 'socks5://host:porta') {
        $manualProxyBox.Text = ''
        $manualProxyBox.ForeColor = [System.Drawing.Color]::Black
    }
})

$updateManualEnabled = {
    $manualProxyBox.Enabled = $radioProxyManual.Checked
}
$radioProxyFree.Add_CheckedChanged($updateManualEnabled)
$radioProxyTor.Add_CheckedChanged($updateManualEnabled)
$radioProxyManual.Add_CheckedChanged($updateManualEnabled)

$manualHintLabel = New-Object System.Windows.Forms.Label
$manualHintLabel.Text = 'Formato: socks5://host:porta, http://host:porta ou https://host:porta.'
$manualHintLabel.ForeColor = [System.Drawing.Color]::Gray
$manualHintLabel.Location = New-Object System.Drawing.Point(33, 128)
$manualHintLabel.AutoSize = $true
$proxyBox.Controls.Add($manualHintLabel)

# --- persistencia ---
$persistBox = New-Object System.Windows.Forms.GroupBox
$persistBox.Text = 'Como deixar o Discord'
$persistBox.Location = New-Object System.Drawing.Point(0, 278)
$persistBox.Size = New-Object System.Drawing.Size(505, 75)
$optionsPage.Controls.Add($persistBox)

$radioPermanent = New-Object System.Windows.Forms.RadioButton
$radioPermanent.Text = 'Permanente -- o Discord abre com o mod toda vez, ate voce remover'
$radioPermanent.Location = New-Object System.Drawing.Point(15, 22)
$radioPermanent.AutoSize = $true
$radioPermanent.Checked = $true
$persistBox.Controls.Add($radioPermanent)

$radioTemporary = New-Object System.Windows.Forms.RadioButton
$radioTemporary.Text = 'Temporario -- vale so nesta sessao, desfeito quando fechar o Discord'
$radioTemporary.Location = New-Object System.Drawing.Point(15, 46)
$radioTemporary.AutoSize = $true
$persistBox.Controls.Add($radioTemporary)

# --------------------------------------------------------------------- pagina 2: progresso

$progressPage = New-Object System.Windows.Forms.Panel
$progressPage.Location = New-Object System.Drawing.Point(20, 75)
$progressPage.Size = New-Object System.Drawing.Size(505, 400)
$progressPage.Visible = $false
$form.Controls.Add($progressPage)

$progressLabel = New-Object System.Windows.Forms.Label
$progressLabel.Text = 'Instalando...'
$progressLabel.Font = New-Object System.Drawing.Font('Segoe UI', 10, [System.Drawing.FontStyle]::Bold)
$progressLabel.Location = New-Object System.Drawing.Point(0, 0)
$progressLabel.AutoSize = $true
$progressPage.Controls.Add($progressLabel)

$progressBar = New-Object System.Windows.Forms.ProgressBar
$progressBar.Style = 'Marquee'
$progressBar.MarqueeAnimationSpeed = 30
$progressBar.Location = New-Object System.Drawing.Point(0, 28)
$progressBar.Size = New-Object System.Drawing.Size(505, 18)
$progressPage.Controls.Add($progressBar)

$logBox = New-Object System.Windows.Forms.RichTextBox
$logBox.Location = New-Object System.Drawing.Point(0, 54)
$logBox.Size = New-Object System.Drawing.Size(505, 346)
$logBox.ReadOnly = $true
$logBox.BackColor = [System.Drawing.Color]::Black
$logBox.ForeColor = [System.Drawing.Color]::Gainsboro
$logBox.Font = New-Object System.Drawing.Font('Consolas', 9)
$progressPage.Controls.Add($logBox)

# --------------------------------------------------------------------- pagina 3: concluido

$donePage = New-Object System.Windows.Forms.Panel
$donePage.Location = New-Object System.Drawing.Point(20, 75)
$donePage.Size = New-Object System.Drawing.Size(505, 400)
$donePage.Visible = $false
$form.Controls.Add($donePage)

$doneIconLabel = New-Object System.Windows.Forms.Label
$doneIconLabel.Font = New-Object System.Drawing.Font('Segoe UI', 28)
$doneIconLabel.Location = New-Object System.Drawing.Point(0, 10)
$doneIconLabel.AutoSize = $true
$donePage.Controls.Add($doneIconLabel)

$doneTitleLabel = New-Object System.Windows.Forms.Label
$doneTitleLabel.Font = New-Object System.Drawing.Font('Segoe UI', 12, [System.Drawing.FontStyle]::Bold)
$doneTitleLabel.Location = New-Object System.Drawing.Point(60, 20)
$doneTitleLabel.AutoSize = $true
$donePage.Controls.Add($doneTitleLabel)

$doneTextLabel = New-Object System.Windows.Forms.Label
$doneTextLabel.Location = New-Object System.Drawing.Point(0, 70)
$doneTextLabel.Size = New-Object System.Drawing.Size(505, 60)
$donePage.Controls.Add($doneTextLabel)

$doneLogBox = New-Object System.Windows.Forms.RichTextBox
$doneLogBox.Location = New-Object System.Drawing.Point(0, 130)
$doneLogBox.Size = New-Object System.Drawing.Size(505, 270)
$doneLogBox.ReadOnly = $true
$doneLogBox.Visible = $false
$donePage.Controls.Add($doneLogBox)

# --------------------------------------------------------------------- botoes

$installButton = New-Object System.Windows.Forms.Button
$installButton.Text = 'Instalar'
$installButton.Location = New-Object System.Drawing.Point(360, 485)
$installButton.Size = New-Object System.Drawing.Size(160, 32)
$installButton.BackColor = [System.Drawing.Color]::FromArgb(88, 101, 242)
$installButton.ForeColor = [System.Drawing.Color]::White
$installButton.FlatStyle = 'Flat'
$form.Controls.Add($installButton)

$closeButton = New-Object System.Windows.Forms.Button
$closeButton.Text = 'Fechar'
$closeButton.Location = New-Object System.Drawing.Point(360, 485)
$closeButton.Size = New-Object System.Drawing.Size(160, 32)
$closeButton.Visible = $false
$form.Controls.Add($closeButton)
$closeButton.Add_Click({ $form.Close() })

# =============================================================================== log

# Chamada so pelo Tick do Timer (thread da UI, sempre) -- por isso nao precisa de
# Invoke/marshaling nenhum. Controles do WinForms so podem ser tocados pela propria thread
# que os criou; a alternativa seria reagir ao evento DataAdded da colecao de saida, que
# dispara na thread da runspace de fundo, exigindo Invoke em toda chamada e arriscando dois
# pipelines rodando ao mesmo tempo na mesma runspace, o que o PowerShell nao suporta e pode
# corromper a resolucao de cmdlets (reproduzido isolado: Start-Sleep parou de ser reconhecido
# no meio do script depois de uma chamada assim).
function Append-Log([string] $text, [System.Drawing.Color] $color) {
    $logBox.SelectionStart = $logBox.TextLength
    $logBox.SelectionLength = 0
    $logBox.SelectionColor = $color
    $logBox.AppendText("$text`n")
    $logBox.ScrollToCaret()
}

function Append-OutputLine($item) {
    if ($null -eq $item) { return }
    $line = "$item"
    $sep = $line.IndexOf('|')
    if ($sep -lt 0) { Append-Log $line $ColorHost; return }

    $prefix = $line.Substring(0, $sep)
    $text = $line.Substring($sep + 1)
    switch ($prefix) {
        'STEP' { Append-Log "  [*] $text" $ColorStep }
        'OK' { Append-Log "  [OK] $text" $ColorOk }
        'WARN' { Append-Log "  [!] $text" $ColorWarn }
        'ERR' { Append-Log "  [X] $text" $ColorErr }
        default { Append-Log $text $ColorHost }
    }
}

$ColorStep = [System.Drawing.Color]::Gainsboro
$ColorOk = [System.Drawing.Color]::LightGreen
$ColorWarn = [System.Drawing.Color]::Khaki
$ColorErr = [System.Drawing.Color]::Salmon
$ColorHost = [System.Drawing.Color]::Gainsboro

# =============================================================================== instalar

# Roda numa runspace separada para nao travar a janela durante o pnpm build, que pode levar
# minutos. As funcoes de interface do core (Write-Step, Select-Proxy etc.) sao redefinidas
# aqui dentro, depois de carregar o core com -NoAutoRun, para escrever "PREFIXO|texto" na
# saida do pipeline em vez de mexer na janela direto -- so a thread da UI pode tocar em
# controles do WinForms, e quem le essa saida e Append-OutputLine, chamada do Tick do Timer
# (thread da UI) em vez de reagir a um evento da propria runspace de fundo.
$workerTemplate = @'
param(
    [string] $CorePath,
    [string] $TargetRoot,
    [bool] $DownloadFresh,
    [string] $ModChoice,
    [string] $ProxyChoice,
    [string] $ManualProxy,
    [bool] $Permanent
)

$ErrorActionPreference = 'Stop'
. $CorePath -NoAutoRun

function Write-Host {
    param(
        [Parameter(Position = 0, ValueFromPipeline = $true)] $Object = '',
        [switch] $NoNewline,
        $Separator = ' ',
        $ForegroundColor,
        $BackgroundColor
    )
    process { Write-Output "HOST|$Object" }
}
function Write-Step($text) { Write-Output "STEP|$text" }
function Write-Ok($text) { Write-Output "OK|$text" }
function Write-Warn($text) { Write-Output "WARN|$text" }
function Write-Err($text) { Write-Output "ERR|$text" }

function Confirm-Action($question) {
    $result = [System.Windows.Forms.MessageBox]::Show($question, 'GoLiveBypass', [System.Windows.Forms.MessageBoxButtons]::YesNo, [System.Windows.Forms.MessageBoxIcon]::Question)
    return $result -eq [System.Windows.Forms.DialogResult]::Yes
}

function Select-Target($root) {
    if ($DownloadFresh) { return (Install-Mod $ModChoice) }
    return $root
}

function Select-Proxy {
    switch ($ProxyChoice) {
        'tor' {
            if (-not (Install-TorDaemon)) { throw 'Nao consegui deixar o Tor pronto. Tente de novo, ou use outra opcao.' }
            return "socks5://127.0.0.1:$TorSocksPort"
        }
        'manual' { return $ManualProxy }
        default { return '' }
    }
}

function Select-Persistence { return $Permanent }

Invoke-Install $TargetRoot
'@

$state = [pscustomobject]@{
    Runspace = $null
    Pipeline = $null
    AsyncResult = $null
    Output = $null
    Timer = $null
    LastIndex = 0
}

function Start-Install {
    $modChoice = if ($radioDownloadVencord.Checked) { 'Vencord' } else { 'Equicord' }
    $downloadFresh = -not ($detectedRoot -and $radioUseExisting.Checked)

    $proxyChoice = 'free'
    if ($radioProxyTor.Checked) { $proxyChoice = 'tor' }
    elseif ($radioProxyManual.Checked) { $proxyChoice = 'manual' }

    $manualProxy = $manualProxyBox.Text.Trim()
    if ($proxyChoice -eq 'manual') {
        if ($manualProxy -eq '' -or $manualProxy -eq 'socks5://host:porta' -or $manualProxy -notmatch '^(socks5|https?)://[a-z0-9.-]{1,253}:\d{1,5}$') {
            [System.Windows.Forms.MessageBox]::Show('Endereco de proxy invalido. Use socks5://host:porta.', 'GoLiveBypass', 'OK', 'Warning') | Out-Null
            return
        }
    }

    $optionsPage.Visible = $false
    $progressPage.Visible = $true
    $installButton.Visible = $false
    $form.Text = 'GoLiveBypass -- instalando...'

    $runspace = [runspacefactory]::CreateRunspace()
    $runspace.Open()

    $ps = [powershell]::Create()
    $ps.Runspace = $runspace
    $ps.AddScript($workerTemplate) | Out-Null
    $ps.AddParameter('CorePath', $coreTempPath) | Out-Null
    $ps.AddParameter('TargetRoot', $detectedRoot) | Out-Null
    $ps.AddParameter('DownloadFresh', $downloadFresh) | Out-Null
    $ps.AddParameter('ModChoice', $modChoice) | Out-Null
    $ps.AddParameter('ProxyChoice', $proxyChoice) | Out-Null
    $ps.AddParameter('ManualProxy', $manualProxy) | Out-Null
    $ps.AddParameter('Permanent', [bool] $radioPermanent.Checked) | Out-Null

    $output = New-Object 'System.Management.Automation.PSDataCollection[psobject]'

    # BeginInvoke($null, $output) nao resolve a sobrecarga certa -- PowerShell.BeginInvoke tem
    # varias sobrecargas que aceitam uma colecao de entrada como primeiro parametro, e $null
    # sozinho nao da pra saber qual delas usar. O worker nunca le nada da entrada, entao uma
    # colecao vazia, tipada explicitamente, resolve sem ambiguidade.
    $emptyInput = New-Object 'System.Management.Automation.PSDataCollection[psobject]'
    $state.Runspace = $runspace
    $state.Pipeline = $ps
    $state.Output = $output
    $state.LastIndex = 0
    $state.AsyncResult = $ps.BeginInvoke($emptyInput, $output)

    # O Tick do Timer roda na thread da UI, entao "puxar" o que ha de novo em $output aqui
    # dentro e seguro sem Invoke nenhum -- ao contrario de reagir ao evento DataAdded da
    # colecao, que dispara na thread da runspace de fundo (ver o comentario de Append-Log).
    $timer = New-Object System.Windows.Forms.Timer
    $timer.Interval = 200
    $timer.Add_Tick({
        while ($state.LastIndex -lt $state.Output.Count) {
            Append-OutputLine $state.Output[$state.LastIndex]
            $state.LastIndex++
        }

        if (-not $state.AsyncResult.IsCompleted) { return }
        $state.Timer.Stop()

        $failure = $null
        try {
            $state.Pipeline.EndInvoke($state.AsyncResult)
        } catch {
            $failure = $_.Exception.Message
        }

        if (-not $failure -and $state.Pipeline.Streams.Error.Count -gt 0) {
            $failure = ($state.Pipeline.Streams.Error | Select-Object -First 1).ToString()
        }

        $state.Pipeline.Dispose()
        $state.Runspace.Close()
        $state.Runspace.Dispose()

        Show-Done $failure
    })
    $state.Timer = $timer
    $timer.Start()
}

function Show-Done([string] $failure) {
    $progressPage.Visible = $false
    $donePage.Visible = $true
    $closeButton.Visible = $true

    if ($failure) {
        $form.Text = 'GoLiveBypass -- erro na instalacao'
        $doneIconLabel.Text = [char] 0x274C
        $doneIconLabel.ForeColor = [System.Drawing.Color]::Firebrick
        $doneTitleLabel.Text = 'Algo deu errado'
        $doneTextLabel.Text = 'Veja o detalhe abaixo. O log completo tambem ficou na caixa de progresso.'
        $doneLogBox.Visible = $true
        $doneLogBox.Text = $failure
    } else {
        $form.Text = 'GoLiveBypass -- pronto'
        $doneIconLabel.Text = [char] 0x2705
        $doneIconLabel.ForeColor = [System.Drawing.Color]::ForestGreen
        $doneTitleLabel.Text = 'Pronto!'
        $doneTextLabel.Text = "O plugin ja vem ativado, nao precisa mexer em nada. Entre numa call e use Go Live ou a camera.`n`nSe o Discord nao abriu sozinho, abra ele manualmente."
    }
}

$installButton.Add_Click({ Start-Install })

[System.Windows.Forms.Application]::EnableVisualStyles()
[void] $form.ShowDialog()
