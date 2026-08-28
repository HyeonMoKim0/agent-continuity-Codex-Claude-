# Codex·Claude 기기간 연속성 구축 계획 v2

## 0. 문서 상태

- 목적: 데스크톱과 노트북 사이에서 Codex·Claude 작업을 안전하게 이어가되, 정상 사용은 `시작` 1회 클릭과 `종료·인계` 1회 클릭으로 끝낸다.
- 범위: 설계 및 구현 계획만 제시한다. 이 문서 승인 전에는 세션 파일, 앱 DB, Git 저장소를 변경하지 않는다.
- 핵심 원칙: 편의성은 정상 경로에 집중하고, 데이터 손실 가능성이 있는 예외는 자동화하지 않고 안전하게 중단한다.
- 기준 플랫폼: Windows, GitHub 비공개 저장소, PowerShell 바로가기.
- 독립 검토: Critic 재검토 완료, 최종 판정 `APPROVED`.

## 1. 결론

권장 구조는 한 가지 기능으로 모든 것을 해결하려 하지 않고 다음 세 경로를 분리하는 것이다.

| 경로 | 해결하는 문제 | 원본 PC 필요 | 기본 사용 여부 |
|---|---|---:|---:|
| Git 핸드오프 | 코드, 결정사항, 검증 결과, 다음 행동을 다른 PC에서 이어감 | 불필요 | 기본 |
| Claude Remote Control | 켜져 있는 원본 PC의 같은 Claude 세션을 다른 기기에서 조작 | 필요 | 선택 |
| 암호화 세션 스냅숏 | 원본 PC가 꺼져 있어도 지원되는 CLI 세션을 실험적으로 복원 | 불필요 | 기본 비활성 |

Codex Import, Codex Cloud, Claude Remote Control을 “로컬 대화 파일의 양방향 동기화”로 취급하지 않는다. 공식 기능이 보장하는 범위 안에서만 사용한다.

MVP는 Git 핸드오프를 완성한다. 원본 JSONL 복원은 MVP가 10회 왕복 시험을 통과한 뒤 별도 기능 플래그로 추가한다.

## 2. 사용자에게 약속하는 연속성의 수준

### 2.1 작업 연속성 — 기본 보장

다른 PC에서 다음 정보가 일치한다.

- 프로젝트 Git 커밋과 브랜치
- 현재 목표와 완료 조건
- 주요 결정과 이유
- 변경 파일과 검증 결과
- 다음에 실행할 명령 또는 작업
- 알려진 위험과 미해결 질문

새 대화를 열더라도 `CURRENT.md`를 자동으로 주입해 첫 행동을 재현할 수 있어야 한다.

### 2.2 같은 실행 중 세션 — 조건부 보장

Claude Remote Control을 사용할 때만 가능하다. 원본 PC가 켜져 있고 Claude Code 세션이 실행 중이어야 한다. 원본 PC가 꺼져 있으면 Git 핸드오프로 전환한다.

### 2.3 동일 로컬 대화 복원 — 실험적 보장

Codex/Claude CLI의 지원 버전과 검증된 JSONL 포맷에 한해서만 시도한다. 앱 내부 SQLite나 비공개 인덱스를 직접 수정하지 않는다. 지원하지 않는 버전에서는 자동으로 Git 핸드오프 모드로 강등한다.

### 2.4 보장하지 않는 것

- Codex와 Claude의 서로 다른 대화를 하나의 공통 UUID로 병합
- 두 PC에서 같은 세션을 동시에 수정한 뒤 자동 병합
- 앱 내부 DB를 수정해 데스크톱 목록을 강제로 재구성
- 공개 저장소에 평문 대화 기록 저장
- 인증 파일, 토큰, OAuth 상태, 개인키의 기기간 복사
- Codex·Claude 데스크톱 앱이나 런처 밖 일반 작업 폴더에서 Phase 1의 1클릭 Start/Finish 보장

## 3. 클릭 예산과 UX 계약

### 3.1 최초 설정

기기당 한 번 `Agent Continuity 설정`을 실행한다. 최초 로그인, GitHub 인증, 키 등록, 프로젝트 선택은 일상 클릭 수에 포함하지 않는다.

설정 마법사는 다음을 한 화면씩 처리한다.

1. GitHub 로그인 상태 검사
2. 기기 이름 등록: 예) `desktop-main`, `laptop-main`
3. 프로젝트 저장소와 전용 연속성 작업 폴더 선택
4. 작업 브랜치와 실행할 에이전트 선택
5. `allowedGlobs`, `excludedGlobs`, `trackedOnly`, `maxDiffSizeBytes` 검토·저장
6. 민감도 정책 선택: 원격 제어 허용/금지, 원본 세션 운반 허용/금지
7. Phase 2 활성화 시 공개 수신자 키 교환 및 복구 키 확인
8. `작업 시작`, `종료·인계`, `상태 확인` 바로가기 생성
9. 설치 자가진단 및 테스트 프로젝트 왕복 검증

### 3.2 정상 일상 흐름

#### 작업 시작 — 1회 클릭

사용자는 프로젝트별 `작업 시작` 바로가기를 누른다.

자동 처리:

1. 등록된 프로젝트, Git remote, 로컬 dirty·미전송 상태, 관리 프로세스를 읽기 전용으로 사전 검사
2. 사전 검사가 모두 통과한 뒤 원격 lease 획득
3. 마지막 완결 transaction 확인
4. transaction이 가리키는 정확한 `projectHead`로 fast-forward
5. `CURRENT.md` 표시 및 선택 에이전트 실행
6. 초록 알림: `작업 준비 완료 · 현재 기기: laptop-main`

목표: 정상 상태에서 30초 이내, 터미널 입력 0회.

#### 종료·인계 — 1회 클릭

사용자는 프로젝트별 `종료·인계` 바로가기를 누른다.

자동 처리:

1. 런처가 관리하는 에이전트에 graceful stop/flush 요청
2. 프로세스 종료와 파일 쓰기 해제 확인
3. 변경 상태, 검증 결과, 다음 행동 수집
4. profile 허용 범위로 코드와 핸드오프 문서의 staging snapshot 구성
5. staging snapshot secret 검사
6. 허용 범위의 변경만 최종 `projectHead` commit으로 생성하고 commit object를 재검사
7. 프로젝트 `projectHead`를 fast-forward/CAS push
8. 선택적 세션 스냅숏 생성
9. 완결 transaction push
10. 원격 read-back 성공 후 lease 해제 및 inactive 전환
11. 초록 알림: `인계 완료 · 다른 기기에서 시작할 수 있음`

graceful stop은 기본 제한 시간 안에 프로세스 종료와 쓰기 핸들 해제를 확인해야 한다. 실패하면 snapshot·commit·push·inactive 전환 없이 중단하고 lease를 유지한다.

목표: 일반 크기 변경에서 60초 이내, 터미널 입력 0회.

### 3.3 예외 UX

예외에서는 “계속”을 기본 버튼으로 두지 않는다. 화면에는 원인, 보존된 백업, 권장 행동 하나를 먼저 보여주고 최대 3개 선택지만 제공한다.

| 상황 | 기본 동작 | 사용자 선택 |
|---|---|---|
| 다른 기기의 활성 lease | 중단 | 상태 확인 / 안전한 인계 요청 / 취소 |
| Finish 누락 추정 · Phase 1 | worktree·recovery branch 보존 후 중단 | 원래 PC에서 Finish / 상태 확인 / 취소 |
| Finish 누락 추정 · Phase 2 이후 | 암호화 rescue 보존 후 중단 | 원래 PC에서 Finish / 안전하게 인계받기 / 취소 |
| secret 탐지 | push 차단 | 파일 열기 / 제외 규칙 검토 / 취소 |
| Git 분기 발생 | 자동 rebase·merge 금지 | 비교 보기 / 복구 브랜치 생성 / 취소 |
| 네트워크 실패 | 로컬 checkpoint 유지 | 다시 시도 / 오프라인 종료 / 취소 |
| 앱 버전 불일치 | 세션 복원 생략 | Git 핸드오프로 시작 / 업데이트 후 재검사 / 취소 |
| 등록 경로 외 변경 | 자동 커밋 금지 | 변경 보기 / 별도 보관 / 취소 |

### 3.4 Phase 1 지원 매트릭스

| 사용 표면 | Start 1클릭 | Finish 1클릭 | 비고 |
|---|---:|---:|---|
| 전용 worktree + 런처가 연 Codex CLI | 보장 | 보장 | 정상 조건 충족 시 |
| 전용 worktree + 런처가 연 Claude Code CLI | 보장 | 보장 | 정상 조건 충족 시 |
| Claude Remote Control 클라이언트 | 해당 없음 | 해당 없음 | 실제 세션이 실행되는 원본 PC의 런처에서 Finish |
| Codex·Claude 데스크톱 앱 | 미보장 | 미보장 | Phase 4 후보, DB 직접 수정 금지 |
| 일반 작업 폴더/외부 터미널 | 미보장 | 미보장 | 변경 감지만 수행, 자동 checkpoint 금지 |

1클릭은 로그인 유효, 네트워크 정상, 충돌·secret 없음, 일반적인 프로젝트 크기, 관리 CLI가 flush 가능한 상태라는 정상 조건에서만 보장한다. 예외에서는 클릭 수보다 보존과 명확한 중단을 우선한다.

## 4. 최소 아키텍처

### 4.1 구성 요소

```text
각 프로젝트 GitHub private repo
├─ 실제 프로젝트 코드
├─ AGENTS.md
├─ CLAUDE.md
└─ docs/agent-handoff/
   ├─ CURRENT.md
   ├─ DECISIONS.md
   └─ OPEN-QUESTIONS.md

agent-continuity private repo
├─ profiles/<project-id>.json
├─ recipients/recipients.txt
├─ transactions/<project-id>/<generation>.json
├─ snapshots/<project-id>/<agent>/<session-id>/<generation>.age
└─ refs only
   ├─ locks/<project-id>
   └─ sync/<project-id>

각 PC 로컬
├─ 전용 continuity worktree
├─ %LOCALAPPDATA%/AgentContinuity/config
├─ %LOCALAPPDATA%/AgentContinuity/backups
└─ DPAPI 보호 개인키
```

### 4.2 왜 프로젝트별 전용 worktree를 쓰는가

일상 Finish를 한 번 클릭으로 만들려면 변경을 자동 checkpoint할 수 있어야 한다. 사용자의 일반 작업 폴더를 자동 커밋하면 관련 없는 변경까지 포함할 위험이 있으므로, 자동화가 관리하는 전용 worktree와 전용 작업 브랜치를 프로젝트별로 만든다.

- 바로가기는 항상 전용 worktree에서 에이전트를 실행한다.
- 자동 커밋은 해당 worktree와 등록된 저장소에만 적용한다.
- 다른 worktree나 저장소 변경에는 손대지 않는다.
- `.gitignore`, 경로 allowlist, secret scan을 모두 통과해야 한다.
- 사용자가 일반 작업 폴더에서 작업한 경우 Finish는 자동 수집하지 않고 안내한다.

프로젝트 profile은 자동 staging 경계를 다음처럼 고정한다.

```json
{
  "allowedGlobs": ["src/**", "docs/agent-handoff/**"],
  "excludedGlobs": ["**/.env*", "**/Library/**", "**/Build/**"],
  "trackedOnly": false,
  "maxDiffSizeBytes": 52428800
}
```

- `allowedGlobs` 안의 tracked 변경과 명시적으로 허용된 untracked 파일만 staging한다.
- `excludedGlobs`, ignored build output, 크기 한도 초과 파일은 자동 staging하지 않는다.
- 허용되지 않은 untracked 파일은 파일명을 보여주되 자동 커밋하지 않는다.
- 이전 실패의 commit·index·작업 잔여물은 정상 branch에 재사용하지 않고 recovery branch로만 보존한다.
- profile 자체 변경은 정상 Finish에 포함하지 않고 설정 변경 절차에서 별도 검증한다.

이 격리가 “한 번 클릭 자동 커밋”과 “관련 없는 변경 보호”를 동시에 만족시키는 핵심 조건이다.

## 5. 원격 단일 작성자 lease

### 5.1 목적

`baton.json` 같은 일반 파일 경고만으로는 두 PC의 동시 시작을 막을 수 없다. 프로젝트별 `locks/<project-id>` 원격 브랜치를 원자적 작업권으로 사용한다.

### 5.2 lease 데이터

```json
{
  "schemaVersion": 1,
  "projectId": "sha256-pseudonym",
  "branch": "continuity/work",
  "machineId": "laptop-main",
  "agent": "codex",
  "sessionId": "opaque-id",
  "generation": 42,
  "leaseNonce": "cryptographic-random-value",
  "state": "active",
  "baseProjectCommit": "<sha>",
  "acquiredAt": "<utc>",
  "heartbeatAt": "<utc>",
  "expiresAt": "<utc>"
}
```

### 5.3 획득 알고리즘

1. 원격 lock ref를 fetch한다.
2. 현재 lease가 같은 `machineId + generation + leaseNonce`이고 keeper·agent가 살아 있으면 새 lease를 만들지 않고 `이미 작업 중`을 표시한 뒤 기존 세션 화면으로 복귀한다.
3. 같은 기기의 lease만 남고 keeper가 없으면 자동 재시작하지 않고 `동일 기기 복구`를 표시한다.
4. 현재 lease가 다른 기기 소유이고 유효하면 중단한다.
5. 현재 lock commit을 부모로 새 lease commit을 만든다.
6. fast-forward push를 시도한다. force push는 사용하지 않는다.
7. push 거부 시 다른 기기가 먼저 획득한 것으로 보고 refetch 후 중단한다.
8. 성공 후에만 프로젝트 파일 갱신과 에이전트 실행을 진행한다.

이 방식은 Git 원격 ref의 fast-forward 검사 자체를 compare-and-swap 경계로 사용한다.

### 5.4 유지·해제·만료

- 런처가 숨김 keeper 프로세스를 실행해 10분마다 heartbeat를 갱신한다.
- 기본 lease 기간은 2시간이며 정상 heartbeat마다 연장한다.
- heartbeat와 release는 현재 원격 lock commit을 부모로 하고 현재 `owner + generation + leaseNonce`가 모두 일치할 때만 가능한 CAS push다.
- takeover는 현재 lease가 만료되고 원격 부모 ref가 그대로일 때만 가능하며, `generation + 1`, 새 owner, 새 cryptographic nonce를 생성한다.
- heartbeat, takeover, release는 push 직전에 원격 lock tip을 다시 확인한다.
- heartbeat와 takeover가 동시에 발생해 부모 ref가 달라지면 push 실패 후 refetch하며, 임의 재시도나 force push를 하지 않는다.
- takeover는 `expiresAt + 5분 허용 시계 오차` 이후에만 선택할 수 있다. 최신성 판단 자체는 서버가 승인한 Git ref 순서를 우선한다.
- Finish의 최종 transaction push가 성공한 뒤 `state: released`인 release commit을 push한다.
- release push가 실패하면 complete transaction 존재 여부와 lease nonce를 다시 읽는다. 같은 owner의 active lease면 release만 CAS 재시도하고, owner가 바뀌었으면 변경하지 않고 충돌 보고한다.
- 앱만 닫거나 PC가 절전되면 lease가 즉시 해제되지 않는다.
- 만료된 lease도 자동 takeover하지 않는다.
- Phase 1에서는 takeover를 제공하지 않는다. 원래 기기에서 Finish하거나 관리자가 원격 상태를 진단해야 한다.
- Phase 2 이후에만 takeover를 활성화한다. takeover 전 현재 PC의 로컬 상태를 암호화 rescue bundle로 보존하고, 사용자가 명시적으로 `안전하게 인계받기`를 선택해야 한다.
- 동일 session ID가 양쪽에서 수정된 흔적이 있으면 자동 병합하지 않는다.
- lock branch에는 force push와 삭제를 금지하는 GitHub branch protection을 적용한다.
- 동일 기기에서 keeper가 사라진 lease를 복구할 때도 현재 `generation + leaseNonce`를 검증하고, 새 작업을 강제 생성하지 않는다. 새 세션이 필요하면 recovery flow에서 기존 상태를 먼저 보존한다.

## 6. 완결 transaction 설계

### 6.1 해결하려는 문제

프로젝트 commit만 push되고 세션/핸드오프가 push되지 않거나 그 반대인 부분 실패가 생길 수 있다. Start는 “가장 최신 파일”이 아니라 “마지막 완결 transaction”만 소비한다.

### 6.2 transaction 레코드

```json
{
  "schemaVersion": 1,
  "projectId": "sha256-pseudonym",
  "generation": 42,
  "parentTransactionHash": "<sha256>",
  "sourceMachineId": "desktop-main",
  "agent": "codex",
  "sourceSessionId": "opaque-id",
  "projectRemote": "owner/repo",
  "projectBranch": "continuity/work",
  "projectHead": "<code-and-handoff-final-git-sha>",
  "expectedProjectParent": "<previous-complete-project-head>",
  "sessionCipherHash": "<sha256-or-null>",
  "sourceAppVersion": "<version>",
  "createdAt": "<utc-informational-only>"
}
```

`createdAt`은 표시용일 뿐 최신 판정에 쓰지 않는다. 최신성은 `parentTransactionHash → generation → projectHead` 연결로 검증한다. 부모가 갈라지면 충돌이다.

두 Git 저장소 사이의 원자적 커밋을 보장한다고 표현하지 않는다. 대신 central complete transaction이 가리키는 `projectHead`와 선택적 session cipher가 모두 존재하고 검증될 때만 한 단위로 적용한다. branch 끝에 더 최신 orphan commit이 있더라도 Start는 자동 적용하지 않는다.

### 6.3 Finish의 commit 순서

1. lease 소유권과 `generation + leaseNonce` 재검증
2. 관리 CLI에 graceful stop/flush를 요청하고 프로세스 종료와 쓰기 핸들 해제를 확인
3. 제한 시간 안에 정지하지 않으면 snapshot·commit 없이 중단하고 lease 유지
4. profile의 `allowedGlobs`, `excludedGlobs`, `trackedOnly`, `maxDiffSizeBytes`로 코드와 핸드오프 staging snapshot 구성
5. worktree와 staging snapshot에 secret scan 및 필수 검증 실행
6. 검사 통과 후 코드와 핸드오프를 포함한 최종 `projectHead` commit 하나 생성
7. `projectHead`의 정확한 첫 부모가 `expectedProjectParent`인지 확인
8. 생성된 commit object를 재검사하고, 실패 시 원격 push 없이 quarantine/recovery branch로 보존
9. `expectedProjectParent`를 기준으로 프로젝트 branch에 fast-forward/CAS push
10. 선택 기능이 켜졌다면 immutable `.age` 스냅숏 생성·검증·push
11. `projectHead`와 session cipher hash를 참조하는 transaction commit 생성
12. `sync/<project-id>`에 fast-forward/CAS push
13. 프로젝트 remote branch tip이 정확히 `projectHead`인지, transaction과 모든 참조 객체가 존재하는지 원격 read-back
14. 같은 lease nonce를 사용해 release CAS push
15. release 성공 후에만 런처 상태를 inactive로 전환

5의 secret 검사 실패는 commit 자체를 만들지 않는다. commit 재검사 실패처럼 이미 로컬 commit이 생긴 경우에는 현재 자동화 branch를 전진시키지 않고 quarantine/recovery branch로 보존한다.

9~12 중 실패하면 lease를 유지하고 `인계 미완료`로 표시한다. 이미 push된 객체는 orphan일 수 있지만 Start가 읽지 않으므로 안전하다. 다음 Finish가 재사용하거나 새 transaction으로 완결한다. 12가 성공하고 14만 실패한 경우에는 `인계 데이터는 완결, lease 해제 대기` 상태로 표시하고 release 전용 재시도를 제공한다.

### 6.4 Start의 적용 순서

1. 등록 경로, remote, local HEAD, dirty·미전송 상태, 관리 프로세스를 읽기 전용 사전 검사
2. 로컬 미전송 상태가 있으면 lease를 잡기 전에 중단한다. Phase 1은 worktree와 recovery branch를 그대로 보존하고, Phase 2 이후에는 추가로 암호화 rescue bundle을 만든다.
3. 사전 검사 통과 후 lease 획득
4. 원격 마지막 complete transaction 읽기
5. transaction 체인, 파일 hash, `projectHead` 존재 및 `projectHead`의 정확한 첫 부모가 `expectedProjectParent`인지 확인
6. 현재 로컬 HEAD가 기록된 마지막 적용 commit에서 `projectHead`까지 fast-forward 가능한지 확인
7. 프로젝트 remote branch tip이 `projectHead`와 정확히 일치하는지 확인. tip이 더 앞서거나 다르면 `remote branch advanced`로 중단
8. branch 최신값이 아니라 transaction의 정확한 `projectHead`까지만 갱신
9. 세션 복원 기능이 켜졌다면 복원 전 암호화 백업 생성
10. 복원 후 hash 및 JSONL 행 완결성 검사
11. keeper를 시작하고 lease 소유권 인계 확인
12. keeper 시작에 실패하면 Start 전체를 실패 처리하고 lease release
13. `CURRENT.md` 표시 후 에이전트 실행

Start 준비 실패 중 lease 획득 후 keeper 인계 전까지는 `finally` 정리로 lease를 해제한다. Start가 성공하면 lease를 keeper에 넘겨 작업 중 계속 유지하며 Start 함수의 `finally`에서는 해제하지 않는다. Finish 성공 시 complete transaction 이후에만 release한다. 원격 소유권이 바뀐 경우에는 자동 해제하지 않고 nonce 충돌을 보고한다.

## 7. 암호화와 키 수명주기

### 7.1 암호화 방식

- 검증된 공개키 파일 암호화 도구 `age`를 사용한다.
- 각 스냅숏은 immutable 파일 하나로 만들고 Git 병합 대상으로 삼지 않는다.
- 각 파일을 데스크톱, 노트북, 오프라인 복구키의 세 수신자에게 암호화한다.
- 평문은 임시 디렉터리에 쓰지 않는 것을 원칙으로 하며, 불가피하면 ACL 제한 후 성공·실패 모두에서 즉시 정리한다.
- Git에는 암호문과 최소한의 무해한 envelope만 저장한다.

### 7.2 개인키 저장

- 기기별 개인키는 `%LOCALAPPDATA%\AgentContinuity\keys\identity.dpapi`에 Windows DPAPI로 보호한다.
- 스크립트는 사용 시 메모리/stdin으로만 복호화하고 평문 개인키 파일을 만들지 않는다.
- `auth.json`, `.credentials.json`, OAuth 상태, GitHub token은 동기화하지 않는다.

### 7.3 공개 메타데이터 최소화

평문 envelope에 허용하는 값:

- 의사 익명화된 project ID
- opaque session ID
- agent 종류
- generation
- parent cipher hash
- cipher hash
- schema/app version

프롬프트, 대화 제목, 실제 로컬 경로, 사용자명, remote URL, 파일 내용은 평문에 두지 않는다.

### 7.4 새 기기 등록

1. 기존 승인 기기에서 `새 기기 추가` 실행
2. 새 기기에서 age 키 생성 및 공개키 QR/파일 표시
3. 기존 기기가 공개키 fingerprint를 확인
4. recipients에 추가하고 새 transaction부터 다중 수신자로 암호화
5. 필요 시 최신 스냅숏 하나만 새 수신자에게 재암호화

과거 전체 이력 재암호화는 기본 동작이 아니다. 필요하면 별도 관리 작업으로 실행한다.

### 7.5 기기 분실·키 교체

- GitHub 인증을 즉시 폐기한다.
- 분실 기기의 수신자 키를 다음 스냅숏부터 제거한다.
- 새 복구키를 등록하고 최신 상태를 재암호화한다.
- 이미 분실 기기에 내려받은 과거 암호문과 개인키의 조합은 원격에서 회수할 수 없음을 명시한다.
- 오프라인 복구키는 암호화 USB 또는 종이 백업 등 Git 밖에 보관한다.

### 7.6 키 분실

복호화 가능한 승인 기기 또는 오프라인 복구키가 하나도 없으면 기존 세션 스냅숏은 복구할 수 없다. 프로젝트 Git 이력과 핸드오프 문서는 그대로 사용할 수 있으므로 작업 연속성은 유지된다.

## 8. 세션 어댑터 안전 범위

### 8.1 지원 정책

- 1차: Codex CLI와 Claude Code CLI의 검증된 버전만 allowlist.
- 2차: 새 버전은 샘플 캡처, schema 검사, 복원 시험 통과 후 허용.
- 데스크톱 앱 목록 복원은 별도 실험으로 유지.
- SQLite, registry, 앱 전용 state DB 직접 수정 금지.

### 8.2 스냅숏 생성

- 앱이 쓰는 중인 파일을 그대로 복사하지 않는다.
- 런처가 관리하는 CLI 프로세스를 정상 정지 또는 flush 가능한 상태로 만든다.
- JSONL 마지막 행이 완전한 JSON인지 검사한다.
- 원본 session ID, 파일별 SHA-256, 행 수, 앱 버전을 암호화 manifest에 기록한다.

### 8.3 복원

- 복원 대상 로컬 파일의 현재 hash와 `lastAppliedHash`를 비교한다.
- 로컬이 더 새롭거나 알 수 없으면 먼저 rescue bundle을 만들고 자동 덮어쓰지 않는다.
- 동일 session ID의 부모 hash가 다르면 conflict bundle 두 개를 보존하고 Git 핸드오프로 시작한다.
- 지원하지 않는 버전이면 원본 파일을 건드리지 않는다.

## 9. Finish 누락과 사후 수정 방지

### 9.1 Finish 누락

다른 PC의 Start는 활성 lease 또는 미완료 transaction을 보면 중단한다. 원래 PC가 사용 가능하면 그 PC에서 `종료·인계`를 누르는 것이 권장 경로다.

원래 PC를 사용할 수 없을 때만 `안전하게 인계받기`를 허용한다.

`안전하게 인계받기`는 Phase 2의 암호화·복구 게이트를 통과한 뒤에만 활성화한다. Phase 1에서는 원래 PC의 Finish가 불가능하면 자동 takeover하지 않고 작업 폴더와 recovery branch를 보존한 채 중단한다.

1. 현재 PC 로컬 상태 rescue bundle 생성
2. 원격 마지막 complete transaction 보존
3. stale lease 정보와 예상 손실 범위 표시
4. 사용자의 명시적 선택 후 새 generation으로 takeover commit
5. 기존 session ID는 fork 처리하고 자동 병합하지 않음

### 9.2 Finish 후 원래 PC에서 다시 수정

- Finish가 끝나면 런처 상태를 `inactive`로 바꾼다.
- 관리 중인 CLI 프로세스는 종료하거나 읽기 전용 완료 화면으로 전환한다.
- 사용자가 다시 작업하려면 같은 PC에서도 `작업 시작`을 눌러 lease를 재획득해야 한다.
- 런처 밖에서 파일이 수정되면 다음 Start/Finish의 hash 검사에서 감지하고 자동 동기화를 차단한다.

OS 수준에서 모든 편집을 완전히 금지할 수 있다고 약속하지는 않는다. 대신 변경 감지와 fail-closed로 데이터 손실을 막는다.

## 10. 백업과 복구

### 10.1 백업 정책

- 위치: `%LOCALAPPDATA%\AgentContinuity\backups\<project-id>\<timestamp>.age`
- 생성 시점: 세션 복원 전, takeover 전, 형식 마이그레이션 전
- 내용: 대상 파일, hash manifest, 앱 버전, source transaction
- 무결성: 생성 직후 복호화 없이 암호문 SHA-256 확인, 샘플 복구 시험에서 전체 복호화 확인
- 자동 삭제 금지. 총량 5GB 또는 설정 한도를 넘으면 정리 필요 알림만 표시한다.

### 10.2 자동 롤백

복원 도중 하나라도 실패하면:

1. 대상 프로세스 정지 확인
2. 변경된 복원 파일 격리
3. 직전 백업 복호화
4. 원래 경로로 원자적 교체
5. hash 재검증
6. 실패 보고서와 백업 경로 표시

롤백도 실패하면 파일을 더 수정하지 않고 수동 복구 모드로 중단한다.

### 10.3 복구 도구

`복구 센터` 바로가기는 다음만 제공한다.

- 마지막 성공 transaction으로 돌아가기
- 특정 로컬 암호화 백업 검증·복원
- orphan checkpoint를 새 복구 브랜치로 보존
- lease 상태 조회
- 진단 보고서 내보내기

기본 화면에서 force push, DB 수정, 백업 삭제는 제공하지 않는다.

## 11. 실패 모드와 처리

| 실패 | 자동 보존 | 자동 진행 | 최종 상태 |
|---|---|---:|---|
| 프로젝트 push 성공, transaction push 실패 | project commit | 금지 | lease 유지, 재시도 가능 |
| session upload 성공, transaction 실패 | immutable 암호문 | 금지 | orphan 무시 |
| lock push 경쟁 | 로컬 무변경 | 금지 | 다른 기기 소유 표시 |
| 네트워크 단절 | 로컬 checkpoint와 rescue | 금지 | pending Finish |
| secret 탐지 | 로컬 변경 | 금지 | push blocked |
| 지원 버전 아님 | 원본 세션 | Git만 진행 | degraded mode |
| 로컬이 원격보다 새로움 | rescue bundle | 금지 | 수동 선택 대기 |
| 키 복호화 실패 | 암호문 원본 | 세션만 금지 | Git 핸드오프 가능 |
| JSONL 손상 | 원본과 백업 | 금지 | 이전 transaction 사용 |
| 분기된 parent hash | 양쪽 immutable 상태 | 금지 | conflict fork |

## 12. 구현 단계와 Go/No-Go 게이트

달력 기준 “3주”처럼 고정하지 않고, 각 단계의 증거가 충족될 때만 다음으로 간다.

### Phase 0 — 정의와 시험 환경

작업:

- “작업 연속성”, “같은 실행 세션”, “동일 로컬 대화 복원” 문구를 UI에 반영
- 테스트용 비공개 저장소와 두 Windows 계정/기기 준비
- Git, gh, Codex, Claude 버전·경로 검사
- 프로젝트 민감도와 Remote Control 정책 등록

Go:

- 양쪽 기기 인증이 독립적으로 완료됨
- credential을 복사하지 않고 clone/fetch/push 성공
- 테스트 저장소 왕복 확인

No-Go:

- 한 기기라도 인증 또는 경로 매핑이 불안정

### Phase 1 — Git 핸드오프 MVP

작업:

- 설정 마법사
- 프로젝트별 전용 worktree/branch
- `CURRENT.md`, `DECISIONS.md`, `OPEN-QUESTIONS.md`
- Start/Finish/Status 바로가기
- fast-forward only, allowlist, secret scan
- remote lease와 complete transaction
- 로컬 checkpoint 및 복구 브랜치
- 지원 범위는 전용 worktree와 런처가 관리하는 Codex CLI/Claude Code CLI로 제한

Go:

- 데스크톱→노트북→데스크톱 10회 연속 성공
- 기준 테스트 저장소(추적 파일 10,000개 이하, 변경 500개 이하, diff 50MB 이하)와 유선 또는 안정적 Wi-Fi 환경에서 Start p95 30초 이하, Finish p95 60초 이하
- dirty, conflict, secret, network failure에서 데이터 손실 0건
- Finish 후 다른 PC가 정확한 project commit과 다음 행동을 열음

No-Go:

- 자동 merge/rebase가 필요함
- 관련 없는 변경이 checkpoint에 포함됨
- partial push를 Start가 완결 상태로 오인함

### Phase 2 — 암호화·복구 기반

작업:

- age 다중 수신자 암호화
- DPAPI 키 보호
- 새 기기 등록, 키 교체, 오프라인 복구키
- 암호화 백업과 자동 롤백
- rescue bundle, stale takeover

Go:

- 개인키 평문 디스크 기록 0건
- 새 기기 등록과 분실 기기 제거 시험 통과
- 복원 실패 주입 후 원본 hash 100% 복구
- 키 분실 시 Git 핸드오프가 계속 작동

No-Go:

- 공개 저장소 또는 평문 로그로 대화/경로/토큰 노출
- 복구키 없이 단일 기기 키에만 의존

### Phase 3 — CLI 세션 스냅숏 실험

작업:

- Codex CLI/Claude Code 버전별 adapter
- immutable session bundle
- parent hash/generation 검증
- Start 전 backup, 복원 후 hash/JSONL 검사
- unsupported version 자동 강등

Go:

- 에이전트별 10회 왕복에서 동일 세션 복원 성공
- 동일 UUID 동시 수정 시험에서 자동 병합 0건
- 앱 실행 중, 중단, 손상, 버전 변경 시험 모두 안전 중단
- Git 핸드오프 fallback 100% 작동

No-Go:

- 앱 DB 수정 없이는 복원이 불가능
- 포맷 판별이 버전별로 안정적이지 않음
- 원본보다 최신인 로컬 세션을 덮어쓸 가능성 존재

### Phase 4 — 선택적 데스크톱 UX 확장

공식 API 또는 안정된 가져오기 경로가 있을 때만 검토한다. 비공개 SQLite 조작이 필요하면 구현하지 않는다.

## 13. 시험 계획

### 13.1 정상 시나리오

1. Desktop Start → 변경 → Finish → Laptop Start
2. Laptop 변경 → Finish → Desktop Start
3. Codex에서 작업 후 Claude 새 세션이 `CURRENT.md`로 인계
4. Claude에서 작업 후 Codex 새 세션이 `CURRENT.md`로 인계
5. Claude Remote Control로 같은 실행 세션 조작 후 정상 Finish
6. 같은 기기에서 Start를 두 번 눌러 새 lease·중복 agent가 생성되지 않고 기존 세션으로 복귀

### 13.2 장애 주입

- Finish 각 단계 직전 네트워크 차단
- 두 PC에서 동시에 Start 클릭
- 같은 PC에서 keeper·agent 생존 중 Start 재클릭
- 같은 PC에서 keeper 소실 후 lease만 남은 상태로 Start
- keeper heartbeat 중단 및 lease 만료
- heartbeat 갱신과 takeover 동시 CAS 경쟁
- transaction 완료 후 release push 실패 및 release 전용 재시도
- heartbeat와 Finish release 동시 경쟁
- 두 저장소에서 project push 성공 후 central transaction push 경합
- Finish를 누르지 않고 다른 PC Start
- 프로젝트 브랜치 양쪽 분기
- secret canary 파일 추가
- allowlist 밖 unrelated untracked 파일 추가
- ignored build output과 `maxDiffSizeBytes` 초과 파일 생성
- 이전 실패의 로컬 commit/index 잔여물 주입
- JSONL 마지막 행 절단
- 잘못된 age 개인키 사용
- 최신 앱 버전을 unsupported로 표시
- 복원 도중 프로세스 강제 종료
- 로컬 경로 변경 및 remote 교체
- transaction 이후 project remote branch를 외부 commit으로 전진
- 시스템 시계 ±12시간 변경

### 13.3 합격 기준

- 정상 왕복 10/10 성공
- 정상 상태 클릭 수: Start 1회, Finish 1회
- 일상 터미널 입력 0회
- 예외 상태 자동 덮어쓰기 0건
- 동일 session 자동 병합 0건
- secret 원격 push 0건
- credential/개인키 Git 추적 0건
- partial transaction 적용 0건
- 롤백 후 원본 hash 불일치 0건
- 오류 화면마다 원인, 보존 위치, 권장 다음 행동 표시

## 14. 위험 등록부

| 위험 | 영향 | 통제 | 잔여 위험 |
|---|---|---|---|
| Finish 누락 | 다른 PC가 오래된 상태 사용 | lease, complete transaction, takeover 시 rescue | 원본 PC의 미푸시 변경은 자동 회수 불가 |
| 동시 작업 | 같은 세션 분기·손실 | 원격 CAS lease, heartbeat, no auto-merge | 런처 밖 편집은 사후 감지 |
| 자동 커밋 오염 | 무관 파일 포함 | 전용 worktree/branch, allowlist, secret scan | 사용자가 전용 폴더 밖에서 한 변경은 수동 인계 |
| 부분 push | 코드·세션 불일치 | final transaction만 적용 | orphan 객체 정리 필요 |
| 키 분실 | 세션 복호화 불가 | 기기별 수신자 + 오프라인 복구키 | 모든 키 분실 시 과거 세션 복구 불가 |
| 기기 도난 | 과거 번들 노출 | DPAPI, GitHub revoke, recipient rotation | 개인키와 Windows 계정 동시 탈취 시 위험 |
| 비공개 포맷 변경 | 복원 실패 | version allowlist, feature flag, Git fallback | 정확한 대화 복원 장기 보장 불가 |
| 메타데이터 노출 | 프로젝트 정보 유출 | private repo, 최소 envelope, pseudonym | Git 접근자가 generation을 볼 수 있음 |
| 시계 오차 | 최신본 오판 | parent hash와 generation 사용 | 표시 시간만 부정확할 수 있음 |
| Remote Control 오해 | 원본 PC 종료 후 사용 불가 | UI에 온라인 조건 명시, Git fallback | 서비스 정책 변화 가능 |

## 15. ADR 요약

### ADR-001: 기본 연속성은 Git 핸드오프

- 결정: 공식 기능과 세션 파일 운반을 분리하고 Git 핸드오프를 기본으로 한다.
- 이유: 원본 PC가 꺼져도 작동하며 가장 안정적이고 검증 가능하다.

### ADR-002: 자동화는 전용 worktree에서만

- 결정: 한 번 클릭 Finish의 자동 checkpoint는 관리 전용 worktree/branch에서만 허용한다.
- 이유: 일반 작업 폴더의 unrelated dirty work를 보호한다.

### ADR-003: 경고 파일 대신 원격 lease

- 결정: `locks/<project-id>` ref의 fast-forward 경쟁으로 단일 작성자를 정한다.
- 이유: 두 PC가 동시에 같은 로컬 baton을 수정하는 경쟁을 막는다.

### ADR-004: 마지막 완결 transaction만 적용

- 결정: Start는 project/session push의 존재만 보지 않고 최종 transaction을 검증한다.
- 이유: 다중 저장소 작업의 부분 성공을 안전하게 무시한다.

### ADR-005: 세션 스냅숏은 immutable + age

- 결정: 암호화 파일은 병합하지 않고 parent hash를 가진 세대별 객체로 저장한다.
- 이유: 암호문 병합 불가능성과 동시 수정 위험을 명시적으로 처리한다.

### ADR-006: 앱 DB 직접 수정 금지

- 결정: 지원 버전의 CLI 파일만 adapter로 다룬다.
- 이유: 비공개 DB 포맷에 의존하면 업데이트 시 데이터 손실 가능성이 크다.

## 16. 구현 산출물

```text
agent-continuity/
├─ bootstrap/
│  ├─ Setup-AgentContinuity.ps1
│  └─ Test-AgentContinuity.ps1
├─ launcher/
│  ├─ Start-Work.ps1
│  ├─ Finish-Work.ps1
│  ├─ Show-Status.ps1
│  └─ Recover-Work.ps1
├─ core/
│  ├─ Lease.psm1
│  ├─ Transaction.psm1
│  ├─ GitSafety.psm1
│  ├─ SecretScan.psm1
│  ├─ Crypto.psm1
│  └─ Backup.psm1
├─ adapters/
│  ├─ CodexCliAdapter.psm1
│  └─ ClaudeCodeAdapter.psm1
├─ schemas/
│  ├─ profile.schema.json
│  ├─ lease.schema.json
│  └─ transaction.schema.json
└─ tests/
   ├─ unit/
   ├─ integration/
   └─ two-device/
```

MVP에서는 `adapters/`의 원본 세션 복원 기능을 비활성 상태로 둔다. Start/Finish와 Git 핸드오프가 독립적으로 완성되어야 한다.

## 17. 최종 운영 규칙

1. 작업은 반드시 프로젝트별 `작업 시작` 바로가기로 연다.
2. 다른 기기로 옮기기 전 `종료·인계`를 한 번 누른다.
3. 초록 `인계 완료` 전에는 다른 기기에서 시작하지 않는다.
4. 빨간 차단은 우회하지 않는다. 자동 force push/rebase/merge는 없다.
5. 인증과 개인키는 Git으로 옮기지 않는다.
6. 동일 session ID의 양쪽 변경은 병합하지 않고 fork로 보존한다.
7. 지원하지 않는 세션 포맷에서는 Git 핸드오프로 계속 작업한다.

## 18. 최종 권고

구축 순서는 `Git 핸드오프 MVP → 원격 lease/transaction 검증 → 암호화·복구 → CLI 세션 실험`으로 고정한다.

사용성 목표는 충분히 현실적이다. 단, “몇 번 딸깍”은 위험한 예외까지 자동 처리한다는 뜻이 아니다. 정상 경로는 Start 1회·Finish 1회로 자동화하고, 충돌·secret·Finish 누락·키 문제에서는 원본을 보존한 채 명확히 멈추는 것이 최종 UX 기준이다.

## 19. 참고 자료

- [Claude Code Remote Control 공식 문서](https://code.claude.com/docs/en/remote-control)
- [Codex Import 공식 문서](https://learn.chatgpt.com/docs/import)
- [Codex 프로젝트·작업 공식 문서](https://learn.chatgpt.com/docs/projects)
- [Codex Cloud 공식 문서](https://learn.chatgpt.com/docs/cloud)
- [Codex 설정 공식 문서](https://learn.chatgpt.com/docs/config-file/config-basic)
- [age 공식 저장소](https://github.com/FiloSottile/age)
- [Git push 공식 문서](https://git-scm.com/docs/git-push)
- [참고 사례: AgentSessionSync](https://cyphen156.tistory.com/508)
