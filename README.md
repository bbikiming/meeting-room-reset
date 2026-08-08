# Meeting Room Reset

회의실 공용 Windows PC에서 재부팅할 때 지정 사용자의 다음 데이터를 삭제하는 가벼운 PowerShell 도구입니다.

- 바탕화면 파일과 폴더 (`.lnk`, `.url` 바로가기는 유지)
- 다운로드 폴더의 모든 내용
- Chrome, Edge, Brave, Naver Whale, Firefox 사용자 데이터
- 브라우저 로그인, 쿠키, 기록, 캐시, 확장 프로그램, 북마크 등 로컬 브라우저 프로필 전체

별도 프로그램이나 런타임을 설치하지 않고 Windows PowerShell 5.1과 예약 작업만 사용합니다.

> **주의:** 이 도구는 의도적으로 데이터를 영구 삭제합니다. 클라우드, 네트워크 드라이브, USB, 다른 사용자 프로필은 삭제하지 않습니다. 브라우저 동기화로 서버에 저장된 데이터도 삭제하지 않습니다.

## 가장 간단한 설치

1. 회의실에서 평소 사용할 Windows 계정으로 로그인합니다.
2. 시작 메뉴에서 **Windows PowerShell**을 찾아 **관리자 권한으로 실행**합니다.
3. 먼저 삭제 대상을 확인합니다.

```powershell
$installer = "$env:TEMP\Install-MeetingRoomReset.ps1"
Invoke-WebRequest -UseBasicParsing "https://github.com/bbikiming/meeting-room-reset/releases/download/v0.1.0/Install-MeetingRoomReset.ps1" -OutFile $installer
Unblock-File $installer
& $installer -Mode Audit
```

4. 출력된 사용자와 폴더가 맞으면 설치합니다.

```powershell
& $installer -Mode Install
```

화면에 `RESET`을 입력하면 설치됩니다. 다음 Windows 시작부터 자동 정리가 실행됩니다.

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

## 범위와 한계

- Windows가 정상적으로 시작되어 예약 작업이 실행되어야 합니다.
- 브라우저나 파일이 다른 프로세스에 의해 잠겨 있으면 일부 항목 삭제가 실패할 수 있습니다.
- 브라우저 전체 사용자 데이터를 삭제하므로 북마크와 확장 프로그램도 초기화됩니다.
- OneDrive로 리디렉션된 바탕화면은 Windows 사용자 설정에서 경로를 확인해 대상으로 사용합니다. 동기화된 클라우드 원본까지 삭제될 수 있으므로 OneDrive 바탕화면을 사용하는 회사에서는 반드시 `Audit` 결과와 동기화 정책을 확인해야 합니다.
- 이 도구는 UWF나 디스크 이미지 복원처럼 운영체제 전체를 초기화하지 않습니다.
- Windows 정품 인증, 백신, 정보 유출 방지 기능을 대체하지 않습니다.

## 로컬 소스 실행

```powershell
.\install.ps1 -Mode Audit
.\install.ps1 -Mode Install
```
