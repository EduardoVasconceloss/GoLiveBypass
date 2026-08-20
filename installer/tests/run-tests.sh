#!/usr/bin/env bash
#
# Testes de caracterizacao da camada de descoberta do instalador (streamfix-installer.sh),
# Linux e macOS.
#
# Shell puro, sem framework: o repositorio nao tem manifesto de dependencias para a parte de
# instalador, e um framework a mais seria a maior adicao desta spec. Roda com o que ja vem
# numa maquina Linux ou macOS comum -- o ramo Darwin da descoberta e exercitado por fixture em
# qualquer runner, sem precisar de um Mac de verdade (ver fixture_setup()).
#
# Uso:
#   ./installer/tests/run-tests.sh
#
# Cada teste monta uma arvore de fixtures num diretorio temporario, aponta FS_PREFIX e HOME
# para dentro dela e chama as funcoes de descoberta do instalador. Nada disso toca o sistema
# de arquivos de verdade: FS_PREFIX prefixa as raizes absolutas que a descoberta varre, e HOME
# aponta a arvore inteira relativa ao usuario para a fixture.

set -uo pipefail

# Nome proprio, e nao SCRIPT_DIR: o instalador tambem define uma variavel SCRIPT_DIR ao ser
# carregado logo abaixo, e ela sobrescreveria esta.
TESTS_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
INSTALLER="$TESTS_DIR/../streamfix-installer.sh"

# shellcheck source=../streamfix-installer.sh
source "$INSTALLER"

# A guarda de sourcing ja impediu o banner e o menu de rodarem; set -e do script sourceado
# ficaria em vigor daqui pra frente e derrubaria o runner no primeiro `[ ... ] || true` mal
# colocado. Os testes tratam falha explicitamente, entao desligamos -e e -o pipefail.
set +e +o pipefail

TESTS_RUN=0
TESTS_FAILED=0

assert_eq() {
    local desc="$1" expected="$2" actual="$3"
    TESTS_RUN=$((TESTS_RUN + 1))
    if [ "$expected" = "$actual" ]; then
        printf '  ok - %s\n' "$desc"
    else
        TESTS_FAILED=$((TESTS_FAILED + 1))
        printf '  FALHOU - %s\n    esperado: %s\n    recebido: %s\n' "$desc" "$expected" "$actual"
    fi
}

# Compara dois conjuntos de linhas ignorando ordem: a descoberta nao promete varrer as raizes
# numa ordem estavel, so promete achar tudo que existe.
assert_set_eq() {
    local desc="$1" expected="$2" actual="$3"
    local expected_sorted actual_sorted
    expected_sorted="$(printf '%s\n' "$expected" | sed '/^$/d' | sort)"
    actual_sorted="$(printf '%s\n' "$actual" | sed '/^$/d' | sort)"
    assert_eq "$desc" "$expected_sorted" "$actual_sorted"
}

assert_true() {
    local desc="$1"; shift
    TESTS_RUN=$((TESTS_RUN + 1))
    if "$@" >/dev/null 2>&1; then
        printf '  ok - %s\n' "$desc"
    else
        TESTS_FAILED=$((TESTS_FAILED + 1))
        printf '  FALHOU - %s (esperava sucesso)\n' "$desc"
    fi
}

assert_false() {
    local desc="$1"; shift
    TESTS_RUN=$((TESTS_RUN + 1))
    if "$@" >/dev/null 2>&1; then
        TESTS_FAILED=$((TESTS_FAILED + 1))
        printf '  FALHOU - %s (esperava falha)\n' "$desc"
    else
        printf '  ok - %s\n' "$desc"
    fi
}

# ------------------------------------------------------------------------------- fixtures

FIXTURE_ROOT=""

# fixture_setup [Linux|Darwin]
#
# O padrao e Linux, e nao o uname -s de verdade do runner: os dois jobs do CI (ubuntu-latest e
# macos-latest) rodam o mesmo run-tests.sh, e sem isto os testes de Linux quebrariam so por
# rodar no runner macOS. Cada teste que quer o ramo Darwin passa isso explicitamente.
fixture_setup() {
    FIXTURE_ROOT="$(mktemp -d)"
    FS_PREFIX="$FIXTURE_ROOT/root"
    HOME="$FIXTURE_ROOT/home"
    OS_NAME="${1:-Linux}"
    unset XDG_CONFIG_HOME XDG_DATA_HOME 2>/dev/null
    mkdir -p "$FS_PREFIX" "$HOME"
}

fixture_teardown() {
    [ -n "$FIXTURE_ROOT" ] && rm -rf "$FIXTURE_ROOT"
    FIXTURE_ROOT=""
}

# make_asar <diretorio-resources>
make_asar() {
    mkdir -p "$1"
    : > "$1/app.asar"
}

# make_checkout <diretorio> <nome-no-package-json>
make_checkout() {
    local dir="$1" name="$2"
    mkdir -p "$dir/src/utils" "$dir/.git"
    printf '{"name":"%s"}\n' "$name" > "$dir/package.json"
    : > "$dir/src/utils/types.ts"
}

# make_injected <diretorio-resources> <diretorio-checkout>
#
# Reproduz o que o Equicord/Vencord deixam para tras: o app.asar original renomeado para
# _app.asar, e uma pasta app/index.js que so faz require() do checkout.
make_injected() {
    local resources="$1" checkout="$2"
    mkdir -p "$resources/app"
    printf 'require("%s/dist/desktop");\n' "$checkout" > "$resources/app/index.js"
    : > "$resources/_app.asar"
}

# ------------------------------------------------------------------------------- descoberta

test_pacote_nativo() {
    printf '\n== descoberta: pacote nativo com o app embutido ==\n'
    fixture_setup
    make_asar "$FS_PREFIX/usr/share/discord/resources"

    assert_set_eq "acha o resources do pacote nativo" \
        "$FS_PREFIX/usr/share/discord/resources" \
        "$(discord_resources)"
    assert_eq "install_location sobe uma pasta" \
        "$FS_PREFIX/usr/share/discord" \
        "$(install_location "$FS_PREFIX/usr/share/discord/resources")"

    fixture_teardown
}

test_bootstrap_usuario() {
    printf '\n== descoberta: esquema de bootstrap no diretorio do usuario ==\n'
    fixture_setup
    make_asar "$HOME/.config/discord/app-1.0.9/resources"

    assert_set_eq "acha o resources baixado na primeira execucao" \
        "$HOME/.config/discord/app-1.0.9/resources" \
        "$(discord_resources)"
    assert_eq "install_location sobe duas pastas (passa por app-1.0.9)" \
        "$HOME/.config/discord" \
        "$(install_location "$HOME/.config/discord/app-1.0.9/resources")"

    fixture_teardown
}

test_flatpak_sistema() {
    printf '\n== descoberta: flatpak de sistema ==\n'
    fixture_setup
    make_asar "$FS_PREFIX/var/lib/flatpak/app/com.discordapp.Discord/current/active/files/discord/resources"

    local achado
    achado="$(discord_resources)"
    assert_set_eq "acha o resources dentro do deploy do flatpak" \
        "$FS_PREFIX/var/lib/flatpak/app/com.discordapp.Discord/current/active/files/discord/resources" \
        "$achado"
    assert_eq "flatpak_app_id le o id do caminho" \
        "com.discordapp.Discord" \
        "$(flatpak_app_id "$achado")"
    assert_eq "install_location para antes do current/active" \
        "$FS_PREFIX/var/lib/flatpak/app/com.discordapp.Discord" \
        "$(install_location "$achado")"

    fixture_teardown
}

test_flatpak_usuario() {
    printf '\n== descoberta: flatpak de usuario ==\n'
    fixture_setup
    make_asar "$HOME/.local/share/flatpak/app/com.discordapp.DiscordPTB/current/active/files/discordptb/resources"

    local achado
    achado="$(discord_resources)"
    assert_set_eq "acha o resources dentro do deploy do flatpak de usuario" \
        "$HOME/.local/share/flatpak/app/com.discordapp.DiscordPTB/current/active/files/discordptb/resources" \
        "$achado"
    assert_eq "flatpak_app_id le o id do canal PTB" \
        "com.discordapp.DiscordPTB" \
        "$(flatpak_app_id "$achado")"
    assert_eq "install_location para antes do current/active tambem no flatpak de usuario" \
        "$HOME/.local/share/flatpak/app/com.discordapp.DiscordPTB" \
        "$(install_location "$achado")"

    fixture_teardown
}

test_discord_ja_injetado() {
    printf '\n== descoberta: Discord ja injetado (asar original renomeado) ==\n'
    fixture_setup
    local checkout="$HOME/Equicord"
    make_checkout "$checkout" "equicord"
    make_injected "$FS_PREFIX/opt/discord/resources" "$checkout"

    assert_set_eq "o resources injetado continua aparecendo na descoberta (_app.asar conta)" \
        "$FS_PREFIX/opt/discord/resources" \
        "$(discord_resources)"
    assert_eq "checkout_from_injection acha o checkout pelo stub" \
        "$checkout" \
        "$(checkout_from_injection)"
    assert_eq "installed_mod le Equicord pelo require() do stub" \
        "Equicord" \
        "$(installed_mod)"
    assert_true "injected_from_checkout confirma que este checkout esta injetado" \
        injected_from_checkout "$checkout"
    assert_eq "install_location continua resolvendo com o Discord ja injetado" \
        "$FS_PREFIX/opt/discord" \
        "$(install_location "$FS_PREFIX/opt/discord/resources")"

    fixture_teardown
}

test_mais_de_um_discord() {
    printf '\n== descoberta: mais de um Discord ao mesmo tempo ==\n'
    fixture_setup
    make_asar "$FS_PREFIX/usr/share/discord/resources"
    make_asar "$HOME/.config/discordptb/app-1.2.3/resources"

    local achado count
    achado="$(discord_resources)"
    count="$(printf '%s\n' "$achado" | sed '/^$/d' | wc -l | tr -d ' ')"
    assert_eq "acha os dois Discords" "2" "$count"
    assert_set_eq "os dois caminhos aparecem, em qualquer ordem" \
        "$FS_PREFIX/usr/share/discord/resources
$HOME/.config/discordptb/app-1.2.3/resources" \
        "$achado"
    assert_eq "install_location resolve o nativo mesmo com outro Discord por perto" \
        "$FS_PREFIX/usr/share/discord" \
        "$(install_location "$FS_PREFIX/usr/share/discord/resources")"
    assert_eq "install_location resolve o bootstrap mesmo com outro Discord por perto" \
        "$HOME/.config/discordptb" \
        "$(install_location "$HOME/.config/discordptb/app-1.2.3/resources")"

    fixture_teardown
}

test_nenhum_discord() {
    printf '\n== descoberta: nenhum Discord instalado ==\n'
    fixture_setup

    assert_eq "discord_resources nao acha nada" "" "$(discord_resources)"
    assert_false "installed_mod falha sem Discord" installed_mod
    assert_false "checkout_from_injection falha sem Discord" checkout_from_injection

    fixture_teardown
}

# ------------------------------------------------------------------------ descoberta: macOS

test_macos_sistema() {
    printf '\n== descoberta (Darwin): canal estavel em /Applications ==\n'
    fixture_setup Darwin
    make_asar "$FS_PREFIX/Applications/Discord.app/Contents/Resources"

    assert_set_eq "acha o resources dentro do bundle de sistema" \
        "$FS_PREFIX/Applications/Discord.app/Contents/Resources" \
        "$(discord_resources)"
    assert_eq "install_location resolve o bundle inteiro, nao o Contents" \
        "$FS_PREFIX/Applications/Discord.app" \
        "$(install_location "$FS_PREFIX/Applications/Discord.app/Contents/Resources")"

    fixture_teardown
}

test_macos_usuario() {
    printf '\n== descoberta (Darwin): canal PTB em ~/Applications ==\n'
    fixture_setup Darwin
    make_asar "$HOME/Applications/Discord PTB.app/Contents/Resources"

    assert_set_eq "acha o resources dentro do bundle do usuario" \
        "$HOME/Applications/Discord PTB.app/Contents/Resources" \
        "$(discord_resources)"
    assert_eq "install_location resolve o bundle do usuario" \
        "$HOME/Applications/Discord PTB.app" \
        "$(install_location "$HOME/Applications/Discord PTB.app/Contents/Resources")"

    fixture_teardown
}

test_macos_quatro_canais() {
    printf '\n== descoberta (Darwin): os quatro canais ao mesmo tempo ==\n'
    fixture_setup Darwin
    make_asar "$FS_PREFIX/Applications/Discord.app/Contents/Resources"
    make_asar "$FS_PREFIX/Applications/Discord PTB.app/Contents/Resources"
    make_asar "$HOME/Applications/Discord Canary.app/Contents/Resources"
    make_asar "$HOME/Applications/Discord Development.app/Contents/Resources"

    local achado count
    achado="$(discord_resources)"
    count="$(printf '%s\n' "$achado" | sed '/^$/d' | wc -l | tr -d ' ')"
    assert_eq "acha os quatro canais" "4" "$count"
    assert_set_eq "os quatro caminhos aparecem, em qualquer ordem" \
        "$FS_PREFIX/Applications/Discord.app/Contents/Resources
$FS_PREFIX/Applications/Discord PTB.app/Contents/Resources
$HOME/Applications/Discord Canary.app/Contents/Resources
$HOME/Applications/Discord Development.app/Contents/Resources" \
        "$achado"

    fixture_teardown
}

test_macos_injetado() {
    printf '\n== descoberta (Darwin): bundle ja injetado (asar original renomeado) ==\n'
    fixture_setup Darwin
    local checkout="$HOME/Equicord"
    make_checkout "$checkout" "equicord"
    make_injected "$FS_PREFIX/Applications/Discord.app/Contents/Resources" "$checkout"

    assert_set_eq "o resources injetado continua aparecendo na descoberta (_app.asar conta)" \
        "$FS_PREFIX/Applications/Discord.app/Contents/Resources" \
        "$(discord_resources)"
    assert_eq "checkout_from_injection acha o checkout pelo stub" \
        "$checkout" \
        "$(checkout_from_injection)"
    assert_eq "installed_mod le Equicord pelo require() do stub" \
        "Equicord" \
        "$(installed_mod)"
    assert_true "injected_from_checkout confirma que este checkout esta injetado" \
        injected_from_checkout "$checkout"
    assert_eq "install_location resolve o bundle mesmo ja injetado" \
        "$FS_PREFIX/Applications/Discord.app" \
        "$(install_location "$FS_PREFIX/Applications/Discord.app/Contents/Resources")"

    fixture_teardown
}

test_macos_sem_flatpak() {
    printf '\n== descoberta (Darwin): nao alcanca o ramo de flatpak ==\n'
    fixture_setup Darwin
    # As mesmas fixtures que os testes Linux usam para achar Discord de flatpak. No ramo
    # Darwin elas tem que ficar invisiveis: nada de flatpak existe no macOS.
    make_asar "$FS_PREFIX/var/lib/flatpak/app/com.discordapp.Discord/current/active/files/discord/resources"
    make_asar "$HOME/.var/app/com.discordapp.Discord/config/discord/app-1.0.9/resources"
    make_asar "$FS_PREFIX/usr/share/discord/resources"

    assert_eq "discord_resources nao ve nenhuma fixture ao estilo Linux/flatpak" \
        "" "$(discord_resources)"

    fixture_teardown
}

# ------------------------------------------------------------------ macOS: settings do mod

test_macos_settings_path() {
    printf '\n== settings (Darwin): pasta de suporte a aplicativos do usuario ==\n'
    fixture_setup Darwin
    local checkout="$HOME/Equicord"
    make_checkout "$checkout" "equicord"

    assert_eq "settings ficam em Library/Application Support, nao em .config" \
        "$HOME/Library/Application Support/Equicord/settings/settings.json" \
        "$(mod_settings_file "$checkout")"

    EQUICORD_USER_DATA_DIR="$HOME/Custom/EquicordData"
    assert_eq "a variavel de override continua valendo no macOS" \
        "$HOME/Custom/EquicordData/settings/settings.json" \
        "$(mod_settings_file "$checkout")"
    unset EQUICORD_USER_DATA_DIR

    fixture_teardown
}

# --------------------------------------------------------------------- identificacao de mod

test_checkout_mod() {
    printf '\n== identificacao: qual mod um checkout e ==\n'
    fixture_setup

    make_checkout "$HOME/a" "equicord"
    assert_eq "package.json com name equicord" "Equicord" "$(checkout_mod "$HOME/a")"

    make_checkout "$HOME/b" "vencord"
    assert_eq "package.json com name vencord" "Vencord" "$(checkout_mod "$HOME/b")"

    # Pasta com nome que nao diz nada (quem baixou o ZIP do GitHub, ex.: Equicord-main):
    # a identidade vem do package.json, nao do nome da pasta.
    make_checkout "$HOME/Equicord-main" "equicord"
    assert_eq "nome da pasta nao importa quando o package.json responde" \
        "Equicord" "$(checkout_mod "$HOME/Equicord-main")"

    fixture_teardown
}

# ------------------------------------------------------------------------------- sourcing

test_guarda_de_sourcing() {
    printf '\n== seam: guarda de sourcing ==\n'
    # Stdin fechado (< /dev/null): se a guarda falhasse e o menu rodasse, o "read" do menu
    # bateria em EOF na hora em vez de travar o teste esperando por um humano.
    local saida
    saida="$(cd "$TESTS_DIR" && bash -c 'source "../streamfix-installer.sh"; echo SOURCED_OK' < /dev/null 2>&1)"
    assert_eq "carregar com source nao imprime o banner nem abre o menu" \
        "SOURCED_OK" "$saida"
}

# ------------------------------------------------------------------------------------ main

test_pacote_nativo
test_bootstrap_usuario
test_flatpak_sistema
test_flatpak_usuario
test_discord_ja_injetado
test_mais_de_um_discord
test_nenhum_discord
test_macos_sistema
test_macos_usuario
test_macos_quatro_canais
test_macos_injetado
test_macos_sem_flatpak
test_macos_settings_path
test_checkout_mod
test_guarda_de_sourcing

printf '\n%s de %s testes passaram\n' "$((TESTS_RUN - TESTS_FAILED))" "$TESTS_RUN"
[ "$TESTS_FAILED" -eq 0 ]
