// Package daemon provides typed API access and local daemon lifecycle operations.
package daemon

import (
	"context"
	"encoding/json"
	"net/http"
	"time"
)

type StorageFile struct {
	Path  string `json:"path"`
	Bytes int64  `json:"bytes"`
}

type StorageSession struct {
	ID    string `json:"id"`
	Bytes int64  `json:"bytes"`
}

type StorageDatabase struct {
	Sessions  []StorageSession `json:"sessions"`
	Images    int64            `json:"images"`
	FreePages int64            `json:"free_pages"`
	PageSize  int64            `json:"page_size"`
}

type StorageReport struct {
	OldKernels        []StorageFile   `json:"old_kernels"`
	OldBackups        []StorageFile   `json:"old_backups"`
	DB                StorageDatabase `json:"db"`
	Database          int64           `json:"database"`
	WAL               int64           `json:"wal"`
	Kernels           int64           `json:"kernels"`
	Backups           int64           `json:"backups"`
	Other             int64           `json:"other"`
	RecentBackups     int64           `json:"recent_backups"`
	RecentBackupCount int             `json:"recent_backup_count"`
}

func GetStorageReport(ctx context.Context, conn *Connection) (StorageReport, error) {
	if ctx == nil {
		ctx = context.Background()
	}
	ctx, cancel := context.WithTimeout(ctx, 20*time.Second)
	defer cancel()
	if err := checkCapability(ctx, conn, "storage_report", "for storage reports"); err != nil {
		return StorageReport{}, err
	}
	var result StorageReport
	err := executeRead(ctx, conn, operation{Name: "get storage report", Method: http.MethodGet, Path: "/storage/report", Policy: readRecovery}, func(data []byte) error {
		var wire struct {
			OldKernels []*storageFileWire `json:"old_kernels"`
			OldBackups []*storageFileWire `json:"old_backups"`
			DB         *struct {
				Sessions []*struct {
					ID    *string `json:"id"`
					Bytes *int64  `json:"bytes"`
				} `json:"sessions"`
				Images    *int64 `json:"images"`
				FreePages *int64 `json:"free_pages"`
				PageSize  *int64 `json:"page_size"`
			} `json:"db"`
			Database          *int64 `json:"database"`
			WAL               *int64 `json:"wal"`
			Kernels           *int64 `json:"kernels"`
			Backups           *int64 `json:"backups"`
			Other             *int64 `json:"other"`
			RecentBackups     *int64 `json:"recent_backups"`
			RecentBackupCount *int   `json:"recent_backup_count"`
		}
		if err := json.Unmarshal(data, &wire); err != nil {
			return err
		}
		if wire.DB == nil {
			return fieldError("db")
		}
		for _, field := range []struct {
			name  string
			value *int64
		}{
			{"database", wire.Database}, {"wal", wire.WAL}, {"kernels", wire.Kernels}, {"backups", wire.Backups}, {"other", wire.Other}, {"recent_backups", wire.RecentBackups},
			{"images", wire.DB.Images}, {"free_pages", wire.DB.FreePages}, {"page_size", wire.DB.PageSize},
		} {
			if field.value == nil || *field.value < 0 {
				return fieldError(field.name)
			}
		}
		if wire.RecentBackupCount == nil || *wire.RecentBackupCount < 0 {
			return fieldError("recent_backup_count")
		}
		kernels, err := decodeStorageFiles(wire.OldKernels, "old_kernels")
		if err != nil {
			return err
		}
		backups, err := decodeStorageFiles(wire.OldBackups, "old_backups")
		if err != nil {
			return err
		}
		if wire.DB.Sessions == nil {
			return fieldError("sessions")
		}
		sessions := make([]StorageSession, 0, len(wire.DB.Sessions))
		for _, row := range wire.DB.Sessions {
			if row == nil || row.ID == nil || *row.ID == "" {
				return fieldError("id")
			}
			if row.Bytes == nil || *row.Bytes < 0 {
				return fieldError("bytes")
			}
			sessions = append(sessions, StorageSession{ID: *row.ID, Bytes: *row.Bytes})
		}
		result = StorageReport{
			OldKernels: kernels,
			OldBackups: backups,
			DB: StorageDatabase{
				Sessions:  sessions,
				Images:    *wire.DB.Images,
				FreePages: *wire.DB.FreePages,
				PageSize:  *wire.DB.PageSize,
			},
			Database:          *wire.Database,
			WAL:               *wire.WAL,
			Kernels:           *wire.Kernels,
			Backups:           *wire.Backups,
			Other:             *wire.Other,
			RecentBackups:     *wire.RecentBackups,
			RecentBackupCount: *wire.RecentBackupCount,
		}
		return nil
	})
	return result, err
}

type storageFileWire struct {
	Path  *string `json:"path"`
	Bytes *int64  `json:"bytes"`
}

func decodeStorageFiles(rows []*storageFileWire, field string) ([]StorageFile, error) {
	if rows == nil {
		return nil, fieldError(field)
	}
	result := make([]StorageFile, 0, len(rows))
	for _, row := range rows {
		if row == nil || row.Path == nil || *row.Path == "" {
			return nil, fieldError("path")
		}
		if row.Bytes == nil || *row.Bytes < 0 {
			return nil, fieldError("bytes")
		}
		result = append(result, StorageFile{Path: *row.Path, Bytes: *row.Bytes})
	}
	return result, nil
}
