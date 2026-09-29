package main

import (
	"albedo/cli/internal/config"
	"albedo/cli/internal/daemon"
	"bufio"
	"context"
	"encoding/json"
	"errors"
	"flag"
	"fmt"
	"io"
	"os"
	"os/exec"
	"path/filepath"
	"reflect"
	"regexp"
	"sort"
	"strings"
	"time"
)

const storageHelp = `Usage: albedo storage [--sessions | --json]
       albedo storage prune --all [--yes]
       albedo storage prune [--session ID ...] [--old-kernels]
                            [--backups] [--vacuum] [--yes]

Preview is read-only; --sessions lists per-session estimates, --json shows all data.
Prune previews first and requires confirmation (or --yes).
--all cleans eligible orphan kernels and old migration backups, then vacuums
SQLite. It NEVER deletes sessions. Stop the daemon before offline cleanup.
--session deletes exactly the selected session via the daemon. Delete child
sessions first; parent sessions with children cannot be deleted directly.
--old-kernels removes orphaned .state files older than 30 days.
--backups removes migration .sqlite backups older than 30 days.
--vacuum reclaims free SQLite pages; needs temporary space up to the DB size.
Session byte counts are approximate payload sizes, excluding shared images.
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
	Database          int64         `json:"database"`
	WAL               int64         `json:"wal"`
	Kernels           int64         `json:"kernels"`
	Backups           int64         `json:"backups"`
	Other             int64         `json:"other"`
	RecentBackups     int64         `json:"recent_backups"`
	RecentBackupCount int           `json:"recent_backup_count"`
	DB                storageDB     `json:"db"`
	OldKernels        []storageFile `json:"old_kernels"`
	OldBackups        []storageFile `json:"old_backups"`
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
		return db, fmt.Errorf("inspect SQLite: %w: %s", err, strings.TrimSpace(string(out)))
	}
	if err := json.Unmarshal(out, &db); err != nil {
		return db, fmt.Errorf("decode SQLite storage: %w", err)
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
		return 0, fmt.Errorf("not a regular file: %s", path)
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
		return 0, nil, fmt.Errorf("storage path is not a directory: %s", dir)
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
		return p, fmt.Errorf("storage home is not a directory: %s", home)
	}
	dbPath := filepath.Join(home, "albedo.sqlite")
	if p.Database, err = regularSize(dbPath); err != nil {
		return p, err
	}
	for _, suffix := range []string{"-wal", "-shm"} {
		size, err := regularSize(dbPath + suffix)
		if err != nil {
			return p, err
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
	fmt.Fprintf(w, "SQLite %s · %s freed pages reclaimable by VACUUM\n", storageSize(p.Database), storageSize(p.DB.FreePages*p.DB.PageSize))
	fmt.Fprintf(w, "Shared images %s (retained single copies, not duplication)\n", storageSize(p.DB.Images))
	fmt.Fprintf(w, "Backups %s · %d recent migration backups (%s) protected for 30 days; --all skips them\n",
		storageSize(p.Backups), p.RecentBackupCount, storageSize(p.RecentBackups))
	fmt.Fprintf(w, "WAL/SHM %s · kernels %s · other files %s · %d sessions\n",
		storageSize(p.WAL), storageSize(p.Kernels), storageSize(p.Other), len(p.DB.Sessions))
	var kernels, backups int64
	for _, f := range p.OldKernels {
		kernels += f.Bytes
	}
	for _, f := range p.OldBackups {
		backups += f.Bytes
	}
	fmt.Fprintf(w, "Eligible: %d orphan kernels (%s), %d old backups (%s)\n", len(p.OldKernels), storageSize(kernels), len(p.OldBackups), storageSize(backups))
	if sessions {
		sort.Slice(p.DB.Sessions, func(i, j int) bool { return p.DB.Sessions[i].Bytes > p.DB.Sessions[j].Bytes })
		for _, s := range p.DB.Sessions {
			fmt.Fprintf(w, "  %s  %s\n", storageSize(s.Bytes), s.ID)
		}
	}
}

func storageHint(w io.Writer) {
	fmt.Fprintln(w, "Details: albedo storage --sessions | --json")
	fmt.Fprintln(w, "Cleanup: stop the daemon, then albedo storage prune --all (never deletes sessions)")
}

func pruneFiles(files []storageFile) error {
	for _, f := range files {
		size, err := regularSize(f.Path)
		if err != nil {
			return err
		}
		if size != f.Bytes {
			return fmt.Errorf("file changed since preview: %s", f.Path)
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
		return errors.New("usage: albedo storage [--json] | storage prune --help")
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
		return errors.New("unexpected positional argument to storage prune")
	}
	if *all {
		if len(sessions) > 0 || *kernels || *backups || *vacuum {
			return errors.New("--all cannot be combined with other prune selections")
		}
		*kernels, *backups, *vacuum = true, true, true
	}
	if len(sessions) == 0 && !*kernels && !*backups && !*vacuum {
		return errors.New("select --all, --session, --old-kernels, --backups or --vacuum")
	}
	if len(sessions) > 0 && (*kernels || *backups || *vacuum) {
		return errors.New("session pruning and offline cleanup require separate invocations")
	}
	p, err := storageSnapshot(home, time.Now())
	if err != nil {
		return err
	}
	if len(sessions) == 0 {
		if *kernels && p.Database == 0 {
			return errors.New("cannot identify orphan snapshots without the SQLite database")
		}
		conn, err := daemon.Existing(home)
		if err != nil {
			return err
		}
		if conn != nil {
			return errors.New("nothing pruned: stop daemon first with albedo daemon --stop")
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
				return fmt.Errorf("session not found: %s (use full ID)", id)
			}
			fmt.Printf("DELETE session %s (permanently, via daemon)\n", id)
		}
	} else {
		if *all {
			fmt.Printf("Will remove %d eligible orphan kernels and %d old backups; retain %d recent migration backups and all sessions.\n",
				len(p.OldKernels), len(p.OldBackups), p.RecentBackupCount)
		} else {
			if *kernels {
				for _, f := range p.OldKernels {
					fmt.Printf("REMOVE %s\n", f.Path)
				}
			}
			if *backups {
				for _, f := range p.OldBackups {
					fmt.Printf("REMOVE %s\n", f.Path)
				}
			}
		}
		if *vacuum {
			fmt.Printf("Vacuum: up to %s of freed SQLite pages can be returned to disk.\n",
				storageSize(p.DB.FreePages*p.DB.PageSize))
		}
	}
	if !*yes {
		if !isTTY() {
			return errors.New("prune requires a terminal confirmation or --yes")
		}
		fmt.Print("Proceed? [y/N] ")
		answer, err := bufio.NewReader(os.Stdin).ReadString('\n')
		if err != nil && !errors.Is(err, io.EOF) {
			return err
		}
		if !confirmed(answer) {
			return nil
		}
	}
	if len(sessions) > 0 {
		conn, err := daemon.Ensure(home, findProjectRoot(), replaceStale)
		if err != nil {
			return err
		}
		for _, id := range sessions {
			path := "/sessions/" + id
			if _, err := daemon.RequestMethod[json.RawMessage](context.Background(), conn, "DELETE", path, nil); err != nil {
				return err
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
		return errors.New("daemon started during confirmation; aborting")
	}
	fresh, err := storageSnapshot(home, time.Now())
	if err != nil {
		return err
	}
	if *kernels {
		if !reflect.DeepEqual(p.OldKernels, fresh.OldKernels) {
			return errors.New("orphan snapshots changed since preview; aborting")
		}
		if err := pruneFiles(p.OldKernels); err != nil {
			return err
		}
	}
	if *backups {
		if !reflect.DeepEqual(p.OldBackups, fresh.OldBackups) {
			return errors.New("backups changed since preview; aborting")
		}
		if err := pruneFiles(p.OldBackups); err != nil {
			return err
		}
	}
	if *vacuum {
		if fresh.Database == 0 {
			return errors.New("no SQLite database to vacuum")
		}
		if fresh.DB.FreePages == 0 {
			fmt.Println("Vacuum skipped: SQLite has no free pages to reclaim.")
		} else {
			path := filepath.Join(home, "albedo.sqlite")
			out, err := exec.Command("python3", "-c", "import sqlite3,sys; db=sqlite3.connect(sys.argv[1]); db.execute('VACUUM'); db.close()", path).CombinedOutput()
			if err != nil {
				return fmt.Errorf("vacuum: %w: %s", err, strings.TrimSpace(string(out)))
			}
			final, err := regularSize(path)
			if err != nil {
				return err
			}
			fmt.Printf("Vacuum complete: SQLite %s → %s (%s reclaimed). Shared images remain stored once.\n",
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
		return errors.New("session requires a full ID")
	}
	for _, id := range *ids {
		if id == value {
			return fmt.Errorf("duplicate session %s", value)
		}
	}
	*ids = append(*ids, value)
	return nil
}
