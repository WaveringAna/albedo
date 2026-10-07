//// The runtime actor's state, its messages, and the records they carry: the
//// `Runtime` handle, a session's `Session`, a prepared `Cached` composition.
//// The helpers here read or step that state without talking to a kernel.

import albedo/harness/client_api
import albedo/harness/command
import albedo/harness/extension
import albedo/harness/extension/composition
import albedo/harness/extension/selection
import albedo/harness/extensions/python/kernel as python
import albedo/harness/extensions/work/ledger as work
import albedo/harness/runtime/catalog as session_catalog
import albedo/openai_api/types
import albedo/shared.{type Shared}
import gleam/dict.{type Dict}
import gleam/erlang/process.{type Subject}
import gleam/erlang/reference.{type Reference}
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result

/// A handle every process can hold and copy: the installed extensions, with
/// every plugin closure, sit behind one shared value.
pub type Runtime {
  Runtime(
    subject: Subject(Message),
    work: work.Store,
    installed: Shared(Installed),
  )
}

/// Fixed for the runtime's lifetime once `start_with_config` has installed.
pub type Installed {
  Installed(
    extensions: List(extension.Extension),
    default_enabled: List(String),
    /// Installed extensions the daemon will not run, with their reasons.
    quarantined: List(extension.Quarantined),
  )
}

pub type Session {
  Session(
    id: String,
    cwd: String,
    kernel: python.Kernel,
    owner: work.Store,
    composition: composition.Composition,
    instructions: String,
    context: List(types.Input),
    /// How the kernel came to be the session's: the adopting session tells
    /// the model what happened to its namespace from this.
    origin: Origin,
  )
}

/// Facts captured before the upgrade and after runtime ownership has settled.
pub type KernelUpgrade {
  KernelUpgrade(
    state: String,
    old: Option(python.Observation),
    new: Option(python.Observation),
    session: Option(Session),
    stopped_jobs: List(String),
    warnings: List(String),
    failure: Option(String),
  )
}

/// The result after runtime ownership has settled, including a failed apply's
/// surviving kernel. Saved preferences are independent of this outcome.
pub type Application {
  Applied(
    session: Option(Session),
    loaded_revision: Option(String),
    warnings: List(String),
  )
  ApplyFailed(session: Option(Session), reason: String)
}

pub type Origin {
  /// Booted for this open; its namespace starts empty.
  Fresh
  /// Attached to the kernel the session already had: the namespace the
  /// session left.
  Resumed
  /// Swapped in for a stale kernel, carrying what its namespace could.
  Upgraded(python.Carried)
  /// The kernel the session had, handed back unchanged.
  Kept
}

/// One session's composition for its workspace. It survives kernel releases,
/// so catalog reads and command runs never boot Python and one session's
/// snapshot stays stable across releases; only reloads and teardown replace it.
pub type Cached {
  Cached(
    cwd: String,
    composition: composition.Composition,
    instructions: String,
    context: List(types.Input),
    loaded_revision: Option(String),
    basis: Option(Desired),
  )
}

/// A retained discovery is valid only while its exact source inputs match.
/// Session reads reuse it while only `saved` matches; see `retained_desired`.
pub type Desired {
  Desired(inputs: String, saved: String, snapshot: session_catalog.Snapshot)
}

pub type CompositionObservation {
  CompositionObservation(
    discovery: session_catalog.Snapshot,
    desired_revision: String,
    loaded_revision: Option(String),
    needs_reload: Bool,
    dependencies: Dict(String, List(String)),
    quarantine: List(extension.Quarantined),
    availability: Dict(String, Bool),
    glances: List(selection.Glance),
  )
}

pub type LoadedObservation {
  LoadedObservation(
    loaded_revision: Option(String),
    kernel: Option(python.Observation),
    phase: String,
    recorded_kernel_id: Option(String),
  )
}

pub type CatalogObservation {
  CatalogObservation(
    discovery: Result(session_catalog.Snapshot, String),
    loaded_revision: Option(String),
    commands: List(#(String, command.Command)),
    client_commands: List(#(String, client_api.Command, command.Command)),
  )
}

pub type ObservationReply {
  CompositionReply(Subject(Result(CompositionObservation, String)))
  CatalogReply(Subject(Result(CatalogObservation, String)))
}

pub type ObservationResult {
  CompositionResult(Result(CompositionObservation, String))
  CatalogResult(Result(CatalogObservation, String))
}

pub type BootRequest {
  Observe(id: String, home: String, reply: ObservationReply, retries: Int)
  Compose(id: String, cwd: String, generation: Reference)
  BootKernel(id: String, generation: Reference, cached: Cached)
  AttachKernel(
    id: String,
    generation: Reference,
    cached: Cached,
    reply: Subject(Nil),
  )
  UpgradeKernel(
    id: String,
    generation: Reference,
    cached: Cached,
    previous: Option(Session),
    answer: fn(Result(KernelUpgrade, String)) -> Nil,
  )
  /// Recompose from the saved desired selection, keeping the live kernel
  /// where its modules allow; `active_strategy` is the compaction the
  /// running composition has, which the new one must not silently drop.
  RecomposeDesired(
    id: String,
    generation: Reference,
    cwd: String,
    previous: Option(Session),
    active_strategy: Option(String),
    reply: Subject(Application),
  )
  /// Swap the stale kernel an open found; the opener waits in `booting`.
  SwapStale(id: String, generation: Reference, cached: Cached, session: Session)
}

pub type Booting {
  Booting(
    generation: Reference,
    waiters: List(fn(Result(Session, python.Error)) -> Nil),
  )
}

pub type PreparedWork {
  CommandsOrOpen
  AttachRecorded(reply: Subject(Nil))
  UpgradeRecorded(answer: fn(Result(KernelUpgrade, String)) -> Nil)
}

pub type Preparation {
  Preparation(generation: Reference, work: PreparedWork)
}

pub type CommandWaiter {
  CommandWaiter(
    cwd: String,
    reply: Subject(Result(#(List(command.Command), command.Context), String)),
  )
}

pub type State {
  State(
    work: work.Store,
    sessions: Dict(String, Session),
    compositions: Dict(String, Cached),
    desired: Dict(String, Desired),
    installed: Shared(Installed),
    self: Subject(Message),
    /// Kernels booting now, each with everyone waiting for it.
    booting: Dict(String, Booting),
    /// Kernels waiting for a boot slot, oldest first.
    waiting: List(BootRequest),
    /// Observation workers share the same admission budget as preparation.
    observing: Int,
    preparing: Dict(String, Preparation),
    /// Command reads join preparation without asking for a Python kernel.
    commands: Dict(String, List(CommandWaiter)),
    /// Set while the daemon shuts down: kernels are let go, not ended, so a
    /// restarted daemon attaches to them again.
    detaching: Bool,
    /// Extension reloads that arrived while their session's kernel was
    /// booting, attaching, or being swapped, newest first: each runs once the
    /// kernel settles, so it never races a kernel on its way in.
    deferred: Dict(String, List(Message)),
  )
}

/// Preparation and observation share four workers. Each class leaves one
/// slot available to the other so slow preparation cannot block reads.
pub const boot_slots = 4

pub type Message {
  /// Answered through the callback, never by blocking the caller: a session
  /// actor asks and keeps serving while its kernel boots.
  Open(String, String, fn(Result(Session, python.Error)) -> Nil)
  Composed(String, Reference, Result(Cached, String))
  Booted(String, Reference, Result(Session, python.Error))
  Upgrade(String, fn(Result(KernelUpgrade, String)) -> Nil)
  UpgradedKernel(
    String,
    Reference,
    Option(Session),
    Result(KernelUpgrade, String),
    fn(Result(KernelUpgrade, String)) -> Nil,
  )
  Peek(
    String,
    String,
    Subject(Result(#(List(command.Command), command.Context), String)),
  )
  Reload(String, String, selection.Change, Subject(Application))
  ReloadDesired(String, String, Subject(Application))
  Reloaded(
    String,
    Reference,
    Option(Session),
    Result(#(Cached, Option(Session)), String),
    Subject(Application),
  )
  Summaries(String, Subject(Result(List(extension.Summary), String)))
  ObserveComposition(
    String,
    String,
    Subject(Result(CompositionObservation, String)),
  )
  Observed(
    String,
    String,
    Int,
    Option(Cached),
    Result(Desired, String),
    ObservationReply,
    ObservationResult,
  )
  ObserveLoaded(String, Subject(Result(LoadedObservation, String)))
  ObserveCatalog(String, String, Subject(Result(CatalogObservation, String)))
  PeekPrompt(String, Subject(Option(#(String, List(types.Input)))))
  LoadedIDs(Subject(List(String)))
  HeldKernels(Subject(List(#(String, Session))))
  Reset(String, Subject(Nil))
  Forget(String, Subject(Nil))
  Delete(String, Subject(Result(Nil, String)))
  Stop(Subject(Nil))
  Detach(Subject(Nil))
  /// Attach to a session's recorded kernel without booting one.
  Reattach(String, String, Subject(Nil))
  Reattached(
    String,
    Reference,
    Cached,
    Result(Option(Session), python.Error),
    Subject(Nil),
  )
}

/// A kernel's origin is news once: the first session to take it tells the
/// model how it arrived (an attach after a daemon restart, a swap), and every
/// later open of the same kernel gets it as `Kept`. A kernel reattached in the
/// background at daemon start keeps its origin until its session asks.
pub fn handed_out(session: Session) -> Session {
  Session(..session, origin: Kept)
}

pub fn holding(state: State, id: String, session: Session) -> State {
  State(..state, sessions: dict.insert(state.sessions, id, session))
}

pub fn without_session(state: State, id: String) -> State {
  State(..state, sessions: dict.delete(state.sessions, id))
}

/// Whether the next open swaps this kernel: it is stale and nothing keeps it.
/// Live jobs keep an older bundle or module set; a
/// kernel on another protocol goes regardless, since it cannot be supervised.
pub fn upgradable(session: Session) -> Bool {
  case python.stale(session.kernel) {
    None -> False
    Some(python.Protocol) -> True
    Some(_) -> python.job_count(session.kernel) == 0
  }
}

/// Admitted workers: exclude queued preparations and include observations.
pub fn active(state: State) -> Int {
  let queued_preparations =
    list.count(state.waiting, fn(request) {
      case request {
        Observe(..) -> False
        _ -> True
      }
    })
  dict.size(state.booting) - queued_preparations + state.observing
}

/// Opens a generation for the session: its kernel work is on the way, and
/// `waiters`, plus whoever asks for the kernel meanwhile, hear how it ends.
pub fn admit(
  state: State,
  id: String,
  generation: Reference,
  waiters: List(fn(Result(Session, python.Error)) -> Nil),
) -> State {
  State(
    ..state,
    booting: dict.insert(state.booting, id, Booting(generation, waiters)),
  )
}

/// The waiters of the session's open generation, if `generation` is still it.
pub fn current_waiters(
  state: State,
  id: String,
  generation: Reference,
) -> Result(List(fn(Result(Session, python.Error)) -> Nil), Nil) {
  case dict.get(state.booting, id) {
    Ok(Booting(current, waiters)) if current == generation -> Ok(waiters)
    _ -> Error(Nil)
  }
}

/// The generation ended: what waited for the session's kernel runs now.
pub fn generation_over(state: State, id: String) -> State {
  State(..state, booting: dict.delete(state.booting, id))
  |> replay(id)
}

pub fn owner_alive(subject: Subject(Message)) -> Bool {
  process.subject_owner(subject)
  |> result.map(process.is_alive)
  |> result.unwrap(False)
}

pub fn defer(state: State, id: String, message: Message) -> State {
  let waiting = dict.get(state.deferred, id) |> result.unwrap([])
  State(
    ..state,
    deferred: dict.insert(state.deferred, id, [message, ..waiting]),
  )
}

/// The session's kernel settled: what waited for it runs now, in order.
pub fn replay(state: State, id: String) -> State {
  dict.get(state.deferred, id)
  |> result.unwrap([])
  |> list.reverse
  |> list.each(process.send(state.self, _))
  State(..state, deferred: dict.delete(state.deferred, id))
}

@external(erlang, "albedo_inspect", "label")
pub fn label(kind: String, id: String) -> Nil

/// How long one composition observation's call waits for the owner.
pub const observe_call_ms = 15_000

/// `observe_call_ms` plus a margin for the observer's reply to arrive.
pub const observe_timeout_ms = 16_000
