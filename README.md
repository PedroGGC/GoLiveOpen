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

1. **No Windows (instalado 1 única vez):** o serviço oficial **WireSock** usa o filtro de pacotes do Windows (WFP) para tunelar **apenas** `Discord.exe` e `Update.exe` pelo seu arquivo `.conf` do WireGuard (`#@ws:AllowedApps = Discord, Update`, sem sobrescrever o DNS do sistema).
2. **No Vencord (`GoLiveOpen`):**
   - Remove o experimento `2026-08-video-guard`;
   - Tem um botão **"Inserir arquivo .conf"** direto nas configurações do plugin (com link para criar/baixar o `.conf` gratuito da Proton);
   - Libera seletor separado de região para **voz** e **transmissão** e mostra o status real da rota.

---

## Por que usar em vez do GoLiveBypass?

| | GoLiveBypass | GoLiveOpen |
|---|---|---|
| **Ao abrir o Discord** | Roda PowerShell, checa/instala coisas e pede reinício | **Nada.** O serviço já roda limpo em segundo plano |
| **Qualidade da live** | Depende de rotas gratuitas compartilhadas/congestionadas | **Igual ao ProtonVPN oficial** (usa o seu próprio `.conf`) |
| **Trocar servidor/.conf** | Fluxo complexo com binário próprio (`proton-confgen.exe`) | **1 botão "Inserir arquivo .conf"** nas configurações do plugin |
| **Login Proton** | Pede usuário/senha/CAPTCHA dentro do Discord | **Não pede.** Você baixa o `.conf` direto no site da Proton |
| **Impacto em jogos** | Isolado por aplicativo | **Isolado por aplicativo** (`0 ms` de impacto nos jogos) |

---

## Passo a passo de instalação

### 1. Rode o instalador (1 comando no PowerShell)
Abra o **PowerShell** e execute:

```powershell
irm https://raw.githubusercontent.com/PedroGGC/GoLiveOpen/main/Install-GoLiveOpen.ps1 -OutFile $env:TEMP\glo-install.ps1; powershell -NoProfile -ExecutionPolicy Bypass -File "$env:TEMP\glo-install.ps1"
```

O que esse PowerShell faz exatamente (tudo aberto e auditável no script):
1. Pede permissão de administrador (UAC) **uma única vez** para instalar o serviço de rede.
2. Baixa e instala o **WireSock SDK 3.8.2.1** oficial (validando o **SHA-256** do instalador).
3. Abre a janela para selecionar seu `.conf` (ou você pode cancelar e inserir depois direto no Discord).
4. Remove `DNS =` do `.conf`, adiciona `#@ws:AllowedApps = Discord, Update` dentro de `[Peer]`, salva em `C:\ProgramData\GoLiveOpen\discord.conf` e inicia o serviço `wiresock-client-service`.
5. Copia o plugin (`index.tsx` e `native.ts`) para `src\userplugins\goLiveOpen` no seu checkout do Vencord e roda `pnpm build --dev`.

### 2. Crie/baixe seu `.conf` gratuito da ProtonVPN (se ainda não tiver)
1. Acesse [account.protonvpn.com/downloads](https://account.protonvpn.com/downloads) com uma conta gratuita da Proton.
2. Vá em **WireGuard configuration**, escolha **Windows** e um servidor gratuito fora do Brasil (ex.: **US-FREE**).
3. Clique em **Create** e depois em **Download** para salvar o `.conf`.

### 3. Ative e use direto no Discord
1. Abra **Configurações do Vencord → Plugins** e ative **`GoLiveOpen`**.
2. Clique na engrenagem do plugin:
   - Se ainda não inseriu ou quiser trocar o servidor, clique em **"Inserir arquivo .conf"** (o link para a Proton fica logo abaixo do botão).
   - Confira se o status mostra **"Rota liberada pelo Discord"** (se acabou de ativar o túnel com o Discord aberto, pressione `Ctrl + R` uma vez).

---

## Uso diário e manutenção

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
