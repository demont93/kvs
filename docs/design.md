# Design

Key value server with naive implementation (for now).

- Single threaded
- HashMap of u8
- One Allocation per request
- Basic request protocol with prefix length
- Basic response protocol with simple errors

## Policy

- Read timeout: 6s
- Write timeout: 6s
- Timeout grace period: 2s: The grace period for draining after a read timeout.
- Max drain: 4KiB: The max drain size for reading after bad requests.
