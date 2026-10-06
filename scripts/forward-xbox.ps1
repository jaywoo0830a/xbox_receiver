#Requires -Version 5.1
<#
.SYNOPSIS
    usbipd 로 Xbox 컨트롤러를 WSL 로 포워딩합니다.  (list -> bind --force -> attach)

.DESCRIPTION
    다음 3단계 프로세스를 그대로 따릅니다.

        usbipd list                                # (1) BUSID 와 VID:PID 확인
        usbipd bind   --busid <BUSID> --force      # (2) 최초 1회 (재부팅에도 유지)
        usbipd attach --wsl --busid <BUSID>        # (3) 재연결/재부팅 후마다 (뽑았다 꽂으면 다시)

    -BusId 를 생략하면 이름/벤더 ID 로 Xbox 컨트롤러를 자동 탐지합니다.
    이미 Shared 이면 (2)를 건너뛰고, 이미 Attached 이면 (3)도 건너뜁니다.

.PARAMETER BusId
    대상 BUSID (예: "2-3"). 생략하면 Xbox 컨트롤러를 자동 탐지합니다.

.PARAMETER Distro
    attach 대상 WSL 배포판. 생략하면 기본 배포판.

.PARAMETER NoForce
    bind 시 --force 를 사용하지 않습니다. (기본은 --force 사용)

.PARAMETER AutoAttach
    attach 시 --auto-attach 를 추가합니다. (장치가 다시 꽂힐 때 자동 재연결)

.PARAMETER Detach
    attach 대신 detach 합니다.

.PARAMETER Only
    목록만 확인하고 bind/attach 는 하지 않습니다.

.PARAMETER Filter
    자동 탐지 시 장치 이름에 적용할 정규식. 기본값: 'xbox'

.EXAMPLE
    .\forward-xbox.ps1
    Xbox 컨트롤러를 자동 탐지하여 bind --force 후 attach

.EXAMPLE
    .\forward-xbox.ps1 -BusId 2-3
    BUSID 2-3 을 지정하여 처리

.EXAMPLE
    .\forward-xbox.ps1 -Only
    usbipd list 만 확인

.EXAMPLE
    .\forward-xbox.ps1 -Detach -BusId 2-3
    연결 해제

.EXAMPLE
    .\forward-xbox.ps1 -AutoAttach
    자동 재연결 옵션으로 attach
#>
[CmdletBinding()]
param(
    [string] $BusId,
    [string] $Distro,
    [switch] $NoForce,
    [switch] $AutoAttach,
    [switch] $Detach,
    [switch] $Only,
    [string] $Filter = 'xbox'
)

$ErrorActionPreference = 'Stop'
# usbipd 는 출력을 UTF-8 로 내보내므로, 캡처 시 한글 장치명이 깨지지 않도록 인코딩을 맞춘다.
try { [Console]::OutputEncoding = [System.Text.Encoding]::UTF8 } catch {}

# --- Xbox 로 인식할 벤더 ID (이름에 'xbox' 가 없어도 잡아줌) ---
$XboxVendorIds = @('045e', '0f0d', '24c6', '3537', '1430', '2dc8', '2e24')

function Write-Info { param([string]$m) Write-Host "[*] $m" -ForegroundColor Cyan }
function Write-Good { param([string]$m) Write-Host "[+] $m" -ForegroundColor Green }
function Write-Warn { param([string]$m) Write-Host "[!] $m" -ForegroundColor Yellow }
function Write-Bad  { param([string]$m) Write-Host "[-] $m" -ForegroundColor Red }

function Test-Admin {
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    (New-Object Security.Principal.WindowsPrincipal($id)).IsInRole(
        [Security.Principal.WindowsBuiltInRole]::Administrator)
}

# 실제 실행되는 usbipd 명령을 화면에 보여주고 실행
function Invoke-Usbipd {
    param([string[]]$ArgList)
    Write-Host ("    > usbipd " + ($ArgList -join ' ')) -ForegroundColor DarkGray
    & usbipd @ArgList
}

# usbipd list 출력을 파싱해서 장치 객체 배열로 반환
function Get-UsbipdDevices {
    $out = & usbipd list 2>&1
    $devices = @()
    foreach ($raw in $out) {
        $line = ($raw.ToString()) -replace "`0", ''
        if ($line -match '^(?<busid>\d+-\d+)\s+(?<vidpid>[0-9a-fA-F]{4}:[0-9a-fA-F]{4})\s+(?<rest>.+?)\s*$') {
            $busid  = $Matches['busid']
            $vidpid = $Matches['vidpid'].ToLower()
            $rest   = $Matches['rest']

            $state = 'Unknown'
            $name  = $rest.Trim()
            if ($rest -cmatch 'Attached') {
                $state = 'Attached'
                $name  = ($rest -replace '\s*Attached.*$', '').Trim()
            } elseif ($rest -cmatch 'Not shared\s*$') {
                $state = 'Not shared'
                $name  = ($rest -replace '\s*Not shared\s*$', '').Trim()
            } elseif ($rest -cmatch 'Shared( \(forced\))?\s*$') {
                # 'Shared' 또는 'Shared (forced)' 둘 다 공유 상태로 인식
                $state = 'Shared'
                $name  = ($rest -replace '\s*Shared( \(forced\))?\s*$', '').Trim()
            }

            $devices += [pscustomobject]@{
                BusId  = $busid
                VidPid = $vidpid
                Vid    = $vidpid.Split(':')[0]
                Name   = $name
                State  = $state
            }
        }
    }
    return $devices
}

function Test-WslRunning {
    try {
        $wslOut = (& wsl.exe --list --verbose 2>&1) -replace "`0", ''
        return @($wslOut | Where-Object { $_ -match 'Running' }).Count -gt 0
    } catch {
        return $false
    }
}


# ================= main =================

if (-not (Get-Command usbipd -ErrorAction SilentlyContinue)) {
    Write-Bad "usbipd 를 찾을 수 없습니다. 설치: winget install --exact dorssel.usbipd-win"
    exit 1
}

# ---------- (1) 장치 확인 ----------
Write-Info "(1) usbipd list  - BUSID 와 VID:PID 확인"
& usbipd list
Write-Host ""

$usbDevices = @(Get-UsbipdDevices)

# ---------- 대상 BUSID 결정 ----------
$target = $null
if ($BusId) {
    $target = @($usbDevices | Where-Object { $_.BusId -eq $BusId })[0]
    if (-not $target) {
        Write-Warn "BUSID '$BusId' 를 목록에서 찾지 못했습니다. 그대로 진행합니다."
        $target = [pscustomobject]@{ BusId = $BusId; VidPid = ''; Name = '(unknown)'; State = 'Unknown' }
    }
} else {
    $xbox = @($usbDevices | Where-Object { ($_.Name -match $Filter) -or ($XboxVendorIds -contains $_.Vid) })
    if ($xbox.Count -eq 0) {
        Write-Warn "Xbox 컨트롤러를 찾지 못했습니다. -BusId 로 직접 지정하세요. (예: -BusId 2-3)"
        exit 1
    }
    if ($xbox.Count -gt 1) {
        Write-Warn ("Xbox 컨트롤러가 {0}개 있습니다. 첫 번째를 사용합니다. (다른 것을 쓰려면 -BusId)" -f $xbox.Count)
    }
    $target = @($xbox)[0]
}

Write-Good ("대상: BUSID={0}  {1}  [{2}]" -f $target.BusId, $target.Name, $target.State)

if ($Only) {
    Write-Info "-Only 옵션: 조회만 하고 종료합니다."
    exit 0
}

# ---------- detach 모드 ----------
if ($Detach) {
    Write-Info "(3') usbipd detach  - 연결 해제"
    Invoke-Usbipd @('detach', '--busid', $target.BusId)
    exit 0
}

# ---------- (2) 최초 1회 bind (공유) ----------
if ($target.State -eq 'Shared' -or $target.State -eq 'Attached') {
    Write-Good "(2) 이미 공유(Shared)되어 있습니다. bind 를 건너뜁니다."
} else {
    $bindExtra = if ($NoForce) { '' } else { ' --force' }
    if (-not (Test-Admin)) {
        Write-Bad "(2) bind 는 관리자 권한이 필요합니다. 관리자 PowerShell 에서 아래를 실행하세요:"
        Write-Host ("    usbipd bind --busid {0}{1}" -f $target.BusId, $bindExtra) -ForegroundColor White
        exit 1
    }
    Write-Info "(2) usbipd bind  - 최초 1회 (재부팅에도 유지)"
    if ($NoForce) {
        Invoke-Usbipd @('bind', '--busid', $target.BusId)
    } else {
        Invoke-Usbipd @('bind', '--busid', $target.BusId, '--force')
    }
}

# ---------- (3) attach ----------
if ($target.State -eq 'Attached') {
    Write-Good "(3) 이미 WSL 에 연결(Attached)되어 있습니다. 건너뜁니다."
    exit 0
}

if (-not (Test-WslRunning)) {
    Write-Warn "실행 중인 WSL 배포판이 없습니다. attach 전에 WSL 터미널을 열어 두세요."
    Write-Warn "(WSL2 경량 VM 이 살아있어야 연결이 유지됩니다.)"
}

$attachArgs = @('attach', '--wsl')
if ($Distro)     { $attachArgs += @('--distribution', $Distro) }
if ($AutoAttach) { $attachArgs += '--auto-attach' }
$attachArgs += @('--busid', $target.BusId)

Write-Info "(3) usbipd attach  - 재연결/재부팅 후마다 (뽑았다 꽂으면 다시)"
Invoke-Usbipd $attachArgs

if ($LASTEXITCODE -eq 0) {
    Write-Good "완료. WSL 안에서 'lsusb' 로 확인하세요."
} else {
    Write-Bad "attach 실패 (exit $LASTEXITCODE). 관리자 권한 / WSL 실행 여부를 확인하세요."
}
