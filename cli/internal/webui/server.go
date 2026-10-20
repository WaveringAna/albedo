// Package webui serves the browser client in web/dist and forwards its API
// calls to the daemon. The daemon token stays in this process: the browser
// proves it was opened by `albedo web` with a launch key it trades once for a
// cookie, and the proxy adds the token to each request it forwards.
package webui

import (
	"context"
	"crypto/rand"
	"crypto/subtle"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"net"
	"net/http"
	"net/http/httputil"
	"net/url"
	"os"
	"path/filepath"
	"strings"
	"time"

	"albedo/cli/internal/daemon"
)

const cookieName = "albedo_web"

// Upstream is the daemon endpoint the proxy forwards to. *daemon.Connection
// implements it; Refresh finds a restarted daemon.
type Upstream interface {
	Snapshot() daemon.ConnectionSnapshot
	Refresh(context.Context) error
}

type Server struct {
	dist     string
	key      string
	hosts    map[string]bool
	clients  []*net.IPNet
	upstream Upstream
	proxy    *httputil.ReverseProxy
	static   http.Handler
}

// New checks that dist holds a built client and draws a fresh launch key.
func New(dist string, upstream Upstream) (*Server, error) {
	if _, err := os.Stat(filepath.Join(dist, "index.html")); err != nil {
		return nil, fmt.Errorf("the web client is not built (%s has no index.html); run npm ci && npm run build in web/", dist)
	}
	raw := make([]byte, 24)
	if _, err := rand.Read(raw); err != nil {
		return nil, err
	}
	s := &Server{dist: dist, key: hex.EncodeToString(raw), hosts: map[string]bool{"127.0.0.1": true, "localhost": true}, upstream: upstream, static: http.FileServer(http.Dir(dist))}
	s.proxy = &httputil.ReverseProxy{
		Rewrite:        s.rewrite,
		FlushInterval:  -1, // session streams are server-sent events
		ModifyResponse: s.observe,
		ErrorHandler:   s.unreachable,
	}
	return s, nil
}

// Share opens the server to other devices on the given networks, as
// `albedo web --allow` does: it answers on this machine's addresses inside
// them (only those names, so a stranger's DNS name pointed here still does
// not pass) and only to clients from them or this machine. A device still
// signs in with the printed link. It returns the addresses it answers on.
func (s *Server) Share(networks []*net.IPNet, addresses []string) []string {
	s.clients = append(s.clients, networks...)
	var shared []string
	for _, address := range addresses {
		if ip := net.ParseIP(address); ip != nil && inside(networks, ip) {
			s.hosts[address] = true
			shared = append(shared, address)
		}
	}
	return shared
}

// LaunchURL is the address that signs a browser in; it works once per
// browser, which keeps the cookie after that.
func (s *Server) LaunchURL(addr string) string {
	return "http://" + addr + "/?key=" + s.key
}

func (s *Server) ServeHTTP(w http.ResponseWriter, r *http.Request) {
	if !s.allowed(r.Host) {
		http.Error(w, "albedo web does not answer on this name", http.StatusMisdirectedRequest)
		return
	}
	if !s.client(r.RemoteAddr) {
		http.Error(w, "albedo web does not serve this network; allow it with --allow", http.StatusForbidden)
		return
	}
	if key := r.URL.Query().Get("key"); key != "" && r.URL.Path == "/" {
		s.signIn(w, r, key)
		return
	}
	if r.URL.Path == "/api" || strings.HasPrefix(r.URL.Path, "/api/") {
		s.forward(w, r)
		return
	}
	if strings.HasPrefix(r.URL.Path, "/assets/") {
		w.Header().Set("Cache-Control", "public, max-age=31536000, immutable")
	} else {
		w.Header().Set("Cache-Control", "no-cache")
	}
	s.static.ServeHTTP(w, r)
}

func (s *Server) signIn(w http.ResponseWriter, r *http.Request, key string) {
	if !s.validKey(key) {
		http.Error(w, "this launch link is from another albedo web; open the link it printed", http.StatusForbidden)
		return
	}
	http.SetCookie(w, &http.Cookie{Name: cookieName, Value: s.key, Path: "/", HttpOnly: true, SameSite: http.SameSiteStrictMode})
	http.Redirect(w, r, "/", http.StatusSeeOther)
}

func (s *Server) forward(w http.ResponseWriter, r *http.Request) {
	cookie, err := r.Cookie(cookieName)
	if err != nil || !s.validKey(cookie.Value) {
		writeError(w, http.StatusUnauthorized, "web_signed_out", "open the link albedo web printed to sign this browser in")
		return
	}
	// The cookie is SameSite=Strict, so this only catches a page on another
	// local port that shares the cookie jar's host.
	if origin := r.Header.Get("Origin"); origin != "" && origin != "http://"+r.Host {
		writeError(w, http.StatusForbidden, "origin_forbidden", "origin is not allowed")
		return
	}
	s.proxy.ServeHTTP(w, r)
}

func (s *Server) rewrite(pr *httputil.ProxyRequest) {
	endpoint := s.upstream.Snapshot()
	target := &url.URL{Scheme: "http", Host: fmt.Sprintf("127.0.0.1:%d", endpoint.Port)}
	pr.SetURL(target)
	pr.Out.URL.Path = strings.TrimPrefix(pr.In.URL.Path, "/api")
	pr.Out.URL.RawPath = ""
	pr.Out.Host = target.Host
	pr.Out.Header.Del("Origin")
	pr.Out.Header.Del("Cookie")
	pr.Out.Header.Del("Referer")
	pr.Out.Header.Set("Authorization", "Bearer "+endpoint.Token)
}

// A refused token means the daemon restarted with a new one; find it so the
// browser's next request lands. The refusal itself still reaches the page.
func (s *Server) observe(response *http.Response) error {
	if response.StatusCode == http.StatusUnauthorized {
		s.refresh()
	}
	return nil
}

func (s *Server) unreachable(w http.ResponseWriter, r *http.Request, err error) {
	if r.Context().Err() != nil {
		return
	}
	s.refresh()
	writeError(w, http.StatusBadGateway, "daemon_unavailable", "the daemon did not answer: "+err.Error())
}

func (s *Server) refresh() {
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	_ = s.upstream.Refresh(ctx)
}

func (s *Server) validKey(candidate string) bool {
	return subtle.ConstantTimeCompare([]byte(candidate), []byte(s.key)) == 1
}

// allowed refuses other names that resolve here (DNS rebinding).
func (s *Server) allowed(hostport string) bool {
	host, _, err := net.SplitHostPort(hostport)
	if err != nil {
		host = hostport
	}
	return s.hosts[strings.Trim(host, "[]")]
}

// client lets this machine in, and devices on the shared networks. Unshared,
// the listener is on loopback alone and every client is this machine.
func (s *Server) client(remote string) bool {
	if len(s.clients) == 0 {
		return true
	}
	host, _, err := net.SplitHostPort(remote)
	if err != nil {
		host = remote
	}
	ip := net.ParseIP(host)
	return ip == nil || ip.IsLoopback() || inside(s.clients, ip)
}

func inside(networks []*net.IPNet, ip net.IP) bool {
	for _, network := range networks {
		if network.Contains(ip) {
			return true
		}
	}
	return false
}

// ParseNetwork reads a network as CIDR, or as an IPv4 address whose trailing
// zero octets stand for any: 10.0.0.0 is 10.0.0.0/8, 100.64.0.0 is
// 100.64.0.0/16, and an address with no zero octets is that address alone.
func ParseNetwork(text string) (*net.IPNet, error) {
	if strings.Contains(text, "/") {
		_, network, err := net.ParseCIDR(text)
		return network, err
	}
	ip := net.ParseIP(text).To4()
	if ip == nil {
		return nil, fmt.Errorf("%q is not an IPv4 address or a CIDR network", text)
	}
	bits := 32
	for octet := 3; octet >= 0 && ip[octet] == 0; octet-- {
		bits -= 8
	}
	return &net.IPNet{IP: ip, Mask: net.CIDRMask(bits, 32)}, nil
}

// NetworkAddresses are this machine's addresses other devices can reach: up
// interfaces' IPv4 addresses, without loopback and link-local ones.
func NetworkAddresses() ([]string, error) {
	interfaces, err := net.Interfaces()
	if err != nil {
		return nil, err
	}
	var found []string
	for _, iface := range interfaces {
		if iface.Flags&net.FlagUp == 0 || iface.Flags&net.FlagLoopback != 0 {
			continue
		}
		addresses, err := iface.Addrs()
		if err != nil {
			continue
		}
		for _, address := range addresses {
			network, ok := address.(*net.IPNet)
			if !ok || network.IP.To4() == nil || network.IP.IsLinkLocalUnicast() {
				continue
			}
			found = append(found, network.IP.String())
		}
	}
	return found, nil
}

func writeError(w http.ResponseWriter, status int, code, detail string) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(status)
	_ = json.NewEncoder(w).Encode(map[string]map[string]string{"error": {"code": code, "detail": detail}})
}
