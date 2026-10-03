// Package storage inspects local usage and applies approved, revalidated cleanup plans.
package storage

import (
	"albedo/cli/internal/daemon"
	"context"
	"errors"
	"fmt"
	"os"
	"regexp"
	"slices"
	"time"
)

// Service keeps offline inspection separate from daemon-backed session deletion.
type Service struct {
	OnlineReport   func(context.Context) (*daemon.StorageReport, error)
	Now            func() time.Time
	Running        func() (bool, error)
	DeleteSessions func(context.Context, []string) error
	Home           string
}
type CleanupOptions struct {
	Sessions                         []string
	All, OldKernels, Backups, Vacuum bool
}

// CleanupPlan exposes a copy of the preview; execution uses its private approved values.
type CleanupPlan struct {
	files   map[string]os.FileInfo
	home    string
	options CleanupOptions
	preview daemon.StorageReport
}

func (p CleanupPlan) Preview() daemon.StorageReport {
	result := p.preview
	result.DB.Sessions = slices.Clone(result.DB.Sessions)
	result.OldKernels = slices.Clone(result.OldKernels)
	result.OldBackups = slices.Clone(result.OldBackups)
	return result
}
func (p CleanupPlan) Options() CleanupOptions {
	options := p.options
	options.Sessions = slices.Clone(options.Sessions)
	return options
}

type CleanupResult struct {
	VacuumSkipped bool
	Vacuumed      bool
	Before, After int64
}

var storageID = regexp.MustCompile(`^(?:[0-9a-f]{32}|[0-9a-f]{8}-[0-9a-f]{4}-7[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12})$`)

func (s *Service) PlanCleanup(ctx context.Context, options CleanupOptions) (CleanupPlan, error) {
	var plan CleanupPlan
	options.Sessions = slices.Clone(options.Sessions)
	for i, id := range options.Sessions {
		if !storageID.MatchString(id) {
			return plan, errors.New("--session needs a full session ID; find it with albedo sessions")
		}
		if slices.Contains(options.Sessions[:i], id) {
			return plan, fmt.Errorf("session %s was selected more than once", id)
		}
	}
	if options.All {
		if len(options.Sessions) > 0 || options.OldKernels || options.Backups || options.Vacuum {
			return plan, errors.New("--all cannot be combined with other cleanup options; use --all on its own or choose individual options")
		}
		options.OldKernels, options.Backups, options.Vacuum = true, true, true
	}
	if len(options.Sessions) == 0 && !options.OldKernels && !options.Backups && !options.Vacuum {
		return plan, errors.New("choose what to clean up: --all, --session, --old-kernels, --backups or --vacuum")
	}
	if len(options.Sessions) > 0 && (options.OldKernels || options.Backups || options.Vacuum) {
		return plan, errors.New("delete sessions and clean up local files in separate commands; session deletion needs Albedo running, file cleanup needs it stopped")
	}
	var preview daemon.StorageReport
	var err error
	if len(options.Sessions) > 0 {
		if s.OnlineReport == nil {
			return plan, errors.New("session deletion needs a running daemon; start Albedo, then try again")
		}
		online, reportErr := s.OnlineReport(ctx)
		if reportErr != nil {
			return plan, reportErr
		}
		if online == nil {
			return plan, errors.New("session deletion needs a running daemon; start Albedo, then try again")
		}
		preview = *online
	} else {
		preview, err = s.OfflineReport(ctx)
	}
	if err != nil {
		return plan, err
	}
	if len(options.Sessions) == 0 {
		if options.OldKernels && preview.Database == 0 {
			return plan, errors.New("cannot identify unused Python state files without the SQLite database; no files have been removed")
		}
		running, err := s.Running()
		if err != nil {
			return plan, err
		}
		if running {
			return plan, errors.New("cleanup needs Albedo stopped; no files have been removed; when its work has finished, run albedo daemon --stop, then try again")
		}
	} else {
		for _, id := range options.Sessions {
			if !slices.ContainsFunc(preview.DB.Sessions, func(session daemon.StorageSession) bool { return session.ID == id }) {
				return plan, fmt.Errorf("no session has the ID %s; use the full ID from albedo sessions", id)
			}
		}
	}
	plan = CleanupPlan{preview: preview, options: options, home: s.Home, files: make(map[string]os.FileInfo)}
	if len(options.Sessions) > 0 {
		return plan, nil
	}
	for _, file := range append(slices.Clone(preview.OldKernels), preview.OldBackups...) {
		if err := ctx.Err(); err != nil {
			return CleanupPlan{}, err
		}
		info, err := os.Lstat(file.Path)
		if err != nil {
			return CleanupPlan{}, err
		}
		plan.files[file.Path] = info
	}
	return plan, nil
}
func (s *Service) ApplyCleanup(ctx context.Context, plan CleanupPlan) (CleanupResult, error) {
	var result CleanupResult
	if plan.home != s.Home || plan.files == nil {
		return result, errors.New("cleanup plan does not belong to this storage directory")
	}
	options, preview := plan.options, plan.preview
	if len(options.Sessions) > 0 {
		return result, s.DeleteSessions(ctx, options.Sessions)
	}
	running, err := s.Running()
	if err != nil {
		return result, err
	}
	if running {
		return result, errors.New("daemon started while you were confirming cleanup; no files have been removed; stop Albedo and try again")
	}
	var files []daemon.StorageFile
	if options.OldKernels {
		files = append(files, preview.OldKernels...)
	}
	if options.Backups {
		files = append(files, preview.OldBackups...)
	}
	helper, err := startMaintenance(ctx, s.Home, files)
	if err != nil {
		return result, err
	}
	defer helper.close()
	fresh, err := s.OfflineReport(ctx)
	if err != nil {
		if ctx.Err() != nil {
			return result, ctx.Err()
		}
		return result, err
	}
	if options.OldKernels && fresh.Database == 0 {
		return result, errors.New("database disappeared after the preview; no Python state files have been removed; restore the database and retry cleanup")
	}
	if options.OldKernels && !slices.Equal(preview.OldKernels, fresh.OldKernels) {
		return result, errors.New("unused Python state files changed after the preview; no files have been removed; run cleanup again to review the new list")
	}
	if options.Backups && !slices.Equal(preview.OldBackups, fresh.OldBackups) {
		return result, errors.New("backups changed after the preview; no backups have been removed; run cleanup again to review the new list")
	}
	// Recheck all approved candidates before deleting any, including replacements of equal size.
	for _, file := range files {
		if err := ctx.Err(); err != nil {
			return result, err
		}
		info, err := os.Lstat(file.Path)
		if err != nil {
			return result, err
		}
		approved := plan.files[file.Path]
		if !info.Mode().IsRegular() || !os.SameFile(approved, info) || info.Size() != approved.Size() || !info.ModTime().Equal(approved.ModTime()) {
			return result, fmt.Errorf("file changed after the preview; cleanup stopped: %s", file.Path)
		}
	}
	if err := ctx.Err(); err != nil {
		return result, err
	}
	return helper.apply(ctx, options.Vacuum, fresh)
}
