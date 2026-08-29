# Agent Continuity — 개발 인수인계 문서

> 이 문서는 이 프로젝트의 개발을 이어받는 사람(또는 새 AI 세션)을 위한 것이다.
> 마지막 갱신: 2026-08-29 · 테스트: 61/61 green

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
                       blob 추출(Save-AcRefBlob), glob 매칭, PNG→ICO 변환
core/Lease.psm1        lease 획득/heartbeat/해제/만료 takeover(Invoke-AcLeaseTakeover),
                       keeper 프로세스 관리. env: AC_LEASE_DURATION_MINUTES, AC_LEASE_SKEW_MINUTES
core/Transaction.psm1  완결 transaction 기록/체인 검증(parent hash→generation→projectHead)
core/GitSafety.psm1    읽기 전용 preflight(profile 인지: allowedGlobs 밖 변경은 무시),
                       profile 경계 staging snapshot, projectHead commit 생성·재검증,
                       CAS push+read-back, ff 전용 적용, recovery/quarantine branch
core/SecretScan.psm1   파일명·내용 시크릿 규칙 (canary: AC_SECRET_CANARY)
core/Crypto.psm1       age 다중 수신자 암호화, DPAPI(비Windows는 AES 폴백) 키 보호,
                       수신자 레지스트리(vault meta/recipients ref), rescue 위생 규칙
core/Backup.psm1       암호화 백업/검증/복원(자동 롤백), rescue bundle
core/SessionSync.psm1  Phase 3 오케스트레이션: 버전 allowlist, JSONL 무결성,
                       스냅숏 생성/복원, 충돌·강등 규칙
adapters/              Codex(rollout JSONL, cwd 매칭)·Claude(경로 munge) 어댑터.
                       env 오버라이드: AC_CODEX_HOME/AC_CODEX_VERSION, AC_CLAUDE_*
launcher/Start-Work.ps1   §6.4 순서 그대로. lease 는 keeper 인계 전 실패 시 finally 해제
launcher/Finish-Work.ps1  §6.3 순서 그대로. 어떤 실패도 lease 유지+중단
launcher/Recover-Work.ps1 복구 센터(Takeover, 백업 검증/복원, ReleaseRetry 등)
launcher/Invoke-LeaseKeeper.ps1  숨김 heartbeat keeper
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

## 5. 아직 검증되지 않은 것 (다음 확인 항목)

1. **진짜 두 번째 PC에서 Phase 3 복원**: `세션 복원 완료` → `codex resume <id>` 로
   대화가 실제로 이어지는지 (가상 기기는 Codex 홈을 공유해서 검증 불가).
2. 최신 UI 라운드(모든 프로젝트 병렬 상태, 팝업 검증, 경로 변경)의 실기기 확인 —
   사용자가 피드백 라운드 진행 중.
3. 대형 실제 프로젝트(untracked 수천 개) 승격 후 일상 사용.
4. `AgentContinuity-Setup.exe` 신규 PC(의존성 전무) 시나리오.

## 6. 알려진 제약·이슈

- **이 개발 세션의 git 프록시가 태그 push 를 차단** → 릴리스는 태그 push 대신
  GitHub Actions 의 `Release` 워크플로 **Run workflow(tag 입력)** 로 발행한다.
- vault 의 `locks/*`, `sync/*` branch protection 은 GitHub Free 비공개 저장소라
  미적용(선택 사항 — CAS 자체는 일반 push 의 ff 검사로 보장됨).
- 코드 서명 없음 → exe 실행 시 SmartScreen 경고 (배포 계획 D5).
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

1. **사용자 피드백 라운드 마무리** — §5 항목 확인, 발견 버그 수정.
   사용자가 "배포하자"라고 하면 v0.6.0 릴리스 발행(방법은 §8).
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
4. **D4** — `Update-AgentContinuity`(진행 중 lease 있으면 거부), CHANGELOG, SECURITY.md.
5. 공개 전환 시: README 의 개인 URL 일반화, 위협 모델 문서.
6. Phase 4(데스크톱 앱 대화 목록 통합)는 **공식 API 없이는 착수 금지** (ADR-006).

## 8. 운영 방법 (개발자용 치트시트)

```powershell
# 전체 테스트 (Linux/Windows 공통; age 없으면 Phase2/3 통합은 자동 skip)
pwsh tests/Run-Tests.ps1

# 릴리스 발행: GitHub → Actions → Release → Run workflow → tag 에 vX.Y.Z 입력
#  (테스트 42+개가 release gate; 통과해야 zip/exe/sha256 이 릴리스에 첨부됨)

# 설치 exe 로컬 빌드 (Go 1.23+, linux/mac 에서 교차 컴파일)
installer/build.sh vX.Y.Z

# 가상 두 번째 기기 (한 PC에서 왕복 시험)
$env:AGENT_CONTINUITY_HOME = "C:\Users\<me>\AppData\Local\AgentContinuity-second"
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
