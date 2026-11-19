# Predictions

Get:

- Allocations
  - Hit: 2: 1 from the parser and 1 for the response
  - Miss: 1 from the parser
- Syscalls
  - read: 1 + n: 1 for the frame + n for (key size / buffer size - first buffer fill)
  - write
    - response size <= send buffer size: 1: full msg
    - response size > send buffer size: response / send buffer

Set:

- Allocations: 3
- Syscalls
  - read: 1 + n: 1 for the frame + n for ((key size + value size) / buffer size - first buffer fill)
  - write: 1: frame

Del:

- Allocations: 1
- Syscalls
  - read: 1 + n: 1 for the frame + n for (key size / buffer size - first buffer fill)
  - write: 1: frame

## Expectations

Get:

- Allocations: 0
- Syscalls
  - read
    - request <= buffer size: 1
    - request > buffer size: 2 (assuming data available)
  - writev: 1: with frame + payload

Set:

- Allocations: 1
- Syscalls
  - read
    - request <= buffer size: 1
    - request > buffer size: 2 (assuming data available)
  - write: 1: the frame

Del:

- Allocations: 0
- Syscalls
  - read
    - request <= buffer size: 1
    - request > buffer size: 2 (assuming data available)
  - write: 1: for the frame

## Results

### Meta

run.id=2026-11-19T07:10:10Z-9de9158
run.started_utc=2026-11-19T07:10:10Z
run.status=success

build.git_hash=9de91589b683ef59e6f107983518dd9ebb4b0f46
build.git_dirty=false
build.mode=ReleaseFast
build.zig=0.16.0-dev.2682+02142a54d

host.kernel=7.0.0-38-generic
host.cpu=Intel(R) Core(TM) Ultra 5 125U
host.isolated=

host.no_turbo=0

host.load_gen.affinity=1
host.load_gen.epp=balance_performance

host.server.affinity=3
host.server.epp=balance_performance

host.perf_version=perf version 7.0.14

workload.ops=get-hit,get-miss,set-insert,set-replace,delete-hit,delete-miss
workload.requests=500000
workload.key_count=600000
workload.seed=0

Get-Hit:

- Allocations: 1_000_000 => 2 pr ✔
- 999994 read => 2 pr ✔
- 500000 write => 1 pr ✔
- 499993 poll

Get-Miss:

- Allocations: 500000 => 1 pr ✔
- 999970 read => 2 pr ✔
- 500000 write => 1 pr ✔
- 499969 poll

Set-Insert:

- Allocations: 1500001 => 3 pr ✔
- 978 mmap
- 978 munmap
- 999982 read => 2 pr ✔
- 500000 write => 1 pr ✔
- 499981 poll => 1 pr ✔

Set-Replace:

- Allocations: 1000000 => 2 pr x
- 999992 read => 2 pr ✔
- 500000 write => 1 pr ✔
- 499991 poll

Delete-Hit:

- Allocations 500000 => 1 pr ✔
- 999990 read => 2 pr ✔
- 500000 write => 1 pr ✔
- 499989 poll

Delete-Miss:

- Allocations 500000 => 1 pr ✔
- 999974 read => 2 pr ✔
- 500000 write => 1 pr ✔
- 499973 poll

### Observations

- Read is done once more because the first read ends up as EAGAIN.
