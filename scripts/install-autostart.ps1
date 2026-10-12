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
    # (a) 지정한 이름으로 찾고,
    # (b) 과거 오타(예: '--Remove') 등으로 등록된 잔여 작업까지 함께 정리하기 위해
    #     이 스크립트(forward-xbox.ps1)를 실행하는 모든 예약 작업을 찾는다.
    $byName   = @(Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue)
    $byScript = @(Get-ScheduledTask -ErrorAction SilentlyContinue | Where-Object {
        $t = $_
        @($t.Actions | Where-Object { $_.Arguments -like '*forward-xbox.ps1*' }).Count -gt 0
    })

    $targets = @{}
    foreach ($t in @($byName) + @($byScript)) {
        $targets["$($t.TaskPath)$($t.TaskName)"] = $t
    }

    if ($targets.Count -eq 0) {
        Write-Warn "예약 작업 '$TaskName' 이(가) 없습니다. (제거할 것 없음)"
        exit 0
    }

    foreach ($key in ($targets.Keys | Sort-Object)) {
        $t = $targets[$key]
        if ($WhatIf) {
            Write-Info "[WhatIf] 예약 작업 '$key' 을(를) 제거합니다."
            continue
        }
        Unregister-ScheduledTask -TaskName $t.TaskName -TaskPath $t.TaskPath -Confirm:$false
        Write-Good "예약 작업 '$key' 을(를) 제거했습니다."
    }
    exit 0
}

# --- 등록 모드 ---
# TaskName 이 '-' 로 시작하면 실수 가능성이 높다 (예: '--Remove' 를 옵션 대신 이름으로 넘김).
if ($TaskName.StartsWith('-')) {
    Write-Bad "예약 작업 이름 '$TaskName' 이(가) 올바르지 않습니다. (이름은 '-' 로 시작할 수 없습니다)"
    Write-Warn "옵션을 잘못 전달하셨나요? 제거하려면 '-Remove' (하이픈 1개)를 사용하세요."
    exit 1
}
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
