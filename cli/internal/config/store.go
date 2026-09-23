package config

import (
	"crypto/rand"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"time"
)

// lockFile takes an exclusive lock file, retrying every 20ms up to attempts
// times. The error wraps os.ErrExist when another holder kept it throughout.
func lockFile(path string, attempts int) (release func(), err error) {
	for attempt := 0; attempt < attempts; attempt++ {
		if attempt > 0 {
			time.Sleep(20 * time.Millisecond)
		}
		var file *os.File
		file, err = os.OpenFile(path, os.O_WRONLY|os.O_CREATE|os.O_EXCL, 0600)
		if err == nil {
			return func() {
				_ = file.Close()
				_ = os.Remove(path)
			}, nil
		}
		if !os.IsExist(err) {
			return nil, err
		}
	}
	return nil, err
}

// lockedUpdate prepares directory as a private store and runs update while
// holding lockName inside it.
func lockedUpdate(directory, lockName string, attempts int, update func() error) error {
	if err := os.MkdirAll(directory, 0700); err != nil {
		return err
	}
	_ = os.Chmod(directory, 0700)
	release, err := lockFile(filepath.Join(directory, lockName), attempts)
	if err != nil {
		return err
	}
	defer release()
	return update()
}

// writeJSONAtomic replaces directory/name with indented JSON, mode 0600, via a
// synced temp file so readers never see a partial write.
func writeJSONAtomic(directory, name string, value any) error {
	encoded, err := json.MarshalIndent(value, "", "  ")
	if err != nil {
		return err
	}
	encoded = append(encoded, '\n')

	randomBytes := make([]byte, 16)
	_, _ = rand.Read(randomBytes)
	stem := name[:len(name)-len(filepath.Ext(name))]
	tempPath := filepath.Join(directory, fmt.Sprintf("%s.%s.tmp", stem, hex.EncodeToString(randomBytes)))

	tempFile, err := os.OpenFile(tempPath, os.O_WRONLY|os.O_CREATE|os.O_EXCL, 0600)
	if err != nil {
		return err
	}
	defer func() {
		_ = tempFile.Close()
		_ = os.Remove(tempPath)
	}()

	if _, err := tempFile.Write(encoded); err != nil {
		return err
	}
	if err := tempFile.Sync(); err != nil {
		return err
	}
	if err := tempFile.Close(); err != nil {
		return err
	}
	return os.Rename(tempPath, filepath.Join(directory, name))
}
