package storage

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"time"
)

type Session struct {
	ID    string `json:"id"`
	Bytes int64  `json:"bytes"`
}

type Database struct {
	Sessions  []Session `json:"sessions"`
	Images    int64     `json:"images"`
	FreePages int64     `json:"free_pages"`
	PageSize  int64     `json:"page_size"`
}

type File struct {
	Path  string `json:"path"`
	Bytes int64  `json:"bytes"`
}

type Preview struct {
	OldKernels        []File   `json:"old_kernels"`
	OldBackups        []File   `json:"old_backups"`
	DB                Database `json:"db"`
	Database          int64    `json:"database"`
	WAL               int64    `json:"wal"`
	Kernels           int64    `json:"kernels"`
	Backups           int64    `json:"backups"`
	Other             int64    `json:"other"`
	RecentBackups     int64    `json:"recent_backups"`
	RecentBackupCount int      `json:"recent_backup_count"`
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

func sqliteStorage(ctx context.Context, path string) (Database, error) {
	var db Database
	out, err := exec.CommandContext(ctx, "python3", "-c", inspectStorage, path).CombinedOutput()
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

func storageFiles(dir string, eligible func(string, os.FileInfo) bool) (int64, []File, error) {
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
	var candidates []File
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
			candidates = append(candidates, File{filepath.Join(dir, entry.Name()), info.Size()})
		}
	}
	return total, candidates, nil
}

func storageSnapshot(ctx context.Context, home string, now time.Time) (Preview, error) {
	var p Preview
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
	if p.DB, err = sqliteStorage(ctx, dbPath); err != nil {
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
