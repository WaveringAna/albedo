package storage

import (
	"albedo/cli/internal/daemon"
	"context"
	_ "embed"
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"time"
)

//go:embed diagnostic.py
var inspectStorage string

func sqliteStorage(ctx context.Context, path string) (daemon.StorageDatabase, error) {
	db := daemon.StorageDatabase{Sessions: []daemon.StorageSession{}}
	if err := ctx.Err(); err != nil {
		return db, err
	}
	scratch, err := os.MkdirTemp("", "albedo-storage-")
	if err != nil {
		return db, fmt.Errorf("create private offline storage snapshot: %w", err)
	}
	defer os.RemoveAll(scratch)
	out, err := exec.CommandContext(ctx, "python3", "-c", inspectStorage, path, scratch).CombinedOutput()
	if ctx.Err() != nil {
		return db, ctx.Err()
	}
	if errors.Is(err, exec.ErrNotFound) {
		return db, errors.New("offline storage diagnostics require Python 3; install Python or query a running daemon without --offline")
	}
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

func storageFiles(ctx context.Context, dir string, eligible func(string, os.FileInfo) bool) (int64, []daemon.StorageFile, error) {
	stat, err := os.Lstat(dir)
	if errors.Is(err, os.ErrNotExist) {
		return 0, []daemon.StorageFile{}, nil
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
	candidates := []daemon.StorageFile{}
	for _, entry := range entries {
		if err := ctx.Err(); err != nil {
			return 0, nil, err
		}
		info, err := entry.Info()
		if err != nil {
			return 0, nil, err
		}
		if !info.Mode().IsRegular() {
			continue
		}
		total += info.Size()
		if eligible(entry.Name(), info) {
			candidates = append(candidates, daemon.StorageFile{Path: filepath.Join(dir, entry.Name()), Bytes: info.Size()})
		}
	}
	return total, candidates, nil
}

func (s *Service) OfflineReport(ctx context.Context) (daemon.StorageReport, error) {
	home, now := s.Home, s.Now()
	if err := ctx.Err(); err != nil {
		return daemon.StorageReport{}, err
	}
	p := daemon.StorageReport{OldKernels: []daemon.StorageFile{}, OldBackups: []daemon.StorageFile{}, DB: daemon.StorageDatabase{Sessions: []daemon.StorageSession{}}}
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
	databaseInfo, err := os.Lstat(dbPath)
	databaseExists := err == nil
	if err != nil && !errors.Is(err, os.ErrNotExist) {
		return p, err
	}
	if databaseExists {
		if !databaseInfo.Mode().IsRegular() {
			return p, fmt.Errorf("expected a file, but found a different kind of entry: %s", dbPath)
		}
		p.Database = databaseInfo.Size()
	}
	for _, suffix := range []string{"-wal", "-shm"} {
		size, sizeErr := regularSize(dbPath + suffix)
		if sizeErr != nil {
			return p, sizeErr
		}
		p.WAL += size
	}
	if databaseExists {
		if p.DB, err = sqliteStorage(ctx, dbPath); err != nil {
			return p, err
		}
	}
	known := make(map[string]bool)
	for _, session := range p.DB.Sessions {
		known[session.ID] = true
	}
	cutoff := now.Add(-30 * 24 * time.Hour)
	p.Kernels, p.OldKernels, err = storageFiles(ctx, filepath.Join(home, "kernels"), func(name string, info os.FileInfo) bool {
		return strings.HasSuffix(name, ".state") && !known[strings.TrimSuffix(name, ".state")] && info.ModTime().Before(cutoff)
	})
	if err != nil {
		return p, err
	}
	p.Backups, p.OldBackups, err = storageFiles(ctx, filepath.Join(home, "backups"), func(name string, info os.FileInfo) bool {
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
		if err := ctx.Err(); err != nil {
			return p, err
		}
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
