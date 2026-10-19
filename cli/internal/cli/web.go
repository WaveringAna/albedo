package cli

import (
	"errors"
	"fmt"
	"net"
	"net/http"
	"os"
	"path/filepath"
	"strconv"
	"time"

	"albedo/cli/internal/webui"
	"github.com/spf13/cobra"
)

func newWeb(deps Dependencies) *cobra.Command {
	var port int
	var noOpen bool
	command := &cobra.Command{Use: "web", Short: "open the canvas client in a browser", Long: `Serve the browser client on 127.0.0.1 and open it. The daemon is found or
started as for the terminal client. The page reaches the daemon through this
command, which keeps the daemon's token; it signs the browser in with the link
it prints, so keep that link to yourself. Stop it with Ctrl-C.

The client is read from web/dist in the albedo checkout, or from ALBEDO_WEB_DIST.`, Args: cobra.NoArgs, RunE: func(cmd *cobra.Command, _ []string) error {
		dist := os.Getenv("ALBEDO_WEB_DIST")
		if dist == "" {
			dist = filepath.Join(deps.ProjectRoot, "web", "dist")
		}
		conn, err := deps.Application.Connect(cmd.Context())
		if err != nil {
			return err
		}
		server, err := webui.New(dist, conn)
		if err != nil {
			return err
		}
		listener, err := net.Listen("tcp", net.JoinHostPort("127.0.0.1", strconv.Itoa(port)))
		if err != nil {
			return fmt.Errorf("cannot listen on 127.0.0.1:%d (use --port to pick another): %w", port, err)
		}
		link := server.LaunchURL(listener.Addr().String())
		if _, err := fmt.Fprintf(cmd.OutOrStdout(), "albedo web is serving at %s\n", link); err != nil {
			listener.Close()
			return err
		}
		if !noOpen && deps.Terminal != nil && deps.Terminal.OpenBrowser != nil {
			deps.Terminal.OpenBrowser(link)
		}
		httpServer := &http.Server{Handler: server, ReadHeaderTimeout: 10 * time.Second}
		go func() {
			<-cmd.Context().Done()
			httpServer.Close()
		}()
		if err := httpServer.Serve(listener); !errors.Is(err, http.ErrServerClosed) {
			return err
		}
		return nil
	}}
	command.Flags().IntVar(&port, "port", 4317, "port to serve on; 0 picks a free one")
	command.Flags().BoolVar(&noOpen, "no-open", false, "print the link without opening a browser")
	return command
}
