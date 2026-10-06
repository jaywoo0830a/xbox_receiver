# scripts

## forward-xbox.ps1 / forward-xbox.cmd

Windows 에 연결된 **Xbox 컨트롤러를 자동으로 찾아 WSL2 로 포워딩(USB/IP)** 하는 스크립트입니다.
내부적으로 [usbipd-win](https://github.com/dorssel/usbipd-win) 을 사용합니다.

> usbipd-win **4.0.0 이상**에서는 WSL 배포판 안에 `usbip` 등 클라이언트 도구를 설치할 필요가 없습니다.

### 동작 순서
1. `usbipd list` 로 장치를 조회하고 Xbox 컨트롤러를 찾습니다.
   - 장치 이름에 `xbox`(기본 필터)가 포함되거나, 알려진 Xbox 벤더 ID(`045e`, `0f0d`, `24c6`, `3537`, `1430`, `2dc8`, `2e24`)이면 매칭됩니다.
2. 공유되지 않았으면 `usbipd bind` 로 공유합니다. **(관리자 권한 필요)**
3. `usbipd attach --wsl` 로 WSL2 에 연결합니다.

### 사용법

```powershell
# 첫 번째 Xbox 컨트롤러를 기본 배포판에 연결
.\forward-xbox.ps1

# 찾기만 하고 연결하지 않음 (안전한 확인용)
.\forward-xbox.ps1 -List

# 모든 Xbox 컨트롤러를 자동 재연결 옵션으로 연결
.\forward-xbox.ps1 -All -AutoAttach

# 연결 해제
.\forward-xbox.ps1 -Detach

# 특정 버스 ID 를 특정 배포판에 연결
.\forward-xbox.ps1 -BusId 1-1 -Distro Ubuntu-24.04
```

`.cmd` 래퍼를 쓰면 실행 정책을 우회하여 더 간단히 실행할 수 있습니다.

```cmd
forward-xbox.cmd -List
forward-xbox.cmd -All -AutoAttach
```

### 옵션
| 옵션 | 설명 |
|------|------|
| `-BusId <id>` | 지정한 버스 ID(예: `1-1`)만 처리 |
| `-Distro <name>` | 연결 대상 WSL 배포판 (기본: 기본 배포판) |
| `-All` | 일치하는 모든 Xbox 컨트롤러 처리 (기본: 첫 번째만) |
| `-Detach` | 연결 대신 해제 |
| `-AutoAttach` | `--auto-attach` 로 연결 (다시 꽂힐 때 자동 재연결) |
| `-List` | 조회만 하고 종료 |
| `-Filter <regex>` | 장치 이름 필터 정규식 (기본: `xbox`) |

### 주의사항
- `usbipd bind` 단계는 **관리자 권한**이 필요합니다. 관리자 권한이 없으면 스크립트가 필요한 명령을 안내합니다.
- attach 전에 **WSL 터미널을 열어 두세요.** WSL2 경량 VM 이 살아있어야 연결이 유지됩니다.
- 장치가 attach 된 동안에는 **Windows 에서 사용할 수 없습니다.** `-Detach` 로 해제하면 다시 Windows 에서 사용할 수 있습니다.
- 연결 후 WSL 안에서 `lsusb` 로 확인할 수 있습니다.

## 재부팅 후에도 유지되나요?

| 단계 | 명령 | 재부팅 후 |
|------|------|-----------|
| 공유(share) | `usbipd bind --busid <id>` | ✅ **유지됨** (persistent) |
| 연결(attach) | `usbipd attach --wsl --busid <id>` | ❌ **풀림** (다시 실행 필요) |

공식 문서(usbipd-win README)에 따르면:
> Sharing a device is persistent; it survives reboots.
> Attaching devices to a client is non-persistent. You will have to re-attach after a reboot,
> or when the device resets or is physically unplugged/replugged.

즉, **공유(bind)는 재부팅 후에도 유지**되지만 **연결(attach)은 재부팅/장치 리셋/재연결 시 풀립니다.**
`--auto-attach` 는 실행 중에 장치가 분리/재연결될 때 자동 재연결을 도와주지만, **Windows 재부팅 후에는 다시 attach 해야 합니다.**

### 자동화: 로그온 시 자동 연결 (`install-autostart.ps1`)

재부팅 후에도 자동으로 다시 연결되게 하려면 로그온 시 실행되는 예약 작업을 등록합니다.

```powershell
# 등록될 내용 미리 보기
.\install-autostart.ps1 -WhatIf

# 로그온 시 자동 실행 등록
.\install-autostart.ps1

# 특정 배포판 지정
.\install-autostart.ps1 -Distro Ubuntu-24.04

# 해제
.\install-autostart.ps1 -Remove
```

등록되는 작업은 로그온 시 `forward-xbox.ps1 -All -AutoAttach` 를 실행합니다.
(스크립트가 버스 ID 를 자동 탐지하므로 재부팅으로 BUSID 가 바뀌어도 동작합니다.)

> 주의: attach 전에 WSL2 VM 이 실행 중이어야 합니다. 로그온 직후 WSL 이 자동 시작되지 않는다면,
> WSL 터미널을 함께 열어 두거나 별도의 시작 프로그램으로 WSL 을 띄워 두세요.
