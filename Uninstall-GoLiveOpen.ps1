[CmdletBinding()]
param(
    [switch]$RemoveWireSock
)

$ErrorActionPreference = "Stop"

$ServiceName = "wiresock-client-service"
$DataDir = Join-Path $env:ProgramData "GoLiveOpen"

$identity = [Security.Principal.WindowsIdentity]::GetCurrent()
$principal = [Security.Principal.WindowsPrincipal]$identity
if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    $argList = @("-NoProfile", "-ExecutionPolicy", "Bypass", "-File", "`"$PSCommandPath`"")
    if ($RemoveWireSock) { $argList += "-RemoveWireSock" }
    $elevated = Start-Process -FilePath "powershell.exe" -ArgumentList $argList -Verb RunAs -Wait -PassThru
    exit $elevated.ExitCode
}

$svc = Get-Service -Name $ServiceName -ErrorAction SilentlyContinue
if ($svc) {
    if ($svc.Status -ne "Stopped") {
        Write-Host "Parando serviço $ServiceName..." -ForegroundColor Cyan
        Stop-Service -Name $ServiceName -Force
        $svc.WaitForStatus("Stopped", [TimeSpan]::FromSeconds(20))
    }

    $client = @(
        "C:\Program Files\WireSock Secure Connect\wiresock-client.exe",
        "C:\Program Files\WireSock Secure Connect\sdk\wiresock-client.exe"
    ) | Where-Object { Test-Path $_ } | Select-Object -First 1

    if ($client) {
        & $client uninstall | Out-Null
    } else {
        & sc.exe delete $ServiceName | Out-Null
    }
    Write-Host "Serviço $ServiceName removido." -ForegroundColor Green
} else {
    Write-Host "Serviço $ServiceName não está instalado." -ForegroundColor Yellow
}

if (Test-Path $DataDir) {
    Remove-Item -Path $DataDir -Recurse -Force
    Write-Host "Configuração removida de $DataDir." -ForegroundColor Green
}

if ($RemoveWireSock) {
    Write-Host "Para remover completamente o WireSock Secure Connect, desinstale-o em Configurações > Aplicativos." -ForegroundColor Cyan
}
