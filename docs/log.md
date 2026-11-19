# Decisions Log

## Zig

Started the project with Rust but decided to give it a try in zig because the low level characteristics of the program require using primitives from OS. Every decision in Rust was a translation from the C API into the Rust library.

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

## mmap in Set-Insert

The Set-Insert run showed 978 mmap and 978 munmap calls for 500k requests, which no other op had. Recording syscalls:sys_enter_mmap with call stacks put all of them under BufMap.put → BufMap.copy → SmpAllocator.alloc. They don’t come from the map resizing. They come from copying each key and value into its own allocation. 500k puts with 2 copies each is 1M allocations of 64 bytes, which works out to one mmap per about 1024 allocations: SmpAllocator mapping a new fixed-size 64 KiB slab whenever a size class runs out. Fixed slabs keep the cost of each refill constant and the waste bounded, at the price of more syscalls in total. At one mmap per ~1000 puts that cost is negligible next to the 4 syscalls per request. It goes away anyway if the parsed buffer is handed to the map instead of copied.
