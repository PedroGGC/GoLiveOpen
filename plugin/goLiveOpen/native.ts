/*
 * Vencord, a Discord client mod
 * Copyright (c) 2026 Vendicated and contributors
 * SPDX-License-Identifier: GPL-3.0-or-later
 */

import { execFile } from "child_process";
import { randomUUID } from "crypto";
import { BrowserWindow, dialog, type IpcMainInvokeEvent } from "electron";
import fs from "fs";
import os from "os";
import path from "path";

const SERVICE_NAME = "wiresock-client-service";
const DATA_DIR = path.join(process.env.ProgramData || "C:\\ProgramData", "GoLiveOpen");
const TARGET_CONF = path.join(DATA_DIR, "discord.conf");

export interface TunnelStatus {
    supported: boolean;
    wireSockInstalled: boolean;
    serviceRunning: boolean;
    confConfigured: boolean;
    endpoint: string | null;
}

export interface TunnelActionResult {
    ok: boolean;
    cancelled?: boolean;
    running?: boolean;
    endpoint?: string | null;
    error?: string;
}

function findWireSockClient(): string | null {
    if (process.platform !== "win32") return null;
    const roots = [process.env.ProgramW6432, process.env.ProgramFiles, process.env["ProgramFiles(x86)"], "C:\\Program Files"]
        .filter((value): value is string => Boolean(value));

    for (const root of new Set(roots)) {
        for (const rel of ["WireSock Secure Connect\\wiresock-client.exe", "WireSock Secure Connect\\sdk\\wiresock-client.exe"]) {
            const candidate = path.join(root, rel);
            if (fs.existsSync(candidate)) return candidate;
        }
    }
    return null;
}

function execFileAsync(file: string, args: string[], timeoutMs = 15_000): Promise<{ code: number; stdout: string; stderr: string }> {
    return new Promise(resolve => {
        execFile(file, args, { windowsHide: true, timeout: timeoutMs, encoding: "utf8" }, (error, stdout, stderr) => {
            const code = error && typeof (error as { code?: unknown }).code === "number"
                ? (error as { code: number }).code
                : error ? 1 : 0;
            resolve({ code, stdout: String(stdout ?? ""), stderr: String(stderr ?? "") });
        });
    });
}

function readEndpoint(raw: string): string | null {
    const match = /^\s*Endpoint\s*=\s*(.+)$/im.exec(raw);
    return match ? match[1].trim() : null;
}

function resolveDiscordAllowedApps(): string {
    const apps = new Set<string>();
    const exe = path.resolve(process.execPath);
    if (/discord\.exe$/i.test(exe) && fs.existsSync(exe)) {
        apps.add(exe);
        const updater = path.join(path.dirname(path.dirname(exe)), "Update.exe");
        if (fs.existsSync(updater)) apps.add(updater);
    }
    if (apps.size === 0) {
        apps.add("Discord.exe");
        apps.add("Update.exe");
    }
    return [...apps].join(", ");
}

function sanitizeWireGuardConf(raw: string): { text: string; endpoint: string } {
    if (!/^\s*\[Interface\]\s*$/im.test(raw) || !/^\s*\[Peer\]\s*$/im.test(raw)) {
        throw new Error("Arquivo .conf inválido: faltam seções [Interface] ou [Peer].");
    }
    if (!/^\s*PrivateKey\s*=/im.test(raw) || !/^\s*Address\s*=/im.test(raw) || !/^\s*PublicKey\s*=/im.test(raw)) {
        throw new Error("Arquivo .conf incompleto: PrivateKey, Address ou PublicKey ausentes.");
    }
    const endpoint = readEndpoint(raw);
    if (!endpoint) {
        throw new Error("Arquivo .conf incompleto: Endpoint ausente.");
    }

    const lines = raw
        .split(/\r?\n/)
        .filter(line => !/^\s*(?:#@ws:)?AllowedApps\s*=/i.test(line))
        .filter(line => !/^\s*DNS\s*=/i.test(line));

    // WireSock só aplica AllowedApps dentro da seção [Peer]
    const peerIdx = lines.findIndex(line => /^\s*\[Peer\]\s*$/i.test(line));
    let insertAt = lines.findIndex((line, i) => i > peerIdx && /^\s*\[/.test(line));
    if (insertAt < 0) insertAt = lines.length;
    while (insertAt > peerIdx + 1 && !lines[insertAt - 1].trim()) insertAt--;

    lines.splice(insertAt, 0, `#@ws:AllowedApps = ${resolveDiscordAllowedApps()}`);
    return { text: `${lines.join("\r\n")}\r\n`, endpoint };
}

function psSingleQuote(value: string): string {
    return `'${value.replace(/'/g, "''")}'`;
}

async function runElevatedPowerShell(scriptLines: string[], errorMessage: string): Promise<void> {
    const encodedInner = Buffer.from(scriptLines.join("\n"), "utf16le").toString("base64");
    const wrapper = `$p = Start-Process powershell.exe -Verb RunAs -WindowStyle Hidden -Wait -PassThru -ArgumentList '-NoProfile','-NonInteractive','-EncodedCommand','${encodedInner}'; exit $p.ExitCode`;
    const encodedWrapper = Buffer.from(wrapper, "utf16le").toString("base64");

    const res = await execFileAsync("powershell.exe", ["-NoProfile", "-NonInteractive", "-EncodedCommand", encodedWrapper], 45_000);
    if (res.code !== 0) {
        throw new Error(errorMessage);
    }
}

async function isServiceRunning(): Promise<boolean> {
    const res = await execFileAsync("sc.exe", ["query", SERVICE_NAME], 5_000);
    return res.code === 0 && /\b4\s+RUNNING\b/i.test(res.stdout);
}

export async function getTunnelStatus(_: IpcMainInvokeEvent): Promise<TunnelStatus> {
    if (process.platform !== "win32") {
        return { supported: false, wireSockInstalled: false, serviceRunning: false, confConfigured: false, endpoint: null };
    }

    const wireSockInstalled = findWireSockClient() !== null;
    let confConfigured = false;
    let endpoint: string | null = null;

    try {
        if (fs.existsSync(TARGET_CONF)) {
            const raw = fs.readFileSync(TARGET_CONF, "utf8");
            endpoint = readEndpoint(raw);
            confConfigured = Boolean(endpoint);
        }
    } catch {
        confConfigured = false;
    }

    const serviceRunning = wireSockInstalled ? await isServiceRunning() : false;
    return { supported: true, wireSockInstalled, serviceRunning, confConfigured, endpoint };
}

export async function selectAndApplyConf(event: IpcMainInvokeEvent): Promise<TunnelActionResult> {
    if (process.platform !== "win32") {
        return { ok: false, error: "Disponível apenas para Windows." };
    }

    const wireSockExe = findWireSockClient();
    if (!wireSockExe) {
        return { ok: false, error: "WireSock não está instalado. Rode o Install-GoLiveOpen.ps1 uma vez primeiro." };
    }

    const win = BrowserWindow.fromWebContents(event.sender);
    const dialogOptions = {
        title: "Selecione o arquivo WireGuard (.conf)",
        defaultPath: path.join(os.homedir(), "Downloads"),
        filters: [{ name: "WireGuard Config", extensions: ["conf"] }],
        properties: ["openFile"] as Array<"openFile">,
    };
    const picked = win
        ? await dialog.showOpenDialog(win, dialogOptions)
        : await dialog.showOpenDialog(dialogOptions);

    if (picked.canceled || picked.filePaths.length === 0) {
        return { ok: false, cancelled: true };
    }

    const stagedPath = path.join(os.tmpdir(), `goliveopen-${randomUUID()}.conf`);
    try {
        const raw = fs.readFileSync(picked.filePaths[0], "utf8");
        const { text, endpoint } = sanitizeWireGuardConf(raw);

        try {
            fs.mkdirSync(DATA_DIR, { recursive: true });
            fs.writeFileSync(TARGET_CONF, text, "utf8");
            if (await isServiceRunning()) {
                const stopRes = await execFileAsync("sc.exe", ["stop", SERVICE_NAME], 15_000);
                if (stopRes.code === 0) {
                    await new Promise(r => setTimeout(r, 1_500));
                    const startRes = await execFileAsync("sc.exe", ["start", SERVICE_NAME], 15_000);
                    if (startRes.code === 0) return { ok: true, running: true, endpoint };
                }
            }
        } catch {
            // Cai no fluxo elevado abaixo quando não há permissão no ProgramData ou no SCM.
        }

        fs.writeFileSync(stagedPath, text, "utf8");
        await runElevatedPowerShell([
            "$ErrorActionPreference = 'Stop'",
            `New-Item -ItemType Directory -Path ${psSingleQuote(DATA_DIR)} -Force | Out-Null`,
            `Copy-Item -Path ${psSingleQuote(stagedPath)} -Destination ${psSingleQuote(TARGET_CONF)} -Force`,
            `$svc = Get-Service -Name ${psSingleQuote(SERVICE_NAME)} -ErrorAction SilentlyContinue`,
            "if ($svc) {",
            "  if ($svc.Status -ne 'Stopped') { Stop-Service -Name $svc.Name -Force; $svc.WaitForStatus('Stopped', [TimeSpan]::FromSeconds(20)) }",
            `  & ${psSingleQuote(wireSockExe)} uninstall | Out-Null`,
            "}",
            `& ${psSingleQuote(wireSockExe)} install -start-type 2 -config ${psSingleQuote(TARGET_CONF)} -log-level info -network-lock disabled`,
            "if ($LASTEXITCODE -ne 0) { throw 'Falha ao configurar o serviço WireSock.' }",
            `Set-Service -Name ${psSingleQuote(SERVICE_NAME)} -StartupType Automatic`,
            `Start-Service -Name ${psSingleQuote(SERVICE_NAME)}`,
            `(Get-Service -Name ${psSingleQuote(SERVICE_NAME)}).WaitForStatus('Running', [TimeSpan]::FromSeconds(20))`,
        ], "Permissão cancelada ou falha ao reiniciar o serviço WireSock.");

        return { ok: true, running: true, endpoint };
    } catch (error) {
        return { ok: false, error: error instanceof Error ? error.message : String(error) };
    } finally {
        fs.rmSync(stagedPath, { force: true });
    }
}

export async function toggleTunnel(_: IpcMainInvokeEvent): Promise<TunnelActionResult> {
    if (process.platform !== "win32") {
        return { ok: false, error: "Disponível apenas para Windows." };
    }
    if (!findWireSockClient()) {
        return { ok: false, error: "WireSock não está instalado. Rode o Install-GoLiveOpen.ps1 uma vez primeiro." };
    }
    if (!fs.existsSync(TARGET_CONF)) {
        return { ok: false, error: "Nenhum arquivo .conf configurado ainda." };
    }

    try {
        const wasRunning = await isServiceRunning();
        const action = wasRunning ? "stop" : "start";
        const directRes = await execFileAsync("sc.exe", [action, SERVICE_NAME], 15_000);
        if (directRes.code === 0) {
            await new Promise(r => setTimeout(r, 800));
            return { ok: true, running: await isServiceRunning() };
        }

        const psCmd = wasRunning
            ? `Stop-Service -Name ${psSingleQuote(SERVICE_NAME)} -Force; (Get-Service -Name ${psSingleQuote(SERVICE_NAME)}).WaitForStatus('Stopped', [TimeSpan]::FromSeconds(20))`
            : `Start-Service -Name ${psSingleQuote(SERVICE_NAME)}; (Get-Service -Name ${psSingleQuote(SERVICE_NAME)}).WaitForStatus('Running', [TimeSpan]::FromSeconds(20))`;

        await runElevatedPowerShell([
            "$ErrorActionPreference = 'Stop'",
            psCmd,
        ], "Permissão cancelada ou falha ao alterar o estado do túnel.");

        return { ok: true, running: await isServiceRunning() };
    } catch (error) {
        return { ok: false, error: error instanceof Error ? error.message : String(error) };
    }
}
