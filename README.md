# Agent Continuity

> One-click, fail-closed cross-device handoff for Codex and Claude workflows.

데스크톱과 노트북 사이에서 Codex·Claude 작업을 안전하게 이어가는 도구입니다.
정상 사용은 **`작업 시작` 1회 클릭 → 작업 → `종료·인계` 1회 클릭**으로 끝납니다.

본문과 코드 주석에서 `§n` 으로 인용되는 절 번호는 이 도구의 설계 계획서
(작성자가 별도 보관하는 문서) 기준입니다. 공개된 요약은
`docs/HANDOFF.md`(개발 인수인계)와 `SECURITY.md`(보안 모델)에 있습니다.
취약점 신고는 `SECURITY.md` 를 참고하세요.

## 설치 (배포판)

**방법 A — 설치 프로그램 (권장)**: GitHub Releases 에서
`AgentContinuity-Setup-vX.Y.Z.exe` 를 받아 더블클릭. 파일 설치, 의존성
(git/PowerShell 7/age) winget 설치 안내, 바로가기 생성, UI 실행까지 한 번에
처리합니다. 이미 설치된 상태에서 다시 실행하면 업데이트 후 실행됩니다.
(코드 서명이 없어 SmartScreen 경고가 뜰 수 있습니다 — "추가 정보 → 실행".
무결성은 함께 배포되는 .sha256 으로 확인할 수 있습니다.)

**방법 B — 스크립트**:

```powershell
# 1) GitHub Releases 에서 AgentContinuity-vX.Y.Z.zip 다운로드 후 압축 해제
# 2) 해제한 폴더에서 (PowerShell 7 이 없어도 실행 가능):
powershell -ExecutionPolicy Bypass -File .\Install-AgentContinuity.ps1
```

설치 스크립트가 의존성(git / PowerShell 7 / age)을 검사해 winget 설치를
제안하고, 파일을 `%LOCALAPPDATA%\Programs\AgentContinuity` 에 배치한 뒤
바탕화면·시작 메뉴에 `Agent Continuity` 바로가기를 만듭니다. 이후 프로젝트
등록은 아래 Setup 마법사로 진행합니다.

PowerShell 모듈로도 쓸 수 있습니다: `Import-Module .\AgentContinuity.psd1`
(모든 `*-Ac*` 함수 노출).

**업데이트**: 새 버전 zip/클론 폴더에서 아래를 실행하면 설치본이 교체됩니다.
진행 중 세션(작업 시작 후 종료·인계 전)이 있으면 안전을 위해 거부합니다.
설정·상태(`%LOCALAPPDATA%\AgentContinuity`)는 건드리지 않습니다.

```powershell
pwsh -ExecutionPolicy Bypass -File .\Update-AgentContinuity.ps1
```

**언어**: 기본 한국어. 영어로 쓰려면 `$env:AC_LANG = 'en'` 을 설정하거나
config.json 에 `"language": "en"` 을 추가하세요.

## 현재 구현 상태 — Phase 3 까지

| 경로 | 상태 |
|---|---|
| Git 핸드오프 (코드 + `CURRENT.md` 인계) | ✅ Phase 1 |
| 원격 단일 작성자 lease (CAS, fast-forward push) | ✅ Phase 1 |
| 완결 transaction (부분 push 무시) | ✅ Phase 1 |
| secret scan / allowlist / 크기 한도 | ✅ Phase 1 |
| age 다중 수신자 암호화 (기기 키 + 오프라인 복구키) | ✅ Phase 2 |
| 개인키 보호 (Windows DPAPI) | ✅ Phase 2 |
| 암호화 rescue bundle / 백업 + 자동 롤백 | ✅ Phase 2 |
| stale lease `안전하게 인계받기` (takeover) | ✅ Phase 2 |
| Claude Remote Control | 공식 기능 사용 (원본 PC가 켜져 있을 때만) |
| CLI 세션 JSONL 스냅숏·복원 (Codex/Claude) | 🧪 Phase 3 (실험, 프로젝트별 opt-in) |

### Phase 3 사용법 (실험 기능)

같은 CLI 대화 세션 자체를 다른 기기에서 이어가는 실험 기능입니다.
Phase 2(암호화)가 켜진 뒤, 프로젝트별로 명시적으로 활성화해야 작동합니다.

```powershell
# 기기마다 1회: CLI 버전 감지 + 샘플 세션 검증 + allowlist 등록 + 활성화
pwsh bootstrap/Enable-AgentContinuityPhase3.ps1 -ProjectName myproject
# (해당 worktree 에서 아직 세션을 만든 적이 없으면 -SkipSampleCheck)

# 끄기 (Git 핸드오프만 사용)
pwsh bootstrap/Enable-AgentContinuityPhase3.ps1 -ProjectName myproject -Disable
```

활성화되면 `종료·인계`가 이번 세션의 JSONL 을 검증(마지막 행 완결성) 후
암호화 번들로 vault `snapshots/` ref 에 push 하고, 완결 transaction 의
`sessionCipherHash` 로 묶습니다. 다른 기기의 `작업 시작`은 그 정확한 번들만
복호화·검증해 로컬 CLI 세션 디렉터리에 복원합니다.

안전 규칙 (§8.3, 자동):
- CLI 버전이 allowlist 에 없으면 복원·스냅숏을 생략하고 Git 핸드오프로 강등
- 로컬 세션이 마지막 적용본보다 새롭거나 알 수 없으면 **덮어쓰지 않고**
  암호화 conflict 번들로 보존 (동일 UUID 자동 병합 0건)
- JSONL 손상(절단) 감지 시 스냅숏 생략 + 손상 사본 암호화 보존
- 복원 전 로컬 세션은 항상 암호화 백업, 복원 후 hash·JSONL 재검사
- 앱 내부 SQLite/DB 는 절대 건드리지 않음 — CLI 세션 파일만 다룸

### Phase 2 사용법

```powershell
# 기기당 1회 (Setup 이후): identity 생성·보호 + 수신자 등록 + 자가 시험
pwsh bootstrap/Enable-AgentContinuityPhase2.ps1

# 오프라인 복구키 생성 (비밀키는 1회만 표시 — USB/종이에 보관, Git 금지)
pwsh bootstrap/Enable-AgentContinuityPhase2.ps1 -GenerateRecoveryKey

# 수신자 목록 / 분실 기기 제거
pwsh bootstrap/Enable-AgentContinuityPhase2.ps1 -ListRecipients
pwsh bootstrap/Enable-AgentContinuityPhase2.ps1 -RemoveRecipient laptop-main

# 원본 PC를 쓸 수 없을 때, 만료된 lease 를 안전하게 인수 (§9.1)
pwsh launcher/Recover-Work.ps1 -ProjectName myproject -Action Takeover -Force

# 암호화 백업 관리
pwsh launcher/Recover-Work.ps1 -ProjectName myproject -Action ListBackups
pwsh launcher/Recover-Work.ps1 -ProjectName myproject -Action VerifyBackup -BackupFile <path.age>
pwsh launcher/Recover-Work.ps1 -ProjectName myproject -Action RestoreBackup -BackupFile <path.age> -Force
```

Phase 2 요구 사항: [age](https://github.com/FiloSottile/age) (`winget install FiloSottile.age`).

보안 노트:
- 개인키는 Windows 에서 DPAPI(CurrentUser)로 보호됩니다. 비 Windows 에서는
  AES 키파일(0600) 폴백을 사용하며 이는 개발·테스트용입니다.
- age CLI 는 identity 를 파일로만 받으므로, 복호화 순간에만 잠금 임시 디렉터리에
  임시 identity 파일을 만들고 사용 직후 덮어쓰기 후 삭제합니다 (§7.2 원칙의
  최소 예외).
- 수신자 제거는 다음 백업부터 적용됩니다. 분실 기기가 이미 받은 과거 암호문은
  회수할 수 없으므로 GitHub 인증 폐기를 병행하세요 (§7.5).

## 요구 사항

- Windows 10/11 (기준 플랫폼) 또는 Linux/macOS (PowerShell 7 이상)
- git 2.30+, GitHub 비공개 저장소 2개
  - 프로젝트 저장소 (코드 + `docs/agent-handoff/`)
  - **vault** 저장소 (`agent-continuity` 전용 비공개 저장소: lease/transaction ref 보관)
- vault 저장소의 `locks/*`, `sync/*` 브랜치에는 force push·삭제를 금지하는
  branch protection 을 적용하세요 (plan §5.4).

## 설치 (기기당 1회)

```powershell
pwsh bootstrap/Setup-AgentContinuity.ps1 `
  -MachineId desktop-main `
  -VaultRemote https://github.com/<you>/agent-continuity-vault.git `
  -ProjectName myproject `
  -ProjectRemote https://github.com/<you>/myproject.git `
  -Agent codex
```

유용한 옵션:

- `-WorktreePath D:\원하는\경로` — 전용 worktree 를 원하는 위치에 만들거나,
  **이미 있는 그 프로젝트의 git 클론을 전용 worktree 로 승격**합니다
  (origin 일치 검증 후 등록; 승격된 폴더의 allowedGlobs 안 변경은 이후
  `종료·인계` 때 자동 커밋된다는 계약을 받아들이는 것입니다).
  프로젝트마다 다른 경로를 지정해 여러 worktree 를 병렬 운영할 수 있습니다.
- `-Agent codex|claude` — `작업 시작`이 전용 worktree 를 작업 폴더로 해당
  CLI 를 자동 실행합니다 (폴더를 직접 찾아갈 필요 없음). 나중에 바꾸려면
  같은 이름으로 Setup 을 다시 실행하면 등록이 갱신됩니다.
- `-AutoStartUi` — Windows 로그인 시 Agent Continuity UI 자동 실행 등록.

수행 내용: 전용 continuity worktree 생성(`§4.2`), 작업 브랜치(`continuity/work`) 준비,
`docs/agent-handoff/` 시드(CURRENT/DECISIONS/OPEN-QUESTIONS), profile 기본값 저장,
Windows 에서는 바탕화면 바로가기 3종 생성, 마지막에 자가진단 실행.

## 편의성 UI (Windows)

바탕화면의 `Agent Continuity` 바로가기(또는 아래 명령)로 창 하나에서 모든
일상 작업을 처리할 수 있습니다:

```powershell
pwsh -ExecutionPolicy Bypass -File ui\AgentContinuity-Ui.ps1
```

- 프로젝트 드롭다운 + 상태 요약(lease 소유/keeper/마지막 generation/dirty)
- 큰 버튼 두 개: **작업 시작** / **종료·인계** — 내부적으로 launcher 스크립트를
  그대로 실행하므로 모든 안전 규칙이 동일하게 적용됩니다
- 실행 로그와 결과 배너(초록=완료, 빨강=중단+원인·보존·권장 행동)
- **복구 센터** 다이얼로그: lease 조회, orphan 보존, 마지막 transaction 복귀,
  백업 검증·복원, 안전하게 인계받기(Takeover)
- **profile 편집** 다이얼로그: allowedGlobs/excludedGlobs/trackedOnly/
  maxDiffSizeBytes 를 검증과 함께 편집 (잘못된 값은 저장되지 않음)
- 트레이 최소화: 인계 진행 중 창을 닫아도 작업은 강제 종료되지 않고 트레이에서
  계속 실행됩니다
- 가상/보조 기기는 `AGENT_CONTINUITY_HOME` 을 설정한 창에서 UI 를 실행하면
  해당 기기로 동작합니다
- **아이콘 커스터마이징**: 원하는 이미지를 `assets\icon.png` 로 저장하면
  UI 창·트레이·바탕화면 바로가기 아이콘에 자동 적용됩니다 (.ico 자동 생성;
  바로가기에 반영하려면 Setup 을 한 번 다시 실행)

## 일상 사용

```powershell
# 작업 시작 (또는 바로가기 클릭)
pwsh launcher/Start-Work.ps1 -ProjectName myproject

# ... 에이전트와 작업, CURRENT.md 를 최신으로 유지 ...

# 종료·인계 (또는 바로가기 클릭)
pwsh launcher/Finish-Work.ps1 -ProjectName myproject
```

- Start: 읽기 전용 사전 검사 → 원격 lease 획득 → **마지막 완결 transaction 의
  정확한 `projectHead`** 로만 fast-forward → keeper 시작 → CURRENT.md 표시 → 에이전트 실행.
- Finish: 에이전트 graceful stop → profile 경계(staging allowlist) → secret scan →
  단일 `projectHead` commit → CAS push → 완결 transaction push → 원격 read-back →
  lease 해제. **어느 단계든 실패하면 lease 를 유지한 채 fail-closed 로 중단합니다.**
- 예외 화면은 항상 원인 · 보존 위치 · 권장 행동 1가지를 보여줍니다 (§3.3).

보조 도구:

```powershell
pwsh launcher/Show-Status.ps1 -ProjectName myproject          # 상태 확인
pwsh launcher/Recover-Work.ps1 -ProjectName myproject -Action LeaseInfo|PreserveOrphan|BackToLastTransaction|ReleaseRetry|Diagnostics
```

## 커스터마이징

- **profile (인계 경계)**: UI 의 `profile 편집` 버튼, 또는
  `%LOCALAPPDATA%\AgentContinuity\config\profiles\<projectId>.json` 직접 편집.
  allowedGlobs 안의 변경만 인계에 포함됩니다.
- **시크릿 규칙 추가**: `%LOCALAPPDATA%\AgentContinuity\config\secret-rules.json`
  (형식: `schemas/secret-rules.schema.json`). 추가 전용 — 기본 규칙은 삭제·대체할
  수 없고, 규칙 파일이 잘못되면 인계가 중단됩니다 (fail-closed).

## 하지 않는 것 (plan §2.4, §17)

- 자동 force push / rebase / merge — 없음
- 동일 session ID 양쪽 변경의 자동 병합 — 없음 (fork 보존)
- 인증 파일·토큰·개인키의 Git 운반 — 금지 (secret scan 이 차단)
- 앱 내부 SQLite/DB 수정 — 금지
- 두 PC 동시 작업 — 원격 lease 가 차단

## 저장소 구조

```text
bootstrap/   Setup / Test / Enable-Phase2 / Enable-Phase3
launcher/    Start-Work, Finish-Work, Show-Status, Recover-Work, Invoke-LeaseKeeper
core/        Common, Lease, Transaction, GitSafety, SecretScan, Crypto, Backup, SessionSync
adapters/    CodexCliAdapter, ClaudeCodeAdapter (세션 파일 탐색·복원 경로)
ui/          AgentContinuity-Ui.ps1 (WPF 편의성 UI, Windows)
i18n/        ko.psd1 / en.psd1 (사용자 노출 문자열 리소스)
schemas/     profile / lease / transaction / secret-rules JSON Schema
templates/   CURRENT.md, DECISIONS.md, OPEN-QUESTIONS.md
installer/   AgentContinuity-Setup.exe 빌드 (Go, payload 내장)
tests/       unit / integration (자체 경량 러너, Pester 불필요)
AgentContinuity.psd1         PowerShell 모듈 manifest
Install-AgentContinuity.ps1  배포판 설치 스크립트
Update-AgentContinuity.ps1   설치본 업데이트 (진행 중 세션 시 거부)
```

## 테스트

```powershell
pwsh tests/Run-Tests.ps1            # 전체 (unit + 두 기기 통합 시나리오)
pwsh tests/Run-Tests.ps1 -Scope unit
```

통합 테스트는 로컬 bare 저장소 2개(vault + project)와 기기별 홈 2개를 만들어
데스크톱↔노트북 왕복 10회, 동시 Start 경쟁, secret canary 차단, dirty 중단,
외부 commit 전진(remote branch advanced) 감지를 검증합니다 (plan §13).
