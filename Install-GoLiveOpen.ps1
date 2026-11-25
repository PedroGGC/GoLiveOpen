[CmdletBinding()]
param(
    [string]$ConfPath = "",
    [string]$VencordDir = "",
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
$PluginBaseUrl = "https://raw.githubusercontent.com/PedroGGC/GoLiveOpen/main/plugin/goLiveOpen"

function Test-IsAdmin {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = [Security.Principal.WindowsPrincipal]$identity
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Select-ConfFile {
    param([string]$InitialDir)

    $pickerScript = @"
Add-Type -AssemblyName System.Windows.Forms
`$dlg = New-Object System.Windows.Forms.OpenFileDialog
`$dlg.Title = 'Selecione o arquivo WireGuard (.conf) da ProtonVPN (ou cancele para escolher depois no Discord)'
`$dlg.Filter = 'WireGuard Config (*.conf)|*.conf|Todos os arquivos (*.*)|*.*'
if (Test-Path '$($InitialDir -replace "'", "''")') { `$dlg.InitialDirectory = '$($InitialDir -replace "'", "''")' }
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
        Write-Host "  WireSock encontrado em: $existing" -ForegroundColor DarkGray
        return $existing
    }

    $tempInstaller = Join-Path $env:TEMP "wiresock-sdk-$WireSockVersion.exe"
    Write-Host "  Baixando WireSock SDK $WireSockVersion oficial..." -ForegroundColor Cyan
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    Invoke-WebRequest -Uri $WireSockUrl -OutFile $tempInstaller -UseBasicParsing

    $hash = (Get-FileHash -Path $tempInstaller -Algorithm SHA256).Hash.ToLowerInvariant()
    if ($hash -ne $WireSockSha256) {
        Remove-Item $tempInstaller -Force -ErrorAction SilentlyContinue
        throw "SHA-256 do instalador WireSock não confere (esperado $WireSockSha256, obtido $hash)."
    }

    Write-Host "  Instalando WireSock SDK..." -ForegroundColor Cyan
    $proc = Start-Process -FilePath $tempInstaller -ArgumentList @("/quiet", "/norestart") -Wait -PassThru
    Remove-Item $tempInstaller -Force -ErrorAction SilentlyContinue
    if ($proc.ExitCode -ne 0) {
        throw "Instalador do WireSock retornou código $($proc.ExitCode)."
    }

    $deadline = (Get-Date).AddSeconds(30)
    while ((Get-Date) -lt $deadline) {
        $found = Find-WireSockClient
        if ($found) { return $found }
        Start-Sleep -Milliseconds 500
    }
    throw "WireSock instalado, mas wiresock-client.exe não foi encontrado."
}

function ConvertTo-DiscordWireSockConf {
    param([string]$RawText)

    if ($RawText -notmatch '(?mi)^\s*\[Interface\]\s*$' -or $RawText -notmatch '(?mi)^\s*\[Peer\]\s*$') {
        throw "Arquivo .conf inválido: faltam seções [Interface] ou [Peer]."
    }
    if ($RawText -notmatch '(?mi)^\s*PrivateKey\s*=' -or $RawText -notmatch '(?mi)^\s*PublicKey\s*=' -or $RawText -notmatch '(?mi)^\s*Endpoint\s*=') {
        throw "Arquivo .conf incompleto: PrivateKey, PublicKey ou Endpoint ausentes."
    }

    $lines = [System.Collections.Generic.List[string]]::new()
    foreach ($line in ($RawText -split "\r?\n")) {
        if ($line -match '^\s*(?:#@ws:)?AllowedApps\s*=') { continue }
        if ($line -match '^\s*DNS\s*=') { continue }
        $lines.Add($line)
    }

    # WireSock só aplica AllowedApps dentro da seção [Peer]
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

    $lines.Insert($insertAt, "#@ws:AllowedApps = Discord, Update")
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

if (-not (Test-IsAdmin)) {
    if (-not $SkipConf -and -not $ConfPath) {
        $ConfPath = Select-ConfFile -InitialDir (Join-Path $env:USERPROFILE "Downloads")
    }

    $argList = @(
        "-NoProfile", "-ExecutionPolicy", "Bypass",
        "-File", "`"$PSCommandPath`"",
        "-Startup", $Startup
    )
    if ($ConfPath -and (Test-Path $ConfPath)) {
        $argList += @("-ConfPath", "`"$((Resolve-Path $ConfPath).Path)`"")
    } else {
        $argList += "-SkipConf"
    }
    if ($VencordDir) { $argList += @("-VencordDir", "`"$VencordDir`"") }
    if ($SkipVencord) { $argList += "-SkipVencord" }

    Write-Host "Solicitando permissão de administrador (1 vez só)..." -ForegroundColor Cyan
    $elevated = Start-Process -FilePath "powershell.exe" -ArgumentList $argList -Verb RunAs -Wait -PassThru
    exit $elevated.ExitCode
}

if ([Environment]::Is64BitOperatingSystem -eq $false) {
    throw "Este instalador exige Windows 64-bit (x64)."
}

New-Item -ItemType Directory -Path $DataDir -Force | Out-Null
# Permite que o usuário local atualize o discord.conf direto pelas configurações do Vencord
& icacls.exe $DataDir /grant "*S-1-5-32-545:(OI)(CI)M" | Out-Null

Write-Host "[1/4] Verificando WireSock SDK $WireSockVersion..." -ForegroundColor Green
$wireSockExe = Install-WireSock

if (-not $SkipConf -and -not $ConfPath) {
    $ConfPath = Select-ConfFile -InitialDir (Join-Path $env:USERPROFILE "Downloads")
}

if ($ConfPath -and (Test-Path $ConfPath)) {
    Write-Host "[2/4] Isolando perfil WireGuard para Discord..." -ForegroundColor Green
    $rawConf = Get-Content -Path $ConfPath -Raw -Encoding UTF8
    $cleanConf = ConvertTo-DiscordWireSockConf -RawText $rawConf
    [System.IO.File]::WriteAllText($TargetConf, $cleanConf, [System.Text.UTF8Encoding]::new($false))

    Write-Host "[3/4] Configurando e iniciando serviço '$ServiceName' ($Startup)..." -ForegroundColor Green
    $existingSvc = Get-Service -Name $ServiceName -ErrorAction SilentlyContinue
    if ($existingSvc) {
        if ($existingSvc.Status -ne "Stopped") {
            Stop-Service -Name $ServiceName -Force
            $existingSvc.WaitForStatus("Stopped", [TimeSpan]::FromSeconds(20))
        }
        & $wireSockExe uninstall | Out-Null
    }

    $startTypeFlag = if ($Startup -eq "Automatic") { "2" } else { "3" }
    & $wireSockExe install -start-type $startTypeFlag -config $TargetConf -log-level info -network-lock disabled
    if ($LASTEXITCODE -ne 0) {
        throw "Falha ao registrar o serviço WireSock."
    }
    Set-Service -Name $ServiceName -StartupType $Startup
    Start-Service -Name $ServiceName
    (Get-Service -Name $ServiceName).WaitForStatus("Running", [TimeSpan]::FromSeconds(20))
} else {
    Write-Host "[2/4] Nenhum .conf selecionado agora — você poderá inserir direto nas configurações do plugin no Discord." -ForegroundColor Yellow
    Write-Host "[3/4] Serviço será ativado assim que você escolher o .conf no plugin." -ForegroundColor Yellow
}

if (-not $SkipVencord) {
    Write-Host "[4/4] Instalando plugin GoLiveOpen no Vencord..." -ForegroundColor Green
    $vencordPath = Find-VencordCheckout -Hint $VencordDir
    if ($vencordPath) {
        $pluginDestDir = Join-Path $vencordPath "src\userplugins\goLiveOpen"
        New-Item -ItemType Directory -Path $pluginDestDir -Force | Out-Null

        foreach ($fileName in @("index.tsx", "native.ts")) {
            $localFile = Join-Path $PSScriptRoot "plugin\goLiveOpen\$fileName"
            $destFile = Join-Path $pluginDestDir $fileName
            if (Test-Path $localFile) {
                Copy-Item -Path $localFile -Destination $destFile -Force
            } else {
                Invoke-WebRequest -Uri "$PluginBaseUrl/$fileName" -OutFile $destFile -UseBasicParsing
            }
        }

        if (Get-Command pnpm -ErrorAction SilentlyContinue) {
            Push-Location $vencordPath
            try {
                & pnpm build --dev
            } finally {
                Pop-Location
            }
        } else {
            Write-Host "  Plugin copiado para $pluginDestDir. Rode 'pnpm build --dev' dentro de $vencordPath." -ForegroundColor Yellow
        }
    } else {
        Write-Host "  Checkout do Vencord não encontrado automaticamente. Copie a pasta 'plugin\goLiveOpen' para 'src\userplugins\goLiveOpen' e rode 'pnpm build --dev'." -ForegroundColor Yellow
    }
}

Write-Host ""
Write-Host "Pronto! Abra as configurações do Vencord e ative 'GoLiveOpen'." -ForegroundColor Green
Write-Host "Se o Discord já estiver aberto, pressione Ctrl + R uma vez." -ForegroundColor Cyan
