# Agent Continuity — 개발 인수인계 문서

> 이 문서는 이 프로젝트의 개발을 이어받는 사람(또는 새 AI 세션)을 위한 것이다.
> 마지막 갱신: 2026-08-29 · 테스트: 73/73 green
> 기준 브랜치: `main` (PR #1 병합 완료 — 아래 §0)

---

## 0. 다음 세션 시작 가이드 (여기부터 읽기)

1. **브랜치 상태**: 2026-08-29 세션의 12커밋(프로필 편집 UI, D3 전체, D4,
   README 일반화, 사용성 라운드, CI 수정)이 PR #1 로 **main 에 병합됐다**
   (merge commit `d49a35a`). 이어지는 작업은 최신 main 에서 시작한다.
2. **첫 명령**: `pwsh tests/Run-Tests.ps1` — 73/73 green 이 기준선이다.
   (Linux 는 PowerShell 7 + age 설치 필요; age 없으면 Phase2/3 통합은 자동 skip)
3. **지금 열려 있는 일**은 §7 을 보라. 요약: ① 실기기(Windows) 검증
   라운드(§5) → ② 사용자가 "배포하자" 하면 v0.6.0 릴리스(§8) → ③ UI
   개선 D 항목(§7 백로그).
4. **건드리면 안 되는 규칙**은 §9. 새 사용자 노출 문자열은 반드시
   `i18n/ko.psd1` + `en.psd1` 양쪽에 추가한다(누락은 I18n.Tests 가 잡음).
5. 이번 세션의 상세 변경 내역은 `CHANGELOG.md` [Unreleased] 와 §10 커밋 표.

---

## 1. 프로젝트가 무엇인가

데스크톱↔노트북에서 Codex/Claude 작업을 이어가는 **1인·다기기** 연속성 도구.
정상 경로는 `작업 시작` 1클릭 → 작업 → `종료·인계` 1클릭. 모든 예외는
fail-closed(원본 보존 후 중단)이며, 자동 merge/rebase/force push 는 없다.

핵심 메커니즘 세 가지:

1. **Git 핸드오프**: 코드 + `docs/agent-handoff/CURRENT.md` 를 전용 worktree 에서
   자동 커밋·push. Start 는 "가장 최신 커밋"이 아니라 **마지막 완결 transaction**
   이 가리키는 정확한 `projectHead` 로만 fast-forward.
2. **원격 단일 작성자 lease**: vault 저장소의 `locks/<projectId>` ref 에 대한
   일반(non-force) push 의 fast-forward 검사를 CAS 로 사용. 두 PC 동시 작업 차단.
3. **세션 스냅숏(실험)**: Codex/Claude CLI 의 세션 JSONL 을 age 암호화 번들로
   vault `snapshots/<projectId>` ref 에 push, 다른 기기에서 복원해
   `codex resume <id>` 로 같은 대화를 이어감. 버전 allowlist·충돌 시 무병합.

## 2. 관련 저장소 3개

| 저장소 | 역할 |
|---|---|
| `HyeonMoKim0/agent-continuity-Codex-Claude-` (이 저장소, main) | 도구 코드·테스트·CI. 공개 전환 예정 |
| `HyeonMoKim0/agent-continuity-vault` (비공개 유지) | 자동화 데이터: `locks/*`, `sync/*`, `snapshots/*`, `meta/recipients` ref. `docs` 브랜치에 개인 계획서 보관(연속성 계획 v2, 배포 계획 v1 — **§n 절 인용의 원문**) |
| `HyeonMoKim0/continuity-test` (비공개) | 검증용 테스트 프로젝트 |

## 3. 코드 맵

```text
core/Common.psm1       git 실행 래퍼(Invoke-AcGit, sha 파싱 Get-AcShaFromOutput),
                       config/home, vault ref CAS 커밋(New-AcRefCommit, 바이너리 포함),
                       blob 추출(Save-AcRefBlob), glob 매칭, PNG→ICO 변환,
                       schemaVersion 강제(Assert-AcSchemaVersion),
                       profile 검증·저장(Test-AcProfileValue/Save-AcProfile),
                       i18n(Get-AcText/Get-AcLanguage — AC_LANG > config.language > ko),
                       CURRENT.md 인계 기록 관리(Update-AcHandoffLog, 최근 3개)
core/Lease.psm1        lease 획득/heartbeat/해제/만료 takeover(Invoke-AcLeaseTakeover),
                       keeper 프로세스 관리. env: AC_LEASE_DURATION_MINUTES, AC_LEASE_SKEW_MINUTES
core/Transaction.psm1  완결 transaction 기록/체인 검증(parent hash→generation→projectHead)
core/GitSafety.psm1    읽기 전용 preflight(profile 인지: allowedGlobs 밖 변경은 무시),
                       profile 경계 staging snapshot, projectHead commit 생성·재검증,
                       CAS push+read-back, ff 전용 적용, recovery/quarantine branch
core/SecretScan.psm1   파일명·내용 시크릿 규칙 (canary: AC_SECRET_CANARY).
                       사용자 규칙 config/secret-rules.json (추가 전용, fail-closed)
core/Crypto.psm1       age 다중 수신자 암호화, DPAPI(비Windows는 AES 폴백) 키 보호,
                       수신자 레지스트리(vault meta/recipients ref), rescue 위생 규칙
core/Backup.psm1       암호화 백업/검증/복원(자동 롤백), rescue bundle
core/SessionSync.psm1  Phase 3 오케스트레이션: 버전 allowlist, JSONL 무결성,
                       스냅숏 생성/복원, 충돌·강등 규칙
adapters/              Codex(rollout JSONL, cwd 매칭)·Claude(경로 munge) 어댑터.
                       env 오버라이드: AC_CODEX_HOME/AC_CODEX_VERSION/AC_CODEX_BIN,
                       AC_CLAUDE_* (BIN 은 커스텀 CLI 경로·테스트용)
launcher/Start-Work.ps1   §6.4 순서 그대로. lease 는 keeper 인계 전 실패 시 finally 해제.
                          에이전트 실행 실패는 세션 유지 + 수동 작업 안내
launcher/Finish-Work.ps1  §6.3 순서 그대로. 어떤 실패도 lease 유지+중단.
                          크기·secret 검사는 CURRENT.md 기록 작성보다 앞 (A1)
launcher/Show-Status.ps1  읽기 전용 상태 + "일치/뒤처짐" 해석 라인
launcher/Recover-Work.ps1 복구 센터(Takeover, 백업 검증/복원, ReleaseRetry 등)
launcher/Invoke-LeaseKeeper.ps1  숨김 heartbeat keeper
i18n/ko.psd1, en.psd1  사용자 노출 문자열 전체 (ko 가 기준, en 은 오버레이;
                       키 완전성·{n} 일치는 I18n.Tests 가 CI 에서 강제)
Update-AgentContinuity.ps1  설치본 업데이트 (진행 중 세션·keeper 감지 시 거부)
ui/AgentContinuity-Ui.ps1  WPF 창(프로젝트 추가/경로 변경/시작/인계/복구/트레이)
bootstrap/Setup-AgentContinuity.ps1   기기·프로젝트 등록, -WorktreePath 로 기존 클론 승격
bootstrap/Enable-AgentContinuityPhase2.ps1  암호화 활성화(identity/복구키/수신자)
bootstrap/Enable-AgentContinuityPhase3.ps1  세션 스냅숏 활성화(샘플 검증→allowlist)
installer/             Go 로 만든 AgentContinuity-Setup.exe (payload 내장, GUI, winget 의존성 설치)
tests/                 자체 러너(Pester 불필요). unit + integration(가상 2기기, file:// 원격)
.github/workflows/     ci.yml(ubuntu+windows), release.yml(workflow_dispatch 로 태그·릴리스 생성)
```

로컬 상태 위치: `%LOCALAPPDATA%\AgentContinuity\` (config/profiles/state/backups/logs/keys,
vault.git bare 클론). 테스트·가상 기기는 `AGENT_CONTINUITY_HOME` 으로 홈 전체를 격리.

## 4. 지금까지 완료·검증된 것

- Phase 0~3 전부 구현 + 실기기(사용자 노트북, Windows 11, 한국어 로캘) 검증:
  - Phase 1 왕복(실기기 + 가상 2기기), 동시 Start 차단, dirty 중단·복구
  - Phase 2 수신자 3개(desktop-main/second-machine/recovery), 자가 시험 통과
  - Phase 3: 실제 Codex CLI 0.149.1 세션 샘플 검증 통과, 스냅숏 push 확인
- UI(WPF) + 설치 exe(v0.5.1 릴리스) + CI(ubuntu/windows) + MIT LICENSE
- 실사용 중 잡은 Windows 전용 버그: CRLF 경고로 sha 파싱 오염, CP949 로그 깨짐,
  ANSI 코드 노출, dot-파일 zip 누락 — 모두 수정 + 회귀 테스트 있음
- 2026-08-29 세션(가상 2기기 전 플로우 구동으로 검증, 실기기 미확인):
  - profile 편집 UI(다이얼로그) + core 검증·저장
  - D3 전체: schemaVersion 강제, 시크릿 규칙 외부화, i18n ko/en 전면 이관
  - D4 전체: Update 스크립트, CHANGELOG, SECURITY.md + README 공개용 일반화
  - 사용성 라운드: 중단된 Finish 의 CURRENT.md 무흔적화, 에이전트 실행 실패
    복구 안내, Setup orphan 가드, CURRENT.md 기록 3개 상한, worktree 경로
    표시, Show-Status 해석 라인 등 (§7 백로그 A/B/C 전부)
  - **CI test-windows 최초 통과**: 테스트 하네스가 자식 launcher 출력을
    파이프로 받는 바람에 Start-Work 가 띄운 백그라운드 keeper 가 그 쓰기
    핸들을 상속해 EOF 가 오지 않았다(run 1~9 는 전부 6시간 타임아웃). 파일
    리다이렉션 + WaitForExit 로 교체, 두 잡에 timeout-minutes 추가.
  - **UI 기동 불능 수정**: i18n 이관 때 `Expand-AcXamlText` 가 첫 호출보다
    아래에 정의되어 UI 가 실행 즉시 CommandNotFoundException 으로 죽었다.
    PowerShell 은 함수를 호이스팅하지 않는다. 정의를 위로 옮기고,
    `tests/unit/ScriptSanity.Tests.ps1` 이 이 부류를 정적으로 막는다
    (WPF UI 는 Windows 전용이라 스위트가 실행할 수 없고, CI parse-check 은
    구문만 본다 — 두 겹 모두 통과하는 실패였다).

## 5. 아직 검증되지 않은 것 (다음 확인 항목)

1. **진짜 두 번째 PC에서 Phase 3 복원**: `세션 복원 완료` → `codex resume <id>` 로
   대화가 실제로 이어지는지 (가상 기기는 Codex 홈을 공유해서 검증 불가).
2. **UI 전반의 실기기 재확인 (최우선)**: 기동 불능 버그(§4) 때문에 i18n
   이관 이후의 UI 는 실기기에서 한 번도 뜬 적이 없다. 창이 뜨는지부터 시작해
   모든 프로젝트 병렬 상태, 팝업 검증, 경로 변경, 라벨(%key% 치환) 확인.
3. 대형 실제 프로젝트(untracked 수천 개) 승격 후 일상 사용.
4. `AgentContinuity-Setup.exe` 신규 PC(의존성 전무) 시나리오.
5. 2026-08-29 세션 산출물의 실기기 확인: profile 편집 다이얼로그, `AC_LANG=en`
   에서의 UI 표시(XAML `%key%` 치환), 새 Setup/Start/Status 출력, CURRENT.md
   마커 기록의 실사용 가독성, Update-AgentContinuity 실제 설치본 대상 실행.
   (UI 항목은 4~5행 기준으로 §5-2 와 같은 라운드에서 함께 본다.)

## 6. 알려진 제약·이슈

- **이 개발 세션의 git 프록시가 태그 push 를 차단** → 릴리스는 태그 push 대신
  GitHub Actions 의 `Release` 워크플로 **Run workflow(tag 입력)** 로 발행한다.
- vault 의 `locks/*`, `sync/*` branch protection 은 GitHub Free 비공개 저장소라
  미적용(선택 사항 — CAS 자체는 일반 push 의 ff 검사로 보장됨).
- 코드 서명 없음 → exe 실행 시 SmartScreen 경고 (배포 계획 D5).
- 릴리스 태그와 `AgentContinuity.psd1` ModuleVersion 의 불일치는 이제 Release
  워크플로가 테스트 전에 막는다 (현재 manifest 0.6.0 = 다음 태그 v0.6.0).
- profile 편집은 UI 의 [profile 편집] 버튼 또는
  `%LOCALAPPDATA%\AgentContinuity\config\profiles\<projectId>.json` 직접 편집.
  UI 편집 대화상자는 아직 실기기 미확인.
- i18n: 모든 사용자 노출 문자열이 `i18n/ko.psd1`(기준)·`en.psd1` 리소스 기반.
  기본 ko, `AC_LANG=en` 또는 config `language` 로 en. UI XAML 라벨은 `%key%`
  자리표시자를 `Expand-AcXamlText` 가 전처리. Install 스크립트는 PS 5.1
  호환을 위해 자체 로더(`Get-InstallText`) 사용.
- age CLI 특성상 복호화 순간 잠금 임시 폴더에 identity 파일이 생겼다 즉시
  파쇄됨 (§7.2 원칙의 최소 예외, README 보안 노트에 문서화).

## 7. 다음에 할 일 (우선순위 순)

1. **사용자 실기기 검증 라운드** — §5 항목 확인, 발견 버그 수정. UI 는
   기동 불능 수정 직후라 §5-2 를 먼저 본다. 사용자가 "배포하자"라고 하면
   v0.6.0 릴리스 발행(방법은 §8).
2. ~~profile 편집 UI~~ — **완료**: 메인 창 [profile 편집] 버튼 →
   allowedGlobs/excludedGlobs/trackedOnly/maxDiffSizeBytes 편집 대화상자.
   검증·저장은 `core/Common.psm1` 의 `Test-AcProfileValue`/`Save-AcProfile`
   (fail-closed, 단위 테스트 있음). profile 은 로컬 전용이라 §4.2 규칙
   ("Finish 에 포함하지 않는다") 그대로 유지. 실기기 확인만 남음.
3. **배포 계획 D3 — 대부분 완료**:
   - ~~schemaVersion 강제 검증~~: `Assert-AcSchemaVersion` 이 config/lease/
     transaction/backup manifest 읽기에 적용, 세션 복원은 `unsupported-schema` 로 강등.
   - ~~시크릿 규칙 외부화~~: `<home>/config/secret-rules.json` (추가 전용,
     기본 규칙 삭제·대체 불가, 잘못된 파일은 스캔 중단). `schemas/secret-rules.schema.json` 참조.
   - ~~i18n~~: 전체 이관 완료 — 런처·예외 화면·core 메시지/Reason·bootstrap·
     installer·WPF UI(XAML 포함)·keeper 로그. en 키 완전성·자리표시자 일치는
     I18n.Tests 가 강제. **UI 의 en 표시는 실기기(Windows)에서 미확인.**
4. ~~D4~~ — **완료**: `Update-AgentContinuity.ps1`(진행 중 세션·keeper 감지 시
   거부, 설치본 아닌 폴더 거부, config/state 무접촉, 단위 테스트 4개),
   `CHANGELOG.md`, `SECURITY.md`. ~~ModuleVersion 불일치~~ — 해소: manifest
   를 0.6.0 으로 올리고, Release 워크플로가 태그와의 일치를 강제한다.
5. ~~공개 전환 시 README 일반화~~ — 완료 (개인 문서 언급 제거, 구조 최신화,
   Update/i18n/커스터마이징 섹션 추가). 위협 모델 요약은 SECURITY.md.
6. Phase 4(데스크톱 앱 대화 목록 통합)는 **공식 API 없이는 착수 금지** (ADR-006).

### 개선 백로그 — 2026-08-29 사용성 점검 (전 CLI 플로우 실제 구동으로 확인)

**A1~A4, B5~B9, C10 완료** (커밋 참조):
- A1 중단된 Finish 의 CURRENT.md 오염 → 크기·secret 검사를 기록 작성 앞으로.
- A2 에이전트 실행 실패 → 세션 유지 + 수동 작업 안내 (AC_CODEX_BIN /
  AC_CLAUDE_BIN 오버라이드도 추가 — 커스텀 CLI 경로 지원).
- A3 기준 브랜치 불명 + 커밋 있는 원격 → orphan 생성 대신 중단.
- A4 미등록 프로젝트 → 등록 목록과 함께 안내.
- B5 Setup·Start 가 worktree 경로(+기본 allowedGlobs) 표시.
- B6 CURRENT.md 인계 기록: 마커 관리 섹션, 최근 3개 유지, 재시도 멱등,
  구버전 무한 append 는 다음 Finish 때 자동 정리 (Update-AcHandoffLog).
- B7 Show-Status: released → 유휴 표기, "일치/뒤처짐" 해석 한 줄.
- B8 setup 완료 메시지에서 64자 projectId 제거(로그로 이동).
- B9 Setup 재실행 시 agent 변경 표시. C10 죽은 -NonInteractive 제거.

**D. 실기기(Windows)에서만 확인 가능 — UI**
- 실행 중 상태 패널 자동 갱신 없음(완료 후에만), 중단 시 원인·권장 행동이
  로그에 묻힘(배너로 승격 검토), en 표시 확인.

점검에서 정상 확인된 것: 2기기 왕복, 동시 Start 차단, secret 차단→수정→재시도,
사용자 시크릿 규칙 e2e, Phase 2 활성화 흐름, Setup 재실행 agent 변경,
에이전트 실행 실패 후 Finish 복구, Start/Finish 로컬 1.2~1.5초.

## 8. 운영 방법 (개발자용 치트시트)

```powershell
# 전체 테스트 (Linux/Windows 공통; age 없으면 Phase2/3 통합은 자동 skip)
pwsh tests/Run-Tests.ps1

# 릴리스 발행: GitHub → Actions → Release → Run workflow → tag 에 vX.Y.Z 입력
#  (release gate: manifest 버전 == 태그 검사 → 전체 테스트 73개 → zip/exe/sha256)
#  manifest 가 태그와 다르면 테스트 전에 실패하므로 psd1 을 먼저 올릴 것

# 설치 exe 로컬 빌드 (Go 1.23+, linux/mac 에서 교차 컴파일)
installer/build.sh vX.Y.Z

# 가상 두 번째 기기 (한 PC에서 왕복 시험)
$env:AGENT_CONTINUITY_HOME = "C:\Users\<me>\AppData\Local\AgentContinuity-second"

# 설치본 업데이트 (새 버전 zip/클론 폴더에서 실행; 진행 중 세션 있으면 거부)
pwsh -ExecutionPolicy Bypass -File .\Update-AgentContinuity.ps1

# 영어 UI/출력 확인
$env:AC_LANG = 'en'   # 또는 config.json 에 "language": "en"

# 커스텀 에이전트 CLI 경로 (미설치 시뮬레이션·비표준 설치 경로)
$env:AC_CODEX_BIN = 'D:\tools\codex.exe'   # AC_CLAUDE_BIN 도 동일
```

## 9. 건드리면 안 되는 불변 규칙 (계획서 §17, ADR)

- force push / 자동 rebase / 자동 merge 금지. lease·sync·프로젝트 push 는 전부
  일반 push(CAS) — 이 성질이 동시성 안전의 근거다.
- Start 는 완결 transaction 만 소비한다. branch tip 이 더 앞서면 적용이 아니라
  **중단**이 정답이다 (`remote branch advanced`).
- 동일 세션 UUID 양쪽 수정은 병합하지 않고 fork 보존한다.
- 인증 파일(auth.json, 토큰, 개인키)은 어떤 경로로도 Git 에 싣지 않는다.
- 앱 내부 SQLite/DB 를 직접 수정하지 않는다.
- 예외 화면은 항상 "원인 / 보존된 것 / 권장 행동 1개"를 보여준다.
- 실패 시 새 코드가 지켜야 할 기본값: **덮어쓰지 말고, 보존하고, 멈춰라.**

## 10. 히스토리 요약 (커밋 단위)

| 커밋 | 내용 |
|---|---|
| `708d80b` | Phase 1 MVP (lease/transaction/secret scan/런처/테스트) |
| `66a0036` | Phase 2 (age·DPAPI·rescue·rollback·takeover) |
| `e5fe92e` | Windows CRLF sha 파싱 수정 |
| `2a3fced` | Phase 3 (세션 스냅숏·어댑터·강등 규칙) |
| `0240046`~`e1601b6` | WPF UI + CP949 로그 수정 |
| `823239a` | -WorktreePath 승격, -AutoStartUi, 아이콘 파이프라인 |
| `f59fb42`~`cd4b106` | 배포 계획, 모듈 manifest, Install 스크립트, CI/Release |
| `a23ab10`~`500fbe4` | Setup exe (payload 내장, 경로 선택), MIT |
| `cb9833f` | UI 프로젝트 추가/경로 변경 (D2) |
| `68527d3` | dirty 클론 승격 허용, profile 인지 preflight, 병렬 상태 뷰 |
| `09f79e1` | 이 인수인계 문서 최초 작성 |
| `2e049ba` | profile 편집 UI + core 검증·저장 (fail-closed) |
| `00d5954` | schemaVersion 읽기 강제 검증 (D3) |
| `ca9e65c` | 시크릿 규칙 secret-rules.json 외부화 (D3) |
| `e43568b`~`ddccf62` | i18n ko/en 전면 이관 — 런처→core→bootstrap→UI (D3) |
| `e25eb81` | Update-AgentContinuity + CHANGELOG + SECURITY.md (D4) |
| `d46db47` | README 공개용 일반화 + 사용성 점검 백로그 |
| `461f595` | 사용성 라운드: A1~A4 fail-closed 수정 + B5~B9/C10 마찰 제거 |
| `764cf6f`~`99e97aa` | CI 수정: 에이전트 부재 판정, test-windows hang, Phase3 픽스처 |
| `d49a35a` | PR #1 main 병합 (위 12커밋) |
| (이 세션) | UI 기동 불능 수정 + ScriptSanity 회귀 테스트, manifest 0.6.0 + 릴리스 게이트 |
