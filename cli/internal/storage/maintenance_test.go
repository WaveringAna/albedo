// The readiness handshake makes ownership and confirmation races deterministic.
// E2E cannot pause Go's apply call between helper capture and authorization.
package storage

import (
	"albedo/cli/internal/daemon"
	"context"
	"errors"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func TestMaintenanceOwnershipAndRelease(t *testing.T) {
	for _, ending := range []string{"success", "cancel", "helper killed", "input EOF", "replacement", "vacuum failure", "deletion failure", "no free pages"} {
		t.Run(ending, func(t *testing.T) {
			if ending == "deletion failure" && os.Geteuid() == 0 {
				t.Skip("root can unlink files in a directory without write permission")
			}
			home := t.TempDir()
			directory := filepath.Join(home, "candidates")
			if err := os.Mkdir(directory, 0700); err != nil {
				t.Fatal(err)
			}
			path := filepath.Join(directory, "candidate")
			if err := os.WriteFile(path, []byte("data"), 0600); err != nil {
				t.Fatal(err)
			}
			ctx, cancel := context.WithCancel(t.Context())
			defer cancel()
			helper, err := testService(home).startMaintenance(ctx, []daemon.StorageFile{{Path: path, Bytes: 4}})
			if err != nil {
				t.Fatal(err)
			}
			defer helper.close()
			if other, acquireErr := testService(home).startMaintenance(t.Context(), nil); acquireErr == nil {
				other.close()
				t.Fatal("second cleanup acquired ownership")
			} else if !strings.Contains(acquireErr.Error(), "storage is in use") {
				t.Fatal(acquireErr)
			}
			switch ending {
			case "success":
				_, err = helper.apply(ctx, false, daemon.StorageReport{})
			case "cancel":
				cancel()
				_, err = helper.apply(ctx, false, daemon.StorageReport{})
				if !errors.Is(err, context.Canceled) {
					t.Fatalf("lost cancellation: %v", err)
				}
			case "helper killed":
				if err = helper.command.Process.Kill(); err != nil {
					t.Fatal(err)
				}
				_, err = helper.apply(ctx, false, daemon.StorageReport{})
			case "input EOF":
				if err = helper.input.Close(); err != nil {
					t.Fatal(err)
				}
				err = helper.command.Wait()
				helper.waited = true
			case "replacement":
				replacement := filepath.Join(home, "replacement")
				if err = os.WriteFile(replacement, []byte("else"), 0600); err != nil {
					t.Fatal(err)
				}
				if err = os.Rename(replacement, path); err != nil {
					t.Fatal(err)
				}
				_, err = helper.apply(ctx, false, daemon.StorageReport{})
			case "deletion failure":
				if err = os.Chmod(directory, 0500); err != nil {
					t.Fatal(err)
				}
				defer os.Chmod(directory, 0700)
				_, err = helper.apply(ctx, false, daemon.StorageReport{})
			case "vacuum failure":
				_, err = helper.apply(ctx, true, daemon.StorageReport{Database: 4096, DB: daemon.StorageDatabase{FreePages: 1}})
			case "no free pages":
				var result CleanupResult
				result, err = helper.apply(ctx, true, daemon.StorageReport{Database: 4096})
				if !result.VacuumSkipped || result.Vacuumed {
					t.Fatalf("unexpected vacuum result: %+v", result)
				}
			}
			wantFailure := ending == "cancel" || ending == "helper killed" || ending == "replacement" || ending == "vacuum failure" || ending == "deletion failure"
			if (err != nil) != wantFailure {
				t.Fatalf("%s: %v", ending, err)
			}
			helper.close()
			deleted := ending == "success" || ending == "vacuum failure" || ending == "no free pages"
			_, statErr := os.Lstat(path)
			if os.IsNotExist(statErr) != deleted {
				t.Fatalf("unexpected candidate state: %v", statErr)
			}
			next, err := testService(home).startMaintenance(t.Context(), nil)
			if err != nil {
				t.Fatalf("ownership not released: %v", err)
			}
			next.close()
		})
	}
}

func TestCleanupRequiresOwnershipBeforeRevalidation(t *testing.T) {
	home := t.TempDir()
	service := testService(home)
	plan, err := service.PlanCleanup(t.Context(), CleanupOptions{Backups: true})
	if err != nil {
		t.Fatal(err)
	}
	helper, err := testService(home).startMaintenance(t.Context(), nil)
	if err != nil {
		t.Fatal(err)
	}
	defer helper.close()
	// Revalidation would fail on this directory. Contention must win first.
	if err := os.Mkdir(filepath.Join(home, "albedo.sqlite"), 0700); err != nil {
		t.Fatal(err)
	}
	if _, err := service.ApplyCleanup(t.Context(), plan); err == nil || !strings.Contains(err.Error(), "storage is in use") {
		t.Fatalf("did not acquire before report: %v", err)
	}
}
