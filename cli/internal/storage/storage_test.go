// Storage pruning must never delete a live session snapshot or unapproved files;
// the age and database checks are local safety boundaries that a daemon E2E cannot force.
package storage

import (
	"context"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

func TestStoragePreviewAndOfflinePrune(t *testing.T) {
	home := t.TempDir()
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
c.execute('CREATE TABLE reclaim(data BLOB)')
c.execute('INSERT INTO reclaim VALUES(zeroblob(262144))')
c.execute('DELETE FROM reclaim')
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
	protected := filepath.Join(home, "backups", "albedo-before-image-store-2.sqlite")
	unrelated := filepath.Join(home, "backups", "personal.sqlite")
	for _, path := range []string{live, orphan, recent, backup, protected, unrelated} {
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
	p, reportErr := testService(home).Report(t.Context())
	if reportErr != nil {
		t.Fatal(reportErr)
	}
	if len(p.DB.Sessions) != 1 || p.DB.Sessions[0].Bytes != 20 || p.DB.Images != 4 {
		t.Fatalf("unexpected storage estimates: %+v", p.DB)
	}
	if len(p.OldKernels) != 1 || p.OldKernels[0].Path != orphan || len(p.OldBackups) != 1 || p.OldBackups[0].Path != backup || p.RecentBackupCount != 1 || p.RecentBackups != 4 || p.DB.FreePages == 0 {
		t.Fatalf("unsafe candidates or missing free pages: %+v", p)
	}
	service := testService(home)
	if _, err := os.Stat(orphan); err != nil {
		t.Fatalf("preview deleted snapshot: %v", err)
	}
	if _, err := service.PlanCleanup(t.Context(), CleanupOptions{All: true, Backups: true}); err == nil {
		t.Fatal("ambiguous --all accepted")
	}
	for _, path := range []string{live, orphan, recent, backup, protected, unrelated} {
		if _, err := os.Stat(path); err != nil {
			t.Fatalf("refused cleanup changed %s: %v", path, err)
		}
	}
	plan, planErr := service.PlanCleanup(t.Context(), CleanupOptions{All: true})
	if planErr != nil {
		t.Fatal(planErr)
	}
	if _, err := service.ApplyCleanup(t.Context(), plan); err != nil {
		t.Fatal(err)
	}
	helper, err := startMaintenance(t.Context(), home, nil)
	if err != nil {
		t.Fatalf("vacuum retained ownership: %v", err)
	}
	helper.close()
	for _, path := range []string{orphan, backup} {
		if _, err := os.Stat(path); !os.IsNotExist(err) {
			t.Errorf("should remove %s: %v", path, err)
		}
	}
	for _, path := range []string{live, recent, protected, unrelated} {
		if _, err := os.Stat(path); err != nil {
			t.Errorf("should retain %s: %v", path, err)
		}
	}
	if after, err := testService(home).Report(t.Context()); err != nil || len(after.DB.Sessions) != 1 || after.Database >= p.Database || after.DB.FreePages != 0 {
		t.Fatalf("--all did not safely reclaim SQLite pages: %+v, %v", after, err)
	}
}

func TestStorageRequiresDatabaseForOrphanCleanup(t *testing.T) {
	home := t.TempDir()
	if _, err := testService(home).PlanCleanup(t.Context(), CleanupOptions{OldKernels: true}); err == nil {
		t.Fatalf("unsafe cleanup without database: %v", err)
	}
	if _, err := testService(home).PlanCleanup(t.Context(), CleanupOptions{Sessions: []string{"../sessions/escape"}}); err == nil {
		t.Fatal("accepted non-session ID")
	}
}

func TestStorageRefusesSymlinkDirectory(t *testing.T) {
	home := t.TempDir()
	outside := t.TempDir()
	if err := os.Symlink(outside, filepath.Join(home, "kernels")); err != nil {
		t.Skipf("symlinks unavailable: %v", err)
	}
	if _, err := testService(home).Report(t.Context()); err == nil {
		t.Fatal("followed symlinked kernel directory")
	}
}

func testService(home string) *Service {
	return &Service{Home: home, Now: time.Now, Running: func() (bool, error) { return false, nil }, DeleteSessions: func(context.Context, []string) error { panic("offline test attempted session deletion") }}
}

// Candidate races occur during the confirmation wait. Force them locally so
// their timing does not depend on a real daemon, terminal, or filesystem clock.
func TestCleanupRevalidatesBeforeAnyDeletion(t *testing.T) {
	for _, change := range []string{"daemon started", "candidate added", "same-size replacement", "symlink replacement"} {
		t.Run(change, func(t *testing.T) {
			home := t.TempDir()
			backups := filepath.Join(home, "backups")
			if err := os.Mkdir(backups, 0700); err != nil {
				t.Fatal(err)
			}
			approved := filepath.Join(backups, "albedo-before-image-store-1.sqlite")
			untouched := filepath.Join(backups, "albedo-before-image-store-2.sqlite")
			old := time.Now().Add(-31 * 24 * time.Hour)
			for _, file := range []string{approved, untouched} {
				if err := os.WriteFile(file, []byte("data"), 0600); err != nil {
					t.Fatal(err)
				}
				if err := os.Chtimes(file, old, old); err != nil {
					t.Fatal(err)
				}
			}
			service := testService(home)
			plan, planErr := service.PlanCleanup(t.Context(), CleanupOptions{Backups: true})
			if planErr != nil {
				t.Fatal(planErr)
			}
			switch change {
			case "daemon started":
				service.Running = func() (bool, error) { return true, nil }
			case "candidate added":
				file := filepath.Join(backups, "albedo-before-image-store-3.sqlite")
				if err := os.WriteFile(file, []byte("data"), 0600); err != nil {
					t.Fatal(err)
				}
				if err := os.Chtimes(file, old, old); err != nil {
					t.Fatal(err)
				}
			case "same-size replacement":
				replacement := filepath.Join(home, "replacement")
				if err := os.WriteFile(replacement, []byte("data"), 0600); err != nil {
					t.Fatal(err)
				}
				if err := os.Chtimes(replacement, old, old); err != nil {
					t.Fatal(err)
				}
				if err := os.Rename(replacement, approved); err != nil {
					t.Fatal(err)
				}
			case "symlink replacement":
				if err := os.Remove(approved); err != nil {
					t.Fatal(err)
				}
				if err := os.Symlink(untouched, approved); err != nil {
					t.Fatal(err)
				}
			}
			_, applyErr := service.ApplyCleanup(t.Context(), plan)
			if applyErr == nil {
				t.Fatal("cleanup accepted changed state")
			}
			helper, err := startMaintenance(t.Context(), home, nil)
			if err != nil {
				t.Fatalf("revalidation failure retained ownership: %v", err)
			}
			helper.close()
			if _, err := os.Stat(untouched); err != nil {
				t.Fatalf("cleanup partially deleted candidates: %v", err)
			}
		})
	}
}

func TestKernelCleanupRefusesDatabaseLostAfterPreview(t *testing.T) {
	home := t.TempDir()
	database := filepath.Join(home, "albedo.sqlite")
	setup := `import sqlite3,sys
with sqlite3.connect(sys.argv[1]) as db:
    db.executescript("CREATE TABLE sessions(id TEXT, pinned_context TEXT); CREATE TABLE transcript(session TEXT,payload BLOB);")
`
	if out, err := exec.Command("python3", "-c", setup, database).CombinedOutput(); err != nil {
		t.Fatalf("setup database: %v %s", err, out)
	}
	kernels := filepath.Join(home, "kernels")
	if err := os.Mkdir(kernels, 0700); err != nil {
		t.Fatal(err)
	}
	candidate := filepath.Join(kernels, "orphan.state")
	if err := os.WriteFile(candidate, []byte("retain"), 0600); err != nil {
		t.Fatal(err)
	}
	old := time.Now().Add(-31 * 24 * time.Hour)
	if err := os.Chtimes(candidate, old, old); err != nil {
		t.Fatal(err)
	}
	service := testService(home)
	plan, planErr := service.PlanCleanup(t.Context(), CleanupOptions{OldKernels: true})
	if planErr != nil {
		t.Fatal(planErr)
	}
	if err := os.Remove(database); err != nil {
		t.Fatal(err)
	}
	if _, err := service.ApplyCleanup(t.Context(), plan); err == nil || !strings.Contains(err.Error(), "database disappeared") {
		t.Fatalf("missing database authorized kernel deletion: %v", err)
	}
	if content, err := os.ReadFile(candidate); err != nil || string(content) != "retain" {
		t.Fatalf("kernel changed: %q, %v", content, err)
	}
	helper, err := startMaintenance(t.Context(), home, nil)
	if err != nil {
		t.Fatalf("refused cleanup retained ownership: %v", err)
	}
	helper.close()
}
