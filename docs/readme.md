# Overview
Albedo is an agentic coding harness that can act on your device and soon able to manage sessions on other devices with agents that can act remotely on different machines or within containers. Our hope is that it being built on BEAM allows it to maintain low memory usage while running many concurrent agents and subagents across devices.

Albedo is daemonized with the CLI and (future) WebUI being clients of this daemon. This ensures the agents can be programatically created, controlled, and even stopped all while still providing an experience similar to other harnesses like Claude Code and Codex. Albedo provides a Python REPL for the agents to use as a scratchpad and data manipulation allowing them to experiment, reason, and play with code before actually writing it down. This is similar to what other harnesses call CodeMode and is based on [prime-agent's](https://github.com/PrimeIntellect-ai/prime-agent/)'s Python REPL and design.

[Daemon attachment and local startup](daemon-lifecycle.md) explains how clients
discover, attach to, start, and explicitly restart a daemon.

[Client API ownership](client-api.md) explains how named operations separate
daemon requests from application commands and TUI screens.
