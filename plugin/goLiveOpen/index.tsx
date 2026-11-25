/*
 * Vencord, a Discord client mod
 * Copyright (c) 2026 Vendicated and contributors
 * SPDX-License-Identifier: GPL-3.0-or-later
 */

import { definePluginSettings } from "@api/Settings";
import { Button } from "@components/Button";
import { Card } from "@components/Card";
import ErrorBoundary from "@components/ErrorBoundary";
import { Heading } from "@components/Heading";
import { Link } from "@components/Link";
import { Margins } from "@components/margins";
import { Paragraph } from "@components/Paragraph";
import { Logger } from "@utils/Logger";
import { useAwaiter } from "@utils/react";
import definePlugin, { OptionType, PluginNative } from "@utils/types";
import { findStoreLazy } from "@webpack";
import { Constants, React, RestAPI, SearchableSelect, UserStore, useEffect, useState } from "@webpack/common";

import type { TunnelStatus } from "./native";

interface RegionStore {
    getPreferredRegion(): string | null;
    getPreferredRegions(): string[] | null;
    shouldIncludePreferredRegion(): boolean;
}

interface VoiceRegion {
    id: string;
    name: string;
    optimal: boolean;
    deprecated: boolean;
    custom: boolean;
}

interface ApexExperiments {
    getServerAssignment(kind: string, unitId: string, name: string): unknown;
}

const Native = VencordNative?.pluginHelpers?.GoLiveOpen as PluginNative<typeof import("./native")> | undefined;
const RTCRegionStore: RegionStore = findStoreLazy("RTCRegionStore");
const ApexExperimentStore: ApexExperiments = findStoreLazy("ApexExperimentStore");

const VIDEO_GUARD_EXPERIMENT = "2026-08-video-guard";
const AUTOMATIC = "";
const VOICE_KEYS: "voiceRegion"[] = ["voiceRegion"];
const STREAM_KEYS: "streamRegion"[] = ["streamRegion"];
const logger = new Logger("GoLiveOpen");

let originalRegionStore: RegionStore | undefined;

function forcedVoiceRegion(): string | null {
    const region = settings.store.voiceRegion;
    if (typeof region !== "string") return null;
    const trimmed = region.trim();
    return trimmed === AUTOMATIC ? null : trimmed;
}

function forceRegion(): void {
    if (originalRegionStore !== undefined) return;

    try {
        if (typeof RTCRegionStore?.getPreferredRegion !== "function"
            || typeof RTCRegionStore?.getPreferredRegions !== "function"
            || typeof RTCRegionStore?.shouldIncludePreferredRegion !== "function") {
            logger.warn("RTCRegionStore não encontrado; seleção de região de voz desativada.");
            return;
        }

        const saved: RegionStore = {
            getPreferredRegion: RTCRegionStore.getPreferredRegion,
            getPreferredRegions: RTCRegionStore.getPreferredRegions,
            shouldIncludePreferredRegion: RTCRegionStore.shouldIncludePreferredRegion
        };

        RTCRegionStore.getPreferredRegion = function () {
            return forcedVoiceRegion() ?? saved.getPreferredRegion.call(this);
        };

        RTCRegionStore.getPreferredRegions = function () {
            const forced = forcedVoiceRegion();
            const ranked = saved.getPreferredRegions.call(this);
            return forced === null ? ranked : [forced, ...(ranked ?? []).filter(r => r !== forced)];
        };

        RTCRegionStore.shouldIncludePreferredRegion = function () {
            return forcedVoiceRegion() !== null || saved.shouldIncludePreferredRegion.call(this);
        };

        originalRegionStore = saved;
    } catch (error) {
        logger.error("Falha ao aplicar override de região de voz", error);
    }
}

function restoreRegion(): void {
    if (originalRegionStore === undefined) return;
    try {
        RTCRegionStore.getPreferredRegion = originalRegionStore.getPreferredRegion;
        RTCRegionStore.getPreferredRegions = originalRegionStore.getPreferredRegions;
        RTCRegionStore.shouldIncludePreferredRegion = originalRegionStore.shouldIncludePreferredRegion;
    } finally {
        originalRegionStore = undefined;
    }
}

function getGatewayRouteStatus(): "clear" | "blocked" | "unknown" {
    try {
        const user = UserStore.getCurrentUser();
        if (!user) return "unknown";

        const assignment = ApexExperimentStore.getServerAssignment("user", user.id, VIDEO_GUARD_EXPERIMENT);
        if (assignment === null || typeof assignment !== "object") return "clear";

        // Variações 1 e 2 são atribuídas pelo servidor quando o IP de conexão é detectado como BR.
        const { variantId } = assignment as { variantId?: unknown; };
        return variantId === 1 || variantId === 2 ? "blocked" : "clear";
    } catch {
        return "unknown";
    }
}

interface RegionSelectProps {
    value: string;
    placeholder: string;
    automaticLabel: string;
    onChange(region: string): void;
}

function RegionSelect({ value, placeholder, automaticLabel, onChange }: RegionSelectProps) {
    const [regions, error, pending] = useAwaiter(
        async () => {
            const { body } = await RestAPI.get({ url: Constants.Endpoints.REGIONS() });
            return (body as VoiceRegion[]).filter(region => !region.deprecated && !region.custom);
        },
        { fallbackValue: [] as VoiceRegion[] }
    );

    if (pending) return <Paragraph>Carregando lista de regiões...</Paragraph>;
    if (error) return <Paragraph>Não foi possível carregar as regiões. Entre em uma conta e reabra as configurações.</Paragraph>;

    const options = [
        { label: automaticLabel, value: AUTOMATIC },
        ...regions.map(region => ({
            label: region.optimal ? `${region.name} (recomendada para o IP atual)` : region.name,
            value: region.id
        }))
    ];

    return (
        <SearchableSelect
            placeholder={placeholder}
            maxVisibleItems={6}
            options={options}
            value={options.find(o => o.value === value)?.value ?? AUTOMATIC}
            onChange={v => onChange(typeof v === "string" ? v : AUTOMATIC)}
            closeOnSelect
        />
    );
}

function VoiceRegionPicker() {
    const { voiceRegion } = settings.use(VOICE_KEYS);
    return (
        <RegionSelect
            value={voiceRegion}
            placeholder="Escolha a região das chamadas de voz"
            automaticLabel="Automático (padrão do Discord)"
            onChange={region => { settings.store.voiceRegion = region; }}
        />
    );
}

function StreamRegionPicker() {
    const { streamRegion } = settings.use(STREAM_KEYS);
    return (
        <RegionSelect
            value={streamRegion}
            placeholder="Escolha a região do Go Live"
            automaticLabel="Mesma região da chamada"
            onChange={region => { settings.store.streamRegion = region; }}
        />
    );
}

const settings = definePluginSettings({
    voiceRegion: {
        type: OptionType.COMPONENT,
        component: VoiceRegionPicker,
        default: AUTOMATIC
    },
    streamRegion: {
        type: OptionType.COMPONENT,
        component: StreamRegionPicker,
        default: AUTOMATIC
    }
});

function AboutPlugin() {
    const status = getGatewayRouteStatus();
    const [tunnel, setTunnel] = useState<TunnelStatus | null>(null);
    const [busy, setBusy] = useState(false);
    const [feedback, setFeedback] = useState<{ kind: "ok" | "err"; text: string } | null>(null);

    const refreshTunnel = async () => {
        if (!Native?.getTunnelStatus) return;
        try {
            setTunnel(await Native.getTunnelStatus());
        } catch {
            // Sem ponte nativa disponível (ex.: Discord Web)
        }
    };

    useEffect(() => {
        void refreshTunnel();
    }, []);

    const handlePickConf = async () => {
        if (!Native?.selectAndApplyConf || busy) return;
        setBusy(true);
        setFeedback(null);
        try {
            const result = await Native.selectAndApplyConf();
            if (result.cancelled) return;
            if (!result.ok) {
                setFeedback({ kind: "err", text: result.error || "Não foi possível aplicar o arquivo .conf." });
                return;
            }
            setFeedback({
                kind: "ok",
                text: `Arquivo aplicado (${result.endpoint ?? "ok"}). Pressione Ctrl + R para o Discord reconhecer a nova rota.`
            });
            await refreshTunnel();
        } catch (error) {
            setFeedback({ kind: "err", text: error instanceof Error ? error.message : String(error) });
        } finally {
            setBusy(false);
        }
    };

    const statusConfig = {
        clear: {
            variant: "success" as const,
            title: "Rota liberada pelo Discord",
            text: "O Gateway do Discord não aplicou o bloqueio regional nesta sessão. O Go Live e a câmera devem funcionar normalmente."
        },
        blocked: {
            variant: "warning" as const,
            title: "Discord ainda detectando IP do Brasil",
            text: "Os botões continuam visíveis na interface, mas o servidor ainda vê um IP brasileiro. Insira seu .conf abaixo e recarregue com Ctrl + R."
        },
        unknown: {
            variant: "info" as const,
            title: "Status da rota indisponível",
            text: "Faça login no Discord e reabra esta janela para verificar se o Gateway liberou o Go Live."
        }
    }[status];

    return (
        <div className={Margins.bottom16}>
            <Card variant={statusConfig.variant} defaultPadding className={Margins.bottom16}>
                <Heading tag="h5">{statusConfig.title}</Heading>
                <Paragraph className={Margins.top8}>{statusConfig.text}</Paragraph>
            </Card>

            <Card variant="normal" defaultPadding className={Margins.bottom16}>
                <Heading tag="h5">Arquivo WireGuard (.conf)</Heading>
                {tunnel?.supported && (
                    <Paragraph className={Margins.top8}>
                        {!tunnel.wireSockInstalled
                            ? "WireSock não encontrado no Windows. Rode o instalador Install-GoLiveOpen.ps1 uma vez primeiro."
                            : tunnel.confConfigured
                                ? `Túnel ${tunnel.serviceRunning ? "ativo" : "parado"} · Endpoint: ${tunnel.endpoint ?? "configurado"}`
                                : "Nenhum .conf configurado ainda."}
                    </Paragraph>
                )}
                <div className={Margins.top8}>
                    <Button
                        variant="primary"
                        size="small"
                        disabled={busy || !Native?.selectAndApplyConf}
                        onClick={handlePickConf}
                    >
                        {busy ? "Aplicando .conf..." : "Inserir arquivo .conf"}
                    </Button>
                </div>
                <Paragraph className={Margins.top8}>
                    Você pode criar e baixar um .conf gratuito aqui:{" "}
                    <Link href="https://account.protonvpn.com/downloads">account.protonvpn.com/downloads</Link>{" "}
                    (em WireGuard configuration).
                </Paragraph>
                {feedback && (
                    <Paragraph className={Margins.top8}>
                        {feedback.text}
                    </Paragraph>
                )}
            </Card>

            <Card variant="normal">
                <Heading tag="h5">Como funciona (zero impacto nos jogos)</Heading>
                <Paragraph className={Margins.top8}>
                    O túnel roteia apenas <code>Discord.exe</code> e <code>Update.exe</code> pelo WireSock, sem alterar o DNS do Windows nem o ping dos seus jogos. Depois da primeira configuração, não abre PowerShell nem pede reinício ao abrir o Discord.
                </Paragraph>
            </Card>
        </div>
    );
}

export default definePlugin({
    name: "GoLiveOpen",
    description: "Remove o bloqueio visual do Go Live/câmera e aplica um .conf WireGuard isolado apenas para o Discord.",
    authors: [{ name: "Local", id: 0n }],
    tags: ["Voice", "Utility"],
    settings,
    settingsAboutComponent: ErrorBoundary.wrap(AboutPlugin, { noop: true }),

    patches: [
        {
            find: '"2026-08-video-guard"',
            replacement: {
                match: /(?<=name:"2026-08-video-guard".{0,100}?)variations:\{.{0,120}?\}\}(?=\}\))/,
                replace: "variations:{}"
            }
        },
        {
            find: ".STREAM_CREATE,{type:",
            replacement: {
                match: /(?<=\.STREAM_CREATE,\{.{0,80}?preferred_region:)\i/,
                replace: "$self.pickStreamRegion($&)"
            }
        }
    ],

    pickStreamRegion(fallback: string | null): string | null {
        try {
            const region = settings.store.streamRegion;
            return typeof region === "string" && region !== AUTOMATIC ? region : fallback;
        } catch {
            return fallback;
        }
    },

    start() {
        forceRegion();
    },

    stop() {
        restoreRegion();
    }
});
