[CmdletBinding()]
param(
    [ValidateSet("", "Install", "Update", "UninstallPlugin", "UninstallAll")]
    [string]$Action = "",
    [string]$ConfPath = "",
    [string]$VencordDir = "",
    [string]$UserAppData = "",
    [string]$UserLocalAppData = "",
    [string]$LogFile = "",
    [ValidateSet("Automatic", "Manual")]
    [string]$Startup = "Automatic",
    [switch]$SkipConf,
    [switch]$SkipVencord
)

$ErrorActionPreference = "Stop"

$WireSockVersion = "3.8.2.1"
$WireSockUrl = "https://wiresock.net/_api/download-release.php?product=wiresock-secure-connect-sdk&platform=x64&version=$WireSockVersion&channel=winget"
$WireSockSha256 = "3fa1ca6e595ff64ee638ccda8c14c8c5c6b65099130c4345f94464bcc3a0469c"
$ServiceName = "wiresock-client-service"
$DataDir = Join-Path $env:ProgramData "GoLiveOpen"
$TargetConf = Join-Path $DataDir "discord.conf"

$RepoRawBase = "https://raw.githubusercontent.com/PedroGGC/GoLiveOpen/main/plugin/goLiveOpen"
$ReleaseDistUrl = "https://github.com/PedroGGC/GoLiveOpen/releases/latest/download/vencord-goliveopen-dist.zip"
$ReleaseShaUrl = "https://github.com/PedroGGC/GoLiveOpen/releases/latest/download/vencord-goliveopen-dist.zip.sha256"

if (-not $UserAppData) { $UserAppData = $env:APPDATA }
if (-not $UserLocalAppData) { $UserLocalAppData = $env:LOCALAPPDATA }

function Write-Log {
    param(
        [string]$Message,
        [string]$Color = "White"
    )
    if ($LogFile) {
        [System.IO.File]::AppendAllText($LogFile, "$Color|$Message`n", [System.Text.UTF8Encoding]::new($false))
    } else {
        Write-Host $Message -ForegroundColor $Color
    }
}

function Flush-LogLines {
    param([string]$Path, [ref]$LineOffset)
    if (-not (Test-Path $Path)) { return }
    $allLines = [System.IO.File]::ReadAllLines($Path, [System.Text.UTF8Encoding]::new($false))
    while ($LineOffset.Value -lt $allLines.Length) {
        $entry = $allLines[$LineOffset.Value]
        $LineOffset.Value++
        $sep = $entry.IndexOf('|')
        if ($sep -gt 0) {
            $c = $entry.Substring(0, $sep)
            $msg = $entry.Substring($sep + 1)
            try { Write-Host $msg -ForegroundColor $c } catch { Write-Host $msg }
        } else {
            Write-Host $entry
        }
    }
}

function Test-IsAdmin {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = [Security.Principal.WindowsPrincipal]$identity
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Show-Menu {
    Write-Host ""
    Write-Host "=== GoLiveOpen ===" -ForegroundColor Cyan
    Write-Host "  [1] Instalar / Reinstalar (WireSock + tunel + plugin GoLiveOpen)"
    Write-Host "  [2] Atualizar plugin e servico"
    Write-Host "  [3] Desinstalar apenas o plugin e o tunel (mantem o WireSock)"
    Write-Host "  [4] Desinstalar tudo (plugin, tunel e WireSock)"
    Write-Host "  [0] Sair"
    Write-Host ""

    while ($true) {
        $choice = (Read-Host "Escolha uma opcao").Trim()
        switch ($choice) {
            "1" { return "Install" }
            "2" { return "Update" }
            "3" { return "UninstallPlugin" }
            "4" { return "UninstallAll" }
            "0" { return "" }
            default { Write-Host "Opcao invalida. Digite 1, 2, 3, 4 ou 0." -ForegroundColor Yellow }
        }
    }
}

function Select-ConfFile {
    param([string]$InitialDir)

    $escapedDir = $InitialDir -replace "'", "''"
    $pickerScript = @"
Add-Type -AssemblyName System.Windows.Forms
`$dlg = New-Object System.Windows.Forms.OpenFileDialog
`$dlg.Title = 'Selecione o arquivo WireGuard (.conf) (ou cancele para escolher depois no Discord)'
`$dlg.Filter = 'WireGuard Config (*.conf)|*.conf|Todos os arquivos (*.*)|*.*'
if (Test-Path '$escapedDir') { `$dlg.InitialDirectory = '$escapedDir' }
if (`$dlg.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) { Write-Output `$dlg.FileName }
"@
    $picked = & powershell.exe -NoProfile -STA -Command $pickerScript 2>$null
    if ($picked -and (Test-Path $picked)) { return $picked.Trim() }
    return ""
}

function Find-WireSockClient {
    $roots = @(
        $env:ProgramW6432,
        $env:ProgramFiles,
        ${env:ProgramFiles(x86)},
        "C:\Program Files"
    ) | Where-Object { $_ } | Select-Object -Unique

    foreach ($root in $roots) {
        foreach ($rel in @("WireSock Secure Connect\wiresock-client.exe", "WireSock Secure Connect\sdk\wiresock-client.exe")) {
            $candidate = Join-Path $root $rel
            if (Test-Path $candidate) { return $candidate }
        }
    }
    return $null
}

function Install-WireSock {
    $existing = Find-WireSockClient
    if ($existing) {
        Write-Log "  WireSock SDK ja instalado ($existing)." "DarkGray"
        return $existing
    }

    $tempInstaller = Join-Path $env:TEMP "wiresock-sdk-$WireSockVersion.exe"
    Write-Log "  Baixando WireSock SDK $WireSockVersion oficial..." "Cyan"
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    Invoke-WebRequest -Uri $WireSockUrl -OutFile $tempInstaller -UseBasicParsing

    Write-Log "  Validando integridade (SHA-256) do instalador..." "Cyan"
    $hash = (Get-FileHash -Path $tempInstaller -Algorithm SHA256).Hash.ToLowerInvariant()
    if ($hash -ne $WireSockSha256) {
        Remove-Item $tempInstaller -Force -ErrorAction SilentlyContinue
        throw "SHA-256 do instalador WireSock nao confere (esperado $WireSockSha256, obtido $hash)."
    }

    Write-Log "  Instalando WireSock SDK..." "Cyan"
    $proc = Start-Process -FilePath $tempInstaller -ArgumentList @("/quiet", "/norestart") -Wait -PassThru
    Remove-Item $tempInstaller -Force -ErrorAction SilentlyContinue
    if ($proc.ExitCode -ne 0) {
        throw "Instalador do WireSock retornou codigo $($proc.ExitCode)."
    }

    $deadline = (Get-Date).AddSeconds(30)
    while ((Get-Date) -lt $deadline) {
        $found = Find-WireSockClient
        if ($found) {
            Write-Log "  WireSock instalado com sucesso." "Green"
            return $found
        }
        Start-Sleep -Milliseconds 500
    }
    throw "WireSock instalado, mas wiresock-client.exe nao foi encontrado."
}

function Uninstall-WireSockPackage {
    $regPaths = @(
        "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*",
        "HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*"
    )
    $entries = Get-ItemProperty -Path $regPaths -ErrorAction SilentlyContinue |
        Where-Object { $_.DisplayName -match "WireSock" }

    $removed = $false
    foreach ($entry in $entries) {
        $cmd = if ($entry.QuietUninstallString) { $entry.QuietUninstallString } else { $entry.UninstallString }
        if (-not $cmd) { continue }

        Write-Log "  Removendo $($entry.DisplayName)..." "Cyan"
        if ($cmd -match '^msiexec(?:\.exe)?\s+(.+)$') {
            $msiArgs = ($Matches[1] -replace '/I', '/X') + " /qn /norestart"
            $p = Start-Process -FilePath "msiexec.exe" -ArgumentList $msiArgs -Wait -PassThru
            if ($p.ExitCode -eq 0) { $removed = $true }
        } elseif ($cmd -match '^"([^"]+)"(.*)$' -or $cmd -match '^(\S+)(.*)$') {
            $exe = $Matches[1]
            $extra = $Matches[2].Trim()
            $argsList = if ($extra) { "$extra /quiet /norestart" } else { "/uninstall /quiet /norestart" }
            if (Test-Path $exe) {
                $p = Start-Process -FilePath $exe -ArgumentList $argsList -Wait -PassThru
                if ($p.ExitCode -eq 0) { $removed = $true }
            }
        }
    }

    if (-not $removed -and (Find-WireSockClient)) {
        Write-Log "  Nao foi possivel desinstalar o WireSock automaticamente; remova em Configuracoes > Aplicativos > WireSock Secure Connect." "Yellow"
    }
}

function Resolve-DiscordAllowedApps {
    $discordDir = Join-Path $UserLocalAppData "Discord"
    $apps = [System.Collections.Generic.List[string]]::new()
    if (Test-Path $discordDir) {
        $latestExe = Get-ChildItem -Path $discordDir -Filter "Discord.exe" -Recurse -Depth 2 -ErrorAction SilentlyContinue |
            Sort-Object LastWriteTime -Descending |
            Select-Object -First 1
        if ($latestExe) { $apps.Add($latestExe.FullName) }
        $updater = Join-Path $discordDir "Update.exe"
        if (Test-Path $updater) { $apps.Add($updater) }
    }
    if ($apps.Count -eq 0) {
        $apps.Add("Discord.exe")
        $apps.Add("Update.exe")
    }
    return ($apps -join ", ")
}

function ConvertTo-DiscordWireSockConf {
    param([string]$RawText)

    if ($RawText -notmatch '(?mi)^\s*\[Interface\]\s*$' -or $RawText -notmatch '(?mi)^\s*\[Peer\]\s*$') {
        throw "Arquivo .conf invalido: faltam secoes [Interface] ou [Peer]."
    }
    if ($RawText -notmatch '(?mi)^\s*PrivateKey\s*=' -or $RawText -notmatch '(?mi)^\s*Address\s*=' -or $RawText -notmatch '(?mi)^\s*PublicKey\s*=' -or $RawText -notmatch '(?mi)^\s*Endpoint\s*=') {
        throw "Arquivo .conf incompleto: PrivateKey, Address, PublicKey ou Endpoint ausentes."
    }

    $lines = [System.Collections.Generic.List[string]]::new()
    foreach ($line in ($RawText -split "\r?\n")) {
        if ($line -match '^\s*(?:#@ws:)?AllowedApps\s*=') { continue }
        if ($line -match '^\s*DNS\s*=') { continue }
        $lines.Add($line)
    }

    # WireSock so aplica AllowedApps dentro da secao [Peer]
    $peerIdx = -1
    for ($i = 0; $i -lt $lines.Count; $i++) {
        if ($lines[$i] -match '^\s*\[Peer\]\s*$') { $peerIdx = $i; break }
    }
    $insertAt = $lines.Count
    for ($i = $peerIdx + 1; $i -lt $lines.Count; $i++) {
        if ($lines[$i] -match '^\s*\[') { $insertAt = $i; break }
    }
    while ($insertAt -gt ($peerIdx + 1) -and [string]::IsNullOrWhiteSpace($lines[$insertAt - 1])) {
        $insertAt--
    }

    $lines.Insert($insertAt, "#@ws:AllowedApps = $(Resolve-DiscordAllowedApps)")
    return ($lines -join "`r`n") + "`r`n"
}

function Find-VencordCheckout {
    param([string]$Hint)

    $candidates = @($Hint, (Join-Path $PSScriptRoot "..\Vencord"), (Join-Path $env:USERPROFILE "Documents\vencord\Vencord"), (Join-Path $env:USERPROFILE "Vencord")) | Where-Object { $_ }
    foreach ($dir in $candidates) {
        $pkg = Join-Path $dir "package.json"
        if ((Test-Path $pkg) -and (Test-Path (Join-Path $dir "src\userplugins"))) {
            return (Resolve-Path $dir).Path
        }
    }
    return $null
}

function Invoke-VencordBuild {
    param([string]$VencordPath)

    Write-Log "  Compilando Vencord (pnpm build --dev)..." "Cyan"
    Push-Location $VencordPath
    try {
        $null = & pnpm build --dev 2>&1
        if ($LASTEXITCODE -ne 0) {
            throw "Falha ao compilar o Vencord (codigo $LASTEXITCODE)."
        }
    } finally {
        Pop-Location
    }
}

function Stop-DiscordIfRunning {
    $procs = Get-Process -Name "Discord" -ErrorAction SilentlyContinue
    if (-not $procs) { return $false }
    Write-Log "  Discord estava aberto — fechando para aplicar alteracoes..." "Cyan"
    $procs | Stop-Process -Force
    Start-Sleep -Seconds 1
    return $true
}

function Launch-Discord {
    param([bool]$WasRunning)

    $updateExe = Join-Path $UserLocalAppData "Discord\Update.exe"
    if (-not (Test-Path $updateExe)) { return }
    if ($WasRunning) {
        Write-Log "Reabrindo Discord..." "Cyan"
    } else {
        Write-Log "Abrindo Discord..." "Cyan"
    }
    Start-Process -FilePath $updateExe -ArgumentList @("--processStart", "Discord.exe") | Out-Null
}

function Install-VencordSourcePlugin {
    param([string]$VencordPath, [switch]$PreferRemote)

    Write-Log "  Copiando arquivos do plugin para $VencordPath\src\userplugins\goLiveOpen..." "Cyan"
    $pluginDestDir = Join-Path $VencordPath "src\userplugins\goLiveOpen"
    New-Item -ItemType Directory -Path $pluginDestDir -Force | Out-Null

    foreach ($fileName in @("index.tsx", "native.ts")) {
        $localFile = Join-Path $PSScriptRoot "plugin\goLiveOpen\$fileName"
        $destFile = Join-Path $pluginDestDir $fileName
        if (-not $PreferRemote -and (Test-Path $localFile)) {
            Copy-Item -Path $localFile -Destination $destFile -Force
        } else {
            Invoke-WebRequest -Uri "$RepoRawBase/$fileName" -OutFile $destFile -UseBasicParsing
        }
    }

    $wasRunning = Stop-DiscordIfRunning
    Invoke-VencordBuild -VencordPath $VencordPath
    Write-Log "Plugin instalado com sucesso!" "Green"
    if (-not $LogFile) { Launch-Discord -WasRunning:$wasRunning }
}

function Install-VencordPrebuilt {
    $vencordData = Join-Path $UserAppData "Vencord"
    $distDir = Join-Path $vencordData "dist"
    if (-not (Test-Path $vencordData)) {
        throw "Vencord nao encontrado em '$vencordData'. Instale e configure o Vencord primeiro (https://vencord.dev) e rode este script novamente."
    }

    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    $zipPath = Join-Path $env:TEMP "vencord-goliveopen-dist.zip"
    $shaPath = Join-Path $env:TEMP "vencord-goliveopen-dist.zip.sha256"

    Write-Log "  Baixando plugin GoLiveOpen pre-compilado..." "Cyan"
    Invoke-WebRequest -Uri $ReleaseDistUrl -OutFile $zipPath -UseBasicParsing
    Invoke-WebRequest -Uri $ReleaseShaUrl -OutFile $shaPath -UseBasicParsing

    Write-Log "  Validando integridade (SHA-256) do plugin..." "Cyan"
    $expectedHash = ((Get-Content $shaPath -Raw).Trim() -split '\s+')[0].ToLowerInvariant()
    $actualHash = (Get-FileHash -Path $zipPath -Algorithm SHA256).Hash.ToLowerInvariant()
    if ($expectedHash -ne $actualHash) {
        Remove-Item $zipPath, $shaPath -Force -ErrorAction SilentlyContinue
        throw "SHA-256 do pacote pre-compilado nao confere (esperado $expectedHash, obtido $actualHash)."
    }

    $wasRunning = Stop-DiscordIfRunning
    Write-Log "  Configurando plugin no Vencord..." "Cyan"
    $backupDir = Join-Path $vencordData "dist.goliveopen-bak"
    if ((Test-Path $distDir) -and -not (Test-Path $backupDir)) {
        Copy-Item -Path $distDir -Destination $backupDir -Recurse -Force
    }
    New-Item -ItemType Directory -Path $distDir -Force | Out-Null
    Expand-Archive -Path $zipPath -DestinationPath $distDir -Force
    Remove-Item $zipPath, $shaPath -Force -ErrorAction SilentlyContinue

    Write-Log "Plugin instalado com sucesso!" "Green"
    if (-not $LogFile) { Launch-Discord -WasRunning:$wasRunning }
}

function Stop-AndRemoveTunnelService {
    $svc = Get-Service -Name $ServiceName -ErrorAction SilentlyContinue
    if ($svc) {
        if ($svc.Status -ne "Stopped") {
            Write-Log "  Parando servico $ServiceName..." "Cyan"
            Stop-Service -Name $ServiceName -Force
            $svc.WaitForStatus("Stopped", [TimeSpan]::FromSeconds(20))
        }
        $client = Find-WireSockClient
        if ($client) {
            & $client uninstall | Out-Null
        } else {
            & sc.exe delete $ServiceName | Out-Null
        }
        Write-Log "  Servico $ServiceName removido." "Green"
    }
    if (Test-Path $DataDir) {
        Remove-Item -Path $DataDir -Recurse -Force
        Write-Log "  Perfil removido de $DataDir." "Green"
    }
}

function Register-AndStartService {
    param([string]$WireSockExe, [string]$ConfFile, [string]$StartupMode)

    $existingSvc = Get-Service -Name $ServiceName -ErrorAction SilentlyContinue
    if ($existingSvc) {
        if ($existingSvc.Status -ne "Stopped") {
            Stop-Service -Name $ServiceName -Force
            $existingSvc.WaitForStatus("Stopped", [TimeSpan]::FromSeconds(20))
        }
        & $WireSockExe uninstall | Out-Null
    }

    $startTypeFlag = if ($StartupMode -eq "Automatic") { "2" } else { "3" }
    & $WireSockExe install -start-type $startTypeFlag -config $ConfFile -log-level info -network-lock disabled
    if ($LASTEXITCODE -ne 0) {
        throw "Falha ao registrar o servico WireSock."
    }
    Set-Service -Name $ServiceName -StartupType $StartupMode
    Start-Service -Name $ServiceName
    (Get-Service -Name $ServiceName).WaitForStatus("Running", [TimeSpan]::FromSeconds(20))
    Write-Log "  Servico $ServiceName ativo e configurado ($StartupMode)." "Green"
}

function Remove-VencordIntegration {
    $vencordPath = Find-VencordCheckout -Hint $VencordDir
    if ($vencordPath -and (Get-Command pnpm -ErrorAction SilentlyContinue)) {
        $pluginDestDir = Join-Path $vencordPath "src\userplugins\goLiveOpen"
        if (Test-Path $pluginDestDir) {
            $wasRunning = Stop-DiscordIfRunning
            Remove-Item -Path $pluginDestDir -Recurse -Force
            Invoke-VencordBuild -VencordPath $vencordPath
            if (-not $LogFile -and $wasRunning) { Launch-Discord -WasRunning:$true }
        }
        return
    }

    $vencordData = Join-Path $UserAppData "Vencord"
    $distDir = Join-Path $vencordData "dist"
    $backupDir = Join-Path $vencordData "dist.goliveopen-bak"
    if (Test-Path $backupDir) {
        $wasRunning = Stop-DiscordIfRunning
        Remove-Item -Path $distDir -Recurse -Force -ErrorAction SilentlyContinue
        Move-Item -Path $backupDir -Destination $distDir -Force
        if (-not $LogFile -and $wasRunning) { Launch-Discord -WasRunning:$true }
    }
}

if (-not $Action) {
    $Action = Show-Menu
    if (-not $Action) { exit 0 }
}

if (-not (Test-IsAdmin)) {
    if ($Action -eq "Install" -and -not $SkipConf -and -not $ConfPath) {
        $ConfPath = Select-ConfFile -InitialDir (Join-Path $env:USERPROFILE "Downloads")
    }
    if (-not $VencordDir) {
        $detected = Find-VencordCheckout -Hint ""
        if ($detected) { $VencordDir = $detected }
    }

    $tempLog = Join-Path $env:TEMP "goliveopen-$([guid]::NewGuid()).log"
    $argList = @(
        "-NoProfile", "-ExecutionPolicy", "Bypass",
        "-File", "`"$PSCommandPath`"",
        "-Action", $Action,
        "-Startup", $Startup,
        "-UserAppData", "`"$UserAppData`"",
        "-UserLocalAppData", "`"$UserLocalAppData`"",
        "-LogFile", "`"$tempLog`""
    )
    if ($ConfPath -and (Test-Path $ConfPath)) {
        $argList += @("-ConfPath", "`"$((Resolve-Path $ConfPath).Path)`"")
    } elseif ($Action -eq "Install") {
        $argList += "-SkipConf"
    }
    if ($VencordDir) { $argList += @("-VencordDir", "`"$VencordDir`"") }
    if ($SkipVencord) { $argList += "-SkipVencord" }

    Write-Host "Solicitando permissao de administrador..." -ForegroundColor Cyan
    $discordWasRunning = [bool](Get-Process -Name "Discord" -ErrorAction SilentlyContinue)
    $elevated = Start-Process -FilePath "powershell.exe" -ArgumentList $argList -Verb RunAs -WindowStyle Hidden -PassThru

    $offset = 0
    while (-not $elevated.HasExited) {
        Flush-LogLines -Path $tempLog -LineOffset ([ref]$offset)
        Start-Sleep -Milliseconds 150
    }
    Flush-LogLines -Path $tempLog -LineOffset ([ref]$offset)
    Remove-Item $tempLog -Force -ErrorAction SilentlyContinue

    if ($elevated.ExitCode -eq 0 -and -not $SkipVencord -and ($Action -eq "Install" -or $Action -eq "Update" -or $discordWasRunning)) {
        $LogFile = ""
        Launch-Discord -WasRunning:$discordWasRunning
    }
    exit $elevated.ExitCode
}

if ([Environment]::Is64BitOperatingSystem -eq $false) {
    throw "Este script exige Windows 64-bit (x64)."
}

try {
    switch ($Action) {
        "Install" {
            New-Item -ItemType Directory -Path $DataDir -Force | Out-Null
            & icacls.exe $DataDir /grant "*S-1-5-32-545:(OI)(CI)M" | Out-Null

            Write-Log "[1/4] Verificando WireSock SDK $WireSockVersion..." "Green"
            $wireSockExe = Install-WireSock

            if (-not $SkipConf -and -not $ConfPath) {
                $ConfPath = Select-ConfFile -InitialDir (Join-Path $env:USERPROFILE "Downloads")
            }

            if ($ConfPath -and (Test-Path $ConfPath)) {
                Write-Log "[2/4] Isolando perfil WireGuard para Discord..." "Green"
                $rawConf = Get-Content -Path $ConfPath -Raw -Encoding UTF8
                $cleanConf = ConvertTo-DiscordWireSockConf -RawText $rawConf
                [System.IO.File]::WriteAllText($TargetConf, $cleanConf, [System.Text.UTF8Encoding]::new($false))

                Write-Log "[3/4] Configurando e iniciando servico '$ServiceName'..." "Green"
                Register-AndStartService -WireSockExe $wireSockExe -ConfFile $TargetConf -StartupMode $Startup
            } else {
                Write-Log "[2/4] Nenhum .conf selecionado agora — insira direto nas configuracoes do plugin no Discord." "Yellow"
                Write-Log "[3/4] O servico sera ativado ao escolher o .conf no plugin." "Yellow"
            }

            if (-not $SkipVencord) {
                Write-Log "[4/4] Configurando plugin GoLiveOpen no Vencord..." "Green"
                $vencordPath = Find-VencordCheckout -Hint $VencordDir
                if ($vencordPath -and (Get-Command pnpm -ErrorAction SilentlyContinue)) {
                    Install-VencordSourcePlugin -VencordPath $vencordPath
                } else {
                    Install-VencordPrebuilt
                }
            }

            Write-Log "" "White"
            Write-Log "Tudo pronto! No Discord, abra Configuracoes do Vencord > Plugins e ative 'GoLiveOpen'." "Green"
        }

        "Update" {
            Write-Log "[1/3] Verificando WireSock SDK $WireSockVersion..." "Green"
            $wireSockExe = Install-WireSock

            if (-not $SkipVencord) {
                Write-Log "[2/3] Atualizando plugin GoLiveOpen no Vencord..." "Green"
                $vencordPath = Find-VencordCheckout -Hint $VencordDir
                if ($vencordPath -and (Get-Command pnpm -ErrorAction SilentlyContinue)) {
                    Install-VencordSourcePlugin -VencordPath $vencordPath -PreferRemote
                } else {
                    Install-VencordPrebuilt
                }
            }

            Write-Log "[3/3] Verificando servico do tunel..." "Green"
            if (Test-Path $TargetConf) {
                Register-AndStartService -WireSockExe $wireSockExe -ConfFile $TargetConf -StartupMode $Startup
            } else {
                Write-Log "  Nenhum .conf salvo em $TargetConf ainda (use o botao no plugin)." "Yellow"
            }

            Write-Log "" "White"
            Write-Log "Atualizacao concluida!" "Green"
        }

        "UninstallPlugin" {
            Write-Log "[1/2] Removendo tunel do GoLiveOpen (mantendo WireSock)..." "Green"
            Stop-AndRemoveTunnelService

            if (-not $SkipVencord) {
                Write-Log "[2/2] Removendo plugin GoLiveOpen do Vencord..." "Green"
                Remove-VencordIntegration
            }
            Write-Log "Plugin e tunel removidos. O WireSock foi mantido no sistema." "Green"
        }

        "UninstallAll" {
            Write-Log "[1/3] Removendo tunel do GoLiveOpen..." "Green"
            Stop-AndRemoveTunnelService

            if (-not $SkipVencord) {
                Write-Log "[2/3] Removendo plugin GoLiveOpen do Vencord..." "Green"
                Remove-VencordIntegration
            }

            Write-Log "[3/3] Desinstalando WireSock Secure Connect..." "Green"
            Uninstall-WireSockPackage
            Write-Log "Desinstalacao completa concluida." "Green"
        }
    }
} catch {
    Write-Log "[ERRO] $($_.Exception.Message)" "Red"
    exit 1
}
