package cli

import (
	"cmp"
	"fmt"
	"io"
	"slices"
	"strings"

	"albedo/cli/internal/daemon"
)

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

func storagePrint(w io.Writer, p daemon.StorageReport, sessions bool) error {
	var text strings.Builder
	fmt.Fprintf(&text, "Database: %s · %s of unused space can be reclaimed with --vacuum\n", storageSize(p.Database), storageSize(p.DB.FreePages*p.DB.PageSize))
	fmt.Fprintf(&text, "Shared images: %s (each image is stored once)\n", storageSize(p.DB.Images))
	fmt.Fprintf(&text, "Backups: %s · %d recent migration backups (%s) are kept for 30 days, including with --all\n",
		storageSize(p.Backups), p.RecentBackupCount, storageSize(p.RecentBackups))
	fmt.Fprintf(&text, "Database working files: %s · Python state: %s · other files: %s · sessions: %d\n",
		storageSize(p.WAL), storageSize(p.Kernels), storageSize(p.Other), len(p.DB.Sessions))
	var kernels, backups int64
	for _, f := range p.OldKernels {
		kernels += f.Bytes
	}
	for _, f := range p.OldBackups {
		backups += f.Bytes
	}
	fmt.Fprintf(&text, "Available to clean up: %d unused Python state files (%s), %d old backups (%s)\n", len(p.OldKernels), storageSize(kernels), len(p.OldBackups), storageSize(backups))
	if sessions {
		slices.SortFunc(p.DB.Sessions, func(a, b daemon.StorageSession) int { return cmp.Compare(b.Bytes, a.Bytes) })
		for _, s := range p.DB.Sessions {
			fmt.Fprintf(&text, "  %s  %s\n", storageSize(s.Bytes), s.ID)
		}
	}
	_, err := io.WriteString(w, text.String())
	return err
}

func storageHint(w io.Writer) error {
	var text strings.Builder
	fmt.Fprintln(&text, "For session sizes, run albedo storage --sessions. For JSON, run albedo storage --json.")
	fmt.Fprintln(&text, "To clean up, stop Albedo after its work has finished with albedo daemon --stop, then run albedo storage prune --all. This does not delete sessions.")
	_, err := io.WriteString(w, text.String())
	return err
}
