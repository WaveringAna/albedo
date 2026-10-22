import albedo/harness/extension
import albedo/harness/extensions/artifacts/ledger
import albedo/harness/extensions/artifacts/rpc
import albedo/harness/extensions/artifacts/service
import albedo/harness/host

pub fn extension() -> extension.Extension {
  extension.Extension(
    "artifacts",
    "Web pages the agent makes, shown beside the chat and kept in a gallery.",
    ["python"],
    [
      extension.ServicePlugin(extension.Service(
        service.admission,
        service.handle,
      )),
      extension.ToolPlugin(instructions, [], ["artifacts"], []),
      // The prepared workspace records where an artifact was made; the
      // gallery itself is global, and outlives the session.
      extension.ManagedPlugin(fn(_, _, workspace) {
        Ok(
          extension.Managed(..extension.empty(), routes: [
            #("artifacts", fn(context: host.Context, method, args) {
              rpc.handle(
                context.store,
                workspace,
                context.session,
                method,
                args,
              )
            }),
          ]),
        )
      }),
    ],
    ledger.initialise,
  )
}

const instructions =
  "Artifacts are web pages you make for the person you work with: a page, a few files, or a whole built app. Each opens in a window beside this chat (in the terminal, as a link that opens the browser), keeps every version, and outlives the session. Make one whenever seeing or using something beats reading about it: a chart, a diagram, a prototype, a small tool, a comparison, a game, a plan with a timeline. You do not need permission to make one. await artifacts.create(title, html) makes a single-page artifact; files={path: str|bytes} gives several files, and directory=\"dist\" publishes a built app whole (build it with relative asset paths, e.g. vite --base ./). Each returns a record with id and version. await artifacts.update(id, html) writes the next version: html replaces the entry page, files= changes only the paths it names (None removes one), directory= replaces the tree; the open window follows the new version, so revise rather than make a new artifact when the person is iterating on the same thing. artifacts.list(), get(id), read(id, path=None) find and read past ones; artifacts.state(id) is what the page saved in localStorage, artifacts.errors(id) what threw in it, so check errors after the person used it; artifacts.url(id) is its address on albedo web for checking it yourself with the browser plugin. The page runs in a sandbox with the network on and no access to albedo: load polished libraries from a CDN (Tailwind, Observable Plot or ECharts, D3, MapLibre or Leaflet, Three.js, Mermaid, KaTeX, Preact or React through esm.sh, Tone.js) rather than hand-rolling them. localStorage persists across reloads and versions. Style it with albedo's colours so it matches light and dark: var(--albedo-bg), --albedo-surface, --albedo-text, --albedo-muted, --albedo-faint, --albedo-accent, --albedo-border, --albedo-added, --albedo-danger, --albedo-sans, --albedo-mono. A page can talk back: await albedo.send(text) posts text to this chat as the person, so a button can say what they picked; send on a click, not on a timer. Make it look considered: real spacing, real typography, empty and loading states, and it should work at phone width."
