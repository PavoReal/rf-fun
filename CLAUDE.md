# Claude Instructions

## This Project
This is a zig project meant to explore and learn about the handling of rf data
from a hackrf one. 

### Software
Running zig version 0.15.2.
- zgui
- SDL3
- libhackrf
- libusb

### Documentation
- Human task planning is done in `.\TODO.md`
- Claude task planning should be done in `.\docs\AI_TODO.md`. You can use this file as
  you like. Try to keep to to medium to long term goals that last between
  sessions. If you implement something once and think it can be improved,
  consider adding it here. 
- Every time I correct you learn from it and add a lesson entry into
  `.\docs\AI_LESSONS.md`. 

## Claude's Workflow
1. Start every complex task in plan mode. Pour your energy into the plan so
   you can 1-shot the implementation. Once you've written a plan, then spin
   up a second Claude to review it as a senior staff engineer. 
2. The moment something goes sideways, switch back to plan
   mode and re-plan. Don't keep pushing. 
3. Use subagents. When creating plans, if at all possible plan to have 2-4
   parallel work streams using subagents.

## Claude's Task Management 
For every design decision, use your ask tool to ask me about it. Give me pros
and cons, plus 1-2 other options. Do the following when handling any
non-trivial task:

1. Plan first
2. Verify plan
3. Track progression
4. Explain changes
5. Document results
6. Capture lessons

## Guidelines
- Use `rg` in place of `grep` whenever possible.
- Research all APIs. When creating a task plan, if the task involves
  interacting with libraries, APIs, etc, always spawn a subagent to browse the
  web for the documentation to use as a reference.
- Avoid writing most code comments. 
- Don't take shortcuts, if you're working on something that you know isn't the
  best fix, say something.
- Make very generous use of subagents to gather reference material from the
  web. 
