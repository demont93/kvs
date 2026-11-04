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
