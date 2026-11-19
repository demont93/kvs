# Decisions Log

## Zig

Started the project with Rust but decided to give it a try in zig because the low level characteristics of the program require using primitives from the OS. Every decision in Rust was a translation from the C API into the Rust library.

## Naive initial implementation

The first implementation is complete. The next big step would be to make it capable of handling several connections instead of waiting on a slow client that would hang the whole server.

Other good candidates for optimization are eliminating intermediate buffers, for example:

- Reading currently goes through a read buffer, then a parsing buffer, and then an allocation for the hashmap. The parsing buffer could hand over the buffer to the hashmap, and the read buffer could be used only for small request, while big requests bypass the read buffer after reading the frame.
- Encoding and writing a get response allocates a new buffer to append a tiny frame. Instead, a vectored write could append the frame without requiring another allocation.

## 2 Syscalls per read/write

The naive implementation polled before each read or write. Considering that the most likely case is that data will be waiting on the receive/send kernel buffer, polling the first time wastes one syscall. Instead, now the system tries to read or write, and polls if WOULDBLOCK.

## A simple client

In order to measure the next steps and take informed decisions, the next logical step is creating a client so we can check many of the claims. Most tests will require opening several connections with the server to test epoll.

## FSM on client

Implemented an FSM on the client to manage all the different states in which the connection can be. Before the fsm, the conditions where all over the place for retrying, errors, state of the connection. The FSM made it easy to have all the state that decides the next transition in one place.

## Feistel on the load generator

Permute ranges in a deterministic way by applying a small feistel network with SplitMix64 as the round function. This allows using ranges for preload, warmup, and measurements while keeping them mapped to arbitrary positions and using computed seeds to modify the order of execution. With random but deterministic order of execution, you better guarantee unbiased results due to unpredictable cache and memory access. The Feistel network also lets the load generator avoid storing keys in memory, which could skew the tests if caches are shared with the server process. All keys and values are computed on demand.

## mmap in Set-Insert

The Set-Insert run showed 978 mmap and 978 munmap calls for 500k requests, which no other op had. Recording syscalls:sys_enter_mmap with call stacks put all of them under BufMap.put → BufMap.copy → SmpAllocator.alloc. They don’t come from the map resizing. They come from copying each key and value into its own allocation. 500k puts with 2 copies each is 1M allocations of 64 bytes, which works out to one mmap per about 1024 allocations: SmpAllocator mapping a new fixed-size 64 KiB slab whenever a size class runs out. Fixed slabs keep the cost of each refill constant and the waste bounded, at the price of more syscalls in total. At one mmap per ~1000 puts that cost is negligible next to the 4 syscalls per request. It goes away anyway if the parsed buffer is handed to the map instead of copied.

## First profile-response runs (64 B keys/values, ping-pong, loopback)

The kernel dominates. User code is around 10% of cycles (about 20k cycles per request in ReleaseFast). Most of the time goes to TCP, poll, wakeup, etc. This is what I expected. With 64-byte keys and values the server does little work per request.

The syscall count came approximately to 2 reads, 1 poll, 1 write. This is because the server tries to read first and polls only on EAGAIN. With a ping-pong client the next request can't be there yet, because the client waits for the response before sending. So after every response the read returns EAGAIN, then poll, then the read that gets the frame. So should we read first or poll first for each request?  For this workload poll-first would save a read. Read-first pays off when data is often already waiting (pipelined clients) most likely. several reads. I think it is unlikely we will implement pipelined requests, and the server will most likely be waiting for the request always at the beginning. I think it doesn't really matter since it will go away on epoll.

Conclusion for small values: Reducing syscalls is a more effective way of optimizing the server, not allocations or the hash map.

Next hypothesis: With larger keys and values, cost will move toward the storage path: more allocations and more time copying in the hash map. Next step: make key and value size configurable and measure whether that cost becomes worth optimizing. After that, the next design question is concurrency in the server.

## memcpy in the parser

With 4 KiB values, `Parser.parse` was the hottest user-space function, at about 11% of the measured window's cycles. It copied the body with a manual byte loop, which the compiler did not vectorize. Replacing the loop with `memcpy` moved the copy into wide vector instructions.

A/B on the same workload and seed, 3 runs each, with the "before" built as HEAD with the commit reverted:

|        | cycles (G)       | mean |
| ------ | ---------------- | ---- |
| before | 6.95, 7.06, 7.02 | 7.01 |
| after  | 6.15, 6.14, 6.22 | 6.17 |

That's 0.84 G fewer cycles (−12%, about X cycles per request), against about ±1% noise between runs. The saving matches what parse used to cost (about 0.81 G), while `memcpy`'s own share grew by only about 0.04 G.

## Large values: copies and fresh memory

Set-Insert and Set-Replace with 256 KiB values (4000 requests, cycles:pp):

- ~835k cycles per request. `memcpy` ~17%, kernel `_copy_to_iter` ~6%.
- Page faults on fresh memory ~25% (`do_anonymous_page`, `kernel_init_pages`, memcg charge, fault entry/exit), plus `zap_present_ptes` on unmap.
- Syscalls per request: read 66, mmap 2, munmap 2, write 1, poll 1.

A value travels: socket → read buffer → parser → hash map, so three copies. Allocations above the allocator's slab sizes are mmap'd and munmap'd every time, so each request faults in and throws away ~128 pages.

Decision: use the buffered read only for the frame. Once the value length is known, allocate the value buffer and read the body straight into it, then hand that buffer from the parser to the hash map. That leaves one copy (kernel → final buffer).

Prediction: reads ~66 → ~2 per request, mmap/munmap 2 → 1, `memcpy` mostly gone, fault cost roughly halved (the stored value is still one fresh allocation per SET).
