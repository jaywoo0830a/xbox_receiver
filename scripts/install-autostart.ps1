#Requires -Version 5.1
<#
.SYNOPSIS
    로그온 시 Xbox 컨트롤러를 WSL 로 자동 포워딩하도록 예약 작업을 등록/해제합니다.

.DESCRIPTION
    usbipd 의 'bind'(공유)는 재부팅 후에도 유지되지만, 'attach'(연결)는 유지되지 않습니다.
    (공식 문서: "Attaching devices to a client is non-persistent. You will have to re-attach
     after a reboot, or when the device resets or is physically unplugged/replugged.")

    이 스크립트는 로그온 시 자동으로 forward-xbox.ps1 을 실행하는 예약 작업을 만들어,
    재부팅 후에도 자동으로 다시 연결되도록 합니다.

.PARAMETER TaskName
    예약 작업 이름. 기본값: ForwardXboxToWSL

.PARAMETER Distro
    연결 대상 WSL 배포판. 생략하면 기본 배포판.

.PARAMETER Remove
    예약 작업을 제거합니다.

.PARAMETER WhatIf
    실제로 등록/제거하지 않고 무엇을 할지 출력만 합니다.

.EXAMPLE
    .\install-autostart.ps1 -WhatIf
    등록될 내용을 미리 확인

.EXAMPLE
    .\install-autostart.ps1
    로그온 시 자동 실행되도록 등록

.EXAMPLE
    .\install-autostart.ps1 -Distro Ubuntu-24.04

.EXAMPLE
    .\install-autostart.ps1 -Remove
    자동 실행 해제
#>
[CmdletBinding()]
param(
    [string] $TaskName = 'ForwardXboxToWSL',
    [string] $Distro,
    [switch] $Remove,
    [switch] $WhatIf
)

$ErrorActionPreference = 'Stop'
try { [Console]::OutputEncoding = [System.Text.Encoding]::UTF8 } catch {}

function Write-Info { param([string]$m) Write-Host "[*] $m" -ForegroundColor Cyan }
function Write-Good { param([string]$m) Write-Host "[+] $m" -ForegroundColor Green }
function Write-Warn { param([string]$m) Write-Host "[!] $m" -ForegroundColor Yellow }
function Write-Bad  { param([string]$m) Write-Host "[-] $m" -ForegroundColor Red }

$scriptPath = Join-Path $PSScriptRoot 'forward-xbox.ps1'
if (-not (Test-Path $scriptPath)) {
    Write-Bad "forward-xbox.ps1 를 찾을 수 없습니다: $scriptPath"
    exit 1
}

# --- 제거 모드 ---
if ($Remove) {
    $existing = Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
    if (-not $existing) {
        Write-Warn "예약 작업 '$TaskName' 이(가) 없습니다. (제거할 것 없음)"
        exit 0
    }
    if ($WhatIf) {
        Write-Info "[WhatIf] 예약 작업 '$TaskName' 을(를) 제거합니다."
        exit 0
    }
    Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false
    Write-Good "예약 작업 '$TaskName' 을(를) 제거했습니다."
    exit 0
}

# --- 등록 모드 ---
$pwshCmd = Get-Command pwsh -ErrorAction SilentlyContinue
if ($pwshCmd) {
    $exe = $pwshCmd.Source
} else {
    $exe = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
}

$argList = "-NoProfile -ExecutionPolicy Bypass -File `"$scriptPath`" -AutoAttach"
if ($Distro) { $argList += " -Distro `"$Distro`"" }

$action    = New-ScheduledTaskAction -Execute $exe -Argument $argList
$trigger   = New-ScheduledTaskTrigger -AtLogOn
$settings  = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries `
                -StartWhenAvailable -ExecutionTimeLimit ([TimeSpan]::Zero) -MultipleInstances IgnoreNew
$principal = New-ScheduledTaskPrincipal -UserId ("{0}\{1}" -f $env:USERDOMAIN, $env:USERNAME) -LogonType Interactive

Write-Info "등록할 예약 작업:"
Write-Host ("    이름   : {0}" -f $TaskName)
Write-Host ("    실행   : {0}" -f $exe)
Write-Host ("    인수   : {0}" -f $argList)
Write-Host ("    트리거 : 로그온 시")
Write-Host ("    사용자 : {0}\{1}" -f $env:USERDOMAIN, $env:USERNAME)

if ($WhatIf) {
    Write-Info "[WhatIf] 실제로는 등록하지 않았습니다."
    exit 0
}

Register-ScheduledTask -TaskName $TaskName -Action $action -Trigger $trigger `
    -Settings $settings -Principal $principal `
    -Description "Xbox 컨트롤러를 WSL 로 자동 포워딩 (usbipd attach)" -Force | Out-Null

Write-Good "예약 작업 '$TaskName' 을(를) 등록했습니다. 다음 로그온부터 자동 실행됩니다."
Write-Info "지금 바로 실행해 보려면: Start-ScheduledTask -TaskName '$TaskName'"
Write-Warn "attach 전에 WSL2 VM 이 실행 중이어야 합니다. (WSL 터미널을 열어 두세요)"
