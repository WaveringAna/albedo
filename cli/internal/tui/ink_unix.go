//go:build darwin || dragonfly || freebsd || linux || netbsd || openbsd

package tui

import (
	"fmt"
	"os"
	"strconv"
	"strings"
	"time"

	"github.com/charmbracelet/x/term"
	"golang.org/x/sys/unix"
)

// queryColors asks for the text and background colors and the palette entries the theme mixes from, then asks
// for the device attributes every terminal answers, so a terminal that
// ignores the color queries ends the read instead of stalling it.
func queryColors() (replyText string, restoreErr error) {
	tty, err := os.OpenFile("/dev/tty", os.O_RDWR, 0)
	if err != nil {
		return "", nil
	}
	defer tty.Close()
	// Query failures use default colors; restoration failures must reach startup.
	fd := tty.Fd()
	state, err := term.MakeRaw(fd)
	if err != nil {
		return "", nil
	}
	defer func() {
		if err := term.Restore(fd, state); err != nil {
			restoreErr = fmt.Errorf("could not restore terminal settings after color detection: %w", err)
		}
	}()
	var query strings.Builder
	query.WriteString("\x1b]10;?\x1b\\\x1b]11;?\x1b\\")
	for _, i := range queriedPalette {
		query.WriteString("\x1b]4;")
		query.WriteString(strconv.Itoa(i))
		query.WriteString(";?\x1b\\")
	}
	query.WriteString("\x1b[c")
	if _, err := tty.WriteString(query.String()); err != nil {
		return "", nil
	}
	var reply strings.Builder
	deadline := time.Now().Add(300 * time.Millisecond)
	buf := make([]byte, 256)
	for {
		left := time.Until(deadline)
		if left <= 0 {
			break
		}
		tv := unix.NsecToTimeval(int64(left))
		var ready unix.FdSet
		ready.Set(int(fd))
		n, err := unix.Select(int(fd)+1, &ready, nil, nil, &tv)
		if err == unix.EINTR {
			continue
		}
		if err != nil || n == 0 {
			break
		}
		n, err = tty.Read(buf)
		if err != nil {
			break
		}
		reply.Write(buf[:n])
		// The device-attributes answer every terminal sends closes the read.
		if da := strings.Index(reply.String(), "\x1b[?"); da >= 0 && strings.Contains(reply.String()[da:], "c") {
			break
		}
	}
	return reply.String(), nil
}
