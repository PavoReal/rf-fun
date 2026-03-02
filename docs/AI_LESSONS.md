# AI Lessons

## Zig 0.15 Atomic Types
- `std.atomic.Value(T)` only works with 8, 16, 32, 64, 128-bit integer types
- `bool` and `u1` are NOT valid — use `u8` with `@intFromBool()`/`!= 0` conversions
- `@bitCast` requires exact size match — can't cast f32 to u64

## Zig 0.15 Thread Sleep
- `std.time.sleep()` does not exist in Zig 0.15
- Use `std.Thread.sleep(nanoseconds)` instead

## Zig Name Shadowing
- Function parameters cannot share names with methods in the same struct
- E.g., `fn init(alloc, capacity)` fails if struct has `pub fn capacity()`

## Zig Array Default Initialization
- `.{.init(0)} ** N` fails — `.init(0)` is treated as a function call on an enum literal
- Use `[_]Type{.init(0)} ** N` to initialize arrays of atomic values with defaults

## Zig 0.15 File I/O API
- `std.io.bufferedWriter()` and `std.io.BufferedWriter` do NOT exist in Zig 0.15
- `file.writer()` now requires a buffer argument: `file.writer(&buf)`
- Returns a `File.Writer` struct; access `writer.interface` (a `std.Io.Writer`) for `writeAll`, `writeInt`, `writeByte`, `flush`
- The buffer provides internal buffering — no separate buffered writer needed

## Zig Mutation Rules
- Variables assigned once and never reassigned must be `const`, even if their value comes from a runtime call like `nanoTimestamp()`
- Zig enforces this strictly — `var` is only for variables that are actually reassigned

## Zig @cImport Type Compatibility
- Separate `@cImport` calls in different files produce incompatible types (even for identical includes)
- Fix: make one file's `@cImport` `pub` and import it from other files
- Example: `pub const c = @cImport({...})` in radio_decoder.zig, then `const c = @import("radio_decoder.zig").c` elsewhere
