package tui

import (
	"errors"
	"net/http"

	"albedo/cli/internal/daemon"
)

func operationError(err error, failure, guidance string) string {
	if _, uncertain := errors.AsType[*daemon.UncertainOutcomeError](err); uncertain {
		return guidance
	}
	return failure + err.Error()
}

// refusedConfiguration reports a change the daemon refused because the copy of
// the configuration it was conditional on is no longer the daemon's.
func refusedConfiguration(err error) bool {
	apiErr, ok := errors.AsType[*daemon.APIError](err)
	return ok && apiErr.StatusCode == http.StatusPreconditionFailed
}
