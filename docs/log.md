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
