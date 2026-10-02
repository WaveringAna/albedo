package app

import (
	"context"

	"albedo/cli/internal/daemon"
)

// StorageReport attaches to a running daemon without launching or upgrading it.
// A nil report means discovery found no running daemon.
func (s *Service) StorageReport(ctx context.Context) (*daemon.StorageReport, error) {
	conn, err := s.Existing(ctx)
	if err != nil || conn == nil {
		return nil, err
	}
	defer conn.HTTPClient().CloseIdleConnections()
	report, err := daemon.GetStorageReport(ctx, conn)
	if err != nil {
		return nil, err
	}
	return &report, nil
}
