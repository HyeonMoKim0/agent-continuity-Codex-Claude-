// AgentContinuity-Setup.exe — 설치와 실행을 겸하는 단일 실행 파일 (배포 계획 D1 확장).
//
// 동작:
//  1. 처음 실행: 설치 확인 → 내장 payload 를 %LOCALAPPDATA%\Programs\AgentContinuity 에 풀고
//     의존성(git / PowerShell 7 / age)을 winget 으로 설치 안내 → 바로가기 생성 → UI 실행
//  2. 이후 실행(바로가기 포함): payload 를 최신으로 덮어쓴 뒤 곧바로 UI 실행 (자가 복구/업데이트)
//
// GUI 서브시스템(-H windowsgui)으로 빌드되어 콘솔 창이 뜨지 않으며, 안내는 MessageBox 로 한다.
// 관리자 권한 불필요(asInvoker), 파일은 모두 사용자 프로필 아래에만 쓴다.
//
// 항상 GOOS=windows 로만 빌드한다.
package main

import (
	"archive/zip"
	"bytes"
	_ "embed"
	"fmt"
	"io"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"syscall"
	"unsafe"
)

//go:embed payload.zip
var payload []byte

var version = "dev" // -ldflags "-X main.version=vX.Y.Z"

const appName = "Agent Continuity"

// ---------------------------------------------------------------------------
// MessageBox helpers (user32, 외부 의존성 없음)
// ---------------------------------------------------------------------------

var (
	user32     = syscall.NewLazyDLL("user32.dll")
	messageBox = user32.NewProc("MessageBoxW")
)

const (
	mbOK       = 0x0
	mbYesNo    = 0x4
	mbIconInfo = 0x40
	mbIconErr  = 0x10
	mbIconQ    = 0x20
	idYes      = 6
)

func msgBox(text string, flags uintptr) int {
	t, _ := syscall.UTF16PtrFromString(text)
	c, _ := syscall.UTF16PtrFromString(appName + " " + version)
	r, _, _ := messageBox.Call(0, uintptr(unsafe.Pointer(t)), uintptr(unsafe.Pointer(c)), flags)
	return int(r)
}

func info(text string)      { msgBox(text, mbOK|mbIconInfo) }
func fail(text string)      { msgBox(text, mbOK|mbIconErr) }
func askYes(text string) bool { return msgBox(text, mbYesNo|mbIconQ) == idYes }

// ---------------------------------------------------------------------------

func installRoot() string {
	return filepath.Join(os.Getenv("LOCALAPPDATA"), "Programs", "AgentContinuity")
}

func exists(p string) bool { _, err := os.Stat(p); return err == nil }

func extractPayload(dst string) error {
	zr, err := zip.NewReader(bytes.NewReader(payload), int64(len(payload)))
	if err != nil {
		return err
	}
	for _, f := range zr.File {
		name := filepath.Clean(f.Name)
		if strings.HasPrefix(name, "..") {
			continue
		}
		out := filepath.Join(dst, name)
		if f.FileInfo().IsDir() {
			if err := os.MkdirAll(out, 0o755); err != nil {
				return err
			}
			continue
		}
		if err := os.MkdirAll(filepath.Dir(out), 0o755); err != nil {
			return err
		}
		rc, err := f.Open()
		if err != nil {
			return err
		}
		w, err := os.Create(out)
		if err != nil {
			rc.Close()
			return err
		}
		_, err = io.Copy(w, rc)
		w.Close()
		rc.Close()
		if err != nil {
			return err
		}
	}
	return nil
}

func copySelf(dst string) {
	self, err := os.Executable()
	if err != nil {
		return
	}
	self, _ = filepath.EvalSymlinks(self)
	if strings.EqualFold(self, dst) {
		return // 설치본에서 실행 중이면 복사 불필요(잠겨 있기도 함)
	}
	data, err := os.ReadFile(self)
	if err != nil {
		return
	}
	_ = os.WriteFile(dst, data, 0o755) // 실패해도 치명적이지 않음(zip 설치본 사용 가능)
}

// runHidden: 창 없이 실행하고 종료를 기다린다.
func runHidden(name string, args ...string) error {
	cmd := exec.Command(name, args...)
	cmd.SysProcAttr = &syscall.SysProcAttr{HideWindow: true, CreationFlags: 0x08000000} // CREATE_NO_WINDOW
	return cmd.Run()
}

// runVisibleWait: 새 콘솔 창을 띄워 실행하고 끝날 때까지 기다린다 (winget 진행 표시용).
func runVisibleWait(args ...string) error {
	full := append([]string{"/C", "start", "/WAIT", ""}, args...)
	cmd := exec.Command("cmd", full...)
	return cmd.Run()
}

func haveCmd(name string) bool {
	_, err := exec.LookPath(name)
	return err == nil
}

// ensureDep: 없으면 winget 설치를 제안한다. 설치해도 현재 프로세스 PATH 에는
// 반영되지 않으므로 호출자가 안내 문구로 처리한다. 반환: 지금 사용 가능 여부.
func ensureDep(cmdName, display, wingetID string, optional bool) bool {
	if haveCmd(cmdName) {
		return true
	}
	q := display + " 이(가) 설치되어 있지 않습니다.\n지금 설치할까요? (winget)"
	if optional {
		q = display + " 이(가) 없습니다 (선택 사항).\n지금 설치할까요? (winget)"
	}
	if !haveCmd("winget") {
		if !optional {
			fail(display + " 이(가) 필요하지만 winget 이 없어 자동 설치할 수 없습니다.\n수동으로 설치해 주세요: " + wingetID)
		}
		return false
	}
	if askYes(q) {
		_ = runVisibleWait("winget", "install", "--id", wingetID, "--source", "winget",
			"--accept-package-agreements", "--accept-source-agreements")
	}
	return haveCmd(cmdName)
}

func makeShortcuts(dir string) {
	exe := filepath.Join(dir, "AgentContinuity.exe")
	script := fmt.Sprintf(`$s = New-Object -ComObject WScript.Shell
foreach ($place in @([Environment]::GetFolderPath('Desktop'), (Join-Path ([Environment]::GetFolderPath('StartMenu')) 'Programs'))) {
  $l = $s.CreateShortcut((Join-Path $place 'Agent Continuity.lnk'))
  $l.TargetPath = '%s'
  $l.WorkingDirectory = '%s'
  $l.Save()
}`, exe, dir)
	_ = runHidden("powershell", "-NoProfile", "-ExecutionPolicy", "Bypass", "-Command", script)
}

func launchUI(dir string) error {
	ui := filepath.Join(dir, "ui", "AgentContinuity-Ui.ps1")
	cmd := exec.Command("pwsh", "-NoProfile", "-ExecutionPolicy", "Bypass",
		"-WindowStyle", "Hidden", "-File", ui)
	cmd.Dir = dir
	cmd.SysProcAttr = &syscall.SysProcAttr{HideWindow: true, CreationFlags: 0x08000000}
	return cmd.Start()
}

func main() {
	dir := installRoot()
	firstInstall := !exists(filepath.Join(dir, "AgentContinuity.psd1"))

	if firstInstall {
		if !askYes(appName + " 를 설치할까요?\n\n설치 위치: " + dir +
			"\n(관리자 권한 불필요, 사용자 폴더에만 설치됩니다)") {
			return
		}
	}

	if err := extractPayload(dir); err != nil {
		fail("파일 설치 실패: " + err.Error())
		return
	}
	copySelf(filepath.Join(dir, "AgentContinuity.exe"))

	_ = ensureDep("git", "Git", "Git.Git", false)
	hasPwsh := ensureDep("pwsh", "PowerShell 7", "Microsoft.PowerShell", false)
	_ = ensureDep("age", "age (Phase 2 암호화용)", "FiloSottile.age", true)

	makeShortcuts(dir)

	if firstInstall {
		next := "설치 완료!\n\n다음 단계:\n" +
			"1) 창이 열리면 프로젝트를 등록하세요 (Setup 마법사)\n" +
			"2) 이후에는 바탕화면의 'Agent Continuity' 로 실행하면 됩니다"
		if !hasPwsh {
			next = "설치 완료!\n\nPowerShell 7 을 방금 설치했다면, 이 프로그램을 한 번 더 실행해 주세요.\n(새로 설치된 도구는 다음 실행부터 인식됩니다)"
		}
		info(next)
	}

	if hasPwsh {
		if err := launchUI(dir); err != nil {
			fail("UI 실행 실패: " + err.Error())
		}
	}
}
