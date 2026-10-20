import { ApiError, listJobs, readJobOutput, type Job, type JobPage } from './api';

// What a terminal window shows: one job's output, read a page at a time from
// where the last page ended. A window opens on the end of the output, which
// is where a terminal is; a running job's output is followed, and a finished
// one's is read to its end once. Read-only: nothing is ever sent to the job.

const RUNNING_MS = 700;
const RETRY_MS = 3000;
/** The most output kept on screen; older lines drop off the top as new ones arrive. */
const KEEP = 400_000;
/** A page this full means more is waiting, so the next read need not wait. */
const FULL = 65_000;

const ESCAPES = /\x1b\[[0-9;?]*[ -/]*[@-~]|\x1b\][^\x07\x1b]*(?:\x07|\x1b\\)/g;

/** Output as a person reads it: colour codes dropped, and a line a program redrew with \r shows its last draw. */
export function readable(text: string): string {
  return text
    .replace(ESCAPES, '')
    .split('\n')
    .map((line) => line.replace(/\r+$/, '').split('\r').at(-1) ?? '')
    .join('\n');
}

/** How a job stands, in a word or two: running, or how it ended. */
export function outcome(job: Job): string {
  if (job.state === 'running') return 'running';
  if (job.timed_out) return 'timed out';
  if (job.exit_code === null) return 'ended';
  return job.exit_code < 0 ? `stopped (signal ${-job.exit_code})` : `exit ${job.exit_code}`;
}

/** The first line of a command, with the folder of its program left off, for a title or a list row. */
export function headline(command: string): string {
  return command.split('\n', 1)[0].trim().replace(/^\S*\//, '');
}

export class Tail {
  text = $state('');
  job = $state<Job | null>(null);
  /** Bytes before the first page shown, that this window does not show. */
  skipped = $state(0);
  /** Why the output cannot be read, or null. */
  problem = $state<string | null>(null);
  /** Whether the end of a finished job's output has been read. */
  done = $state(false);
  #next: number | undefined;
  #timer: ReturnType<typeof setTimeout> | undefined;
  #abort: AbortController | undefined;

  constructor(
    readonly sessionId: string,
    readonly jobId: string,
  ) {}

  start() {
    this.#read();
  }

  stop() {
    clearTimeout(this.#timer);
    this.#abort?.abort();
  }

  #later(ms: number) {
    this.#timer = setTimeout(() => this.#read(), ms);
  }

  async #read() {
    if (document.hidden) return this.#later(RUNNING_MS);
    const abort = (this.#abort = new AbortController());
    try {
      const page = await readJobOutput(this.sessionId, this.jobId, this.#next, abort.signal);
      this.problem = null;
      this.#take(page);
      const finished = page.job.state === 'exited' && page.next_offset === page.offset;
      if (finished) this.done = true;
      else this.#later(page.text.length >= FULL ? 0 : RUNNING_MS);
    } catch (error) {
      if (abort.signal.aborted) return;
      this.#fail(error);
    }
  }

  #take(page: JobPage) {
    this.job = page.job;
    if (this.#next === undefined) {
      this.skipped = page.offset;
      this.text = page.text;
    } else {
      const text = this.text + page.text;
      this.text = text.length > KEEP ? text.slice(text.length - KEEP) : text;
    }
    this.#next = page.next_offset;
  }

  #fail(error: unknown) {
    if (error instanceof ApiError && error.code === 'job_not_found') {
      this.problem = 'the kernel no longer has this job';
      this.done = true;
    } else if (error instanceof ApiError && error.code === 'output_lost') {
      // Fell behind a job that wrote more than the kernel keeps: start again from the end.
      this.#next = undefined;
      this.#later(0);
    } else {
      this.problem = String((error as Error).message ?? error);
      this.#later(RETRY_MS);
    }
  }
}

/** Polls the session's job list while something shows it; `on` gets each answer. */
export function watchJobs(sessionId: string, on: (jobs: Job[]) => void): () => void {
  let timer: ReturnType<typeof setTimeout>;
  const abort = new AbortController();
  const tick = async () => {
    let running = false;
    if (!document.hidden) {
      const jobs = await listJobs(sessionId, abort.signal).catch(() => null);
      if (abort.signal.aborted) return;
      if (jobs) on(jobs);
      running = !!jobs?.some((job) => job.state === 'running');
    }
    timer = setTimeout(tick, running ? 2000 : 6000);
  };
  tick();
  return () => {
    clearTimeout(timer);
    abort.abort();
  };
}
