package tui

import (
	"errors"

	"albedo/cli/internal/daemon"
)

func operationError(err error, failure, guidance string) string {
	if _, uncertain := errors.AsType[*daemon.UncertainOutcomeError](err); uncertain {
		return guidance
	}
	return failure + err.Error()
}
