package cli

import (
	"fmt"
	"os"
	"os/signal"
	"strings"
	"syscall"

	"albedo/cli/internal/storage"
	"github.com/spf13/cobra"
)

func newStorage(deps Dependencies) *cobra.Command {
	var asJSON, sessions bool
	command := &cobra.Command{Use: "storage", Short: "show disk usage or clean up selected data", Args: cobra.NoArgs, RunE: func(cmd *cobra.Command, _ []string) error {
		preview, err := deps.Storage.Report(cmd.Context())
		if err != nil {
			return err
		}
		if asJSON {
			return writeJSON(cmd.OutOrStdout(), preview, true)
		}
		if err := storagePrint(cmd.OutOrStdout(), preview, sessions); err != nil {
			return err
		}
		return storageHint(cmd.OutOrStdout())
	}}
	command.Flags().BoolVar(&asJSON, "json", false, "print the full storage report as JSON")
	command.Flags().BoolVar(&sessions, "sessions", false, "show estimated sizes by session")
	command.MarkFlagsMutuallyExclusive("json", "sessions")
	command.AddCommand(newPrune(deps))
	return command
}
func newPrune(deps Dependencies) *cobra.Command {
	var options storage.CleanupOptions
	var yes bool
	command := &cobra.Command{Use: "prune", Short: "preview and confirm storage cleanup", Long: `Preview storage cleanup and ask for confirmation. --yes approves the preview without a terminal.

--all removes unused Python state files and migration backups older than 30 days,
then shrinks the database. It keeps all sessions and recent backups.
Session deletion requires the daemon; delete child sessions first.
Stop Albedo before cleaning local files or shrinking SQLite. Vacuum may require
temporary disk space equal to the database size. Session sizes exclude shared images.`, Args: cobra.NoArgs, RunE: func(cmd *cobra.Command, _ []string) error {
		plan, err := deps.Storage.PlanCleanup(cmd.Context(), options)
		if err != nil {
			return err
		}
		if renderErr := renderCleanup(cmd, plan); renderErr != nil {
			return renderErr
		}
		if !yes {
			approved, confirmErr := deps.Terminal.ConfirmCleanup(len(options.Sessions) > 0)
			if confirmErr != nil {
				return confirmErr
			}
			if !approved {
				return nil
			}
		}
		ctx, stop := signal.NotifyContext(cmd.Context(), os.Interrupt, syscall.SIGTERM)
		defer stop()
		result, err := deps.Storage.ApplyCleanup(ctx, plan)
		if err != nil {
			return err
		}
		if result.VacuumSkipped {
			_, err = fmt.Fprintln(cmd.OutOrStdout(), "The database has no unused space to reclaim. Skipping --vacuum.")
		}
		if result.Vacuumed {
			_, err = fmt.Fprintf(cmd.OutOrStdout(), "Database shrunk from %s to %s (%s reclaimed). Shared images are still stored once.\n", storageSize(result.Before), storageSize(result.After), storageSize(max(0, result.Before-result.After)))
		}
		return err
	}}
	command.Flags().StringArrayVar(&options.Sessions, "session", nil, "full session ID to permanently delete (repeatable)")
	command.Flags().BoolVar(&options.All, "all", false, "clean eligible files and vacuum; keep sessions")
	command.Flags().BoolVar(&options.OldKernels, "old-kernels", false, "remove orphan .state files older than 30 days")
	command.Flags().BoolVar(&options.Backups, "backups", false, "remove migration SQLite backups older than 30 days")
	command.Flags().BoolVar(&options.Vacuum, "vacuum", false, "reclaim unused SQLite pages")
	command.Flags().BoolVar(&yes, "yes", false, "approve the preview without a terminal")
	return command
}
func renderCleanup(cmd *cobra.Command, plan storage.CleanupPlan) error {
	preview, options := plan.Preview(), plan.Options()
	if err := storagePrint(cmd.OutOrStdout(), preview, false); err != nil {
		return err
	}
	var text strings.Builder
	if len(options.Sessions) > 0 {
		for _, id := range options.Sessions {
			fmt.Fprintf(&text, "Permanently delete session %s\n", id)
		}
	} else {
		if options.All {
			fmt.Fprintf(&text, "Remove %d unused Python state files and %d old backups. Keep %d recent migration backups and all sessions.\n", len(preview.OldKernels), len(preview.OldBackups), preview.RecentBackupCount)
		} else {
			if options.OldKernels {
				for _, file := range preview.OldKernels {
					fmt.Fprintf(&text, "Remove %s\n", file.Path)
				}
			}
			if options.Backups {
				for _, file := range preview.OldBackups {
					fmt.Fprintf(&text, "Remove %s\n", file.Path)
				}
			}
		}
		if options.Vacuum {
			fmt.Fprintf(&text, "Shrink the database to reclaim up to %s of unused disk space.\n", storageSize(preview.DB.FreePages*preview.DB.PageSize))
		}
	}
	_, err := fmt.Fprint(cmd.OutOrStdout(), text.String())
	return err
}
