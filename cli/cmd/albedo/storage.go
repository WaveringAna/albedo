package main

import (
	"bufio"
	"cmp"
	"context"
	"encoding/json"
	"errors"
	"flag"
	"fmt"
	"io"
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"slices"
	"strings"
	"time"

	"albedo/cli/internal/config"
	"albedo/cli/internal/daemon"
)

const storageHelp = `Usage: albedo storage [--sessions | --json]
       albedo storage prune --all [--yes]
       albedo storage prune [--session ID ...] [--old-kernels]
                            [--backups] [--vacuum] [--yes]

Showing disk usage does not change any files. Use --sessions for estimates
by session, or --json for the full report.

Cleanup shows what it will change and asks for confirmation. Use --yes to
confirm without a terminal.

--all removes unused Python state files and migration backups older than
30 days, then shrinks the database. It does not delete sessions.
--session permanently deletes the selected session. Delete its child sessions
first, if it has any. This option needs Albedo running in the background.
--old-kernels removes .state files older than 30 days with no matching session.
--backups removes migration .sqlite backups older than 30 days.
--vacuum shrinks the SQLite database by reclaiming unused space. It may need
additional temporary disk space equal to the size of the database.

Stop Albedo before using --all, --old-kernels, --backups or --vacuum.
Session sizes are estimates and do not include shared images.
`

type storageSession struct {
	ID    string `json:"id"`
	Bytes int64  `json:"bytes"`
}

type storageDB struct {
	Sessions  []storageSession `json:"sessions"`
	Images    int64            `json:"images"`
	FreePages int64            `json:"free_pages"`
	PageSize  int64            `json:"page_size"`
}

type storageFile struct {
	Path  string `json:"path"`
	Bytes int64  `json:"bytes"`
}

type storagePreview struct {
	OldKernels        []storageFile `json:"old_kernels"`
	OldBackups        []storageFile `json:"old_backups"`
	DB                storageDB     `json:"db"`
	Database          int64         `json:"database"`
	WAL               int64         `json:"wal"`
	Kernels           int64         `json:"kernels"`
	Backups           int64         `json:"backups"`
	Other             int64         `json:"other"`
	RecentBackups     int64         `json:"recent_backups"`
	RecentBackupCount int           `json:"recent_backup_count"`
}

// Use Python's bundled sqlite3 instead of introducing a second SQLite engine.
// The read-only URI does not create a missing database or journal.
const inspectStorage = `import json, sqlite3, sys
from pathlib import Path
p = Path(sys.argv[1])
if not p.is_file():
    print(json.dumps({'sessions': [], 'images': 0, 'free_pages': 0, 'page_size': 0}))
    sys.exit(0)
db = sqlite3.connect(p.as_uri() + '?mode=ro', uri=True)
db.execute('PRAGMA query_only=ON')
tables = {row[0] for row in db.execute("SELECT name FROM sqlite_master WHERE type='table'")}
sessions = []
if 'sessions' in tables:
    for sid, pinned in db.execute('SELECT id, length(pinned_context) FROM sessions'):
        sessions.append({'id': sid, 'bytes': pinned or 0})
if 'transcript' in tables:
    sizes = dict(db.execute('SELECT session, COALESCE(sum(length(payload)),0) FROM transcript GROUP BY session'))
    for session in sessions:
        session['bytes'] += sizes.get(session['id'], 0)
if 'cells' in tables:
    traces = 'LEFT JOIN cell_traces t ON t.id=c.id' if 'cell_traces' in tables else ''
    trace_bytes = 'COALESCE(length(t.payload),0)' if traces else '0'
    sql = ('SELECT c.session, COALESCE(sum(length(c.source) + '
        'COALESCE(length(c.payload),0) + ' + trace_bytes + '),0) '
        'FROM cells c ' + traces + ' GROUP BY c.session')
    sizes = dict(db.execute(sql))
    for session in sessions:
        session['bytes'] += sizes.get(session['id'], 0)
images = db.execute('SELECT COALESCE(sum(length(data)),0) FROM images').fetchone()[0] if 'images' in tables else 0
print(json.dumps({'sessions': sessions, 'images': images,
    'free_pages': db.execute('PRAGMA freelist_count').fetchone()[0],
    'page_size': db.execute('PRAGMA page_size').fetchone()[0]}))
`

func sqliteStorage(path string) (storageDB, error) {
	var db storageDB
	out, err := exec.Command("python3", "-c", inspectStorage, path).CombinedOutput()
	if err != nil {
		return db, fmt.Errorf("read disk usage from the database: %w: %s", err, strings.TrimSpace(string(out)))
	}
	if err := json.Unmarshal(out, &db); err != nil {
		return db, fmt.Errorf("decode the database disk usage report: %w", err)
	}
	return db, nil
}

func regularSize(path string) (int64, error) {
	info, err := os.Lstat(path)
	if errors.Is(err, os.ErrNotExist) {
		return 0, nil
	}
	if err != nil {
		return 0, err
	}
	if !info.Mode().IsRegular() {
		return 0, fmt.Errorf("expected a file, but found a different kind of entry: %s", path)
	}
	return info.Size(), nil
}

func storageFiles(dir string, eligible func(string, os.FileInfo) bool) (int64, []storageFile, error) {
	stat, err := os.Lstat(dir)
	if errors.Is(err, os.ErrNotExist) {
		return 0, nil, nil
	}
	if err != nil {
		return 0, nil, err
	}
	if !stat.IsDir() {
		return 0, nil, fmt.Errorf("expected a directory for storage: %s", dir)
	}
	entries, err := os.ReadDir(dir)
	if err != nil {
		return 0, nil, err
	}
	var total int64
	var candidates []storageFile
	for _, entry := range entries {
		info, err := entry.Info()
		if err != nil {
			return 0, nil, err
		}
		if !info.Mode().IsRegular() {
			continue
		}
		total += info.Size()
		if eligible(entry.Name(), info) {
			candidates = append(candidates, storageFile{filepath.Join(dir, entry.Name()), info.Size()})
		}
	}
	return total, candidates, nil
}

func storageSnapshot(home string, now time.Time) (storagePreview, error) {
	var p storagePreview
	root, err := os.Lstat(home)
	if errors.Is(err, os.ErrNotExist) {
		return p, nil
	}
	if err != nil {
		return p, err
	}
	if !root.IsDir() {
		return p, fmt.Errorf("ALBEDO_HOME must be a directory: %s", home)
	}
	dbPath := filepath.Join(home, "albedo.sqlite")
	if p.Database, err = regularSize(dbPath); err != nil {
		return p, err
	}
	for _, suffix := range []string{"-wal", "-shm"} {
		size, sizeErr := regularSize(dbPath + suffix)
		if sizeErr != nil {
			return p, sizeErr
		}
		p.WAL += size
	}
	if p.DB, err = sqliteStorage(dbPath); err != nil {
		return p, err
	}
	known := make(map[string]bool)
	for _, session := range p.DB.Sessions {
		known[session.ID] = true
	}
	cutoff := now.Add(-30 * 24 * time.Hour)
	p.Kernels, p.OldKernels, err = storageFiles(filepath.Join(home, "kernels"), func(name string, info os.FileInfo) bool {
		return strings.HasSuffix(name, ".state") && !known[strings.TrimSuffix(name, ".state")] && info.ModTime().Before(cutoff)
	})
	if err != nil {
		return p, err
	}
	p.Backups, p.OldBackups, err = storageFiles(filepath.Join(home, "backups"), func(name string, info os.FileInfo) bool {
		if !strings.HasPrefix(name, "albedo-before-image-store-") || !strings.HasSuffix(name, ".sqlite") {
			return false
		}
		if info.ModTime().Before(cutoff) {
			return true
		}
		p.RecentBackups += info.Size()
		p.RecentBackupCount++
		return false
	})
	if err != nil {
		return p, err
	}
	entries, err := os.ReadDir(home)
	if err != nil {
		return p, err
	}
	for _, entry := range entries {
		if entry.Name() == "kernels" || entry.Name() == "backups" || entry.Name() == "albedo.sqlite" || entry.Name() == "albedo.sqlite-wal" || entry.Name() == "albedo.sqlite-shm" {
			continue
		}
		info, err := entry.Info()
		if err != nil {
			return p, err
		}
		if info.Mode().IsRegular() {
			p.Other += info.Size()
		}
	}
	return p, nil
}

func storageSize(bytes int64) string {
	if bytes < 1024 {
		return fmt.Sprintf("%d B", bytes)
	}
	value := float64(bytes)
	for _, unit := range []string{"KiB", "MiB", "GiB", "TiB"} {
		value /= 1024
		if value < 1024 || unit == "TiB" {
			return fmt.Sprintf("%.1f %s", value, unit)
		}
	}
	return ""
}

func storagePrint(w io.Writer, p storagePreview, sessions bool) {
	fmt.Fprintf(w, "Database: %s · %s of unused space can be reclaimed with --vacuum\n", storageSize(p.Database), storageSize(p.DB.FreePages*p.DB.PageSize))
	fmt.Fprintf(w, "Shared images: %s (each image is stored once)\n", storageSize(p.DB.Images))
	fmt.Fprintf(w, "Backups: %s · %d recent migration backups (%s) are kept for 30 days, including with --all\n",
		storageSize(p.Backups), p.RecentBackupCount, storageSize(p.RecentBackups))
	fmt.Fprintf(w, "Database working files: %s · Python state: %s · other files: %s · sessions: %d\n",
		storageSize(p.WAL), storageSize(p.Kernels), storageSize(p.Other), len(p.DB.Sessions))
	var kernels, backups int64
	for _, f := range p.OldKernels {
		kernels += f.Bytes
	}
	for _, f := range p.OldBackups {
		backups += f.Bytes
	}
	fmt.Fprintf(w, "Available to clean up: %d unused Python state files (%s), %d old backups (%s)\n", len(p.OldKernels), storageSize(kernels), len(p.OldBackups), storageSize(backups))
	if sessions {
		slices.SortFunc(p.DB.Sessions, func(a, b storageSession) int { return cmp.Compare(b.Bytes, a.Bytes) })
		for _, s := range p.DB.Sessions {
			fmt.Fprintf(w, "  %s  %s\n", storageSize(s.Bytes), s.ID)
		}
	}
}

func storageHint(w io.Writer) {
	fmt.Fprintln(w, "For session sizes, run albedo storage --sessions. For JSON, run albedo storage --json.")
	fmt.Fprintln(w, "To clean up, stop Albedo after its work has finished with albedo daemon --stop, then run albedo storage prune --all. This does not delete sessions.")
}

func pruneFiles(files []storageFile) error {
	for _, f := range files {
		size, err := regularSize(f.Path)
		if err != nil {
			return err
		}
		if size != f.Bytes {
			return fmt.Errorf("file changed after the preview; cleanup stopped: %s", f.Path)
		}
		if err := os.Remove(f.Path); err != nil {
			return err
		}
	}
	return nil
}

func storageCommand(args []string) error {
	home := config.HomeDir()
	if len(args) > 0 && (args[0] == "-h" || args[0] == "--help") {
		fmt.Print(storageHelp)
		return nil
	}
	if len(args) == 0 || args[0] == "--json" || args[0] == "--sessions" {
		if len(args) > 1 {
			return errors.New("usage: albedo storage [--sessions | --json]")
		}
		p, err := storageSnapshot(home, time.Now())
		if err != nil {
			return err
		}
		if len(args) == 1 && args[0] == "--json" {
			data, err := json.MarshalIndent(p, "", "  ")
			if err != nil {
				return err
			}
			fmt.Println(string(data))
		} else {
			storagePrint(os.Stdout, p, len(args) == 1 && args[0] == "--sessions")
			storageHint(os.Stdout)
		}
		return nil
	}
	if args[0] != "prune" {
		return errors.New("run albedo storage to see disk usage, or albedo storage prune --help for cleanup options")
	}
	if len(args) == 2 && (args[1] == "-h" || args[1] == "--help") {
		fmt.Print(storageHelp)
		return nil
	}
	flags := flag.NewFlagSet("storage prune", flag.ContinueOnError)
	flags.SetOutput(io.Discard)
	var sessions sessionIDs
	flags.Var(&sessions, "session", "session ID to delete (repeatable)")
	all := flags.Bool("all", false, "clean eligible files and vacuum, never delete sessions")
	kernels := flags.Bool("old-kernels", false, "remove old orphan snapshots")
	backups := flags.Bool("backups", false, "remove old migration backups")
	vacuum := flags.Bool("vacuum", false, "reclaim SQLite pages")
	yes := flags.Bool("yes", false, "confirm without terminal")
	if err := flags.Parse(args[1:]); err != nil {
		return err
	}
	if flags.NArg() != 0 {
		return errors.New("cleanup only accepts options; run albedo storage prune --help for examples")
	}
	if *all {
		if len(sessions) > 0 || *kernels || *backups || *vacuum {
			return errors.New("--all cannot be combined with other cleanup options; use --all on its own or choose individual options")
		}
		*kernels, *backups, *vacuum = true, true, true
	}
	if len(sessions) == 0 && !*kernels && !*backups && !*vacuum {
		return errors.New("choose what to clean up: --all, --session, --old-kernels, --backups or --vacuum")
	}
	if len(sessions) > 0 && (*kernels || *backups || *vacuum) {
		return errors.New("delete sessions and clean up local files in separate commands; session deletion needs Albedo running, file cleanup needs it stopped")
	}
	p, err := storageSnapshot(home, time.Now())
	if err != nil {
		return err
	}
	if len(sessions) == 0 {
		if *kernels && p.Database == 0 {
			return errors.New("cannot identify unused Python state files without the SQLite database; no files have been removed")
		}
		conn, existingErr := daemon.Existing(home)
		if existingErr != nil {
			return existingErr
		}
		if conn != nil {
			return errors.New("cleanup needs Albedo stopped; no files have been removed; when its work has finished, run albedo daemon --stop, then try again")
		}
	}
	storagePrint(os.Stdout, p, false)
	if len(sessions) > 0 {
		known := make(map[string]bool)
		for _, s := range p.DB.Sessions {
			known[s.ID] = true
		}
		for _, id := range sessions {
			if !known[id] {
				return fmt.Errorf("no session has the ID %s; use the full ID from albedo sessions", id)
			}
			fmt.Printf("Permanently delete session %s\n", id)
		}
	} else {
		if *all {
			fmt.Printf("Remove %d unused Python state files and %d old backups. Keep %d recent migration backups and all sessions.\n",
				len(p.OldKernels), len(p.OldBackups), p.RecentBackupCount)
		} else {
			if *kernels {
				for _, f := range p.OldKernels {
					fmt.Printf("Remove %s\n", f.Path)
				}
			}
			if *backups {
				for _, f := range p.OldBackups {
					fmt.Printf("Remove %s\n", f.Path)
				}
			}
		}
		if *vacuum {
			fmt.Printf("Shrink the database to reclaim up to %s of unused disk space.\n",
				storageSize(p.DB.FreePages*p.DB.PageSize))
		}
	}
	if !*yes {
		if !isTTY() {
			return errors.New("no files have been removed; run cleanup in a terminal to confirm, or add --yes to approve the changes shown above")
		}
		if len(sessions) > 0 {
			fmt.Print("Permanently delete the sessions listed above? [y/N] ")
		} else {
			fmt.Print("Apply the cleanup shown above? [y/N] ")
		}
		answer, readErr := bufio.NewReader(os.Stdin).ReadString('\n')
		if readErr != nil && !errors.Is(readErr, io.EOF) {
			return readErr
		}
		if !confirmed(answer) {
			return nil
		}
	}
	if len(sessions) > 0 {
		conn, ensureErr := daemon.Ensure(home, findProjectRoot(), replaceStale)
		if ensureErr != nil {
			return ensureErr
		}
		for _, id := range sessions {
			path := "/sessions/" + id
			if _, deleteErr := daemon.RequestMethod[json.RawMessage](context.Background(), conn, "DELETE", path, nil); deleteErr != nil {
				return deleteErr
			}
		}
		return nil
	}
	// Check again after confirmation, before touching any local file.
	conn, err := daemon.Existing(home)
	if err != nil {
		return err
	}
	if conn != nil {
		return errors.New("daemon started while you were confirming cleanup; no files have been removed; stop Albedo and try again")
	}
	fresh, err := storageSnapshot(home, time.Now())
	if err != nil {
		return err
	}
	if *kernels {
		if !slices.Equal(p.OldKernels, fresh.OldKernels) {
			return errors.New("unused Python state files changed after the preview; no files have been removed; run cleanup again to review the new list")
		}
		if err := pruneFiles(p.OldKernels); err != nil {
			return err
		}
	}
	if *backups {
		if !slices.Equal(p.OldBackups, fresh.OldBackups) {
			return errors.New("backups changed after the preview; no backups have been removed; run cleanup again to review the new list")
		}
		if err := pruneFiles(p.OldBackups); err != nil {
			return err
		}
	}
	if *vacuum {
		if fresh.Database == 0 {
			return errors.New("no SQLite database to shrink")
		}
		if fresh.DB.FreePages == 0 {
			fmt.Println("The database has no unused space to reclaim. Skipping --vacuum.")
		} else {
			path := filepath.Join(home, "albedo.sqlite")
			out, err := exec.Command("python3", "-c", "import sqlite3,sys; db=sqlite3.connect(sys.argv[1]); db.execute('VACUUM'); db.close()", path).CombinedOutput()
			if err != nil {
				return fmt.Errorf("shrink the database: %w: %s", err, strings.TrimSpace(string(out)))
			}
			final, err := regularSize(path)
			if err != nil {
				return err
			}
			fmt.Printf("Database shrunk from %s to %s (%s reclaimed). Shared images are still stored once.\n",
				storageSize(fresh.Database), storageSize(final), storageSize(max(0, fresh.Database-final)))
		}
	}
	return nil
}

type sessionIDs []string

var storageID = regexp.MustCompile(`^[0-9a-f]{32}$`)

func (ids *sessionIDs) String() string { return strings.Join(*ids, ",") }
func (ids *sessionIDs) Set(value string) error {
	if !storageID.MatchString(value) {
		return errors.New("--session needs a full session ID; find it with albedo sessions")
	}
	if slices.Contains(*ids, value) {
		return fmt.Errorf("session %s was selected more than once", value)
	}
	*ids = append(*ids, value)
	return nil
}
