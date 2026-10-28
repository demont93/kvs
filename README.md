# README

TCP key-value server using raw linux syscalls where each iteration is measured.

## Current Design

Key value server with naive implementation (for now).

- Single threaded
- In-memory HashMap of u8 without persistence
- Basic request protocol with prefix length
- Basic response protocol with simple errors
- Resumable chunk parsing
- A [log](docs/log.md) to show different decisions made along the way

## Policy

- Read timeout: 6s
- Write timeout: 6s
- Timeout grace period: 2s: The grace period for draining after a read timeout.
- Max drain: 4KiB: The max drain size for reading after bad requests.

## Protocol

- Length-prefixed binary frames
- GET | SET | DEL u8 codes
- Clear limits

More information on [protocol spec](docs/protocol.md).

## Zig

Zig was chosed for this project to have full control and clear mapping to linux syscalls. Other languages hide these with abstraction and make using syscalls extremely inconvenient. Because this project is being hand-written completely, a language that favors a human programmer is a better suit for this use-case. Explicit memory-management without destructors or drop-traits is preferred because the spec is small and optimizations are easy to implement correctly.

The second choice would've been C, but I wanted to try something newer for this project.

Version is 0.16-dev.
