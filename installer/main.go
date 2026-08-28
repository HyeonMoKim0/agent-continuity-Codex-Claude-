// AgentContinuity-Setup.exe — 설치와 실행을 겸하는 단일 실행 파일 (배포 계획 D1 확장).
//
// 동작:
//  1. 처음 실행: 설치 확인 → 설치 위치 선택(기본 위치 또는 폴더 선택 대화상자) →
//     내장 payload 를 풀고 의존성(git / PowerShell 7 / age)을 winget 으로 설치 안내 →
//     바로가기 생성 → UI 실행. 선택한 경로는 기록되어 다음 실행이 찾아간다.
//  2. 이후 실행(바로가기 포함): payload 를 최신으로 덮어쓴 뒤 곧바로 UI 실행 (자가 복구/업데이트)
//
// GUI 서브시스템(-H windowsgui)으로 빌드되어 콘솔 창이 뜨지 않으며, 안내는 MessageBox 로 한다.
// 관리자 권한 불필요(asInvoker), 파일은 사용자가 지정한 폴더에만 쓴다.
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
// Win32 helpers (user32 / shell32 / ole32, 외부 의존성 없음)
// ---------------------------------------------------------------------------

var (
	user32       = syscall.NewLazyDLL("user32.dll")
	shell32      = syscall.NewLazyDLL("shell32.dll")
	ole32        = syscall.NewLazyDLL("ole32.dll")
	messageBox   = user32.NewProc("MessageBoxW")
	browseFolder = shell32.NewProc("SHBrowseForFolderW")
	pathFromIDL  = shell32.NewProc("SHGetPathFromIDListW")
	coInitEx     = ole32.NewProc("CoInitializeEx")
	coTaskFree   = ole32.NewProc("CoTaskMemFree")
)

const (
	mbOK       = 0x0
	mbYesNo    = 0x4
	mbIconInfo = 0x40
	mbIconErr  = 0x10
	mbIconQ    = 0x20
	idYes      = 6

	bifReturnOnlyFSDirs = 0x0001
	bifNewDialogStyle   = 0x0040
	maxPath             = 260
)

func msgBox(text string, flags uintptr) int {
	t, _ := syscall.UTF16PtrFromString(text)
	c, _ := syscall.UTF16PtrFromString(appName + " " + version)
	r, _, _ := messageBox.Call(0, uintptr(unsafe.Pointer(t)), uintptr(unsafe.Pointer(c)), flags)
	return int(r)
}

func info(text string)        { msgBox(text, mbOK|mbIconInfo) }
func fail(text string)        { msgBox(text, mbOK|mbIconErr) }
func askYes(text string) bool { return msgBox(text, mbYesNo|mbIconQ) == idYes }

type browseInfo struct {
	hwndOwner      uintptr
	pidlRoot       uintptr
	pszDisplayName *uint16
	lpszTitle      *uint16
	ulFlags        uint32
	lpfn           uintptr
	lParam         uintptr
	iImage         int32
}

// pickFolder: Windows 폴더 선택 대화상자. 취소하면 "" 반환.
func pickFolder(title string) string {
	coInitEx.Call(0, 0x2 /* COINIT_APARTMENTTHREADED */)
	display := make([]uint16, maxPath)
	t, _ := syscall.UTF16PtrFromString(title)
	bi := browseInfo{
		pszDisplayName: &display[0],
		lpszTitle:      t,
		ulFlags:        bifReturnOnlyFSDirs | bifNewDialogStyle,
	}
	pidl, _, _ := browseFolder.Call(uintptr(unsafe.Pointer(&bi)))
	if pidl == 0 {
		return ""
	}
	defer coTaskFree.Call(pidl)
	buf := make([]uint16, maxPath)
	ok, _, _ := pathFromIDL.Call(pidl, uintptr(unsafe.Pointer(&buf[0])))
	if ok == 0 {
		return ""
	}
	return syscall.UTF16ToString(buf)
}

// ---------------------------------------------------------------------------
// install location resolution
// ---------------------------------------------------------------------------

func defaultInstallRoot() string {
	return filepath.Join(os.Getenv("LOCALAPPDATA"), "Programs", "AgentContinuity")
}

// markerPath: 사용자 지정 설치 경로 기억 파일 (도구 상태 폴더와 같은 위치 계열).
func markerPath() string {
	return filepath.Join(os.Getenv("LOCALAPPDATA"), "AgentContinuity", "install-path.txt")
}

func exists(p string) bool { _, err := os.Stat(p); return err == nil }

func isInstallDir(p string) bool { return exists(filepath.Join(p, "AgentContinuity.psd1")) }

// resolveInstallDir: (설치 폴더, 이미 설치되어 있었는지) 를 결정한다.
func resolveInstallDir() (string, bool) {
	// 1) 설치본 폴더 안에서 실행 중이면 그곳이 홈이다 (사용자 지정 경로 포함)
	if self, err := os.Executable(); err == nil {
		d := filepath.Dir(self)
		if isInstallDir(d) {
			return d, true
		}
	}
	// 2) 이전 설치가 기록해 둔 경로
	if data, err := os.ReadFile(markerPath()); err == nil {
		p := strings.TrimSpace(string(data))
		if p != "" && isInstallDir(p) {
			return p, true
		}
	}
	// 3) 기본 위치에 기존 설치가 있는지
	if isInstallDir(defaultInstallRoot()) {
		return defaultInstallRoot(), true
	}
	// 4) 신규 설치: 위치 선택
	def := defaultInstallRoot()
	if !askYes(appName + " 를 설치할까요?\n\n기본 설치 위치:\n" + def +
		"\n\n[예] 기본 위치에 설치    [아니오] 설치할 폴더 직접 선택") {
		picked := pickFolder("Agent Continuity 를 설치할 폴더를 선택하세요 (하위에 AgentContinuity 폴더가 생성됩니다)")
		if picked == "" {
			return "", false // 취소
		}
		return filepath.Join(picked, "AgentContinuity"), false
	}
	return def, false
}

func rememberInstallDir(dir string) {
	_ = os.MkdirAll(filepath.Dir(markerPath()), 0o755)
	_ = os.WriteFile(markerPath(), []byte(dir), 0o644)
}

// ---------------------------------------------------------------------------

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
	dir, alreadyInstalled := resolveInstallDir()
	if dir == "" {
		return // 사용자가 설치를 취소함
	}

	if err := extractPayload(dir); err != nil {
		fail("파일 설치 실패: " + err.Error())
		return
	}
	copySelf(filepath.Join(dir, "AgentContinuity.exe"))
	rememberInstallDir(dir)

	_ = ensureDep("git", "Git", "Git.Git", false)
	hasPwsh := ensureDep("pwsh", "PowerShell 7", "Microsoft.PowerShell", false)
	_ = ensureDep("age", "age (Phase 2 암호화용)", "FiloSottile.age", true)

	makeShortcuts(dir)

	if !alreadyInstalled {
		next := "설치 완료!\n\n설치 위치: " + dir + "\n\n다음 단계:\n" +
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
