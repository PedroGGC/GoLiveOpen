# GoLiveOpen

Plugin simples para o **Vencord** que libera **Go Live**, câmera e seleção de região no Discord, isolando apenas o tráfego do Discord via **WireSock** para não afetar o ping dos seus jogos.

---

## Como funciona

```text
Discord.exe / Update.exe  ──▶  WireSock (serviço do Windows)  ──▶  Seu arquivo .conf WireGuard
Jogos, Steam, Navegador   ──▶  Conexão direta normal (0 ms de impacto)
```

- **No Windows:** o serviço **WireSock** aplica um filtro por aplicativo (`#@ws:AllowedApps = Discord, Update`, sem alterar o DNS do Windows), mantendo jogos e demais programas fora do túnel.
- **No Vencord:** o plugin remove a trava visual do cliente, libera seletores de região para voz e transmissão e oferece um botão **"Inserir arquivo .conf"** direto nas configurações.

---

## Instalação, atualização e remoção

Execute o comando abaixo no **PowerShell**:

```powershell
irm https://raw.githubusercontent.com/PedroGGC/GoLiveOpen/main/Install-GoLiveOpen.ps1 -OutFile $env:TEMP\glo-install.ps1; powershell -NoProfile -ExecutionPolicy Bypass -File "$env:TEMP\glo-install.ps1"
```

O script abre um menu com as opções:
1. **Instalar / Reinstalar tudo** — instala o WireSock SDK oficial (validado por SHA-256), configura o serviço do túnel e compila o plugin no seu checkout do Vencord.
2. **Atualizar** — baixa a versão mais recente do plugin, recompila o Vencord e mantém o serviço ativo.
3. **Desinstalar apenas o plugin e o túnel** — remove o plugin e o serviço do GoLiveOpen, mantendo o WireSock instalado.
4. **Desinstalar tudo** — remove o plugin, o serviço, os arquivos de configuração e o WireSock.

*(Também aceita `-Action Install | Update | UninstallPlugin | UninstallAll` direto por linha de comando.)*

---

## Como usar no Discord

1. Baixe um arquivo **WireGuard (`.conf`)** gratuito fora do Brasil em [account.protonvpn.com/downloads](https://account.protonvpn.com/downloads) (**WireGuard configuration**).
2. No Discord, abra **Configurações do Vencord → Plugins** e ative **`GoLiveOpen`**.
3. Clique na engrenagem do plugin e use **"Inserir arquivo .conf"** (se ainda não tiver escolhido na instalação).
4. Se o Discord já estava aberto, pressione `Ctrl + R` uma vez para validar a nova rota.

---

## Comandos rápidos (PowerShell como Admin)

```powershell
Stop-Service wiresock-client-service   # pausa o túnel
Start-Service wiresock-client-service  # retoma o túnel
```
