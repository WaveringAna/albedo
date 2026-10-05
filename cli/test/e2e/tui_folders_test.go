//go:build unix

// /cd crosses the composer, the folder picker, the daemon's workspace routes and
// its workspace move. A fake folder source cannot show the daemon listing a
// real directory, resolving a relative path, or keeping the new workspace.
package e2e

import (
	"context"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"albedo/cli/internal/daemon"
	"albedo/cli/internal/tui"

	tea "charm.land/bubbletea/v2"
)

func TestTUICdMovesTheSessionThroughThePicker(t *testing.T) {
	t.Parallel()
	providerRoute(t, echoReply)
	d := newTUIDriver(t)
	root := t.TempDir()
	for _, dir := range []string{"picked/src", "other", ".hidden"} {
		if err := os.MkdirAll(filepath.Join(root, dir), 0o755); err != nil {
			t.Fatal(err)
		}
	}
	d.Update(tea.WindowSizeMsg{Width: 120, Height: 30})
	same := func(got, want string) bool {
		g, _ := filepath.EvalSymlinks(got)
		w, _ := filepath.EvalSymlinks(want)
		return g == w
	}

	d.App.Chat.TextArea.SetValue("/cd")
	d.Dispatch(d.Key(tea.KeyEnter))
	if d.App.State != tui.AppStateFolderPicker {
		t.Fatalf("/cd did not open the picker:\n%s", d.View())
	}
	// The daemon lists the typed folder; the last segment filters it and
	// dot folders stay hidden.
	d.Type(root + "/pi")
	if view := d.View(); !strings.Contains(view, "picked") || strings.Contains(view, "other") || strings.Contains(view, ".hidden") {
		t.Fatalf("the listing was not filtered to picked:\n%s", view)
	}
	d.Dispatch(tea.KeyPressMsg{Code: tea.KeyEnter})
	if d.App.State != tui.AppStateChat {
		t.Fatalf("enter did not return to the chat:\n%s", d.View())
	}
	id := d.App.ActiveSession.ID
	if got := daemonSession(t, id).Workspace; !same(got, filepath.Join(root, "picked")) {
		t.Fatalf("the daemon kept workspace %q", got)
	}

	// /cd with a path moves at once, relative to where the session is.
	d.Dispatch(tui.ChatExecuteCommandMsg{Name: "/cd", Args: "../other"})
	if got := daemonSession(t, id).Workspace; !same(got, filepath.Join(root, "other")) || !same(d.App.Chat.Workspace, got) {
		t.Fatalf("/cd ../other left the daemon at %q and the chat at %q", got, d.App.Chat.Workspace)
	}
	// The chat offers linking the folder it left, as a command to paste.
	view := d.View()
	_, offered, ok := strings.Cut(view, "/link add ")
	if !ok {
		t.Fatalf("moving did not offer /link add:\n%s", view)
	}
	offered = strings.Fields(offered)[0]
	if !same(offered, filepath.Join(root, "picked")) {
		t.Fatalf("the hint offers %q, not the folder the session left", offered)
	}
	d.Dispatch(tui.ChatExecuteCommandMsg{Name: "/link", Args: "add " + offered})
	if d.App.State != tui.AppStatePageView || d.App.PageView.Doc == nil || d.App.PageView.Doc.Title != "Link workspace groups" || len(d.App.PageView.Doc.Rows) != 2 || !strings.Contains(d.View(), "complete groups will share memory and work") {
		t.Fatalf("pasting the hint did not prepare the observed groups:\n%s", d.View())
	}
	d.Dispatch(tea.KeyPressMsg{Code: tea.KeyEnter})
	d.Dispatch(tea.KeyPressMsg{Code: tea.KeyEnter})
	if d.App.PageView.Error != "" {
		t.Fatal(d.App.PageView.Error)
	}
	group, err := daemon.LoadPage(t.Context(), conn(t), d.App.ActiveSession.ID, "/links")
	if err != nil {
		t.Fatal(err)
	}
	linked := false
	for _, member := range group.Rows {
		linked = linked || member.Text == offered
	}
	if !linked {
		t.Fatalf("confirmed merge omitted old workspace: %+v", group.Rows)
	}
}

func TestTUIMissingWorkspaceSendsTheTurnFromThePickedFolder(t *testing.T) {
	t.Parallel()
	profile := providerRoute(t, echoReply)
	root := t.TempDir()
	gone, found := filepath.Join(root, "gone"), filepath.Join(root, "found")
	for _, dir := range []string{gone, found} {
		if err := os.Mkdir(dir, 0o755); err != nil {
			t.Fatal(err)
		}
	}
	session := daemonSession(t, newSession(t, gone))
	d := driveTUI(t, &session)
	defer d.App.Chat.Close()
	d.Update(tea.WindowSizeMsg{Width: 120, Height: 30})
	d.App.Chat.TextArea.SetValue("keep this draft")
	d.Dispatch(tui.FolderNewSessionMsg{Workspace: filepath.Join(root, "never-created")})
	if d.App.State != tui.AppStateChat || d.App.ActiveSession == nil || d.App.ActiveSession.ID != session.ID || d.App.Chat.Workspace != session.Workspace || d.App.Chat.TextArea.Value() != "keep this draft" {
		t.Fatalf("a rejected creation changed the unrelated active session:\n%s", d.View())
	}
	if err := os.Remove(gone); err != nil {
		t.Fatal(err)
	}

	d.connected()
	d.App.Chat.TextArea.SetValue("hello from nowhere")
	messages := d.results(d.Update(tea.KeyPressMsg{Code: tea.KeyEnter}))
	var admitted tui.ChatTurnSentMsg
	for _, message := range messages {
		if sent, ok := message.(tui.ChatTurnSentMsg); ok {
			admitted = sent
			d.Update(sent)
		}
	}
	if admitted.Err != nil || admitted.Handle == nil || !admitted.OK {
		t.Fatalf("durable admission: %+v", admitted)
	}
	var receipt daemon.InputReceipt
	deadline := time.Now().Add(5 * time.Second)
	for {
		var err error
		receipt, err = daemon.ResolveOperation(t.Context(), conn(t), admitted.Handle)
		if err != nil {
			t.Fatal(err)
		}
		if receipt.BlockingDetail() != "" {
			break
		}
		if time.Now().After(deadline) {
			t.Fatal("missing workspace did not retain blocked pending input")
		}
		time.Sleep(25 * time.Millisecond)
	}
	if !receipt.Pending() {
		t.Fatalf("blocked input was lost: %+v", receipt)
	}
	d.Update(tui.ChatOperationResolvedMsg{SessionID: session.ID, Generation: d.App.Chat.Generation, Handle: admitted.Handle, Receipt: receipt})
	if d.App.State != tui.AppStateChat || d.App.Chat.TextArea.Value() != "" || !strings.Contains(d.View(), "hello from nowhere") {
		t.Fatalf("blocked admission state=%v composer=%q view=%q", d.App.State, d.App.Chat.TextArea.Value(), d.View())
	}

	d.Dispatch(tui.ChatExecuteCommandMsg{Name: "/cd"})
	d.Type(root + "/fou")
	moved, ok := d.Key(tea.KeyEnter).(tui.FolderMovedMsg)
	if !ok || moved.Err != nil {
		for cause := moved.Err; cause != nil; cause = errors.Unwrap(cause) {
			t.Logf("workspace move cause: %T %v", cause, cause)
		}
		t.Fatalf("enter did not move the session: %v (message %T)", moved.Err, moved)
	}
	d.Update(moved)
	waitIdle(t, session.ID, profile, 1)
	history, err := daemon.NewChatClient(conn(t), session.ID).History(t.Context(), 0, 120)
	if err != nil {
		t.Fatal(err)
	}
	users := 0
	for _, event := range history.Events {
		if event.Type == daemon.EventUser {
			users++
			if event.OperationID != admitted.OperationID {
				t.Fatal("workspace repair created another user intent")
			}
		}
	}
	if users != 1 {
		t.Fatalf("workspace repair delivered %d user rows", users)
	}
	if got, _ := filepath.EvalSymlinks(daemonSession(t, session.ID).Workspace); got != mustEval(t, found) {
		t.Fatalf("the daemon kept workspace %q", got)
	}
}

func TestTUISessionsByFolderOpenAndStartSessions(t *testing.T) {
	t.Parallel()
	providerRoute(t, echoReply)
	cache, err := os.UserCacheDir()
	if err != nil {
		t.Fatal(err)
	}
	if err = os.MkdirAll(cache, 0o700); err != nil {
		t.Fatal(err)
	}
	// The system temporary directory may be inside a repository. This
	// scenario needs a plain directory whose complete tree is visible.
	root, err := os.MkdirTemp(cache, "albedo-go-plain-workspace-")
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() {
		if err := os.RemoveAll(root); err != nil {
			t.Errorf("remove the plain workspace fixture: %v", err)
		}
	})
	busy, empty, crowded := filepath.Join(root, "busy"), filepath.Join(root, "empty"), filepath.Join(root, "crowded")
	for _, dir := range []string{busy, empty, crowded} {
		if err := os.Mkdir(dir, 0o755); err != nil {
			t.Fatal(err)
		}
	}
	// A deep tree, taller than the pane, must not push the sessions off.
	for i := range 12 {
		for j := range 5 {
			if err := os.MkdirAll(filepath.Join(busy, fmt.Sprintf("d%02d/c%d", i, j)), 0o755); err != nil {
				t.Fatal(err)
			}
		}
	}
	there := newSession(t, busy)
	// In the sessions view the leading slash opens the folder browser, which
	// must be on screen before the rest of the path is typed into it.
	typePath := func(d *tuiDriver, path string) {
		d.Dispatch(tea.KeyPressMsg{Code: '/', Text: "/"})
		d.Type(strings.TrimPrefix(path, "/"))
	}

	// ^f in the sessions view browses folders; → steps into the highlighted
	// folder's sessions and enter opens one.
	d := driveTUI(t, nil)
	d.Update(tea.WindowSizeMsg{Width: 120, Height: 30})
	d.Dispatch(tea.KeyPressMsg{Code: 'f', Mod: tea.ModCtrl})
	if d.App.State != tui.AppStateFolderPicker {
		t.Fatalf("^f did not open the folder browser:\n%s", d.View())
	}
	d.Type(root + "/bu")
	if view := d.View(); !strings.Contains(view, "d00/") || !strings.Contains(view, "Untitled session") {
		preview, previewErr := daemon.PreviewFolder(t.Context(), conn(t), busy)
		t.Logf("daemon preview: tree=%d more=%d repository=%+v error=%v", len(preview.Tree), preview.More, preview.Repo, previewErr)
		listing, listErr := daemon.ListFolders(t.Context(), conn(t), busy)
		t.Logf("daemon directory: entries=%d error=%v", len(listing.Entries), listErr)
		t.Fatalf("the preview lost its tree or its sessions:\n%s", view)
	}
	d.Dispatch(tea.KeyPressMsg{Code: tea.KeyRight})
	opened, ok := d.Key(tea.KeyEnter).(tui.FolderOpenSessionMsg)
	if !ok || opened.Session.ID != there {
		t.Fatalf("enter in the folder's sessions did not open %s: %#v\n%s", there, opened, d.View())
	}
	d.Update(opened)
	if d.App.State != tui.AppStateChat || d.App.ActiveSession.ID != there {
		t.Fatalf("the picked session is not on screen:\n%s", d.View())
	}

	// Under a short tree the sessions fill the pane instead of a third of it.
	for range 12 {
		newSession(t, crowded)
	}
	d = driveTUI(t, nil)
	d.Update(tea.WindowSizeMsg{Width: 120, Height: 30})
	typePath(d, root+"/cr")
	if view := d.View(); strings.Count(view, "Untitled session") != 12 {
		t.Fatalf("the preview cut the sessions short:\n%s", view)
	}

	// A path typed into an empty search browses too, and enter on a folder
	// starts a session there.
	d = driveTUI(t, nil)
	d.Update(tea.WindowSizeMsg{Width: 120, Height: 30})
	typePath(d, root+"/em")
	if d.App.State != tui.AppStateFolderPicker {
		t.Fatalf("typing a path did not open the folder browser:\n%s", d.View())
	}
	started, ok := d.Key(tea.KeyEnter).(tui.FolderNewSessionMsg)
	if !ok {
		t.Fatalf("enter on a folder did not start a session: %#v", started)
	}
	d.Update(d.Send(started))
	if got := d.App.ActiveSession; d.App.State != tui.AppStateChat || got == nil || mustEval(t, got.Workspace) != mustEval(t, empty) {
		t.Fatalf("the new session is not in %s:\n%s", empty, d.View())
	}
}

func mustEval(t *testing.T, p string) string {
	t.Helper()
	resolved, err := filepath.EvalSymlinks(p)
	if err != nil {
		t.Fatal(err)
	}
	return resolved
}

// A host is picked like a folder: scp syntax lists its home through the
// daemon's ssh, the rows fold under that host's ~, enter starts a session
// whose kernel boots there, and a host ssh cannot reach is never picked.
//
// The TUI starts the session on the active profile, so this runs alone.
func TestTUIStartsASessionOnAHostPickedLikeAFolder(t *testing.T) {
	profile := providerRoute(t, echoReply)
	picked := filepath.Join(suite.remoteHome, "proj", fmt.Sprintf("picked-%d", os.Getpid()))
	if err := os.MkdirAll(picked, 0o755); err != nil {
		t.Fatal(err)
	}
	d := driveTUI(t, nil)
	d.Update(tea.WindowSizeMsg{Width: 120, Height: 30})
	d.Dispatch(tea.KeyPressMsg{Code: 'f', Mod: tea.ModCtrl})
	d.Type("gohost:")
	if view := d.View(); !strings.Contains(view, "in gohost:~") || !strings.Contains(view, "proj") {
		t.Fatalf("gohost: did not list the host's home:\n%s", view)
	}
	d.Type("proj/" + filepath.Base(picked)[:6])
	if view := d.View(); !strings.Contains(view, "in gohost:proj") || !strings.Contains(view, filepath.Base(picked)) {
		t.Fatalf("the host's folder did not list:\n%s", view)
	}
	started, ok := d.Key(tea.KeyEnter).(tui.FolderNewSessionMsg)
	if !ok || started.Workspace != "gohost:"+picked {
		t.Fatalf("enter did not start a session in gohost:%s: %#v", picked, started)
	}
	d.Update(d.Send(started))
	session := d.App.ActiveSession
	if d.App.State != tui.AppStateChat || session == nil || session.Workspace != "gohost:"+picked {
		t.Fatalf("the new session is not on gohost:\n%s", d.View())
	}
	// the daemon's parsed location reaches the client, so the header shows the host
	if l := session.Location; l == nil || l.Host == nil || *l.Host != "gohost" || l.Path != picked {
		t.Fatalf("the session's location did not decode: %+v", l)
	}

	// its kernel boots on the host, and the status says it is attached
	if _, err := daemon.NewChatClient(conn(t), session.ID).Send(context.Background(), "hello there", nil); err != nil {
		t.Fatal(err)
	}
	waitIdle(t, session.ID, profile, 1)
	status, err := daemon.NewChatClient(conn(t), session.ID).GetStatus(context.Background())
	if err != nil || status.KernelLink != "attached" {
		t.Fatalf("after a turn the kernel status is %+v (%v)", status, err)
	}

	// a host ssh cannot reach says why and is never picked
	d = driveTUI(t, nil)
	d.Update(tea.WindowSizeMsg{Width: 120, Height: 30})
	d.Dispatch(tea.KeyPressMsg{Code: 'f', Mod: tea.ModCtrl})
	d.Type("nohost:")
	if view := d.View(); !strings.Contains(view, "connect to host nohost") {
		t.Fatalf("an unreachable host does not say why:\n%s", view)
	}
	if msg, started := d.Key(tea.KeyEnter).(tui.FolderNewSessionMsg); started {
		t.Fatalf("enter started a session on an unreachable host: %#v", msg)
	}
}

// A turn at a host that needs a person to sign in is kept, waiting on the
// daemon's next try, and the chat offers to open the daemon's ssh master
// here so ssh can ask.
func TestTUIOffersSignInForATurnWaitingOnItsHost(t *testing.T) {
	t.Parallel()
	providerRoute(t, echoReply)
	session := daemonSession(t, newSession(t, "lockedhost:/srv/app"))
	d := driveTUI(t, &session)
	d.Update(tea.WindowSizeMsg{Width: 120, Height: 30})
	d.connected()
	d.App.Chat.TextArea.SetValue("hello behind a lock")
	var admitted tui.ChatTurnSentMsg
	for _, message := range d.results(d.Update(tea.KeyPressMsg{Code: tea.KeyEnter})) {
		if sent, ok := message.(tui.ChatTurnSentMsg); ok {
			admitted = sent
			d.Update(sent)
		}
	}
	if admitted.Err != nil || admitted.Handle == nil {
		t.Fatalf("the turn was not admitted: %+v", admitted)
	}
	var receipt daemon.InputReceipt
	for deadline := time.Now().Add(10 * time.Second); receipt.BlockingDetail() == ""; time.Sleep(25 * time.Millisecond) {
		var err error
		if receipt, err = daemon.ResolveOperation(t.Context(), conn(t), admitted.Handle); err != nil {
			t.Fatal(err)
		}
		if time.Now().After(deadline) {
			t.Fatalf("the turn never waited on its host: %+v", receipt)
		}
	}
	// The receipt's own poll answers only at the daemon's next try, so each
	// answer is taken as it comes rather than waiting for all of them.
	resolved := tui.ChatOperationResolvedMsg{SessionID: session.ID, Generation: d.App.Chat.Generation, Handle: admitted.Handle, Receipt: receipt}
	answers := make(chan tea.Msg, 4)
	for _, cmd := range d.Update(resolved)().(tea.BatchMsg) {
		go func() { answers <- cmd() }()
	}
	offer := "Press ctrl+l to sign in to lockedhost here"
	for timeout := time.After(10 * time.Second); !strings.Contains(d.View(), offer); {
		select {
		case answer := <-answers:
			d.Update(answer)
		case <-timeout:
			t.Fatalf("a turn waiting on a sign-in does not offer one:\n%s", d.View())
		}
	}
	if view := d.View(); !strings.Contains(view, "Permission denied") {
		t.Fatalf("the waiting turn does not say why:\n%s", view)
	}
}

// A probe is readable before its target has SSH config or session history.
func TestHostProbeObservesUnconfiguredTargets(t *testing.T) {
	for _, target := range []string{"fresh-host", "ana@fresh-host"} {
		t.Run(target, func(t *testing.T) {
			known, err := daemon.ListHosts(t.Context(), conn(t))
			if err != nil {
				t.Fatal(err)
			}
			for _, host := range known {
				if host.Host == target {
					t.Fatalf("fixture target %s is already known", target)
				}
			}
			status, err := daemon.GetHost(t.Context(), conn(t), target)
			if err != nil || status.Host != target || status.State != "unknown" {
				t.Fatalf("unconfigured target before probe: %+v, %v", status, err)
			}
			ctx, cancel := context.WithTimeout(t.Context(), 10*time.Second)
			defer cancel()
			status, err = daemon.WarmHost(ctx, conn(t), target)
			if err != nil || status.Host != target || status.State != "ready" || status.Home != suite.remoteHome {
				t.Fatalf("unconfigured target after probe: %+v, %v", status, err)
			}
		})
	}
}
