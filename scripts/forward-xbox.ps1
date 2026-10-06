#Requires -Version 5.1
<#
.SYNOPSIS
    Xbox 컨트롤러를 찾아서 WSL2 로 포워딩(USB/IP)합니다.

.DESCRIPTION
    usbipd-win (https://github.com/dorssel/usbipd-win) 을 감싸서:
      1. Windows 에 연결된 Xbox 컨트롤러를 자동으로 찾습니다.
      2. 공유(bind)되지 않았으면 공유합니다.  (관리자 권한 필요)
      3. WSL2 배포판에 연결(attach)합니다.

    usbipd-win 4.0.0 이상에서는 배포판 안에 별도 클라이언트 도구 설치가 필요 없습니다.

.PARAMETER BusId
    이 버스 ID 를 가진 장치만 처리합니다. (예: "1-1")

.PARAMETER Distro
    연결 대상 WSL 배포판 이름. 생략하면 기본 배포판.

.PARAMETER All
    일치하는 모든 Xbox 컨트롤러를 처리합니다. (기본: 첫 번째 하나만)

.PARAMETER Detach
    연결(attach) 대신 해제(detach)합니다.

.PARAMETER AutoAttach
    --auto-attach 로 연결하여 장치가 다시 꽂힐 때 자동 재연결되게 합니다.

.PARAMETER List
    찾기만 하고 공유/연결하지 않습니다.

.PARAMETER Filter
    장치 이름에 대해 적용할 정규식. 기본값: 'xbox'

.EXAMPLE
    .\forward-xbox.ps1
    첫 번째로 찾은 Xbox 컨트롤러를 기본 배포판에 연결

.EXAMPLE
    .\forward-xbox.ps1 -List
    찾기만 하고 종료 (안전한 확인용)

.EXAMPLE
    .\forward-xbox.ps1 -All -AutoAttach
    모든 Xbox 컨트롤러를 자동 재연결 옵션으로 연결

.EXAMPLE
    .\forward-xbox.ps1 -Detach
    연결 해제

.EXAMPLE
    .\forward-xbox.ps1 -BusId 1-1 -Distro Ubuntu-24.04
    특정 버스 ID 를 특정 배포판에 연결
#>
[CmdletBinding()]
param(
    [string] $BusId,
    [string] $Distro,
    [switch] $All,
    [switch] $Detach,
    [switch] $AutoAttach,
    [switch] $List,
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
            } elseif ($rest -cmatch 'Shared\s*$') {
                $state = 'Shared'
                $name  = ($rest -replace '\s*Shared\s*$', '').Trim()
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

function Select-XboxDevices {
    param($Devices, [string]$Filter, [string[]]$VendorIds)
    $result = @()
    foreach ($d in $Devices) {
        $isXboxName = $d.Name -match $Filter
        $isXboxVid  = $VendorIds -contains $d.Vid
        if ($isXboxName -or $isXboxVid) {
            $reason = if ($isXboxName) { 'name' } else { 'vid' }
            $d | Add-Member -NotePropertyName MatchReason -NotePropertyValue $reason -Force
            $result += $d
        }
    }
    return $result
}

function Test-WslRunning {
    try {
        $wslOut = (& wsl.exe --list --verbose 2>&1) -replace "`0", ''
        return @($wslOut | Where-Object { $_ -match 'Running' }).Count -gt 0
    } catch {
        return $false
    }
}

# ---------------- main ----------------

if (-not (Get-Command usbipd -ErrorAction SilentlyContinue)) {
    Write-Bad "usbipd 를 찾을 수 없습니다. 설치: winget install --exact dorssel.usbipd-win"
    exit 1
}

Write-Info "USB 장치 목록을 조회합니다..."
# 주의: 변수명을 $all 로 하면 [switch] $All 파라미터와 (대소문자 무시) 충돌하므로 $usbDevices 사용
$usbDevices = @(Get-UsbipdDevices)

$xbox = @(Select-XboxDevices -Devices $usbDevices -Filter $Filter -VendorIds $XboxVendorIds)

if ($BusId) {
    $xbox = @($xbox | Where-Object { $_.BusId -eq $BusId })
}

if ($xbox.Count -eq 0) {
    Write-Warn "Xbox 컨트롤러를 찾지 못했습니다. (이름 필터: '$Filter')"
    Write-Host "`n현재 연결된 USB 장치 목록:" -ForegroundColor Gray
    ($usbDevices | Format-Table BusId, VidPid, Name, State -AutoSize | Out-String).Trim() | Write-Host
    exit 0
}

Write-Good ("Xbox 컨트롤러 {0}개 발견:" -f $xbox.Count)
($xbox | Format-Table BusId, VidPid, Name, State -AutoSize | Out-String).Trim() | Write-Host

if ($List) {
    Write-Info "-List 옵션: 조회만 하고 종료합니다."
    exit 0
}


# 처리 대상 선택 (BusId 지정 > All > 첫 번째)
$targets = if ($BusId) { $xbox } elseif ($All) { $xbox } else { @($xbox)[0] }

$isAdmin = Test-Admin

# attach 전에는 WSL2 VM 이 살아있어야 함
if (-not $Detach) {
    if (-not (Test-WslRunning)) {
        Write-Warn "실행 중인 WSL 배포판이 없습니다. attach 전에 WSL 터미널을 열어 두세요."
        Write-Warn "(WSL2 경량 VM 이 살아있어야 장치 연결이 유지됩니다.)"
    }
}

foreach ($t in $targets) {
    Write-Host ""
    Write-Info ("대상: BUSID={0}  {1}  [{2}]" -f $t.BusId, $t.Name, $t.State)

    if ($Detach) {
        Write-Info "연결 해제: usbipd detach --busid $($t.BusId)"
        & usbipd detach --busid $t.BusId
        continue
    }

    # 1) 공유(bind) 단계 - 관리자 권한 필요
    if ($t.State -eq 'Not shared') {
        if (-not $isAdmin) {
            Write-Bad "이 장치는 아직 공유되지 않았습니다. 관리자 권한 PowerShell 에서 먼저 실행하세요:"
            Write-Host ("    usbipd bind --busid {0}" -f $t.BusId) -ForegroundColor White
            continue
        }
        Write-Info "공유(bind) 중: usbipd bind --busid $($t.BusId)"
        & usbipd bind --busid $t.BusId
    }

    # 2) 연결(attach) 단계
    if ($t.State -eq 'Attached') {
        Write-Good "이미 WSL 에 연결되어 있습니다. (건너뜀)"
        continue
    }

    $attachArgs = @('attach', '--wsl')
    if ($Distro)     { $attachArgs += @('--distribution', $Distro) }
    if ($AutoAttach) { $attachArgs += '--auto-attach' }
    $attachArgs += @('--busid', $t.BusId)

    Write-Info ("연결(attach) 중: usbipd " + ($attachArgs -join ' '))
    & usbipd @attachArgs

    if ($LASTEXITCODE -eq 0) {
        Write-Good "완료: $($t.BusId) -> WSL.  WSL 안에서 'lsusb' 로 확인하세요."
    } else {
        Write-Bad "attach 실패 (exit $LASTEXITCODE). 관리자 권한 / WSL 실행 여부를 확인하세요."
    }
}

Write-Host ""
Write-Info "끝. WSL 에서 확인: lsusb"
