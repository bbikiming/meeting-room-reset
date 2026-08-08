# Meeting Room Reset

회의실 공용 Windows PC에서 재부팅할 때 지정 사용자의 다음 데이터를 삭제하는 가벼운 PowerShell 도구입니다.

- 바탕화면 파일과 폴더 (`.lnk`, `.url` 바로가기는 유지)
- 다운로드 폴더의 모든 내용
- Chrome, Edge, Brave, Naver Whale, Firefox 사용자 데이터
- 브라우저 로그인, 쿠키, 기록, 캐시, 확장 프로그램, 북마크 등 로컬 브라우저 프로필 전체

별도 프로그램이나 런타임을 설치하지 않고 Windows PowerShell 5.1과 예약 작업만 사용합니다.

> **주의:** 이 도구는 해당 날짜에 생성된 파일만 골라내는 방식이 아닙니다. 재부팅할 때마다 대상 폴더와 브라우저 프로필에 남아 있는 내용을 모두 영구 삭제합니다. 클라우드, 네트워크 드라이브, USB, 다른 사용자 프로필은 삭제하지 않으며 브라우저 동기화 서버의 데이터도 삭제하지 않습니다.

## 가장 간단한 설치

1. 회의실에서 평소 사용할 Windows 계정으로 로그인합니다.
2. 시작 메뉴에서 **Windows PowerShell**을 찾아 **관리자 권한으로 실행**합니다.
3. 먼저 삭제 대상을 확인합니다.

```powershell
$installer = "$env:TEMP\Install-MeetingRoomReset.ps1"
Invoke-WebRequest -UseBasicParsing "https://github.com/bbikiming/meeting-room-reset/releases/download/v0.2.0/Install-MeetingRoomReset.ps1" -OutFile $installer
Unblock-File $installer
& $installer -Mode Audit
```

4. 출력된 사용자와 폴더가 맞으면 설치합니다.

```powershell
& $installer -Mode Install
```

화면에 `RESET`을 입력하면 설치됩니다. 다음 Windows 시작부터 자동 정리가 실행됩니다.

설치 파일은 ZIP 패키지와 SHA-256 체크섬을 GitHub Release에서 받아 검증한 뒤 실행하며, 임시 다운로드 파일은 작업 후 삭제합니다.

무인 설치가 필요한 경우에만 데이터 삭제 동의를 명시합니다.

```powershell
& $installer -Mode Install -AcceptDataLoss
```

다른 Windows 사용자를 지정하려면 다음과 같이 실행합니다.

```powershell
& $installer -Mode Audit -TargetUser "COMPUTER-NAME\meetingroom"
& $installer -Mode Install -TargetUser "COMPUTER-NAME\meetingroom"
```

바탕화면이 OneDrive 내부에 있으면 설치가 중단됩니다. `Audit` 결과를 확인하고 클라우드에서도 파일이 삭제될 수 있음을 승인한 경우에만 다음 옵션을 사용합니다.

```powershell
& $installer -Mode Install -IncludeCloudDesktop
```

## 제거

관리자 PowerShell에서 실행합니다.

```powershell
& "$env:ProgramData\MeetingRoomReset\uninstall.ps1"
```

제거 이후에는 새 데이터가 삭제되지 않습니다. 이미 삭제된 데이터는 복구되지 않습니다.

## 동작 방식

설치 프로그램은 `C:\ProgramData\MeetingRoomReset`에 정리 스크립트와 설정을 복사하고, `MeetingRoomReset-OnStartup` 예약 작업을 등록합니다. 예약 작업은 Windows 시작 시 `SYSTEM` 권한으로 한 번 실행됩니다.

실행 결과에는 삭제된 항목 수와 오류 수만 기록하며 파일명은 기록하지 않습니다. 로그는 `C:\ProgramData\MeetingRoomReset\logs`에 14일 동안 보관됩니다.

Edge와 Chrome에는 브라우저 프로필 로그인 및 동기화를 막는 로컬 컴퓨터 정책도 설정합니다. 설치 전에 존재하던 정책은 백업했다가 제거 시 복구하며, 설치 이후 회사 IT 정책이 변경한 값은 제거 프로그램이 덮어쓰지 않습니다. 회사 도메인 정책이 더 높은 우선순위로 값을 다시 설정할 수 있지만, 재부팅 시 브라우저 로컬 프로필 전체를 삭제하는 기본 동작에는 영향이 없습니다.

## 설치 확인

설치 직후 관리자 PowerShell에서 다음 명령으로 예약 작업을 확인할 수 있습니다.

```powershell
Get-ScheduledTask -TaskName "MeetingRoomReset-OnStartup"
Get-Content "$env:ProgramData\MeetingRoomReset\config.json"
```

실제 정리는 다음 재부팅 때 실행됩니다. 테스트 PC에서만 확인용 파일을 만든 후 재부팅하고, 아래 명령으로 마지막 실행 결과와 로그를 확인합니다. `LastTaskResult`가 `0`이면 정상 완료입니다.

```powershell
Get-ScheduledTaskInfo -TaskName "MeetingRoomReset-OnStartup"
Get-Content "$env:ProgramData\MeetingRoomReset\logs\*.log" -Tail 20
```

## 범위와 한계

- Windows가 정상적으로 시작되어 예약 작업이 실행되어야 합니다.
- 브라우저나 파일이 다른 프로세스에 의해 잠겨 있으면 일부 항목 삭제가 실패할 수 있습니다.
- 삭제 오류가 발생하면 예약 작업이 최대 두 번 다시 시도하며, 남은 항목과 오류 수는 로그에서 확인할 수 있습니다.
- 브라우저 전체 사용자 데이터를 삭제하므로 북마크와 확장 프로그램도 초기화됩니다.
- OneDrive로 리디렉션된 바탕화면은 Windows 사용자 설정에서 경로를 확인해 대상으로 사용합니다. 동기화된 클라우드 원본까지 삭제될 수 있으므로 OneDrive 바탕화면을 사용하는 회사에서는 반드시 `Audit` 결과와 동기화 정책을 확인해야 합니다.
- 이 도구는 UWF나 디스크 이미지 복원처럼 운영체제 전체를 초기화하지 않습니다.
- Windows 정품 인증 여부와 무관하게 PowerShell 및 예약 작업 기능이 정상이라면 동작합니다. 다만 Windows 라이선스 문제를 해결하거나 정품 인증, 백신, 정보 유출 방지 기능을 대체하지는 않습니다.

## 자동 검증 범위

GitHub Actions의 Windows Server 2022 및 2025, Windows PowerShell 5.1 환경에서 다음 항목을 자동 검증합니다.

- 일반 파일·폴더·브라우저 프로필 삭제와 바탕화면 바로가기 보존
- 잠긴 파일 실패 처리와 다음 실행 복구
- 프로필 밖 경로, 위험한 로그 경로, 정션 및 심볼릭 링크 차단
- 존재하지 않는 사용자와 OneDrive 바탕화면의 기본 설치 차단
- 명시적으로 승인한 OneDrive 바탕화면 설치
- `SYSTEM` 예약 작업 실행, 재시도 설정, 재설치, 정책 백업 및 제거

CI에서는 예약 작업을 직접 시작해 전체 흐름을 검사합니다. 실제 PC의 펌웨어·회사 보안 정책·재부팅 환경은 다를 수 있으므로, 전사 배포 전 회의실 PC 한 대에서 위의 재부팅 확인을 한 번 수행해야 합니다.

## 로컬 소스 실행

```powershell
.\install.ps1 -Mode Audit
.\install.ps1 -Mode Install
```
