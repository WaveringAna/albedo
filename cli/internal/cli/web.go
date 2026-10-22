package cli

import (
	"errors"
	"fmt"
	"net"
	"net/http"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"time"

	"albedo/cli/internal/daemon"
	"albedo/cli/internal/webui"
	"github.com/spf13/cobra"
)

func newWeb(deps Dependencies) *cobra.Command {
	var port int
	var noOpen, save bool
	var allow []string
	command := &cobra.Command{Use: "web", Short: "open the canvas client in a browser", Long: `Serve the browser client on 127.0.0.1 and open it. The daemon is found or
started as for the terminal client. The page reaches the daemon through this
command, which keeps the daemon's token; it signs the browser in with the link
it prints, so keep that link to yourself. Stop it with Ctrl-C.

--allow opens it to devices on a network as well: it listens on this
machine's addresses inside that network and prints a link for each, and only
devices on an allowed network may connect. A network is CIDR (10.0.0.0/8) or
an address whose trailing zeros stand for any (10.0.0.0, 100.64.0.0). Repeat
it for several. --save remembers the networks given, in the daemon's settings,
for every later albedo web; --save alone forgets them. Anyone holding a link
controls the daemon, so only open it to your own devices.

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
		settings, err := daemon.GetSettings(cmd.Context(), conn)
		if err != nil {
			return err
		}
		if save {
			if err := daemon.SaveWebAllow(cmd.Context(), conn, settings.UI.ETag, allow); err != nil {
				return fmt.Errorf("cannot save the allowed networks: %w", err)
			}
		} else if len(allow) == 0 {
			allow = settings.UI.WebAllow
		}
		networks := make([]*net.IPNet, 0, len(allow))
		for _, text := range allow {
			network, err := webui.ParseNetwork(text)
			if err != nil {
				return err
			}
			networks = append(networks, network)
		}
		bind := "127.0.0.1"
		var addresses []string
		if len(networks) > 0 {
			local, err := webui.NetworkAddresses()
			if err != nil {
				return fmt.Errorf("cannot list this machine's network addresses: %w", err)
			}
			if addresses = server.Share(networks, local); len(addresses) == 0 {
				return fmt.Errorf("this machine has no address in %s", strings.Join(allow, ", "))
			}
			bind = "0.0.0.0"
		}
		listener, err := net.Listen("tcp", net.JoinHostPort(bind, strconv.Itoa(port)))
		if err != nil {
			return fmt.Errorf("cannot listen on %s:%d (use --port to pick another): %w", bind, port, err)
		}
		boundPort := listener.Addr().(*net.TCPAddr).Port
		bound := strconv.Itoa(boundPort)
		link := server.LaunchURL(net.JoinHostPort("127.0.0.1", bound))
		manifestPath := webui.ManifestPath()
		ownsManifest := true
		if existing, readErr := webui.ReadManifest(manifestPath); readErr == nil && webui.ManifestAlive(existing) {
			ownsManifest = false
		}
		if ownsManifest {
			if err := webui.WriteManifest(manifestPath, webui.Manifest{PID: os.Getpid(), Port: boundPort, URL: "http://127.0.0.1:" + bound}); err != nil {
				listener.Close()
				return fmt.Errorf("cannot write web.json: %w", err)
			}
			defer func() {
				if current, readErr := webui.ReadManifest(manifestPath); readErr == nil && current.PID == os.Getpid() {
					_ = os.Remove(manifestPath)
				}
			}()
		}
		out := cmd.OutOrStdout()
		if _, err := fmt.Fprintf(out, "albedo web is serving at %s\n", link); err != nil {
			listener.Close()
			return err
		}
		for _, address := range addresses {
			fmt.Fprintf(out, "  on the network: %s\n", server.LaunchURL(net.JoinHostPort(address, bound)))
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
	command.Flags().StringArrayVar(&allow, "allow", nil, "also serve devices on this network (CIDR, or 10.0.0.0 for 10.0.0.0/8); repeatable")
	command.Flags().BoolVar(&save, "save", false, "remember the --allow networks for later runs (alone, forget them)")
	return command
}
