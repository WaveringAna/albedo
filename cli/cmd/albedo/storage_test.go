// Storage pruning must never delete a live session snapshot or unapproved files;
// the age and database checks are local safety boundaries that a daemon E2E cannot force.
package main

import (
	"bytes"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

func TestStoragePreviewAndOfflinePrune(t *testing.T) {
	home := t.TempDir()
	t.Setenv("ALBEDO_HOME", home)
	setup := `import sqlite3,sys
c=sqlite3.connect(sys.argv[1])
c.execute('CREATE TABLE sessions(id TEXT,pinned_context BLOB)')
c.execute('CREATE TABLE transcript(session TEXT,payload BLOB)')
c.execute('CREATE TABLE images(data TEXT)')
c.execute('CREATE TABLE cells(id TEXT,session TEXT,source TEXT,payload BLOB)')
c.execute('CREATE TABLE cell_traces(id TEXT,payload BLOB)')
c.execute('INSERT INTO sessions VALUES(?,?)',('live',b'abc'))
c.execute('INSERT INTO transcript VALUES(?,?)',('live',b'abcd'))
c.execute('INSERT INTO images VALUES(?)',('abcd',))
c.execute('INSERT INTO cells VALUES(?,?,?,?)',('cell','live','hello',b'xyz'))
c.execute('INSERT INTO cell_traces VALUES(?,?)',('cell',b'trace'))
c.commit()
c.close()`
	if out, err := exec.Command("python3", "-c", setup, filepath.Join(home, "albedo.sqlite")).CombinedOutput(); err != nil {
		t.Fatalf("setup SQLite: %v %s", err, out)
	}
	if err := os.Mkdir(filepath.Join(home, "kernels"), 0700); err != nil {
		t.Fatal(err)
	}
	if err := os.Mkdir(filepath.Join(home, "backups"), 0700); err != nil {
		t.Fatal(err)
	}
	live := filepath.Join(home, "kernels", "live.state")
	orphan := filepath.Join(home, "kernels", "orphan.state")
	recent := filepath.Join(home, "kernels", "recent.state")
	backup := filepath.Join(home, "backups", "albedo-before-image-store-1.sqlite")
	unrelated := filepath.Join(home, "backups", "personal.sqlite")
	for _, path := range []string{live, orphan, recent, backup, unrelated} {
		if err := os.WriteFile(path, []byte("data"), 0600); err != nil {
			t.Fatal(err)
		}
	}
	old := time.Now().Add(-31 * 24 * time.Hour)
	for _, path := range []string{live, orphan, backup, unrelated} {
		if err := os.Chtimes(path, old, old); err != nil {
			t.Fatal(err)
		}
	}
	p, err := storageSnapshot(home, time.Now())
	if err != nil {
		t.Fatal(err)
	}
	if len(p.DB.Sessions) != 1 || p.DB.Sessions[0].Bytes != 20 || p.DB.Images != 4 {
		t.Fatalf("unexpected storage estimates: %+v", p.DB)
	}
	if len(p.OldKernels) != 1 || p.OldKernels[0].Path != orphan || len(p.OldBackups) != 1 || p.OldBackups[0].Path != backup {
		t.Fatalf("unsafe candidates: %+v", p)
	}
	var summary bytes.Buffer
	storagePrint(&summary, p, false)
	if strings.Contains(summary.String(), "live") || !strings.Contains(summary.String(), "1 sessions") || !strings.Contains(summary.String(), "Cleanup: albedo storage prune --all") {
		t.Fatalf("unreadable default preview: %s", summary.String())
	}
	var detailed bytes.Buffer
	storagePrint(&detailed, p, true)
	if !strings.Contains(detailed.String(), "live") || storageSize(508272640) != "484.7 MiB" {
		t.Fatalf("session detail or size formatting: %s", detailed.String())
	}
	if err := storageCommand(nil); err != nil {
		t.Fatal(err)
	}
	if _, err := os.Stat(orphan); err != nil {
		t.Fatalf("preview deleted snapshot: %v", err)
	}
	if err := storageCommand([]string{"prune", "--all"}); err == nil || !strings.Contains(err.Error(), "--yes") {
		t.Fatalf("prune without confirmation: %v", err)
	}
	if err := storageCommand([]string{"prune", "--all", "--backups", "--yes"}); err == nil || !strings.Contains(err.Error(), "cannot be combined") {
		t.Fatalf("ambiguous --all accepted: %v", err)
	}
	if err := storageCommand([]string{"prune", "--all", "--yes"}); err != nil {
		t.Fatal(err)
	}
	for _, path := range []string{orphan, backup} {
		if _, err := os.Stat(path); !os.IsNotExist(err) {
			t.Errorf("should remove %s: %v", path, err)
		}
	}
	for _, path := range []string{live, recent, unrelated} {
		if _, err := os.Stat(path); err != nil {
			t.Errorf("should retain %s: %v", path, err)
		}
	}
	if after, err := storageSnapshot(home, time.Now()); err != nil || len(after.DB.Sessions) != 1 {
		t.Fatalf("--all deleted sessions: %+v, %v", after.DB.Sessions, err)
	}
}

func TestStorageRequiresDatabaseForOrphanCleanup(t *testing.T) {
	home := t.TempDir()
	t.Setenv("ALBEDO_HOME", home)
	if err := storageCommand([]string{"prune", "--old-kernels", "--yes"}); err == nil || !strings.Contains(err.Error(), "without the SQLite database") {
		t.Fatalf("unsafe cleanup without database: %v", err)
	}
	var ids sessionIDs
	if err := ids.Set("../sessions/escape"); err == nil {
		t.Fatal("accepted non-session ID")
	}
}

func TestStorageRefusesSymlinkDirectory(t *testing.T) {
	home := t.TempDir()
	outside := t.TempDir()
	if err := os.Symlink(outside, filepath.Join(home, "kernels")); err != nil {
		t.Skipf("symlinks unavailable: %v", err)
	}
	if _, err := storageSnapshot(home, time.Now()); err == nil {
		t.Fatal("followed symlinked kernel directory")
	}
}
