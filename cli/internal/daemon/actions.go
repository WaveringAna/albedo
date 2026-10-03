package daemon

import (
	"context"
	"fmt"
	"io"
	"net/http"
	"time"

	"albedo/cli/internal/daemon/protocol"
)

const completedActionTimeout = 200 * time.Second

type ReloadRequest struct{ Target string }

type SessionReloadResult protocol.ReloadResult
type KernelUpgradeResult protocol.KernelUpgradeResult
type CompactionResult protocol.CompactionResult

func ReloadSession(ctx context.Context, conn *Connection, id string, request ReloadRequest) (SessionReloadResult, error) {
	var w protocol.ReloadResult
	err := executeMutation(ctx, conn, operation{Name: "reload session", BuildRequest: func(base string, body io.Reader) (*http.Request, error) {
		return protocol.NewReloadSessionRequestWithBody(base, id, "application/json", body)
	}, Body: protocol.ReloadRequest{Target: optionalText(request.Target)}, Policy: noRecovery, Timeout: completedActionTimeout}, []int{200}, func(data []byte, _ int) error {
		if err := decodeRequired(data, &w, "session", "models", "cache_policy"); err != nil {
			return err
		}
		if w.CachePolicy != nil && (w.CachePolicy.State != "refreshed" && w.CachePolicy.State != "failed" || (w.CachePolicy.State == "failed") != (w.CachePolicy.Failure != nil)) {
			return fieldError("cache policy reload outcome")
		}
		return nil
	})
	return SessionReloadResult(w), err
}

func (r SessionReloadResult) Message() string {
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
	var w protocol.KernelUpgradeResult
	err := executeMutation(ctx, conn, operation{Name: "upgrade kernel", BuildRequest: func(base string, body io.Reader) (*http.Request, error) {
		return protocol.NewUpgradeKernelRequestWithBody(base, id, "application/json", body)
	}, Body: struct{}{}, Policy: noRecovery, Timeout: completedActionTimeout}, []int{200}, func(data []byte, _ int) error {
		return decodeRequired(data, &w, "old_build", "new_build", "state", "stopped_jobs", "warnings", "failure", "old_kernel_id", "new_kernel_id")
	})
	return KernelUpgradeResult(w), err
}

func (r KernelUpgradeResult) Message() string {
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
	body := protocol.CompactionRequest{Strategy: optionalText(strategy)}
	var w protocol.CompactionResult
	err := executeMutation(ctx, conn, operation{Name: "compact session", BuildRequest: func(base string, body io.Reader) (*http.Request, error) {
		return protocol.NewCompactSessionRequestWithBody(base, id, "application/json", body)
	}, Body: body, Policy: noRecovery, Timeout: completedActionTimeout}, []int{200}, func(data []byte, _ int) error {
		return decodeRequired(data, &w, "selection_applied", "effective_strategy", "state", "observation", "failure")
	})
	return CompactionResult(w), err
}

func (r CompactionResult) Message() string {
	message := "Context " + r.State + "."
	if r.Observation != nil {
		message += fmt.Sprintf(" %d entries evicted.", r.Observation.EvictedEntries)
	}
	if r.Failure != nil {
		message += " " + r.Failure.Detail
	}
	return message
}
