# Crypto.psm1 — Phase 2 placeholder. age multi-recipient encryption, DPAPI key
# protection, recipient rotation, and rescue bundles are implemented behind the
# Phase 2 gate (plan §7, §12). Phase 1 must not depend on any of this.

Set-StrictMode -Version Latest

function Test-AcCryptoEnabled { return $false }

function Protect-AcSnapshot {
    throw "Phase 2 기능(암호화 스냅숏)은 아직 활성화되지 않았습니다. Git 핸드오프로 계속 작업하세요."
}

function Unprotect-AcSnapshot {
    throw "Phase 2 기능(암호화 스냅숏)은 아직 활성화되지 않았습니다. Git 핸드오프로 계속 작업하세요."
}

Export-ModuleMember -Function Test-AcCryptoEnabled, Protect-AcSnapshot, Unprotect-AcSnapshot
