package storage

import (
	"albedo/cli/internal/daemon"
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"os/exec"
	"strings"
)

// maintenance owns both mutations and the lock. Closing input revokes ownership.
type maintenance struct {
	command *exec.Cmd
	input   io.WriteCloser
	output  *json.Decoder
	stderr  bytes.Buffer
	waited  bool
}

type maintenanceMessage struct {
	Result *CleanupResult `json:"result"`
	Ready  bool           `json:"ready"`
}

func (s *Service) startMaintenance(ctx context.Context, files []daemon.StorageFile) (*maintenance, error) {
	command, err := s.command(ctx, "storage", "maintain", s.Home)
	if err != nil {
		return nil, err
	}
	helper := &maintenance{command: command}
	helper.command.Stderr = &helper.stderr
	input, err := helper.command.StdinPipe()
	if err != nil {
		return nil, err
	}
	helper.input = input
	output, err := helper.command.StdoutPipe()
	if err != nil {
		_ = input.Close()
		return nil, err
	}
	helper.output = json.NewDecoder(output)
	helper.output.DisallowUnknownFields()
	if err := helper.command.Start(); err != nil {
		_ = input.Close()
		return nil, err
	}
	paths := make([]string, 0, len(files))
	for _, file := range files {
		paths = append(paths, file.Path)
	}
	if err := json.NewEncoder(input).Encode(struct {
		Paths []string `json:"paths"`
	}{paths}); err != nil {
		helper.close()
		return nil, helper.failure(ctx, err)
	}
	var message maintenanceMessage
	if err := helper.output.Decode(&message); err != nil {
		helper.close()
		return nil, helper.failure(ctx, err)
	}
	if !message.Ready || message.Result != nil {
		helper.close()
		return nil, helper.failure(ctx, errors.New("invalid maintenance readiness"))
	}
	return helper, nil
}

// close always reaps the child, including revalidation failures before authorization.
func (m *maintenance) close() {
	_ = m.input.Close()
	if !m.waited {
		_ = m.command.Process.Kill()
		_ = m.command.Wait()
		m.waited = true
	}
}

func (m *maintenance) failure(ctx context.Context, err error) error {
	if ctx.Err() != nil {
		return ctx.Err()
	}
	return fmt.Errorf("storage maintenance: %w: %s", err, strings.TrimSpace(m.stderr.String()))
}

func (m *maintenance) apply(ctx context.Context, vacuum bool, fresh daemon.StorageReport) (CleanupResult, error) {
	var result CleanupResult
	err := json.NewEncoder(m.input).Encode(struct {
		Apply     bool  `json:"apply"`
		Vacuum    bool  `json:"vacuum"`
		Before    int64 `json:"before"`
		FreePages int64 `json:"free_pages"`
	}{true, vacuum, fresh.Database, fresh.DB.FreePages})
	if err != nil {
		m.close()
		return result, m.failure(ctx, err)
	}
	var message maintenanceMessage
	if err = m.output.Decode(&message); err != nil {
		m.close()
		return result, m.failure(ctx, err)
	}
	if message.Ready || message.Result == nil {
		m.close()
		return result, m.failure(ctx, errors.New("invalid maintenance result"))
	}
	// Keep input open until the helper finishes, so its EOF watcher cannot
	// interrupt successful work. A valid result alone does not prove success.
	err = m.command.Wait()
	m.waited = true
	if ctx.Err() != nil {
		return result, ctx.Err()
	}
	if err != nil {
		return result, m.failure(ctx, err)
	}
	return *message.Result, nil
}
