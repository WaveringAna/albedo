package manual

import (
	"albedo/cli/internal/daemon"
	"context"
)

func benchmarkRequest(ctx context.Context, connection *daemon.Connection, method string, body any, read bool) error {
	policy := daemon.AuthRecovery
	if read {
		policy = daemon.ReadRecovery
	}
	result, err := daemon.RequestOperation[map[string]any](ctx, connection, daemon.Operation{
		Name: "benchmark operation", Method: method, Path: "/operation", Body: body, Policy: policy,
	})
	_ = result
	return err
}
