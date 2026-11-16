package main

import (
	"bytes"
	"context"
	"crypto/ed25519"
	"crypto/rand"
	"crypto/subtle"
	"encoding/json"
	"encoding/pem"
	"errors"
	"flag"
	"fmt"
	"io"
	"log"
	"net"
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"strings"
	"sync"
	"sync/atomic"
	"syscall"
	"time"

	"golang.org/x/crypto/ssh"
	"golang.org/x/sys/windows"
)

const createNoWindow = 0x08000000

var (
	reDirectCmd = regexp.MustCompile(
		`^(?:(?:PATH="[^"]*"|PATH='[^']*'|PATH=\S+|HC_SESSION=([A-Za-z0-9._-]+))\s+)*(?:exec\s+)?(?:hc|herdr-core)(?:\.exe)?\s+(connect|--version)(?:\s+--session(?:=|\s+)([A-Za-z0-9._-]+))?$`,
	)
	reUnixMachinePipe = regexp.MustCompile(
		`^sh -c 'p=\$\(command -v herdr-core\) \|\| p=\$HOME/\.local/bin/herdr-core; \[ -x "\$p" \] \|\| \{ echo "herdr-core is not installed here" >&2; exit 127; \}; (?:HC_SESSION=([A-Za-z0-9._-]+) )?exec "\$p" (connect|--version)'$`,
	)
	reWinMachinePipe = regexp.MustCompile(
		`^cmd /d /c "if exist \.\\AppData\\Local\\Programs\\herdr-core\\herdr-core\.exe \(\.\\AppData\\Local\\Programs\\herdr-core\\herdr-core\.exe (connect|--version)(?: --session ([A-Za-z0-9._-]+))?\) else \(echo herdr-core is not installed here 1>&2 & exit /b 127\)"$`,
	)
	reSafeSession   = regexp.MustCompile(`^[A-Za-z0-9._-]+$`)
	reBinaryVersion = regexp.MustCompile(`herdr-core\s+[0-9]+\.[0-9]+\.[0-9]+(?:-[A-Za-z0-9.]+)?`)
)

type boundedLogWriter struct {
	mu      sync.Mutex
	path    string
	maxSize int64
}

func (w *boundedLogWriter) Write(p []byte) (int, error) {
	w.mu.Lock()
	defer w.mu.Unlock()

	if info, err := os.Stat(w.path); err == nil && info.Size()+int64(len(p)) > w.maxSize {
		_ = os.Rename(w.path, w.path+".1")
	}
	f, err := os.OpenFile(w.path, os.O_CREATE|os.O_WRONLY|os.O_APPEND, 0600)
	if err != nil {
		return len(p), nil
	}
	defer f.Close()
	_, _ = f.Write(p)
	return len(p), nil
}

func resolveHcBinary() (string, error) {
	if localAppData := os.Getenv("LOCALAPPDATA"); localAppData != "" {
		candidate := filepath.Join(localAppData, "Programs", "herdr-core", "hc.exe")
		if _, err := os.Stat(candidate); err == nil {
			return candidate, nil
		}
	}
	if home, err := os.UserHomeDir(); err == nil {
		candidate := filepath.Join(home, "AppData", "Local", "Programs", "herdr-core", "hc.exe")
		if _, err := os.Stat(candidate); err == nil {
			return candidate, nil
		}
	}
	return exec.LookPath("hc.exe")
}

func loadOrCreateHostKey(baseDir string) (ssh.Signer, error) {
	privPath := filepath.Join(baseDir, "host_ed25519")
	pubPath := filepath.Join(baseDir, "host_ed25519.pub")
	fpPath := filepath.Join(baseDir, "host_ed25519.fingerprint")

	var signer ssh.Signer
	if pemBytes, err := os.ReadFile(privPath); err == nil {
		signer, err = ssh.ParsePrivateKey(pemBytes)
		if err != nil {
			return nil, fmt.Errorf("parse host key: %w", err)
		}
	} else {
		_, priv, err := ed25519.GenerateKey(rand.Reader)
		if err != nil {
			return nil, fmt.Errorf("generate ed25519 key: %w", err)
		}
		block, err := ssh.MarshalPrivateKey(priv, "herdr-ssh-bridge")
		if err != nil {
			return nil, fmt.Errorf("marshal host key: %w", err)
		}
		pemBytes := pem.EncodeToMemory(block)
		if err := os.WriteFile(privPath, pemBytes, 0600); err != nil {
			return nil, fmt.Errorf("write host key: %w", err)
		}
		signer, err = ssh.NewSignerFromKey(priv)
		if err != nil {
			return nil, fmt.Errorf("signer from key: %w", err)
		}
	}

	_ = os.WriteFile(pubPath, ssh.MarshalAuthorizedKey(signer.PublicKey()), 0644)
	_ = os.WriteFile(fpPath, []byte(ssh.FingerprintSHA256(signer.PublicKey())+"\n"), 0644)
	return signer, nil
}

type authorizedEntry struct {
	key     ssh.PublicKey
	comment string
}

func loadAuthorizedKeys(paths []string) []authorizedEntry {
	var entries []authorizedEntry
	for _, p := range paths {
		data, err := os.ReadFile(p)
		if err != nil {
			continue
		}
		rest := bytes.TrimSpace(data)
		for len(rest) > 0 {
			pub, comment, _, next, err := ssh.ParseAuthorizedKey(rest)
			if err != nil {
				idx := bytes.IndexByte(rest, '\n')
				if idx < 0 {
					break
				}
				rest = bytes.TrimSpace(rest[idx+1:])
				continue
			}
			entries = append(entries, authorizedEntry{key: pub, comment: comment})
			rest = bytes.TrimSpace(next)
		}
	}
	return entries
}

type overlappedPipe struct {
	handle windows.Handle
	closed atomic.Bool
}

func isPipeEOF(err error) bool {
	return errors.Is(err, windows.ERROR_BROKEN_PIPE) ||
		errors.Is(err, windows.ERROR_NO_DATA) ||
		errors.Is(err, windows.ERROR_PIPE_NOT_CONNECTED) ||
		errors.Is(err, windows.ERROR_OPERATION_ABORTED)
}

// Matches herdr-core's crates/herdr-core/src/platform/windows.rs::endpoints().
func corePipePath(session string) string {
	if session == "" {
		session = "default"
	}
	rawUser := os.Getenv("USERNAME")
	var b strings.Builder
	for i := 0; i < len(rawUser); i++ {
		c := rawUser[i]
		if (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9') {
			b.WriteByte(c)
		}
	}
	return fmt.Sprintf(`\\.\pipe\herdr-core-%s-%s.sock`, b.String(), session)
}

func dialNamedPipe(pipePath string) (*overlappedPipe, error) {
	path16, err := windows.UTF16PtrFromString(pipePath)
	if err != nil {
		return nil, err
	}
	const securitySqosPresent = 0x00100000
	const securityIdentification = 0x00010000
	flags := uint32(windows.FILE_FLAG_OVERLAPPED | securitySqosPresent | securityIdentification)

	for i := 0; i < 40; i++ {
		h, err := windows.CreateFile(
			path16,
			windows.GENERIC_READ|windows.GENERIC_WRITE,
			0,
			nil,
			windows.OPEN_EXISTING,
			flags,
			0,
		)
		if err == nil {
			return &overlappedPipe{handle: h}, nil
		}
		if errors.Is(err, windows.ERROR_PIPE_BUSY) {
			time.Sleep(50 * time.Millisecond)
			continue
		}
		return nil, err
	}
	return nil, errors.New("named pipe busy timeout")
}

// Opens the running core's named pipe directly; if the core has not started yet
// (e.g. right after Windows sign-in before Herdr Desktop opens), starts it via
// `hc server start` and waits for the pipe to appear.
func dialOrStartPipe(ctx context.Context, hcExe string, session string, pipePath string) (*overlappedPipe, error) {
	pipe, err := dialNamedPipe(pipePath)
	if err == nil || !errors.Is(err, windows.ERROR_FILE_NOT_FOUND) {
		return pipe, err
	}

	args := []string{"server", "start"}
	if session != "" {
		args = append(args, "--session", session)
	}
	cmd := exec.Command(hcExe, args...)
	cmd.SysProcAttr = &syscall.SysProcAttr{
		HideWindow:    true,
		CreationFlags: createNoWindow,
	}
	if startErr := cmd.Start(); startErr == nil {
		go func() { _ = cmd.Wait() }()
	}

	deadline := time.Now().Add(15 * time.Second)
	for time.Now().Before(deadline) {
		select {
		case <-ctx.Done():
			return nil, ctx.Err()
		case <-time.After(100 * time.Millisecond):
		}
		if pipe, dialErr := dialNamedPipe(pipePath); dialErr == nil {
			return pipe, nil
		}
	}
	return dialNamedPipe(pipePath)
}

func (p *overlappedPipe) Read(buf []byte) (int, error) {
	if len(buf) == 0 {
		return 0, nil
	}
	ev, err := windows.CreateEvent(nil, 1, 0, nil)
	if err != nil {
		return 0, err
	}
	defer windows.CloseHandle(ev)

	var ov windows.Overlapped
	ov.HEvent = ev
	var done uint32
	err = windows.ReadFile(p.handle, buf, &done, &ov)
	if err != nil {
		if !errors.Is(err, windows.ERROR_IO_PENDING) {
			if isPipeEOF(err) {
				return 0, io.EOF
			}
			return 0, err
		}
		err = windows.GetOverlappedResult(p.handle, &ov, &done, true)
		if err != nil {
			if isPipeEOF(err) {
				return 0, io.EOF
			}
			return 0, err
		}
	}
	if done == 0 {
		return 0, io.EOF
	}
	return int(done), nil
}

func (p *overlappedPipe) Write(buf []byte) (int, error) {
	total := 0
	for total < len(buf) {
		ev, err := windows.CreateEvent(nil, 1, 0, nil)
		if err != nil {
			return total, err
		}
		var ov windows.Overlapped
		ov.HEvent = ev
		var n uint32
		err = windows.WriteFile(p.handle, buf[total:], &n, &ov)
		if err != nil {
			if !errors.Is(err, windows.ERROR_IO_PENDING) {
				_ = windows.CloseHandle(ev)
				return total, err
			}
			err = windows.GetOverlappedResult(p.handle, &ov, &n, true)
			_ = windows.CloseHandle(ev)
			if err != nil {
				return total, err
			}
		} else {
			_ = windows.CloseHandle(ev)
		}
		if n == 0 {
			return total, io.ErrShortWrite
		}
		total += int(n)
	}
	return total, nil
}

func (p *overlappedPipe) Close() error {
	if p.closed.CompareAndSwap(false, true) {
		_ = windows.CancelIoEx(p.handle, nil)
		return windows.CloseHandle(p.handle)
	}
	return nil
}

func resolveExecCommand(raw string, envSession string) (mode string, session string, ok bool) {
	s := strings.TrimSpace(raw)
	if s == "exit" {
		return "exit", "", true
	}
	if m := reDirectCmd.FindStringSubmatch(s); m != nil {
		if m[2] == "--version" {
			return "version", "", true
		}
		sess := m[3]
		if sess == "" {
			sess = m[1]
		}
		if sess == "" {
			sess = envSession
		}
		return "connect", sess, true
	}
	if m := reUnixMachinePipe.FindStringSubmatch(s); m != nil {
		if m[2] == "--version" {
			return "version", "", true
		}
		sess := m[1]
		if sess == "" {
			sess = envSession
		}
		return "connect", sess, true
	}
	if m := reWinMachinePipe.FindStringSubmatch(s); m != nil {
		if m[1] == "--version" {
			return "version", "", true
		}
		sess := m[2]
		if sess == "" {
			sess = envSession
		}
		return "connect", sess, true
	}
	return "", "", false
}

func sendExitStatus(ch ssh.Channel, code uint32) {
	payload := ssh.Marshal(&struct{ Status uint32 }{Status: code})
	_, _ = ch.SendRequest("exit-status", false, payload)
}

func bridgeDirectPipe(connCtx context.Context, ch ssh.Channel, req *ssh.Request, pipe *overlappedPipe, pipePath string, peerDesc string) {
	if req.WantReply {
		_ = req.Reply(true, nil)
	}
	log.Printf("[%s] connected directly to pipe %s", peerDesc, pipePath)

	done := make(chan struct{})
	go func() {
		select {
		case <-connCtx.Done():
			_ = pipe.Close()
		case <-done:
		}
	}()

	go func() {
		_, _ = io.Copy(pipe, ch)
		select {
		case <-done:
		case <-time.After(250 * time.Millisecond):
			_ = pipe.Close()
		}
	}()

	_, _ = io.Copy(ch, pipe)
	_ = pipe.Close()
	close(done)

	_ = ch.CloseWrite()
	sendExitStatus(ch, 0)
	_ = ch.Close()
	log.Printf("[%s] closed pipe session %s", peerDesc, pipePath)
}

func handleSessionChannel(connCtx context.Context, newChan ssh.NewChannel, hcExe string, peerDesc string) {
	ch, requests, err := newChan.Accept()
	if err != nil {
		log.Printf("[%s] accept session channel failed: %v", peerDesc, err)
		return
	}

	var envSession string
	execStarted := false

	for req := range requests {
		switch req.Type {
		case "keepalive@openssh.com":
			if req.WantReply {
				_ = req.Reply(true, nil)
			}
		case "env":
			var envReq struct {
				Name  string
				Value string
			}
			if err := ssh.Unmarshal(req.Payload, &envReq); err == nil {
				if envReq.Name == "HC_SESSION" && reSafeSession.MatchString(envReq.Value) {
					envSession = envReq.Value
				}
			}
			if req.WantReply {
				_ = req.Reply(true, nil)
			}
		case "exec":
			if execStarted {
				if req.WantReply {
					_ = req.Reply(false, nil)
				}
				continue
			}
			var execReq struct {
				Command string
			}
			if err := ssh.Unmarshal(req.Payload, &execReq); err != nil {
				if req.WantReply {
					_ = req.Reply(false, nil)
				}
				_ = ch.Close()
				return
			}

			mode, session, ok := resolveExecCommand(execReq.Command, envSession)
			if !ok {
				log.Printf("[%s] rejected unsupported exec command: %q", peerDesc, execReq.Command)
				if req.WantReply {
					_ = req.Reply(true, nil)
				}
				_, _ = io.WriteString(ch.Stderr(), "herdr-ssh-bridge: only `hc connect` is permitted on this endpoint\n")
				sendExitStatus(ch, 126)
				_ = ch.Close()
				return
			}

			execStarted = true
			if mode == "exit" {
				if req.WantReply {
					_ = req.Reply(true, nil)
				}
				sendExitStatus(ch, 0)
				_ = ch.Close()
				return
			}
			if mode == "version" {
				hcVersion := queryCoreVersion(hcExe, envSession)
				if req.WantReply {
					_ = req.Reply(true, nil)
				}
				_, _ = io.WriteString(ch, hcVersion+"\n")
				_ = ch.CloseWrite()
				sendExitStatus(ch, 0)
				_ = ch.Close()
				log.Printf("[%s] answered --version (%s)", peerDesc, hcVersion)
				return
			}

			pipePath := corePipePath(session)
			if pipe, err := dialOrStartPipe(connCtx, hcExe, session, pipePath); err == nil {
				go bridgeDirectPipe(connCtx, ch, req, pipe, pipePath, peerDesc)
				continue
			} else {
				log.Printf("[%s] direct pipe %s unavailable (%v), falling back to hc.exe", peerDesc, pipePath, err)
			}

			args := []string{"connect"}
			if session != "" {
				args = append(args, "--session", session)
			}
			go runHcProcess(connCtx, ch, req, hcExe, args, peerDesc)

		default:
			if req.WantReply {
				_ = req.Reply(false, nil)
			}
		}
	}

	if !execStarted {
		_ = ch.Close()
	}
}

func runHcProcess(connCtx context.Context, ch ssh.Channel, req *ssh.Request, hcExe string, args []string, peerDesc string) {
	cmd := exec.Command(hcExe, args...)
	cmd.SysProcAttr = &syscall.SysProcAttr{
		HideWindow:    true,
		CreationFlags: createNoWindow,
	}

	stdinPipe, err := cmd.StdinPipe()
	if err != nil {
		if req.WantReply {
			_ = req.Reply(false, nil)
		}
		_ = ch.Close()
		return
	}
	stdoutPipe, err := cmd.StdoutPipe()
	if err != nil {
		if req.WantReply {
			_ = req.Reply(false, nil)
		}
		_ = ch.Close()
		return
	}
	stderrPipe, err := cmd.StderrPipe()
	if err != nil {
		if req.WantReply {
			_ = req.Reply(false, nil)
		}
		_ = ch.Close()
		return
	}

	if err := cmd.Start(); err != nil {
		log.Printf("[%s] failed to start %s %v: %v", peerDesc, hcExe, args, err)
		if req.WantReply {
			_ = req.Reply(true, nil)
		}
		_, _ = fmt.Fprintf(ch.Stderr(), "herdr-ssh-bridge: failed to start hc: %v\n", err)
		sendExitStatus(ch, 127)
		_ = ch.Close()
		return
	}

	if req.WantReply {
		_ = req.Reply(true, nil)
	}
	log.Printf("[%s] started hc %v (pid=%d)", peerDesc, args, cmd.Process.Pid)

	procDone := make(chan struct{})

	go func() {
		select {
		case <-connCtx.Done():
			_ = stdinPipe.Close()
			select {
			case <-procDone:
			case <-time.After(2 * time.Second):
				if cmd.Process != nil {
					_ = cmd.Process.Kill()
				}
			}
		case <-procDone:
		}
	}()

	go func() {
		_, _ = io.Copy(stdinPipe, ch)
		_ = stdinPipe.Close()
	}()

	var wg sync.WaitGroup
	wg.Add(2)
	go func() {
		defer wg.Done()
		_, _ = io.Copy(ch, stdoutPipe)
		_ = ch.CloseWrite()
	}()
	go func() {
		defer wg.Done()
		_, _ = io.Copy(ch.Stderr(), stderrPipe)
	}()

	wg.Wait()
	waitErr := cmd.Wait()
	close(procDone)

	var exitCode uint32
	if waitErr != nil {
		var exitErr *exec.ExitError
		if errors.As(waitErr, &exitErr) {
			exitCode = uint32(exitErr.ExitCode())
		} else {
			exitCode = 1
		}
	}
	sendExitStatus(ch, exitCode)
	_ = ch.Close()
	log.Printf("[%s] finished hc %v (pid=%d, exit=%d)", peerDesc, args, cmd.Process.Pid, exitCode)
}

func startKeepaliveLoop(ctx context.Context, sshConn *ssh.ServerConn, peerDesc string) {
	ticker := time.NewTicker(30 * time.Second)
	defer ticker.Stop()
	missed := 0
	for {
		select {
		case <-ctx.Done():
			return
		case <-ticker.C:
			replyCh := make(chan error, 1)
			go func() {
				_, _, err := sshConn.SendRequest("keepalive@openssh.com", true, nil)
				replyCh <- err
			}()
			select {
			case err := <-replyCh:
				if err != nil {
					missed++
				} else {
					missed = 0
				}
			case <-time.After(15 * time.Second):
				missed++
			case <-ctx.Done():
				return
			}
			if missed >= 2 {
				log.Printf("[%s] closing stale SSH connection after missed keepalives", peerDesc)
				_ = sshConn.Close()
				return
			}
		}
	}
}

func queryCoreVersion(hcExe string, session string) string {
	if pipe, err := dialNamedPipe(corePipePath(session)); err == nil {
		defer pipe.Close()
		if _, err := pipe.Write([]byte(`{"jsonrpc":"2.0","id":1,"method":"hello","params":{}}` + "\n")); err == nil {
			buf := make([]byte, 4096)
			if n, err := pipe.Read(buf); err == nil && n > 0 {
				line := buf[:n]
				if idx := bytes.IndexByte(line, '\n'); idx >= 0 {
					line = line[:idx]
				}
				var resp struct {
					Result struct {
						Version string `json:"version"`
					} `json:"result"`
				}
				if err := json.Unmarshal(line, &resp); err == nil && resp.Result.Version != "" {
					return "herdr-core " + resp.Result.Version
				}
			}
		}
	}

	coreExe := filepath.Join(filepath.Dir(hcExe), "herdr-core.exe")
	for _, binPath := range []string{coreExe, hcExe} {
		if data, err := os.ReadFile(binPath); err == nil {
			if m := reBinaryVersion.Find(data); len(m) > 0 {
				return strings.Join(strings.Fields(string(m)), " ")
			}
		}
	}

	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()
	cmd := exec.CommandContext(ctx, hcExe, "--version")
	cmd.SysProcAttr = &syscall.SysProcAttr{
		HideWindow:    true,
		CreationFlags: createNoWindow,
	}
	if out, err := cmd.Output(); err == nil {
		if v := strings.TrimSpace(string(out)); v != "" {
			return v
		}
	}
	return "herdr-core"
}

func handleTCPConn(rawConn net.Conn, baseConfig *ssh.ServerConfig, hcExe string) {
	if tcpConn, ok := rawConn.(*net.TCPConn); ok {
		_ = tcpConn.SetKeepAlive(true)
		_ = tcpConn.SetKeepAlivePeriod(30 * time.Second)
	}
	_ = rawConn.SetDeadline(time.Now().Add(30 * time.Second))

	sshConn, chans, reqs, err := ssh.NewServerConn(rawConn, baseConfig)
	if err != nil {
		_ = rawConn.Close()
		return
	}
	_ = rawConn.SetDeadline(time.Time{})

	keyDesc := ""
	if sshConn.Permissions != nil {
		keyDesc = sshConn.Permissions.Extensions["key-comment"]
	}
	peerDesc := fmt.Sprintf("%s user=%q key=%q", sshConn.RemoteAddr(), sshConn.User(), keyDesc)
	log.Printf("[%s] authenticated (%s)", peerDesc, string(sshConn.ClientVersion()))

	connCtx, cancelConn := context.WithCancel(context.Background())
	defer cancelConn()

	go startKeepaliveLoop(connCtx, sshConn, peerDesc)

	go func() {
		for req := range reqs {
			if req.WantReply {
				_ = req.Reply(req.Type == "keepalive@openssh.com", nil)
			}
		}
	}()

	for newChan := range chans {
		if newChan.ChannelType() != "session" {
			_ = newChan.Reject(ssh.UnknownChannelType, "only session channels are supported")
			continue
		}
		go handleSessionChannel(connCtx, newChan, hcExe, peerDesc)
	}

	_ = sshConn.Wait()
	log.Printf("[%s] disconnected", peerDesc)
}

func main() {
	exePath, err := os.Executable()
	if err != nil {
		os.Exit(1)
	}
	defaultDir := filepath.Dir(exePath)

	listenAddr := flag.String("listen", "127.0.0.1:2222", "Loopback TCP address to listen on")
	stateDir := flag.String("dir", defaultDir, "Directory for host key, authorized_keys, and logs")
	logStderr := flag.Bool("stderr", false, "Also mirror logs to stderr")
	flag.Parse()

	_ = os.MkdirAll(*stateDir, 0700)
	logWriter := &boundedLogWriter{
		path:    filepath.Join(*stateDir, "bridge.log"),
		maxSize: 512 * 1024,
	}
	if *logStderr {
		log.SetOutput(io.MultiWriter(logWriter, os.Stderr))
	} else {
		log.SetOutput(logWriter)
	}
	log.SetFlags(log.LstdFlags | log.Lmicroseconds)

	hcExe, err := resolveHcBinary()
	if err != nil {
		log.Fatalf("cannot find hc.exe: %v", err)
	}

	hostSigner, err := loadOrCreateHostKey(*stateDir)
	if err != nil {
		log.Fatalf("host key error: %v", err)
	}

	homeDir, _ := os.UserHomeDir()
	authKeyPaths := []string{
		filepath.Join(*stateDir, "authorized_keys"),
	}
	if homeDir != "" {
		authKeyPaths = append(authKeyPaths, filepath.Join(homeDir, ".ssh", "authorized_keys"))
	}

	serverConfig := &ssh.ServerConfig{
		ServerVersion: "SSH-2.0-herdr-ssh-bridge_2.0",
		PublicKeyCallback: func(conn ssh.ConnMetadata, key ssh.PublicKey) (*ssh.Permissions, error) {
			candidate := key.Marshal()
			for _, entry := range loadAuthorizedKeys(authKeyPaths) {
				if subtle.ConstantTimeCompare(candidate, entry.key.Marshal()) == 1 {
					fp := ssh.FingerprintSHA256(key)
					return &ssh.Permissions{
						Extensions: map[string]string{
							"pubkey-fp":   fp,
							"key-comment": entry.comment,
						},
					}, nil
				}
			}
			log.Printf("rejected public key %s for user %q from %s", ssh.FingerprintSHA256(key), conn.User(), conn.RemoteAddr())
			return nil, errors.New("unauthorized public key")
		},
	}
	serverConfig.AddHostKey(hostSigner)

	ln, err := net.Listen("tcp", *listenAddr)
	if err != nil {
		log.Printf("listen %s failed (already running?): %v", *listenAddr, err)
		return
	}
	defer ln.Close()

	log.Printf("herdr-ssh-bridge listening on %s -> %s (host key %s)",
		*listenAddr, hcExe, ssh.FingerprintSHA256(hostSigner.PublicKey()))

	for {
		conn, err := ln.Accept()
		if err != nil {
			if errors.Is(err, net.ErrClosed) {
				return
			}
			time.Sleep(100 * time.Millisecond)
			continue
		}
		go handleTCPConn(conn, serverConfig, hcExe)
	}
}
