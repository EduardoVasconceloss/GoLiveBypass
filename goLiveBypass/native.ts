/*
 * Vencord, a Discord client mod
 * Copyright (c) 2026 Vendicated and contributors
 * SPDX-License-Identifier: GPL-3.0-or-later
 */

import { NativeSettings, RendererSettings } from "@main/settings";
import { app, IpcMainInvokeEvent, session } from "electron";
import { request } from "https";
import { AddressInfo, connect, createServer as createSocksServer, Server as SocksServer, Socket } from "net";
import { connect as connectTls } from "tls";

const FREE_PROXY_API = "https://api.proxyscrape.com/v4/free-proxy-list/get?request=display_proxies&protocol=socks5&proxy_format=protocolipport&format=json&timeout=1500";
const DISCORD_HOST = "discord.com";

// O trace da Cloudflare responde em ~200 bytes e ja diz tudo que precisamos saber de uma
// candidata: que o tunel SOCKS abre, que o TLS fecha com certificado valido (proxy que
// intercepta cai aqui), que veio HTTP 200, e de que pais ela sai. A validacao antiga
// gastava duas conexoes, uma no discord.com e outra no ifconfig.co, para descobrir o mesmo.
const TRACE_HOST = "cloudflare.com";
const TRACE_PATH = "/cdn-cgi/trace";

const GATEWAY_HOSTS = ["gateway.discord.gg", "remote-auth-gateway.discord.gg"];
const LOGIN_HOSTS = ["discord.com", "canary.discord.com", "ptb.discord.com"];

const MAX_LIST_BYTES = 1024 * 1024;
const PROBE_TIMEOUT_MS = 6000;

// Prazo curto para as checagens que acontecem no caminho da abertura: a saida do campo Proxy
// e as guardadas no pote. Todas elas ou respondem rapido ou nao servem, e cada segundo gasto
// aqui sai do orcamento que segura o gateway.
const WARM_PROBE_TIMEOUT_MS = 2500;

const PARALLEL_PROBES = 12;
const MAX_CANDIDATES = 48;
const MIN_UPTIME = 90;
const MAX_LISTED_TIMEOUT = 1500;

// Portas SOCKS de clientes Tor, em ordem de preferencia. A 9052 vem primeiro porque e a que
// o instalador configura com bridge meek: ela atravessa rede censurada, que e exatamente o
// cenario de quem precisa deste plugin. As outras sao Tor Browser, daemon e Brave, que podem
// estar sem bridge nenhuma.
const TOR_PORTS = [9052, 9150, 9050, 9250];
const TOR_PORT_TIMEOUT_MS = 400;

const POOL_SIZE = 5;
const POOL_MAX_AGE_MS = 24 * 60 * 60 * 1000;

const MAX_LOG_LINES = 200;
const MAX_RETRIES = 2;

// Quanto tempo o gateway fica segurado enquanto a saida e escolhida. Estourou, ele sai
// direto: perde-se o Go Live daquela sessao, nunca o Discord.
const STALL_BUDGET_MS = 12_000;

// Orcamentos do trafego vivo, bem menores que os do teste de candidata. Uma saida agonizante
// que demora seis segundos para falhar e pior que uma morta: ela faz o Chromium desistir do
// roteador inteiro.
const RELAY_TUNNEL_TIMEOUT_MS = 2500;
const RELAY_DIRECT_TIMEOUT_MS = 8000;

const INTERCEPTING_PORTS = new Set([4145]);
const PROXY_RULES_RE = /^(socks5|https?):\/\/([a-z0-9.-]{1,253}):(\d{1,5})$/;

export type Scope = "login" | "gateway" | "off";

interface PoolEntry {
    proxy: string;
    country: string;
    ms: number;
    at: number;
}

const history: string[] = [];

let retries = 0;

function log(message: string) {
    const line = `${new Date().toISOString().slice(11, 19)} ${message}`;
    history.push(line);
    if (history.length > MAX_LOG_LINES) history.shift();
}

function parseProxy(proxyRules: string) {
    const match = PROXY_RULES_RE.exec(proxyRules);
    if (!match) return null;

    const port = Number(match[3]);
    if (port < 1 || port > 65535) return null;

    return { scheme: match[1], host: match[2], port };
}

function pluginSettings() {
    return RendererSettings.plain.plugins?.GoLiveBypass;
}

function pluginEnabled() {
    return pluginSettings()?.enabled === true;
}

// Tres respostas diferentes, e antes elas estavam misturadas numa so: o campo esta vazio
// (procure sozinho), o campo tem um endereco bom (use este), o campo tem lixo (nao invente
// uma saida que a pessoa nao escolheu).
function manualProxy(): { proxy: string; } | "auto" | "invalid" {
    const proxy = pluginSettings()?.proxy;
    if (typeof proxy !== "string" || proxy.trim() === "") return "auto";

    const trimmed = proxy.trim();
    return parseProxy(trimmed) === null ? "invalid" : { proxy: trimmed };
}

function excludedCountries() {
    const raw: unknown = pluginSettings()?.excludedCountries;
    const codes = typeof raw === "string" ? raw.split(",") : ["BR"];

    return new Set(codes.map(code => code.trim().toUpperCase()).filter(code => /^[A-Z]{2}$/.test(code)));
}

// O renderer manda a propria lista nas chamadas que ele inicia. O nome do parametro cobre o
// da funcao acima dentro daquelas funcoes, entao a leitura precisa de nome proprio.
function requestedCountries(raw: unknown) {
    return new Set(
        typeof raw === "string"
            ? raw.split(",").map(code => code.trim().toUpperCase()).filter(code => /^[A-Z]{2}$/.test(code))
            : []
    );
}

function routesLogin() {
    return pluginSettings()?.sessionRouting === "login";
}

function readPool(): PoolEntry[] {
    let stored: unknown;
    try {
        stored = NativeSettings.plain.plugins?.GoLiveBypass?.pool;
    } catch {
        return [];
    }

    if (!Array.isArray(stored)) return [];

    return stored.filter((entry): entry is PoolEntry => {
        if (typeof entry !== "object" || entry === null) return false;

        const { proxy, country, ms, at } = entry as Partial<PoolEntry>;
        return typeof proxy === "string" && parseProxy(proxy) !== null
            && typeof country === "string" && typeof ms === "number"
            && typeof at === "number" && Date.now() - at < POOL_MAX_AGE_MS;
    });
}

// Duas instancias do Discord dividem este arquivo, entao gravar pode falhar por disputa.
// Perder o pote custa uma busca a mais no proximo boot. Deixar a excecao subir custava o
// processo principal.
function writePool(entries: PoolEntry[]) {
    try {
        NativeSettings.store.plugins.GoLiveBypass ??= {};
        NativeSettings.store.plugins.GoLiveBypass.pool = entries
            .sort((a, b) => a.ms - b.ms)
            .slice(0, POOL_SIZE);
    } catch {
        // sem pote guardado, o proximo boot procura de novo
    }
}

function readFrame(socket: Socket, size: (buffer: Buffer) => number, done: (frame: Buffer | null) => void) {
    const chunks: Buffer[] = [];
    let settled = false;

    const finish = (frame: Buffer | null) => {
        if (settled) return;
        settled = true;
        socket.off("data", onData);
        socket.off("close", onClose);
        done(frame);
    };

    const onClose = () => finish(null);

    const onData = (chunk: Buffer) => {
        chunks.push(chunk);
        const buffer = Buffer.concat(chunks);
        const wanted = size(buffer);
        if (wanted < 0 || buffer.length < wanted) return;

        socket.pause();
        if (buffer.length > wanted) socket.unshift(buffer.subarray(wanted));
        finish(buffer.subarray(0, wanted));
    };

    socket.on("data", onData);
    socket.on("close", onClose);
    socket.resume();
}

function socksReplySize(buffer: Buffer) {
    if (buffer.length < 4) return -1;
    if (buffer[3] === 1) return 10;
    if (buffer[3] === 4) return 22;
    return buffer.length < 5 ? -1 : 7 + buffer[4];
}

function negotiateSocks5(socket: Socket, host: string, port: number, done: (ok: boolean) => void) {
    readFrame(socket, buffer => buffer.length < 2 ? -1 : 2, greeting => {
        if (greeting === null || greeting[1] !== 0) return done(false);

        readFrame(socket, socksReplySize, reply => done(reply !== null && reply[1] === 0));

        const target = Buffer.from(host, "latin1");
        socket.write(Buffer.concat([
            Buffer.from([5, 1, 0, 3, target.length]),
            target,
            Buffer.from([port >> 8, port & 0xff])
        ]));
    });

    socket.write(Buffer.from([5, 1, 0]));
}

function negotiateConnect(socket: Socket, host: string, port: number, done: (ok: boolean) => void) {
    readFrame(socket, buffer => {
        const end = buffer.indexOf("\r\n\r\n");
        return end < 0 ? -1 : end + 4;
    }, reply => done(reply !== null && /^HTTP\/1\.[01] 200/.test(reply.toString("latin1"))));

    socket.write(`CONNECT ${host}:${port} HTTP/1.1\r\nHost: ${host}:${port}\r\n\r\n`);
}

function openDirect(host: string, port: number, timeoutMs: number): Promise<Socket | null> {
    return new Promise(resolve => {
        const socket = connect({ host, port });
        let settled = false;

        const finish = (result: Socket | null) => {
            if (settled) return;
            settled = true;
            clearTimeout(guard);
            socket.setTimeout(0);
            if (result === null) socket.destroy();
            resolve(result);
        };

        const guard = setTimeout(() => finish(null), timeoutMs);
        socket.setTimeout(timeoutMs, () => finish(null));
        socket.on("error", () => finish(null));
        socket.once("connect", () => finish(socket));
    });
}

function openTunnel(proxy: string, host: string, port: number, timeoutMs = PROBE_TIMEOUT_MS): Promise<Socket | null> {
    const parsed = parseProxy(proxy);
    if (parsed === null) return Promise.resolve(null);

    return new Promise(resolve => {
        const socket = connect({ host: parsed.host, port: parsed.port });
        let settled = false;

        const finish = (tunnel: Socket | null) => {
            if (settled) return;
            settled = true;
            clearTimeout(guard);
            socket.setTimeout(0);
            if (tunnel === null) socket.destroy();
            resolve(tunnel);
        };

        const guard = setTimeout(() => finish(null), timeoutMs);
        socket.setTimeout(timeoutMs, () => finish(null));
        socket.on("error", () => finish(null));
        socket.once("connect", () => {
            const done = (ok: boolean) => finish(ok ? socket : null);
            if (parsed.scheme === "socks5") negotiateSocks5(socket, host, port, done);
            else negotiateConnect(socket, host, port, done);
        });
    });
}

function readOverTls(socket: Socket, host: string, path: string, timeoutMs = PROBE_TIMEOUT_MS): Promise<string | null> {
    return new Promise(resolve => {
        let body = "";
        let settled = false;

        const finish = (value: string | null) => {
            if (settled) return;
            settled = true;
            clearTimeout(timer);
            tls.destroy();
            resolve(value);
        };

        const timer = setTimeout(() => finish(null), timeoutMs);
        const tls = connectTls({ socket, servername: host, host }, () => {
            tls.write(`GET ${path} HTTP/1.1\r\nHost: ${host}\r\nAccept: */*\r\nConnection: close\r\n\r\n`);
        });

        tls.setEncoding("latin1");
        tls.on("error", () => finish(null));
        tls.on("data", (chunk: string) => {
            body += chunk;
            if (body.length > 65536) finish(body);
        });
        tls.on("end", () => finish(body));
    });
}

function listening(port: number, timeoutMs: number): Promise<boolean> {
    return new Promise(resolve => {
        const socket = connect({ host: "127.0.0.1", port });
        const finish = (open: boolean) => {
            socket.destroy();
            resolve(open);
        };

        socket.setTimeout(timeoutMs, () => finish(false));
        socket.once("connect", () => finish(true));
        socket.on("error", () => finish(false));
    });
}

function downloadText(url: string): Promise<string> {
    return new Promise((resolve, reject) => {
        const req = request(url, res => {
            if (res.statusCode !== 200) {
                res.resume();
                reject(new Error("Unexpected response status"));
                return;
            }

            const chunks: Buffer[] = [];
            let size = 0;
            let settled = false;

            res.on("data", (chunk: Buffer) => {
                if (settled) return;

                size += chunk.length;
                if (size > MAX_LIST_BYTES) {
                    settled = true;
                    res.destroy();
                    reject(new Error("Response too large"));
                    return;
                }

                chunks.push(chunk);
            });

            res.on("end", () => {
                if (settled) return;
                settled = true;
                resolve(Buffer.concat(chunks).toString("utf8"));
            });
        });

        req.on("error", reject);
        req.setTimeout(15_000, () => req.destroy(new Error("Request timed out")));
        req.end();
    });
}

async function measure(proxy: string, timeoutMs = PROBE_TIMEOUT_MS) {
    const started = Date.now();

    const socket = await openTunnel(proxy, TRACE_HOST, 443, timeoutMs);
    if (socket === null) return null;

    const response = await readOverTls(socket, TRACE_HOST, TRACE_PATH, timeoutMs);
    if (response === null || !/^HTTP\/1\.[01] 200/.test(response)) return null;

    const country = /(?:^|\n)loc=([A-Za-z]{2})/.exec(response);
    if (country === null) return null;

    const ip = /(?:^|\n)ip=(\S+)/.exec(response);

    return { proxy, country: country[1].toUpperCase(), ip: ip?.[1] ?? "", ms: Date.now() - started };
}

// Todas as candidatas do lote andam juntas, e a primeira que responder bem ganha. Antes o
// teste de pais rodava uma candidata por vez depois do lote inteiro terminar, o que sozinho
// podia somar um minuto.
function firstUsable(candidates: string[], excluded: Set<string>, timeoutMs: number) {
    return new Promise<PoolEntry | null>(resolve => {
        let pending = candidates.length;
        if (pending === 0) return resolve(null);

        let settled = false;

        // O prazo vai escrito na chamada de proposito. Um candidates.map(measure) parece
        // igual e nao e: map passa (item, indice, array), entao o indice cairia em timeoutMs
        // e a candidata numero zero teria zero milissegundo para responder.
        for (const candidate of candidates) {
            measure(candidate, timeoutMs).then(result => {
                if (!settled && result !== null && !excluded.has(result.country)) {
                    settled = true;
                    log(`${result.proxy} passou: ${result.ms}ms, saida em ${result.country}`);
                    resolve({ proxy: result.proxy, country: result.country, ms: result.ms, at: Date.now() });
                    return;
                }

                if (result !== null && excluded.has(result.country)) log(`${result.proxy} recusada: saida em ${result.country}`);
                if (--pending === 0 && !settled) resolve(null);
            });
        }
    });
}

async function torExit(excluded: Set<string>, timeoutMs: number) {
    for (const port of TOR_PORTS) {
        const proxy = `socks5://127.0.0.1:${port}`;
        if (!await listening(port, TOR_PORT_TIMEOUT_MS)) continue;

        const found = await firstUsable([proxy], excluded, timeoutMs);
        if (found !== null) {
            log(`Tor local encontrado na porta ${port}`);
            return found;
        }

        log(`porta ${port} aberta mas nao respondeu como proxy, ignorando`);
    }

    return null;
}

function rankFreeProxies(body: string, excluded: Set<string>) {
    const data: unknown = JSON.parse(body);
    const { proxies } = data as { proxies?: unknown; };
    if (!Array.isArray(proxies)) return [];

    const usable: { proxy: string; uptime: number; timeout: number; }[] = [];

    for (const item of proxies) {
        if (typeof item !== "object" || item === null) continue;

        const entry = item as {
            proxy?: unknown;
            alive?: unknown;
            uptime?: unknown;
            timeout?: unknown;
            ip_data?: { countryCode?: unknown; };
        };

        if (typeof entry.proxy !== "string" || entry.alive !== true) continue;

        const parsed = parseProxy(entry.proxy);
        if (parsed === null || INTERCEPTING_PORTS.has(parsed.port)) continue;

        const uptime = typeof entry.uptime === "number" ? entry.uptime : 0;
        const timeout = typeof entry.timeout === "number" ? entry.timeout : MAX_LISTED_TIMEOUT;
        if (uptime < MIN_UPTIME || timeout > MAX_LISTED_TIMEOUT) continue;

        const country = typeof entry.ip_data?.countryCode === "string" ? entry.ip_data.countryCode.toUpperCase() : "";
        if (excluded.has(country)) continue;

        usable.push({ proxy: entry.proxy, uptime, timeout });
    }

    return usable
        .sort((a, b) => b.uptime - a.uptime || a.timeout - b.timeout)
        .slice(0, MAX_CANDIDATES)
        .map(entry => entry.proxy);
}

async function freeExit(excluded: Set<string>, want: number) {
    let candidates: string[];
    try {
        candidates = rankFreeProxies(await downloadText(FREE_PROXY_API), excluded);
    } catch {
        return [];
    }

    log(`${candidates.length} candidatas depois do ranqueamento`);

    const found: PoolEntry[] = [];

    for (let i = 0; i < candidates.length && found.length < want; i += PARALLEL_PROBES) {
        const batch = candidates.slice(i, i + PARALLEL_PROBES);
        const winner = await firstUsable(batch, excluded, PROBE_TIMEOUT_MS);
        if (winner !== null) found.push(winner);
    }

    return found;
}

// Reabastecer o pote e uma escolha nova disparada por uma saida que morreu podem correr ao
// mesmo tempo. Duas buscas paralelas disputam a mesma banda e dobram o tempo ate a primeira
// saida ficar pronta, que e exatamente a janela em que o gateway conecta sem protecao. Quem
// chegar depois espera a busca que ja esta correndo.
let hunting: Promise<PoolEntry[]> | null = null;

function sharedFreeExit(excluded: Set<string>, want: number) {
    hunting ??= freeExit(excluded, want).finally(() => { hunting = null; });
    return hunting;
}

let exit: string | null = null;
let exitSettled = false;
let waiting: ((value: string | null) => void)[] = [];

function settleExit(value: string | null) {
    exit = value;
    exitSettled = true;

    const pending = waiting;
    waiting = [];
    for (const resume of pending) resume(value);
}

// O gateway chega aqui antes de existir saida escolhida, e e exatamente isso que a versao
// anterior nao conseguia fazer: como o proxy era aplicado na sessao inteira, escolher tinha
// que acontecer antes do app subir, e o boot inteiro parava de 8 a 23 segundos. Segurando
// so este socket, o Discord carrega na velocidade normal enquanto a busca acontece.
function currentExit(): Promise<string | null> {
    if (exitSettled) return Promise.resolve(exit);

    return new Promise(resolve => {
        const resume = (value: string | null) => {
            clearTimeout(guard);
            resolve(value);
        };

        const guard = setTimeout(() => {
            waiting = waiting.filter(entry => entry !== resume);
            log("nenhuma saida ficou pronta a tempo, esta conexao vai direta");
            resolve(null);
        }, STALL_BUDGET_MS);

        waiting.push(resume);
    });
}

// Saida que falhou no trafego vivo sai do pote e a busca recomeca. Ate a nova chegar o
// roteador manda direto, que custa o Go Live e nunca a conexao.
function dropExit(dead: string, excluded?: Set<string>) {
    if (exit !== dead) return;

    log(`${dead} parou de entregar, tirando do pote e procurando outra`);
    writePool(readPool().filter(entry => entry.proxy !== dead));
    exit = null;
    chooseExit(excluded);
}

// Uma escolha por vez, e quem pedir no meio recebe a que ja esta correndo em vez de comecar
// outra. Guardar a promessa em vez de um booleano importa: o retryWithProxy precisa esperar
// o resultado antes de recarregar a janela, e com um booleano ele veria "ja tem alguem
// escolhendo" e recarregaria sem saida nenhuma, queimando uma tentativa a toa.
let choosing: Promise<void> | null = null;

function chooseExit(excluded?: Set<string>) {
    choosing ??= runChoice(excluded ?? excludedCountries()).finally(() => { choosing = null; });
    return choosing;
}

// Nada aqui pode escapar. Este plugin roda no processo principal do Discord, e no Node
// atual uma promessa rejeitada sem tratamento derruba o processo inteiro: o Discord some
// da tela, ou pior, sobra a janela presa na tela de conexao sem processo principal atras.
// Aconteceu ao subir duas instancias, que disputaram o mesmo native-settings.json.
async function runChoice(excluded: Set<string>) {
    try {
        await pickExit(excluded);
    } catch {
        // Quem ja escolheu nao perde a saida por causa de um erro que veio depois: sem esta
        // condicao um tropeco no reabastecimento apagaria a saida que esta funcionando.
        if (!exitSettled) settleExit(null);
    }
}

async function pickExit(excluded: Set<string>) {
    const manual = manualProxy();
    if (manual === "invalid") {
        log("o endereco do campo Proxy nao e valido, nenhuma saida foi usada");
        return settleExit(null);
    }

    if (manual !== "auto") {
        // Sem testar, uma saida fora do ar viraria conexao direta dentro do roteador e o
        // bypass falharia em silencio, que foi exatamente o que aconteceu com o Tor fechado.
        const started = Date.now();
        if (await measure(manual.proxy, WARM_PROBE_TIMEOUT_MS) !== null) {
            log(`seu proxy respondeu em ${Date.now() - started}ms: ${manual.proxy}`);
            return settleExit(manual.proxy);
        }

        log(`seu proxy nao respondeu: ${manual.proxy}`);
        log("se for Tor, ele precisa estar aberto ANTES do Discord. Procurando alternativa.");
    }

    return autoExit(excluded);
}

async function autoExit(excluded: Set<string>) {
    const pool = readPool();
    if (pool.length > 0) {
        const warm = await firstUsable(pool.map(entry => entry.proxy), excluded, WARM_PROBE_TIMEOUT_MS);
        if (warm !== null) {
            log(`saida guardada revalidada em ${warm.ms}ms: ${warm.proxy}`);
            settleExit(warm.proxy);

            // Solta sem esperar: o pote so serve para o proximo boot, e prender a escolha
            // ate ele encher deixaria uma saida morta no meio da sessao sem substituta,
            // porque quem descarta a saida morta encontraria a escolha ainda ocupada.
            refillPool(excluded, warm).catch(() => { });
            return;
        }

        log("as saidas guardadas morreram, procurando outra");
    }

    const tor = await torExit(excluded, PROBE_TIMEOUT_MS);
    if (tor !== null) return settleExit(tor.proxy);

    log(`procurando uma saida nova, o gateway fica segurado por ate ${Math.round(STALL_BUDGET_MS / 1000)}s`);
    const [first] = await sharedFreeExit(excluded, 1);
    log(first === undefined ? "nenhuma saida passou nos testes" : `saida escolhida: ${first.proxy}`);

    settleExit(first?.proxy ?? null);
    if (first !== undefined) writePool([first]);
}

// A busca cara acontece com a sessao ja aberta, para o proximo boot ter opcao pronta. E a
// diferenca entre abrir o Discord em dois segundos e esperar meio minuto por uma lista.
// Vale tambem quando o campo Proxy esta preenchido mas morto: a essa altura quem esta
// carregando o gateway e uma saida encontrada, entao guardar as outras e o mesmo ganho.
async function refillPool(excluded: Set<string>, keep: PoolEntry) {
    try {
        const found = await sharedFreeExit(excluded, POOL_SIZE);
        writePool([keep, ...found.filter(entry => entry.proxy !== keep.proxy)]);
        log(`pote guardado com ${Math.min(found.length + 1, POOL_SIZE)} saida(s)`);
    } catch {
        writePool([keep]);
    }
}

let socks: SocksServer | undefined;
let scope: Scope = "off";
let fallbackRule = "DIRECT";

function refuse(client: Socket) {
    if (!client.destroyed) client.write(Buffer.from([5, 5, 0, 1, 0, 0, 0, 0, 0, 0]));
    client.destroy();
}

function readTarget(request: Buffer) {
    if (request[3] === 1) {
        return { host: Array.from(request.subarray(4, 8)).join("."), port: request.readUInt16BE(8) };
    }

    if (request[3] === 3) {
        const size = request[4];
        return { host: request.subarray(5, 5 + size).toString("latin1"), port: request.readUInt16BE(5 + size) };
    }

    return null;
}

function serveSocks(client: Socket) {
    client.on("error", () => client.destroy());

    readFrame(client, buffer => buffer.length < 2 ? -1 : 2 + buffer[1], greeting => {
        if (greeting === null || greeting[0] !== 5) return client.destroy();
        client.write(Buffer.from([5, 0]));

        readFrame(client, socksReplySize, request => {
            // Cada conexao e isolada: o que der errado aqui fecha este socket e mais nada.
            // Sem o catch, um erro em qualquer await abaixo viraria rejeicao nao tratada e
            // levaria junto o processo principal do Discord.
            serveRequest(client, request).catch(() => client.destroy());
        });
    });
}

async function serveRequest(client: Socket, request: Buffer | null) {
    if (request === null || request[0] !== 5 || request[1] !== 1) return client.destroy();

    const target = readTarget(request);
    if (target === null) return refuse(client);

    // Sucesso respondido agora, antes de saber por onde vamos sair, e isso e deliberado. O
    // Chromium mantem uma lista de proxies ruins: basta uma resposta lenta ou negativa para
    // ele parar de usar este roteador e mandar tudo direto, sem avisar. Foi o que aconteceu,
    // com o relay de pe e saudavel e nenhuma conexao passando por ele. Respondendo na hora
    // ele nunca tem motivo para desconfiar, e uma saida que falhe vira uma conexao fechada,
    // que e problema do destino e nao do proxy. O socket continua pausado pelo readFrame,
    // entao nada que o cliente mandar se perde ate o pipe comecar.
    client.write(Buffer.from([5, 0, 0, 1, 0, 0, 0, 0, 0, 0]));

    const through = await currentExit();
    if (client.destroyed) return;

    let upstream = through === null
        ? await openDirect(target.host, target.port, RELAY_DIRECT_TIMEOUT_MS)
        : await openTunnel(through, target.host, target.port, RELAY_TUNNEL_TIMEOUT_MS);

    // Saida que nao entrega e descartada na hora, senao toda conexao seguinte paga o mesmo
    // tempo de espera antes de cair para direto.
    if (upstream === null && through !== null) {
        dropExit(through);
        upstream = await openDirect(target.host, target.port, RELAY_DIRECT_TIMEOUT_MS);
    }

    if (upstream === null) return client.destroy();

    if (client.destroyed) {
        upstream.destroy();
        return;
    }

    upstream.on("error", () => client.destroy());
    client.on("close", () => upstream.destroy());
    upstream.on("close", () => client.destroy());

    upstream.pipe(client);
    client.pipe(upstream);
}

function pacScript(socksPort: number, routed: string[]) {
    const list = routed.map(host => `"${host}"`).join(",");

    // O host roteado sai pelo roteador e ponto, sem alternativa depois do ponto e virgula.
    // Ter uma custou uma sessao inteira: uma saida gratuita falhou uma vez, o Chromium
    // marcou o SOCKS local como ruim, e a partir dali mandou tudo pela alternativa sem
    // avisar ninguem. PAC servido, roteador escutando, e nenhuma conexao passando por ele.
    // A rede de seguranca real e outra: o roteador nunca recusa por causa da saida, ele
    // mesmo cai para conexao direta. Ela vive dentro do processo, onde da para medir, e nao
    // numa regra do Chromium que decide sozinho e nao conta.
    // Quem nao esta na lista continua com a regra que o sistema ja usava, entao proxy
    // corporativo ou PAC da empresa seguem valendo para o resto do Discord.
    return `var routed = [${list}];\n`
        + "function FindProxyForURL(url, host) {\n"
        + "    for (var i = 0; i < routed.length; i++)\n"
        + `        if (host === routed[i]) return "SOCKS5 127.0.0.1:${socksPort}";\n`
        + `    return "${fallbackRule}";\n`
        + "}\n";
}

function routedHosts(): string[] {
    if (scope === "off") return [];
    return scope === "login" ? [...GATEWAY_HOSTS, ...LOGIN_HOSTS] : [...GATEWAY_HOSTS];
}

// O PAC vai embutido na propria URL. A alternativa era servi-lo de um HTTP local, e ai o
// Chromium precisa buscar o arquivo bem no meio da subida do app, com a rede ainda se
// montando. Numa build de Electron mais antiga isso derrubava o processo principal em
// silencio: o app nao abria, e nao havia excecao para pegar. Sem servidor nao ha busca.
// Trocar o escopo troca o conteudo, e conteudo diferente ja e URL diferente, entao nao
// precisa de numero de versao para o Chromium reler.
function pacDataUrl(socksPort: number) {
    const script = pacScript(socksPort, routedHosts());
    return "data:application/x-ns-proxy-autoconfig;base64," + Buffer.from(script, "utf8").toString("base64");
}

async function installPac(redial: boolean) {
    if (socks === undefined) return false;

    try {
        const socksPort = (socks.address() as AddressInfo | null)?.port;
        if (socksPort === undefined) return false;

        await session.defaultSession.setProxy({ mode: "pac_script", pacScript: pacDataUrl(socksPort) });

        // Conferir em vez de supor. Se a regra nao pegou, e melhor sair direto de propria
        // vontade do que ficar num meio termo em que o roteador existe e ninguem o usa,
        // que foi como este plugin falhou em silencio antes.
        // Confere o endereco inteiro, e nao so o numero da porta: a resposta de um PAC
        // ignorado e a regra do sistema, e um "PROXY host:porta" dela pode conter os mesmos
        // digitos por acaso. Ai a checagem diria que a rota pegou justamente quando nao pegou.
        const route = await session.defaultSession.resolveProxy(`https://${GATEWAY_HOSTS[0]}`);
        if (typeof route !== "string" || !route.includes(`127.0.0.1:${socksPort}`)) {
            log("o Chromium ignorou o PAC, voltando para a regra do sistema");

            // "system" e o que uma sessao intocada usa. Voltar para "direct" arrancaria o
            // proxy do sistema de quem esta atras de PAC, VPN ou proxy corporativo.
            await session.defaultSession.setProxy({ mode: "system" });

            // Nada ficou roteado, e o escopo tem que dizer isso. Com ele mentindo "gateway",
            // o retryWithProxy recarrega o cliente atras de uma rota que nao existe e queima
            // as tentativas sem chance nenhuma de consertar a sessao.
            scope = "off";
            return false;
        }

        // Regra nova nao muda socket que ja nasceu, e o gateway costuma nascer antes daqui.
        // Sem derrubar o que ja esta aberto o Discord fica com a rota velha a sessao inteira,
        // que e exatamente o modo de falhar em silencio: o roteador de pe, ninguem passando
        // por ele. So no boot, porque depois do login derrubar o gateway seria reconectar a
        // sessao recem autenticada a toa.
        if (redial) await session.defaultSession.closeAllConnections();
    } catch {
        log("nao consegui aplicar a regra de rota, a sessao continua como estava");
        return false;
    }

    log(`rota aplicada: ${routedHosts().join(", ")} pelo roteador local, o resto em ${fallbackRule}`);
    return true;
}

async function startRouter(next: Scope) {
    scope = next;

    if (socks === undefined) {
        const server = createSocksServer(serveSocks);
        server.on("error", () => { });

        // A promessa resolve tambem no erro. Esperar por um listen que nunca vai acontecer
        // deixaria o boot pendurado para sempre, e este codigo roda no caminho de abertura
        // do Discord.
        const started = await new Promise<boolean>(resolve => {
            server.once("error", () => resolve(false));
            server.listen(0, "127.0.0.1", () => resolve(true));
        });

        if (!started) {
            log("nao consegui subir o roteador local, a sessao inteira continua direta");
            return false;
        }

        socks = server;
        log(`roteador local de pe na porta ${(server.address() as AddressInfo).port}`);
    }

    if (await installPac(true)) return true;

    // Mesmo motivo de dentro do installPac, e vale tambem quando a excecao apareceu antes de
    // a regra chegar a mudar: no boot nao havia rota nenhuma para sobreviver, entao o unico
    // escopo verdadeiro depois de uma falha aqui e "off".
    scope = "off";
    return false;
}

async function stopRouter() {
    scope = "off";

    try {
        // "system" e o que uma sessao intocada usa. Voltar para "direct" arrancaria o proxy
        // do sistema de quem esta atras de PAC, VPN ou proxy corporativo.
        await session.defaultSession.setProxy({ mode: "system" });
        await session.defaultSession.closeAllConnections();
    } catch {
        // nada a fazer: a sessao ja esta fechando
    }

    socks?.close();
    socks = undefined;
    log("roteador desligado, tudo volta a sair direto");
}

// Sairam daqui tres protecoes da versao que aplicava proxy na sessao inteira: o prazo de
// dois minutos que soltava o proxy sozinho, a marca de boot pendente gravada em disco para
// nao repetir uma abertura travada, e o did-fail-load que desistia quando a pagina nao
// carregava. As tres cobriam o mesmo acidente, saida quebrada segurando o Discord inteiro
// sem tela e sem como pedir socorro, e esse acidente nao existe mais: so o gateway passa
// pela saida, o resto do app nunca depende dela, e a conexao que depende cai para direta
// sozinha dentro do roteador. Manter o prazo hoje seria dano puro, porque ele arrancaria o
// gateway da saida no meio de uma sessao que estava funcionando.
app.whenReady().then(async () => {
    try {
        if (!pluginEnabled()) return;

        // A regra do sistema e lida antes de qualquer coisa, para o PAC saber para onde mandar
        // tudo que nao e Discord.
        try {
            const resolved = await session.defaultSession.resolveProxy(`https://${DISCORD_HOST}`);
            if (typeof resolved === "string" && resolved.trim() !== "") fallbackRule = resolved.trim();
        } catch {
            // fica em DIRECT
        }

        // Subir o roteador leva milissegundos, entao ele esta de pe antes do gateway nascer.
        // Escolher a saida acontece depois, em paralelo com o app carregando.
        await startRouter(routesLogin() ? "login" : "gateway");
        chooseExit();
    } catch {
        // Falhar aqui e abrir o Discord sem bypass. Deixar a excecao subir era abrir o
        // Discord sem processo principal, ou seja, nao abrir.
        await stopRouter();
    }
}).catch(() => { });

export async function sessionOpened(_: IpcMainInvokeEvent) {
    // Com a sessao aberta o login ja passou, entao o escopo encolhe para o gateway e o resto
    // do Discord volta a sair direto. O gateway continua roteado de proposito: se ele cair e
    // reconectar (rede oscilando, notebook suspenso), o socket novo nasce pela mesma saida e
    // a liberacao sobrevive, coisa que a versao anterior perdia.
    if (scope === "login") await installPacWithScope("gateway");
    return { exit, scope };
}

export async function sessionClosed(_: IpcMainInvokeEvent) {
    if (routesLogin() && scope !== "off") await installPacWithScope("login");
}

// O escopo descreve o que esta instalado, nao o que foi pedido. Se a troca falhar no meio da
// sessao a rota antiga continua valendo, e e ela que o diagnostico e o retryWithProxy
// precisam enxergar. Quando o proprio installPac desliga tudo, o "off" dele e que vale.
async function installPacWithScope(next: Scope) {
    const installed = scope;
    scope = next;

    if (await installPac(false)) return true;

    if (scope === next) scope = installed;
    return false;
}

export async function shutdown(_: IpcMainInvokeEvent) {
    await stopRouter();
    settleExit(null);
    return { success: true as const };
}

export function getActiveProxy(_: IpcMainInvokeEvent) {
    return exit;
}

export function getLog(_: IpcMainInvokeEvent) {
    return history.join("\n");
}

export function sessionWorked(_: IpcMainInvokeEvent) {
    if (retries > 0) log(`sessao liberada depois de ${retries} tentativa(s)`);
    retries = 0;
}

// O gateway pode nascer antes de existir saida escolhida: quando isso acontece ele sai
// direto, o servidor continua bloqueando video, e nao ha como consertar sem refazer o
// gateway. Recarregar com a saida ja pronta resolve, mas so pode acontecer um numero fixo de
// vezes: sem teto isso vira a tela de carregamento infinita.
export async function retryWithProxy(event: IpcMainInvokeEvent, excludedCountries: unknown) {
    if (retries >= MAX_RETRIES) {
        log(`o servidor continuou bloqueando apos ${retries} tentativas, desistindo`);
        return { retried: false as const, reason: "tentativas esgotadas" };
    }

    if (scope === "off") {
        log("o roteador nao esta de pe, recarregar repetiria a mesma falha");
        return { retried: false as const, reason: "roteador desligado" };
    }

    // A lista chega do renderer porque e a que a pessoa esta vendo nas settings agora; a copia
    // lida no processo principal so muda depois que o renderer grava. Vazia quer dizer que nao
    // veio nada util, e ai vale o que esta gravado.
    const requested = requestedCountries(excludedCountries);
    const excluded = requested.size > 0 ? requested : undefined;

    // Se a saida que esta no ar ainda responde, a causa foi a corrida: o gateway nasceu antes
    // dela e o roteador o mandou direto. Recarregar faz o gateway renascer ja pela saida, e
    // isso conserta a sessao. A rota nao precisa ser reinstalada, ela nunca saiu do lugar.
    let through = exit;
    if (through !== null && await measure(through, PROBE_TIMEOUT_MS) === null) {
        log(`${through} parou de responder no meio da sessao`);

        // A lista vai junto porque quem descarta ja comeca a procurar a substituta. Sem ela,
        // a busca que o await abaixo aproveita seria a que ignora o pais que a pessoa acabou
        // de excluir, e a tentativa seguinte nasceria no pais errado.
        dropExit(through, excluded);

        // Le de volta em vez de assumir null: se o trafego vivo ja tinha descartado esta saida
        // e achado outra, ela serve, e comecar uma busca nova por cima jogaria fora a que esta
        // funcionando neste instante.
        through = exit;
    }

    // Sem saida no ar, recarregar cairia direto de novo e repetiria a mesma falha, gastando
    // uma tentativa. Aqui nao ha corrida com o gateway para ganhar, entao vale esperar a
    // busca inteira em vez dos prazos curtos do boot.
    if (through === null) {
        await chooseExit(excluded);
        through = exit;
    }

    if (through === null) {
        log("nenhuma saida respondeu, a sessao continua direta");
        return { retried: false as const, reason: "nenhuma saida respondeu" };
    }

    if (event.sender.isDestroyed()) return { retried: false as const, reason: "janela indisponivel" };

    retries++;
    log(`o servidor bloqueou esta sessao, recarregando atras de ${through} (tentativa ${retries} de ${MAX_RETRIES})`);

    // event.sender e a janela que roda o plugin. Guardar a primeira janela criada nao servia:
    // a primeira do Discord e a tela de abertura, e recarregar ela nao recarrega o cliente.
    event.sender.reload();
    return { retried: true as const, attempt: retries };
}

export async function testProxy(_: IpcMainInvokeEvent, proxyRules: unknown) {
    if (typeof proxyRules !== "string" || parseProxy(proxyRules.trim()) === null)
        return { success: false as const, error: "Invalid proxy format. Use socks5://host:port." };

    const result = await measure(proxyRules.trim());
    if (result === null)
        return { success: false as const, error: "The proxy could not carry a real TLS request." };

    return { success: true as const, ms: result.ms, country: result.country, ip: result.ip };
}
