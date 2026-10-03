package daemon

import (
	"context"
	"io"
	"net/http"

	"albedo/cli/internal/daemon/protocol"
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
	result := StorageReport{OldKernels: []StorageFile{}, OldBackups: []StorageFile{}, DB: StorageDatabase{Sessions: []StorageSession{}}}
	params := protocol.GetStorageParams{Limit: new(int64(200))}
	seenSessions, seenFiles := map[string]bool{}, map[string]bool{}
	seenTokens := map[[2]string]bool{}
	for {
		var w protocol.StorageReport
		err := executeRead(ctx, conn, operation{Capability: "storage_report", Name: "read storage", BuildRequest: func(base string, body io.Reader) (*http.Request, error) {
			return protocol.NewGetStorageRequest(base, &params)
		}, Policy: readRecovery}, func(data []byte) error {
			return decodeRequired(data, &w, "database", "sessions", "images", "files", "measured_at")
		})
		if err != nil {
			return result, err
		}
		result.Database = w.Database.MainFileBytes
		result.WAL = w.Database.WalBytes
		result.DB.Images = w.Images.Bytes
		result.DB.FreePages = w.Database.FreePageCount
		result.DB.PageSize = w.Database.PageSizeBytes
		result.Kernels = w.Files.Totals.KernelBytes
		result.Backups = w.Files.Totals.BackupBytes
		result.Other = w.Files.Totals.OtherBytes
		result.RecentBackups = w.Files.Totals.RecentBackupBytes
		result.RecentBackupCount = int(w.Files.Totals.RecentBackupCount)
		for _, row := range w.Sessions.Items {
			if !seenSessions[row.ID] {
				seenSessions[row.ID] = true
				result.DB.Sessions = append(result.DB.Sessions, StorageSession{ID: row.ID, Bytes: row.EstimatedContentBytes})
			}
		}
		for _, row := range w.Files.Items {
			if seenFiles[row.Path] {
				continue
			}
			seenFiles[row.Path] = true
			file := StorageFile{Path: row.Path, Bytes: row.Bytes}
			if row.CleanupCandidate {
				switch row.Category {
				case "kernel":
					result.OldKernels = append(result.OldKernels, file)
				case "backup":
					result.OldBackups = append(result.OldBackups, file)
				}
			}
		}
		if w.Sessions.Next == nil && w.Files.Next == nil {
			return result, nil
		}
		if w.Sessions.Next != nil {
			params.SessionsNext = w.Sessions.Next
		}
		if w.Files.Next != nil {
			params.FilesNext = w.Files.Next
		}
		key := [2]string{value(params.SessionsNext), value(params.FilesNext)}
		if seenTokens[key] {
			return result, fieldError("storage page cursor")
		}
		seenTokens[key] = true
	}
}
