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
