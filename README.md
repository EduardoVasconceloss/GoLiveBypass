# GoLiveBypass — Bypass do Go Live no Discord (Brasil)

Plugin para **Equicord** e **Vencord**, feito por um desenvolvedor brasileiro, que **devolve o Go Live e a câmera para usuários brasileiros**. São duas travas: o Discord desabilita os próprios botões, e o servidor recusa a transmissão. O plugin desarma a primeira direto no cliente, e a segunda mandando **apenas o WebSocket de gateway** por uma saída fora do Brasil — todo o resto do Discord, e todo o resto do computador, continua saindo direto na velocidade normal, inclusive durante a abertura do app.

> **English summary below / Resumo em inglês no final.**

## A instalação inteira, do começo ao fim

<p align="center">
  <img src="assets/instalacao.gif" alt="O instalador acha o Equicord, instala o plugin, compila e o Go Live volta a funcionar" width="720">
</p>

Um script faz tudo: acha o seu Equicord ou Vencord, instala o plugin, compila e abre o Discord com o Go Live funcionando. **[Começar aqui](#instalação-automática-recomendado)** — ou siga o [passo a passo escrito](#instalação-passo-a-passo-completo) se preferir fazer à mão.

## Índice

**Quero instalar agora**

- [Instalação automática](#instalação-automática-recomendado) — um script faz tudo sozinho, no Windows e no Linux
- [Instalação manual, passo a passo](#instalação-passo-a-passo-completo) — se preferir fazer cada etapa à mão
- [Dependências](#dependências-o-que-baixar-e-como-instalar) — só para o caminho manual

**Já instalei**

- [Configuração](#configuração) — região da call, região da transmissão, proxy
- [Uso](#uso) — o que fazer depois de instalar
- [Solução de problemas](#solução-de-problemas) — Discord travado, transmissão que não sobe, plugin sumido

**Quero entender antes**

- [Por que este plugin existe](#por-que-este-plugin-existe)
- [Como funciona](#como-funciona) — as duas travas e como cada uma é desarmada
- [Avisos importantes](#avisos-importantes) — o que o plugin faz com a sua conexão, e os riscos

**Projeto**

- [Estrutura](#estrutura) · [Licença](#licença) · [Autor](#autor) · [Agradecimentos](#agradecimentos)

## Por que este plugin existe

Em agosto de 2026, a ANPD [ordenou que o Discord suspendesse as transmissões ao vivo (Go Live) no Brasil](https://www.gov.br/anpd/pt-br/assuntos/noticias/em-medida-preventiva-anpd-determina-que-discord-suspenda-transmissoes-ao-vivo-no-brasil), pouco depois de o país ter bloqueado o X (Twitter). Para quem depende dessas plataformas para se comunicar, organizar e denunciar, o recado foi claro: o acesso e a privacidade dos brasileiros na internet podem ser cortados por canetaço.

O GoLiveBypass nasce dessa luta. Ele é uma ferramenta de **resistência à censura**: devolve o que foi cortado por canetaço, sem pedir licença e sem entregar o resto da sua conexão em troca.

**O que ele entrega, verificado na prática:** como o WebSocket de gateway nasce fora do Brasil, o **Go Live e a câmera voltam a funcionar** para contas brasileiras — veja a seção abaixo.

Se você também quer que a **autenticação** aconteça atrás da saída, e não pelo seu IP real, mude **Session routing** para `Gateway and login`. Não é o padrão porque custa tempo de abertura, e porque login por proxy pública costuma render captcha.

## Go Live no Brasil: por que funciona

Testes práticos mostram que o bloqueio do Go Live funciona assim:

- O Discord verifica sua região **apenas no momento em que você entra num canal de voz** (`VOICE STATE UPDATE`), usando o **IP da conexão WebSocket do gateway** — e **nunca reavalia** durante a chamada.
- O WebSocket do gateway é aberto no boot do app. Se ele nasce atrás de uma proxy fora do Brasil, o gate de região libera telas e câmera para contas brasileiras.
- A mídia (UDP) não passa por verificação nenhuma — ela pode sair direta pelo seu IP real sem derrubar a liberação.

Ou seja, o bypass manual "ligar VPN, abrir o Discord, entrar na call, desligar a VPN" funciona porque só o gateway precisava da VPN. O plugin faz exatamente isso, e nada além disso: `gateway.discord.gg` sai pela saída escolhida, todo o resto sai direto, o tempo inteiro.

**Ressalvas honestas:**

- A liberação vale enquanto o WebSocket do gateway continuar vivo, e ele continua roteado o tempo todo. Se cair e reconectar (queda de internet, notebook suspenso), o socket novo nasce pela mesma saída e a liberação sobrevive. Ctrl+R também. Isso é uma mudança em relação às versões que aplicavam proxy só no boot, onde qualquer reconexão custava o Go Live até reiniciar o app.
- Isso depende de comportamento atual do Discord, que pode mudar a qualquer momento.
- Usar proxy/VPN para contornar a restrição pode violar os Termos de Serviço do Discord. Risco de punição à conta é baixo, mas existe — considere usar uma conta secundária.

## Avisos importantes

- **Só funciona no Discord para computador** com Equicord ou Vencord injetado. Vesktop e Equibop não são suportados pelos instaladores: eles trazem o mod embutido e não carregam de um checkout. Não funciona na versão de navegador/extensão.
- **Proxies gratuitas são fracas para anonimato**: o operador da proxy vê seus metadados de conexão, muitas estão mortas ou lentas, e o Discord pode pedir captcha para IPs de proxies públicas. Para anonimato real, **use Tor**.
- Usar clientes modificados viola os Termos de Serviço do Discord. Use por sua conta e risco.
- A saída cobre **apenas o gateway**. No padrão, o seu login e todo o resto do tráfego saem pelo seu IP real. Se você quer que a autenticação também vá escondida, mude **Session routing** para `Gateway and login` — ciente de que aí o boot fica mais lento.
- **O plugin nunca te deixa sem Discord.** A saída morrendo custa o Go Live, não o app — o roteador local cai sozinho para conexão direta, e isso é coberto por teste. Não existe mais prazo de 120 segundos nem marca de boot, porque não existe mais o cenário que eles cobriam, o de uma proxy quebrada segurando o Discord inteiro.
- **Quem opera a saída vê o seu tráfego de gateway.** É pouca coisa em bytes e vai toda dentro de TLS, mas é o canal por onde passam suas mensagens em tempo real. Uma proxy gratuita significa um desconhecido nesse lugar. Um servidor seu, ou o Tor, não.

## Como funciona

São duas travas independentes, e o plugin desarma as duas de formas diferentes.

### Trava 1: o cliente se auto-bloqueia

O Discord embarca um experimento de usuário que desliga vídeo. Quando o servidor te coloca nele, o cliente desabilita sozinho os botões de câmera e Go Live: é o `MediaEngineStore.supportsInApp(VIDEO)` que passa a retornar falso, e com ele o `canGoLive`.

O plugin esvazia a tabela de variações desse experimento. Qualquer bucket que o servidor atribua passa a cair na configuração padrão, que tem vídeo ligado. Isso destrava o cliente inteiro de uma vez, porque todos os consumidores leem do mesmo lugar.

### Trava 2: o servidor recusa a transmissão

Destravar o cliente não basta: o servidor decide separadamente se você pode transmitir, e essa decisão é tomada **uma única vez, quando você entra no canal de voz**, a partir do IP de origem da **conexão de gateway** (o WebSocket que carrega o `VOICE_STATE_UPDATE`). Depois disso não há reavaliação: o servidor de voz só transporta mídia por UDP.

Por isso o plugin roteia **só o gateway**, e é aqui que está a diferença de velocidade.

O `session.setProxy` do Electron vale para a sessão inteira. Ele não sabe dizer "esta conexão sim, aquela não". Uma versão que só tenha essa ferramenta é obrigada a mandar o boot inteiro pela proxy e tirar depois, e é isso que fazia o Discord demorar — o app subia por uma proxy pública, e ainda esperava a escolha dela terminar antes de começar a subir.

O Chromium tem uma segunda porta de entrada que resolve as duas coisas: **PAC**. Em `pac_script`, o campo `pacScript` recebe uma URL, e a resposta dela é uma função `FindProxyForURL(url, host)` que decide **por host**. É só disso que o plugin precisa:

1. Um **SOCKS5 local**, na abertura do app, que recebe só o que o PAC mandar e decide na hora por onde sair.
2. Um **PAC embutido numa `data:` URL** — sem servidor, sem arquivo, sem busca — dizendo que `gateway.discord.gg` vai para esse roteador e que **qualquer outro host segue a regra que o sistema já usava**, lida pelo `resolveProxy` antes de tudo. Quem está atrás de proxy corporativo não perde o Discord.

Subir o roteador leva milissegundos, então ele está de pé muito antes do gateway nascer. A escolha da saída acontece **depois**, em paralelo com o Discord carregando. Quando o gateway chega no roteador antes de existir saída, ele fica segurado ali (até 12 segundos) enquanto o resto do app carrega na velocidade normal. É a inversão que interessa — em vez do app inteiro esperar a proxy, uma única conexão espera, e ela é justamente a que precisa esperar.

O que foi verificado com um Chromium de verdade, passando o Edge pelo roteador:

- o PAC entregue como `data:` URL é obedecido, e `SOCKS5 127.0.0.1:porta` como retorno funciona;
- a separação por host é real: `gateway.discord.gg` atravessou o roteador e o `example.com` inteiro, com todos os subrecursos, saiu direto sem encostar nele;
- segurar a resposta do SOCKS5 por 6 segundos não derruba o pedido — o Chromium espera e carrega;
- com a saída apontando para uma porta morta, a página ainda carrega, porque o roteador cai para direto sozinho.

O que **não** dá para verificar sem uma conta bloqueada de verdade: se rotear só o gateway basta para liberar o Go Live, ou se o gate também olha o IP do login. Se no seu caso não bastar, mude **Session routing** para `Gateway and login`.

### Como as saídas são escolhidas

A ordem é a seguinte — a proxy que você escreveu, depois as que já funcionaram antes, depois um Tor local, depois a lista gratuita.

- **As que já funcionaram ficam guardadas.** Até cinco delas, com a latência medida, em `native-settings.json`. No boot seguinte todas são testadas juntas e a primeira a responder ganha. A busca cara na lista gratuita acontece com a sessão já aberta, para reabastecer o pote, e não mais no caminho da abertura do app.
- **Um teste só, em vez de dois.** A validação bate em `cloudflare.com/cdn-cgi/trace`, que responde em cerca de 200 bytes e já prova as quatro coisas de uma vez: o túnel SOCKS abre, o TLS fecha com certificado válido (proxy que intercepta morre aqui), veio HTTP 200, e de que país ela sai. A versão anterior gastava duas conexões para saber o mesmo, uma no `discord.com` e outra no `ifconfig.co`.
- **Candidatas correm juntas.** Doze por vez, e a primeira aceitável ganha. Antes o teste de país rodava uma por vez, depois do lote inteiro terminar, o que sozinho podia somar um minuto.
- A lista da ProxyScrape já traz `alive`, `uptime` e `timeout`, e o plugin **ranqueia por esses campos** (uptime >= 90, timeout <= 1500ms) em vez de sortear.
- Descarta a porta 4145: numa amostra medida, 14 de 14 proxies nessa porta interceptavam TLS com certificado forjado.
- Confirma o **país de saída real**, porque o `countryCode` da lista descreve o IP de entrada, que frequentemente é diferente do de saída.

**O melhor caminho continua não sendo lista gratuita.** Uma máquina sua fora do Brasil, com `ssh -D 1080 seu-servidor` e `socks5://127.0.0.1:1080` no campo Proxy, é estável, rápida, e não coloca um desconhecido no meio do seu gateway. As camadas gratuitas existem para quem não tem isso, não porque sejam boas.

### Proteções contra travar o Discord

Rotear só um host muda o pior caso. Uma saída ruim agora atinge uma conexão, não o app — e por isso a maior parte das proteções antigas deixou de ter motivo para existir.

- **O roteador local cai para direto sozinho.** Se a saída não abrir, ou se ela demorar demais para ser escolhida, ele conecta ao destino sem intermediário — custa o Go Live daquela sessão, e nada além. Recusar seria custar o Discord, porque a conexão em questão é o gateway.
- **A rede de segurança vive dentro do roteador, e não numa alternativa do PAC.** O host roteado sai por ele e ponto, sem `DIRECT` depois do ponto e vírgula. Ter essa alternativa custou uma sessão inteira durante o desenvolvimento: uma saída gratuita falhou uma vez, o Chromium marcou o SOCKS local como ruim, e a partir dali mandou tudo pela alternativa sem avisar ninguém — PAC no lugar, roteador escutando, e nenhuma conexão passando por ele.
- **Nada é aplicado fora do Discord.** Todo host que não está na lista recebe exatamente a regra que já valia antes do plugin existir.
- **Não existe mais prazo de 120 segundos**, porque não existe mais o cenário em que uma proxy quebrada segurava o app inteiro e precisava ser arrancada à força.
- **Não existe mais marca de boot.** Ela protegia contra o mesmo cenário, e tinha um efeito colateral ruim — qualquer inicialização que não terminasse (fechar o Discord na tela de login, por exemplo) fazia a inicialização seguinte se recusar a aplicar proxy, em silêncio. Na prática dava para ficar alternando entre um boot que libera e um que não libera sem entender o motivo. Quem vem de uma versão anterior pode apagar `bootPending` e `verifiedProxy` do `native-settings.json`, que não são mais lidos.

## Instalação automática (recomendado)

Um script encontra sozinho o Equicord ou o Vencord que você tem, instala o plugin, compila e injeta. Se você não tiver nenhum dos dois, ele pergunta qual você quer e instala junto.

**Windows, jeito mais simples:** baixe o [`GoLiveBypass-Installer.bat`](installer/GoLiveBypass-Installer.bat) e dê dois cliques. Ele libera a execução só para aquele processo (`Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass`), baixa o `.ps1` se ele não estiver do lado, e roda tudo.

**Linux:**

```bash
curl -fsSLO https://raw.githubusercontent.com/bezumiya/GoLiveBypass/main/installer/golivebypass-installer.sh
chmod +x golivebypass-installer.sh
./golivebypass-installer.sh
```

Ao abrir, ele mostra o que encontrou e um menu:

```
  Detectado:
    Discord   instalado (1)
    Mod       Equicord
    Fonte     /home/voce/Equicord
    Plugin    nao instalado

  O que voce quer fazer?

    [1] Instalar ou atualizar o GoLiveBypass
    [2] Remover so o plugin (o mod continua)
    [3] Restaurar tudo (remove o plugin e desfaz a injecao)
    [0] Sair
```

Escolhendo instalar, ele pergunta três coisas: **onde** (usar o mod que já está aí ou baixar outro), **como sair do Brasil** (proxy gratuita testada sozinha, Tor local, ou uma proxy sua) e **por quanto tempo** (permanente, ou temporário — que desfaz a injeção quando você fechar o Discord).

**Pelo PowerShell:**

```powershell
irm https://raw.githubusercontent.com/bezumiya/GoLiveBypass/main/installer/GoLiveBypass-Installer.ps1 -OutFile GoLiveBypass-Installer.ps1
powershell -ExecutionPolicy Bypass -File .\GoLiveBypass-Installer.ps1
```

Ele descobre onde está o seu checkout **lendo a própria injeção do Discord**: o instalador do Equicord e o do Vencord substituem o `app.asar` por um stub que faz `require` da pasta de build, e desse caminho dá para derivar a raiz do repositório. Se não achar por aí, procura nos lugares habituais.

| sua situação | o que acontece |
|---|---|
| Equicord ou Vencord já instalado a partir do fonte | Copia o plugin, compila e reinicia o Discord |
| Instalado, mas o Discord não carrega desse checkout | Compila e roda o `pnpm inject` para apontar o Discord para ele |
| Você não tem nenhum dos dois | Mostra uma tela para escolher **Equicord** ou **Vencord**, baixa, compila e injeta |
| Falta Git ou Node | No Windows, oferece instalar pelo winget. No Linux, mostra o comando da sua distro (o pacote do Node é `nodejs`, e costuma ser antigo demais: nesse caso use nvm, fnm ou o NodeSource). O pnpm sai do `corepack enable` nos dois |

A descoberta é automática e roda em milissegundos: primeiro lê a injeção do Discord, depois varre os lugares onde um checkout costuma estar (perfil, Documentos, Desktop, Downloads, `dev`, `repos`, `projects`, `source`, e a raiz de cada disco).

Outros modos:

```powershell
.\GoLiveBypass-Installer.ps1 -Source C:\caminho\do\Equicord  # aponta o checkout na mão
.\GoLiveBypass-Installer.ps1 -Mod Vencord                     # escolhe o mod sem a tela
.\GoLiveBypass-Installer.ps1 -Yes                             # sem perguntas, para automação
.\GoLiveBypass-Installer.ps1 -Mode Install                    # instala direto, sem menu
.\GoLiveBypass-Installer.ps1 -Mode Uninstall                  # remove o plugin e recompila
.\GoLiveBypass-Installer.ps1 -Mode Restore                    # remove o plugin e desfaz a injeção
```

```bash
./golivebypass-installer.sh --source ~/Equicord   # aponta o checkout na mão
./golivebypass-installer.sh --mod vencord         # escolhe o mod sem a tela
./golivebypass-installer.sh --yes                 # sem perguntas, para automação
./golivebypass-installer.sh --install             # instala direto, sem menu
./golivebypass-installer.sh --uninstall           # remove o plugin e recompila
./golivebypass-installer.sh --restore             # remove o plugin e desfaz a injeção
```

O instalador **baixa o plugin direto deste repositório** em vez de carregar uma cópia embutida, então nunca instala uma versão defasada. Ele nunca mexe no `app.asar`: quem injeta é o instalador oficial do Equicord/Vencord.

O instalador já deixa o plugin **ativado e configurado**. Depois que ele terminar, feche o Discord pela bandeja e abra de novo: é isso.

## Dependências: o que baixar e como instalar

> Se você usou o instalador automático acima, **pule esta seção e a próxima**. O instalador confere o que falta e oferece instalar sozinho. O que vem daqui em diante é o caminho manual, para quem prefere fazer cada passo à mão ou precisa entender o que está acontecendo.

Você precisa de **4 programas** antes de começar. Instale na ordem. Depois de instalar cada um, **feche e abra o terminal de novo** — o Windows só reconhece programas novos em terminais abertos depois da instalação.

### 1. Git — o programa que baixa código do GitHub

É ele que faz o `git clone` (baixar) deste repositório e do Equicord/Vencord.

**Windows (jeito mais fácil):**
1. Abra o **PowerShell** (tecla Windows → digite "PowerShell" → Enter)
2. Rode: `winget install Git.Git`
3. Ou, se preferir baixar manualmente: entre em [git-scm.com/download/win](https://git-scm.com/download/win), baixe o instalador de 64-bit e clique em **Next** em tudo (as opções padrão são as certas)

**Linux:** `sudo apt install git` (Debian/Ubuntu) ou o equivalente da sua distro.
**macOS:** `brew install git`.

**Confira se deu certo** (num terminal novo): `git --version` → deve mostrar algo como `git version 2.x.x`. Se disser "comando não encontrado", feche e abra o terminal.

### 2. Node.js 22 ou superior — o motor que compila o plugin

O Equicord/Vencord é feito em TypeScript, e quem transforma isso no programa final é o Node. **Versão menor que 22 quebra o build.**

**Windows/macOS:**
1. Entre em [nodejs.org](https://nodejs.org/) e baixe o botão verde **LTS** (qualquer LTS a partir do 22)
2. Instale clicando em **Next** em tudo — deixe marcada a opção de adicionar ao PATH (vem marcada)
3. Ou pelo terminal: `winget install OpenJS.NodeJS.LTS`

**Linux:** use o [NodeSource](https://github.com/nodesource/distributions) — o Node dos repositórios da distro costuma ser velho demais.

**Confira:** `node --version` → precisa mostrar `v22.x.x` ou maior.

### 3. pnpm — o instalador de peças do projeto

O projeto usa **pnpm** (e não o npm que vem com o Node) para baixar as bibliotecas do build. Você não baixa instalador nenhum: o Node já traz o **Corepack**, que ativa o pnpm com dois comandos.

Num terminal (depois de instalar o Node):

```bash
corepack enable
corepack prepare pnpm@latest --activate
```

Se der erro de permissão no Windows, abra o PowerShell **como administrador** e rode de novo. Se o Corepack não existir, a alternativa é: `npm install -g pnpm`.

**Confira:** `pnpm --version` → o projeto foi testado com pnpm 11.

### 4. Discord para computador — onde o plugin vai rodar

O plugin **só funciona no app de computador** (ele usa recursos do Electron que o navegador não tem):

- **Discord normal**: baixe em [discord.com/download](https://discord.com/download) (stable, PTB ou Canary servem); ou
- **Vesktop/Equibop**: apps alternativos que já trazem o mod embutido. Os instaladores daqui não mexem neles.
- **Não funciona** no Discord aberto no navegador nem no celular.

### Opcional: Tor — só se você quiser mais estabilidade

**Não é necessário.** Por padrão o plugin escolhe e testa uma proxy gratuita sozinho, sem nenhuma dependência extra.

O Tor é só uma opção para quem quer mais estabilidade: ele é mais rápido e não morre no meio do caminho como as proxies públicas. Se você já tiver o [Tor Browser](https://www.torproject.org/download/) aberto, o plugin detecta sozinho em `127.0.0.1:9150`; o daemon `tor` fica em `9050`.

## Instalação: passo a passo completo

> Este é o caminho manual. O [instalador automático](#instalação-automática-recomendado) faz tudo isto sozinho; siga daqui só se preferir fazer na mão.

Escolha **Equicord** ou **Vencord** — os dois funcionam, o processo é idêntico. Os exemplos usam Equicord; para Vencord, troque o link do clone por `https://github.com/Vendicated/Vencord` e a pasta para `Vencord`.

### Passo 1 — Baixe o código do Equicord

Abra o terminal, vá para a pasta onde quer guardar o projeto e clone:

```bash
cd Documents
git clone https://github.com/Equicord/Equicord
cd Equicord
```

### Passo 2 — Instale as bibliotecas do build

```bash
pnpm install
```

Isso baixa tudo que o Equicord precisa para compilar (demora um pouco na primeira vez, é normal).

### Passo 3 — Baixe o plugin e coloque na pasta certa

Duas formas de baixar este repositório:

- **Pelo terminal** (estando fora da pasta Equicord): `git clone https://github.com/bezumiya/GoLiveBypass`
- **Pelo navegador**: abra [github.com/bezumiya/GoLiveBypass](https://github.com/bezumiya/GoLiveBypass), clique no botão verde **Code → Download ZIP** e extraia o arquivo

Depois copie a pasta **`goLiveBypass`** (a que contém `index.tsx` e `native.ts`) para dentro de:

```
Equicord/src/userplugins/goLiveBypass
```

**Atenção aos detalhes que mais quebram:**

- A pasta `userplugins` **não existe por padrão** — crie ela dentro de `src/`
- Ela fica em `src/userplugins`, **ao lado** de `src/plugins` — **nunca dentro** de `src/plugins` (isso gera o erro `Could not resolve "./plugins/userplugins"` no build)
- No final, o caminho dos arquivos deve ser exatamente `src/userplugins/goLiveBypass/index.tsx` e `src/userplugins/goLiveBypass/native.ts`

### Passo 4 — Compile

```bash
pnpm build
```

Isso gera a pasta `dist/` com o Equicord modificado já incluindo o plugin. Se aparecer algum erro vermelho, leia a seção **Solução de problemas** antes de tentar de novo.

### Passo 5 — Injete no Discord

**Feche o Discord completamente antes** (ícone na bandeja perto do relógio → botão direito → **Quit Discord**). Depois:

```bash
pnpm inject
```

O instalador abre uma janelinha perguntando **qual Discord** você usa (Stable, PTB ou Canary) — escolha o seu e confirme. É isso que "injetar" faz: ele aponta o seu Discord para o build que você compilou. Para desfazer depois, basta rodar `pnpm uninject` na mesma pasta.

### Passo 6 — Ative o plugin e use

1. Abra o Discord
2. Vá em **Configurações → Equicord (ou Vencord) → Plugins** e ative **GoLiveBypass**
3. Deixe **Voice region** em `Automatic`, que é o padrão (leia o aviso abaixo antes de mudar)
4. Reinicie o Discord por completo (bandeja, Quit). O roteador sobe junto com o app, e a saída é escolhida enquanto o Discord carrega
5. Entre num canal de voz: **Go Live e câmera liberados**. Quem escolhe o servidor de voz é o Discord, e pode não ser o brasileiro. Não force `brazil` em **Voice region** sem ler o aviso na seção Configuração

## Configuração

Nas settings do plugin:

- **Voice region**: seletor com a lista real de regiões que o Discord expõe. Padrão: `Automatic`, que devolve a decisão ao Discord.

  > **Cuidado ao forçar `brazil` aqui.** Há indício de que o servidor de mídia brasileiro é justamente onde a transmissão é recusada: numa sessão em que a call caiu no Brasil o Go Live não subiu, e numa sessão em que caiu em Santiago funcionou. São duas observações, não uma prova, mas o padrão seguro é não forçar. Use este campo se quiser priorizar latência e estiver disposto a perder o Go Live.

  Vale saber que isto é uma **preferência**, não uma ordem: o Discord pode ignorar e escolher outra região, e foi o que aconteceu no teste.
- **Session routing**: o que passa pela saída. Padrão `Gateway only` — o mais rápido, e o único necessário para liberar o Go Live. Em `Gateway and login`, o `discord.com` também passa pela saída enquanto você autentica, o que esconde seu endereço real nesse momento e deixa a abertura do app mais lenta. Assim que a sessão abre, o escopo encolhe sozinho de volta para o gateway.
- **Proxy**: a saída do gateway — no formato `esquema://host:porta` (`socks5`, `http` ou `https`).
  - Um servidor seu é a melhor opção: `ssh -D 1080 usuario@seu-servidor` e depois `socks5://127.0.0.1:1080` aqui.
  - Tor, se você usa: `socks5://127.0.0.1:9150` com o **Tor Browser** aberto, ou `socks5://127.0.0.1:9050` para o **daemon** `tor`.
  - **Deixe vazio** para o plugin reaproveitar uma saída já testada, detectar um Tor local, ou buscar uma gratuita validada, nessa ordem.
- **Excluded countries**: códigos de país de duas letras separados por vírgula que nunca são usados (padrão: `BR`). O país conferido é o de **saída real**, medido através da proxy, não o que a lista afirma.

## Uso

1. Abra o Discord normalmente. O roteador sobe junto e a saída é escolhida em paralelo, sem segurar o app.
2. Se você escolheu Tor, deixe o Tor aberto antes; com saída automática não precisa fazer nada.
3. Espere o toast. `Go Live is unlocked` diz por qual saída o gateway ficou. `Discord still has Go Live blocked` diz o que falhou — se nenhuma saída foi encontrada a tempo, feche o Discord de verdade (bandeja, Quit) e abra de novo; se uma saída foi usada e mesmo assim ficou bloqueado, troque a saída ou mude **Session routing** para `Gateway and login`.
4. Entre na call e transmita.

Reconexão do gateway no meio da sessão não custa mais o desbloqueio — o socket novo nasce pela mesma saída, porque a regra continua valendo. Ctrl+R também funciona.

## Solução de problemas

- **Discord carregando infinitamente**: não deveria mais acontecer por causa do plugin, já que ele não roteia nada além de `gateway.discord.gg` e cai para direto sozinho. Se acontecer mesmo assim, com o Discord fechado abra `%APPDATA%/Equicord/settings/settings.json` (ou `.../Vencord/...`) e coloque `"GoLiveBypass": { "enabled": false }`. Em `native-settings.json` a chave deste plugin é `pool` (as saídas guardadas), e apagá-la devolve tudo ao estado inicial. Se você vem de uma versão anterior, apague também `verifiedProxy`, `bootPending` e `lastKnownProxy`, que não são mais lidas.
- **"GoLiveBypass is reloading behind the exit"**: a saída ficou pronta depois de o gateway já ter conectado, então a sessão nasceu desprotegida e o servidor manteve o bloqueio. O plugin procura uma saída que responda e recarrega o cliente sozinho para a sessão renascer atrás dela. São no máximo duas tentativas: sem esse teto, um bloqueio que a saída não resolve viraria recarregamento sem fim.
- **"GoLiveBypass could not unlock this session"**: as tentativas acabaram e a sessão continua bloqueada. Aponte o campo **Proxy** para um servidor seu e reinicie o Discord pela bandeja. Rotear só o gateway pode não ter bastado no seu caso: **Session routing** em `Gateway and login` manda o `discord.com` junto durante a autenticação.
- **Nenhuma saída passou nos testes**: nenhuma candidata fechou TLS com certificado válido naquele momento. Tente de novo, ou use Tor ou uma proxy sua no campo Proxy.
- **Quer ver o que aconteceu**: rode `/golivebypass` em qualquer canal. Ele copia um diagnóstico com o estado das travas, da transmissão, da região e o registro do processo principal — qual saída foi testada, quanto tempo levou, em que país ela sai e por que foi recusada.
- **A região da call não mudou**: saia e entre de novo no canal. Canais de servidor com região fixada por um admin ignoram sua preferência, e numa call que já está rolando a região já foi decidida.
- **Captcha ou verificação de telefone no login**: o Discord marca muitos IPs de proxies públicas. Use Tor ou outra proxy.
- **`Cannot find matching keyid` ao instalar as dependências**: é o corepack, não o plugin. Ele cria o atalho do `pnpm` antes de saber que versão usar, e na primeira execução busca essa versão no registro do npm conferindo a assinatura com chaves embutidas nele — as que vêm no Node 22 estão vencidas. O instalador detecta isso e instala o pnpm pelo npm. Se estiver fazendo à mão, rode `npm install -g pnpm` e siga com `pnpm install`.
- **Erro de build `Could not resolve "./plugins/userplugins"`**: você copiou a pasta para dentro de `src/plugins/` por engano. O caminho certo é `src/userplugins/goLiveBypass` — a pasta `userplugins` fica em `src/`, **ao lado** de `plugins`, e pode ser necessário criá-la.
- **Plugin não aparece na lista**: confirme que a pasta está em `src/userplugins/goLiveBypass` (com `index.tsx` e `native.ts`) e que você rodou `pnpm build` + `pnpm inject` e reiniciou o Discord.

## Estrutura

```
goLiveBypass/
├── index.tsx                      # renderer: patches do video guard e do stream, seletor de região,
│                                  #   override do RTCRegionStore, eventos de fluxo
└── native.ts                      # processo principal: roteador SOCKS5 local e PAC por data: URL,
                                   #   escolha e validação TLS das saídas, detecção de Tor,
                                   #   registro e nova tentativa

installer/
├── GoLiveBypass-Installer.bat     # Windows: dois cliques, libera a execução e chama o .ps1
├── GoLiveBypass-Installer.ps1     # Windows: instalador automático
└── golivebypass-installer.sh      # Linux: mesmo instalador, mesmo menu

assets/
└── instalacao.gif                 # o vídeo do começo deste README
```

## Licença

GPL-3.0-or-later, mesma licença do Vencord/Equicord. Veja [LICENSE](LICENSE).

## Autor

**bezumiya**

- GitHub: [bezumiya/GoLiveBypass](https://github.com/bezumiya/GoLiveBypass)
- Twitter: [@obezumiya](https://twitter.com/obezumiya)
- Discord: `1366453661970071633`

## Agradecimentos

**Obrigado ao [Vithor](https://github.com/Vith0r)** pelo instalador.

Ele escreveu o primeiro instalador do GoLiveBypass por conta própria, e foi ele quem mostrou
que dava para automatizar tudo isso num script só. O instalador que está aqui hoje nasceu
desse trabalho.

# English

**GoLiveBypass** is an **Equicord/Vencord** plugin, made by a Brazilian developer, that **restores Go Live and camera for Brazilian Discord users**. Discord's region gate is evaluated once at voice-channel join, from the gateway WebSocket origin IP, and never re-evaluated mid-call, so that single socket is the only thing that needs to leave Brazil.

The plugin routes exactly that. On startup it brings up a local SOCKS5 router and installs a PAC embedded in a `data:` URL — no server, no file, no fetch — that sends only `gateway.discord.gg` to the router; every other host keeps whatever rule the system already had, read from `resolveProxy` beforehand. Startup costs milliseconds, so the exit is chosen afterwards, in parallel with Discord loading, instead of holding the whole boot. A gateway connection that arrives before an exit exists waits at the local router for up to 12 seconds while the rest of the app loads at full speed.

Verified against real Chromium: a PAC delivered as a `data:` URL is honoured and `SOCKS5 127.0.0.1:port` works as a return value; per-host separation is real (the routed host crossed the router while another site loaded fully without touching it); holding the SOCKS5 reply for 6 seconds does not kill the request; and with the exit pointed at a dead port the page still loads, because the router falls back to direct on its own. What cannot be verified without a blocked account: whether routing the gateway alone is enough, or whether the gate also reads the login IP. Switch **Session routing** to `Gateway and login` if it is not enough for you.

It was written after Brazil's data protection authority (ANPD) [ordered Discord to suspend live streaming (Go Live) in Brazil](https://www.gov.br/anpd/pt-br/assuntos/noticias/em-medida-preventiva-anpd-determina-que-discord-suspenda-transmissoes-ao-vivo-no-brasil) in August 2026, shortly after the country blocked X (Twitter). Because the rule stays installed, a gateway reconnect keeps the unlock and Ctrl+R works. Bypassing the restriction may violate Discord's ToS.

- Desktop Discord with Equicord or Vencord injected. Vesktop and Equibop are not supported by the installers, since they bundle the mod instead of loading it from a checkout. Not available on the browser extension.
- Dependencies: Git, Node.js 22+, pnpm 11 (via `corepack enable`), and a desktop Discord client. Tor is optional, not required: by default the plugin picks and validates a free proxy on its own.
- **Your calls stay on the region you pick.** Creating the session abroad makes Discord rank foreign voice servers, so the plugin overrides the three `RTCRegionStore` getters that feed `preferred_region` / `preferred_regions` in the gateway `VOICE_STATE_UPDATE`. The override is evaluated at read time, so Discord's latency test cannot undo it, and it writes nothing into Discord's persisted state, so the region is not left pinned after you remove the plugin. Restored on `stop()`.
- Exit order: your manual proxy, then exits that already worked (up to five, kept with their measured latency and all probed together on the next boot), then a local Tor (`127.0.0.1:9150` for Tor Browser, `9050` for the daemon), then a validated free proxy. The expensive search over the free list runs once the session is already open, to refill the pool, not on the startup path.
- Validation is a single request to `cloudflare.com/cdn-cgi/trace`, roughly 200 bytes, which proves the SOCKS tunnel opens, TLS closes with a valid certificate (intercepting proxies die here), HTTP 200 came back, and which country it exits from. Candidates are validated twelve at a time and the first acceptable one wins.
- Free proxies are ranked by the `alive` / `uptime` / `timeout` metadata the list already returns, and port 4145 is dropped (measured 14/14 TLS interception).
- Free proxies are weak for anonymity, and whoever runs the exit sees your gateway traffic. Your own machine abroad (`ssh -D 1080`, then `socks5://127.0.0.1:1080`) is the option with nobody else in the middle. Tor is the next best.
- It cannot leave you unable to open Discord: the local router falls back to a direct connection if the exit fails or takes too long, the PAC keeps the system rule as its last resort, and nothing outside `gateway.discord.gg` is touched at all.
- Install: copy the `goLiveBypass` folder into `src/userplugins/` of your Equicord or Vencord clone, then `pnpm install && pnpm build && pnpm inject`, fully restart Discord, and enable **GoLiveBypass** in plugin settings.
- Made by **bezumiya** — [GitHub](https://github.com/bezumiya/GoLiveBypass), [Twitter](https://twitter.com/obezumiya), Discord `1366453661970071633`.
- Thanks to **[Vithor](https://github.com/Vith0r)** for the installer: he wrote the first GoLiveBypass installer on his own and showed that the whole setup could be automated in a single script.
- License: GPL-3.0-or-later.
