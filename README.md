# GoLiveOpen

Alternativa enxuta, transparente e *plug-and-play* para liberar **Go Live** e **câmera** no Discord no Brasil — sem alterar o `app.asar`, sem PowerShell abrindo toda hora e sem afetar o ping dos seus jogos.

---

## Como funciona

O bloqueio do Go Live no Brasil acontece em duas camadas:
1. **Cliente:** o experimento `2026-08-video-guard` esconde/trava os botões na interface.
2. **Servidor (GeoIP + WebRTC/UDP):** os servidores do Discord verificam o IP do Gateway e da conexão de mídia (`discord_voice.node` em UDP).

Por isso o **GoLiveOpen** divide o trabalho em duas peças simples:

```text
Discord.exe / Update.exe  ──▶  WireSock (serviço do Windows)  ──▶  Seu .conf WireGuard (ex.: Proton Free EUA)
Jogos, Steam, Navegador   ──▶  Conexão direta do Brasil (0 ms de impacto)
```

1. **No Windows (configurado 1 única vez):** o serviço oficial **WireSock** usa o filtro de pacotes do Windows (WFP) para tunelar **apenas** `Discord.exe` e `Update.exe` pelo seu arquivo `.conf` do WireGuard (`#@ws:AllowedApps = Discord, Update`, sem sobrescrever o DNS do sistema).
2. **No Vencord (`GoLiveOpen`):** um plugin de ~260 linhas que apenas remove o experimento `2026-08-video-guard`, libera seletor separado de região para **voz** e **transmissão**, e mostra na tela de configurações se o Gateway do Discord já liberou a rota.

---

## Por que usar em vez do GoLiveBypass?

| | GoLiveBypass | GoLiveOpen |
|---|---|---|
| **Ao abrir o Discord** | Roda PowerShell, checa/instala coisas e pede reinício | **Nada.** O serviço já roda limpo em segundo plano |
| **Qualidade da live** | Depende de rotas gratuitas compartilhadas/congestionadas | **Igual ao ProtonVPN oficial** (usa o seu próprio `.conf`) |
| **Código no Vencord** | ~3.200+ linhas, `native.ts`, `proton-confgen.exe`, auto-updater | **1 arquivo (`index.tsx`), zero código nativo/executáveis** |
| **Login Proton** | Pede usuário/senha/CAPTCHA dentro do Discord | **Não pede.** Você baixa o `.conf` direto no site da Proton |
| **Impacto em jogos** | Isolado por aplicativo | **Isolado por aplicativo** (`0 ms` de impacto nos jogos) |

---

## Passo a passo de instalação

### 1. Baixe seu arquivo `.conf` gratuito da ProtonVPN (1 vez só)
1. Entre em [account.protonvpn.com/downloads](https://account.protonvpn.com/downloads) com uma conta gratuita da Proton.
2. Vá em **WireGuard configuration**.
3. Escolha plataforma **Windows** (ou **Router**), selecione um servidor gratuito fora do Brasil (ex.: **US-FREE**), clique em **Create** e depois em **Download** para salvar o `.conf`.

### 2. Rode o instalador (1 comando no PowerShell)
Abra o **PowerShell** e execute:

```powershell
irm https://raw.githubusercontent.com/PedroGGC/GoLiveOpen/main/Install-GoLiveOpen.ps1 -OutFile $env:TEMP\glo-install.ps1; powershell -NoProfile -ExecutionPolicy Bypass -File "$env:TEMP\glo-install.ps1"
```

*(Ou baixe o repositório e rode `.\Install-GoLiveOpen.ps1 -ConfPath "C:\caminho\seu.conf"`.)*

O que o script faz:
1. Pede elevação (UAC) **uma única vez** para instalar o serviço de rede.
2. Pede para você selecionar o arquivo `.conf` baixado no passo 1.
3. Baixa e instala o **WireSock SDK 3.8.2.1** oficial (conferindo o **SHA-256** do instalador).
4. Sanitiza o `.conf` (remove `DNS =` e adiciona `#@ws:AllowedApps = Discord, Update` dentro de `[Peer]`) e salva em `C:\ProgramData\GoLiveOpen\discord.conf`.
5. Registra e inicia o serviço `wiresock-client-service` no Windows.
6. Se encontrar seu checkout local do **Vencord** (ou via `-VencordDir`), copia o plugin para `src\userplugins\goLiveOpen\index.tsx` e compila com `pnpm build --dev`.

### 3. Ative o plugin no Discord
1. Abra as **Configurações do Vencord → Plugins**.
2. Ative **`GoLiveOpen`**.
3. Clique na engrenagem do plugin para conferir se aparece **"Rota liberada pelo Discord"** (se o Discord já estava aberto antes da instalação, pressione `Ctrl + R` uma vez).

---

## Uso diário e manutenção

- **Trocar de servidor (`.conf` novo):** rode o `Install-GoLiveOpen.ps1` novamente apontando o novo `.conf` (ele não baixa o WireSock de novo, apenas atualiza o arquivo e reinicia o serviço).
- **Pausar / retomar rapidamente (PowerShell como Admin):**
  ```powershell
  Stop-Service wiresock-client-service   # pausa
  Start-Service wiresock-client-service  # retoma
  ```
- **Modo manual (não iniciar com o Windows):** passe `-Startup Manual` ao instalar.
- **Desinstalar completamente:**
  ```powershell
  powershell -NoProfile -ExecutionPolicy Bypass -File .\Uninstall-GoLiveOpen.ps1
  ```

---

## Aviso sobre latência

- **Jogos e demais apps:** **0 ms** de alteração (não passam pelo túnel).
- **Discord (voz e live):** depende da distância e carga do servidor WireGuard do seu `.conf`. Servidores gratuitos na costa leste dos EUA (Miami/Newark) costumam entregar a melhor estabilidade a partir do Brasil.
