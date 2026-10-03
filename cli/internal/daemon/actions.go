package daemon

import (
	"context"
	"fmt"
	"net/http"
	"time"
)

const completedActionTimeout = 200 * time.Second

type ReloadRequest struct {
	Target string `json:"target"`
}

type SessionReloadResult = wireReloadResult
type KernelUpgradeResult = wireKernelUpgradeResult
type CompactionResult = wireCompactionResult

func ReloadSession(ctx context.Context, conn *Connection, id string, request ReloadRequest) (SessionReloadResult, error) {
	var w wireReloadResult
	err := executeMutation(ctx, conn, operation{Name: "reload session", Method: http.MethodPost, Path: sessionPath(id, "/reload"), Body: request, Policy: noRecovery, Timeout: completedActionTimeout}, []int{200}, func(data []byte, _ int) error {
		if err := decodeRequired(data, &w, "session", "models", "cache_policy"); err != nil {
			return err
		}
		if w.CachePolicy != nil && (w.CachePolicy.State != "refreshed" && w.CachePolicy.State != "failed" || (w.CachePolicy.State == "failed") != (w.CachePolicy.Failure != nil)) {
			return fieldError("cache policy reload outcome")
		}
		return nil
	})
	return w, err
}

func (r wireReloadResult) Message() string {
	message := "Reload completed."
	if r.Session != nil {
		if r.Session.State != "applied" {
			message = "Session reload " + r.Session.State + "."
		}
		if r.Session.RestartRequired {
			message += " Kernel restart required."
		}
		if r.Session.Failure != nil {
			message = r.Session.Failure.Detail
		}
		for _, warning := range r.Session.Warnings {
			message += " " + warning.Detail
		}
	}
	for _, model := range r.Models {
		if model.Failure != nil {
			message += " " + model.Failure.Detail
		}
	}
	if r.CachePolicy != nil && r.CachePolicy.Failure != nil {
		message += " Cache policy reload failed: " + r.CachePolicy.Failure.Detail
	}
	return message
}
func UpgradeKernel(ctx context.Context, conn *Connection, id string) (KernelUpgradeResult, error) {
	var w wireKernelUpgradeResult
	err := executeMutation(ctx, conn, operation{Name: "upgrade kernel", Method: http.MethodPost, Path: sessionPath(id, "/kernel/upgrade"), Body: struct{}{}, Policy: noRecovery, Timeout: completedActionTimeout}, []int{200}, func(data []byte, _ int) error {
		return decodeRequired(data, &w, "old_build", "new_build", "state", "stopped_jobs", "warnings", "failure", "old_kernel_id", "new_kernel_id")
	})
	return w, err
}

func (r wireKernelUpgradeResult) Message() string {
	message := fmt.Sprintf("Kernel %s; %d background jobs stopped.", r.State, len(r.StoppedJobs))
	for _, warning := range r.Warnings {
		message += " " + warning.Detail
	}
	if r.Failure != nil {
		message += " " + r.Failure.Detail
	}
	return message
}
func CompactSession(ctx context.Context, conn *Connection, id, strategy string) (CompactionResult, error) {
	body := map[string]any{}
	if strategy != "" {
		body["strategy"] = strategy
	}
	var w wireCompactionResult
	err := executeMutation(ctx, conn, operation{Name: "compact session", Method: http.MethodPost, Path: sessionPath(id, "/compaction"), Body: body, Policy: noRecovery, Timeout: completedActionTimeout}, []int{200}, func(data []byte, _ int) error {
		return decodeRequired(data, &w, "selection_applied", "effective_strategy", "state", "observation", "failure")
	})
	return w, err
}

func (r wireCompactionResult) Message() string {
	message := "Context " + r.State + "."
	if r.Observation != nil {
		message += fmt.Sprintf(" %d entries evicted.", r.Observation.EvictedEntries)
	}
	if r.Failure != nil {
		message += " " + r.Failure.Detail
	}
	return message
}
