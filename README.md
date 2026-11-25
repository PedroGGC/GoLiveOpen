# GoLiveOpen

Plugin simples para o **Vencord** que libera **Go Live**, câmera e seleção de região no Discord, isolando apenas o tráfego do Discord via **WireSock**.

---

## Pré-requisitos

### Para usuários comuns (pré-compilado)
- **Windows 10 ou 11 (64-bit)**
- **Discord** para desktop com o **Vencord já instalado e configurado** ([vencord.dev](https://vencord.dev))
- **Conta gratuita na ProtonVPN** (ou outro provedor WireGuard) para baixar um arquivo `.conf`
- *Não precisa de Node.js, Git nem pnpm.*

---

## Como funciona

```text
Discord.exe / Update.exe  ──▶  WireSock (serviço do Windows)  ──▶  Seu arquivo .conf WireGuard
Jogos, Steam, Navegador   ──▶  Conexão direta normal (0 ms de impacto)
```

- **No Windows:** o serviço **WireSock** aplica um filtro por aplicativo (`#@ws:AllowedApps = Discord, Update`, sem alterar o DNS do Windows), mantendo jogos e demais programas fora do túnel.
- **No Vencord:** o plugin remove a trava visual do cliente, libera seletores de região para voz e transmissão e traz botões para **Inserir/Trocar `.conf`** e **Pausar/Ativar túnel** direto nas configurações.

---

## Instalação, atualização e remoção (1 comando)

Execute no **PowerShell**:

```powershell
irm https://raw.githubusercontent.com/PedroGGC/GoLiveOpen/main/Install-GoLiveOpen.ps1 -OutFile $env:TEMP\glo-install.ps1; powershell -NoProfile -ExecutionPolicy Bypass -File "$env:TEMP\glo-install.ps1"
```

O script abre um menu com as opções:
1. **Instalar / Reinstalar** — instala o WireSock SDK oficial (validado por SHA-256), configura o serviço do túnel e adiciona o **GoLiveOpen** ao seu Vencord já instalado (ou compila no seu checkout local do Vencord, se houver).
2. **Atualizar** — baixa a versão mais recente pré-compilada (ou recompila seu checkout) e mantém o serviço ativo.
3. **Desinstalar apenas o plugin e o túnel** — remove o plugin (restaurando o backup do Vencord) e o serviço do GoLiveOpen, mantendo o WireSock instalado.
4. **Desinstalar tudo** — remove o plugin, o serviço, os arquivos de configuração e o WireSock.

*(Também aceita `-Action Install | Update | UninstallPlugin | UninstallAll` direto via parâmetro.)*

---

## Como usar no Discord

1. Baixe um arquivo **WireGuard (`.conf`)** gratuito fora do Brasil em [account.protonvpn.com/downloads](https://account.protonvpn.com/downloads) (**WireGuard configuration**).
2. No Discord, abra **Configurações do Vencord → Plugins** e ative **`GoLiveOpen`**.
3. Clique na engrenagem do plugin para **Inserir/Trocar `.conf`** ou **Pausar/Ativar túnel**.
4. Se o Discord já estava aberto, pressione `Ctrl + R` uma vez para validar a nova rota.
