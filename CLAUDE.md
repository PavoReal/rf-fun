# Claude Instructions

## This Project
This ia a zig project meant to explore and learn about the  handling of rf data from a hackrf one. 

### Zig
Running zig version 0.16 master branch, updated often, always refer to the
following web pages before writing or reading any zig code:
- Language reference: https://ziglang.org/documentation/master/
- std lib reference: https://ziglang.org/documentation/master/std/
- When build errors occur, check the actual Zig 0.16 API rather than guessing from older versions.
- For C interop (@cImport), be aware of type incompatibilities between separate compilation units.

## Claude's Workflow
1. Start every complex task in plan mode. Pour your energy into the plan so
   you can 1-shot the implementation. Once you've written a plan, then spin
   up a second Claude to review it as a staff engineer. 
2. The moment something goes sideways, switch back to plan
   mode and re-plan. Don't keep pushing. 
3. Use subagents. When creating plans, if at all possible plan to have 2-4 parallel work streams using subagents.

## Claude's Task Management 
Do the following when handling any non-trivial task:

1. Plan first
2. Verify plan
3. Track progression
4. Explain changes
5. Document results
6. Capture lessons
