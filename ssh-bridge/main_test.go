package main

import (
	"crypto/ed25519"
	"crypto/rand"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"golang.org/x/crypto/ssh"
)

func TestResolveExecCommand(t *testing.T) {
	cases := []struct {
		name       string
		cmd        string
		envSession string
		wantMode   string
		wantSess   string
		wantOK     bool
	}{
		{
			name:     "direct hc connect",
			cmd:      "hc connect",
			wantMode: "connect",
			wantSess: "",
			wantOK:   true,
		},
		{
			name:       "direct connect inherits HC_SESSION env",
			cmd:        "herdr-core.exe connect",
			envSession: "work",
			wantMode:   "connect",
			wantSess:   "work",
			wantOK:     true,
		},
		{
			name:     "posix mobile wrapper connect",
			cmd:      `sh -c 'p=$(command -v herdr-core) || p=$HOME/.local/bin/herdr-core; [ -x "$p" ] || { echo "herdr-core is not installed here" >&2; exit 127; }; HC_SESSION=mobile exec "$p" connect'`,
			wantMode: "connect",
			wantSess: "mobile",
			wantOK:   true,
		},
		{
			name:     "posix mobile wrapper version",
			cmd:      `sh -c 'p=$(command -v herdr-core) || p=$HOME/.local/bin/herdr-core; [ -x "$p" ] || { echo "herdr-core is not installed here" >&2; exit 127; }; exec "$p" --version'`,
			wantMode: "version",
			wantSess: "",
			wantOK:   true,
		},
		{
			name:     "windows wrapper connect with session",
			cmd:      `cmd /d /c "if exist .\AppData\Local\Programs\herdr-core\herdr-core.exe (.\AppData\Local\Programs\herdr-core\herdr-core.exe connect --session dev_1) else (echo herdr-core is not installed here 1>&2 & exit /b 127)"`,
			wantMode: "connect",
			wantSess: "dev_1",
			wantOK:   true,
		},
		{
			name:     "windows wrapper version",
			cmd:      `cmd /d /c "if exist .\AppData\Local\Programs\herdr-core\herdr-core.exe (.\AppData\Local\Programs\herdr-core\herdr-core.exe --version) else (echo herdr-core is not installed here 1>&2 & exit /b 127)"`,
			wantMode: "version",
			wantSess: "",
			wantOK:   true,
		},
		{
			name:   "reject arbitrary command",
			cmd:    "whoami",
			wantOK: false,
		},
		{
			name:   "reject command chaining",
			cmd:    "hc connect && whoami",
			wantOK: false,
		},
		{
			name:   "reject other hc subcommands",
			cmd:    "hc run powershell",
			wantOK: false,
		},
		{
			name:   "reject unsafe session traversal",
			cmd:    "hc connect --session ../evil",
			wantOK: false,
		},
	}

	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			mode, sess, ok := resolveExecCommand(tc.cmd, tc.envSession)
			if ok != tc.wantOK || mode != tc.wantMode || sess != tc.wantSess {
				t.Fatalf("resolveExecCommand(%q, %q) = (%q, %q, %v), want (%q, %q, %v)",
					tc.cmd, tc.envSession, mode, sess, ok, tc.wantMode, tc.wantSess, tc.wantOK)
			}
		})
	}
}

func TestCorePipePathMatchesHerdrSanitization(t *testing.T) {
	t.Setenv("USERNAME", "Jane_Doe-Corp.1")
	got := corePipePath("")
	want := `\\.\pipe\herdr-core-JaneDoeCorp1-default.sock`
	if got != want {
		t.Fatalf("corePipePath() = %q, want %q", got, want)
	}
}

func TestLoadAuthorizedKeysSkipsCommentsAndMalformedLines(t *testing.T) {
	pub, _, err := ed25519.GenerateKey(rand.Reader)
	if err != nil {
		t.Fatal(err)
	}
	sshPub, err := ssh.NewPublicKey(pub)
	if err != nil {
		t.Fatal(err)
	}
	keyLine := strings.TrimSpace(string(ssh.MarshalAuthorizedKey(sshPub))) + " test-phone"

	dir := t.TempDir()
	path := filepath.Join(dir, "authorized_keys")
	content := "# comment\nnot-a-valid-key\n\n" + keyLine + "\n"
	if err := os.WriteFile(path, []byte(content), 0600); err != nil {
		t.Fatal(err)
	}

	entries := loadAuthorizedKeys([]string{path})
	if len(entries) != 1 || entries[0].comment != "test-phone" {
		t.Fatalf("loadAuthorizedKeys got %d entries (%+v), want 1 entry 'test-phone'", len(entries), entries)
	}
}
