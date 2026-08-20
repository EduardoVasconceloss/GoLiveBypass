# Contribuindo com o StreamFix

Obrigado por querer ajudar. Este projeto é pequeno, então o processo também é.

## Rodando localmente

O plugin não roda sozinho — ele é compilado dentro de um checkout do Equicord ou Vencord. Veja o [passo a passo completo no README](README.md#instalação-passo-a-passo-completo); resumindo:

```bash
git clone https://github.com/Equicord/Equicord
cd Equicord
pnpm install

git clone https://github.com/EduardoVasconceloss/StreamFix
cp -r StreamFix/streamFix src/userplugins/streamFix

pnpm build
pnpm inject   # com o Discord fechado
```

Depois de mexer no código, `pnpm build` de novo e reinicie o Discord pela bandeja para ver o efeito.

- `streamFix/index.tsx` — renderer: patches do video guard, seletor de região, override do `RTCRegionStore`
- `streamFix/native.ts` — processo principal: roteador SOCKS5 local, PAC, escolha e validação de saídas
- `installer/` — os instaladores automáticos (`.ps1`, `.sh`, `.bat`); veja o [workflow de build](.github/workflows/build-installer.yml) para como os `.exe` são gerados

## Propondo mudanças

1. Abra uma issue antes de PRs grandes, pra alinhar a ideia — evita trabalho jogado fora.
2. Um PR por mudança lógica. PRs pequenos e focados são revisados mais rápido.
3. Teste manualmente com um Discord de verdade antes de abrir o PR: o plugin mexe em rede e em travas do próprio Discord, e isso não tem como validar só lendo o código.
4. Descreva no PR **o que mudou e por quê** — o "porquê" é o que mais falta em revisão de código de rede/proxy.

## Testes do instalador Linux

A camada de descoberta do `installer/streamfix-installer.sh` (achar o Discord, resolver o caminho do mod, identificar qual mod um checkout é) tem testes de caracterização em shell puro, sem framework, contra uma árvore de fixtures — não precisa de Discord instalado nem de rede:

```bash
bash installer/tests/run-tests.sh
```

O CI roda o mesmo comando e o ShellCheck em todo PR que toca o instalador. Isso não substitui o item 3 acima: os testes cobrem só a descoberta, e o resto do fluxo (injeção, proxy, persistência) continua exigindo um Discord de verdade.

## Convenção de commits

O histórico segue [Conventional Commits](https://www.conventionalcommits.org/), com alguns prefixos específicos deste repositório além dos padrão (`feat`, `fix`, `docs`, `chore`, `ci`, `refactor`):

- `instalador:` — mudanças nos scripts de `installer/`
- `plugin:` — mudanças no `streamFix/` que não são `feat` nem `fix` (ex.: renomeações, migração de configs)

Exemplos do histórico real: `fix: fazer release-please disparar o build do instalador na mesma run`, `instalador: bump do pin do instalador Linux pro rename StreamFix`.

Mensagens em português, curtas, no imperativo. O `CHANGELOG.md` é gerado automaticamente a partir delas (via [release-please](https://github.com/googleapis/release-please)), então a primeira linha precisa fazer sentido sozinha.

## Código de conduta

Este projeto segue o [Código de Conduta](CODE_OF_CONDUCT.md).
