# Code Rules
---

## 1. Compression-Oriented Programming

The central methodology. Treat programming like dictionary compression.
Your job is to make the codebase semantically smaller — less duplicated
logic, fewer redundant patterns.

**The process:**

1. Write exactly what you want to happen for each specific case. No
   regard for "correctness" or "abstraction." Just get it working.
2. Do NOT extract shared code until at least two real instances exist.
   This is the most common mistake — trying to write "reusable" code
   before you have a single working example.
3. When a second instance appears, extract the shared portion into a
   function or struct.
4. Repeat at progressively higher levels. Objects and architecture
   emerge naturally from this process.

**Make your code usable before you try to make it reusable.**

With only one example (or zero), you will almost certainly design the
abstraction wrong. Two concrete instances give you two real use cases to
guide the extraction.

---

## 2. Write the Usage Code First

Before consulting documentation, before designing an API, before writing
any implementation — write the calling code. Think in your program's
terms, not the library's terms.

```
// Write THIS first:
mesh = load_mesh("player.obj");
draw_mesh(mesh, position, rotation);

// THEN figure out how load_mesh and draw_mesh work internally.
```

The simple exercise of writing down what the API should look like is all
that is really necessary to see where a bad design falls down.

---

## 3. Non-Pessimization

This is the most important performance concept. It is NOT optimization.

**Optimization** is hard, time-consuming, machine-specific work:
profiling hotspots, hand-tuning assembly, exploiting microarchitectural
features. This is what Knuth meant by "premature optimization."

**Non-pessimization** is simply not writing code that does unnecessary
work. It requires zero extra effort — it is actually less code:

- Don't copy data unless you must
- Don't chase pointers when contiguous arrays work
- Don't use indirect dispatch when direct dispatch works
- Don't scatter related data across the heap
- Don't create abstraction layers that prevent the compiler from seeing
  what's happening
- Don't do work the CPU doesn't need to do

The difference between pessimized and non-pessimized code is typically
larger than the difference between non-optimized and optimized code,
because there is no limit to how wasteful you can make something.

**refterm proof:** 3,000 lines of C that runs 100x faster than Windows
Terminal, achieved entirely through non-pessimization, not optimization.

---

## 4. The Five Multipliers

Five independent factors that compound to determine how slow a program
runs relative to hardware capability:

1. **Waste** — Instructions that don't contribute to the result.
   High-level languages can execute thousands of CPU instructions for
   what one instruction could do.
2. **Instructions Per Clock (IPC)** — Modern CPUs execute multiple
   instructions per cycle. Dependency chains and pipeline stalls reduce
   IPC from its theoretical max (4-6) down to 1 or less.
3. **SIMD** — Processing one element at a time when vector units handle
   4, 8, 16, or 32 simultaneously. This is a different programming
   paradigm, not an "optimization."
4. **Caching** — A cache miss to main memory costs ~100x more than an L1
   hit. Poor data layout destroys cache utilization.
5. **Multithreading** — Using one core when 8, 16, or more are
   available.

These multiply together. A program hitting all five penalties can run
10,000x to 50,000x slower than what the hardware delivers. Modern
software commonly operates 1,000x slower than hardware capability.

---

## 5. Objects Emerge — They Are Not Designed

Never design class hierarchies, UML diagrams, or inheritance trees
before writing code. These methodologies "always fail to achieve" their
goals because they "start from a place where the details don't exist."

Code is procedurally oriented. Objects are constructs that allow
procedures to be reused. They should arise from compression of concrete
code, not from upfront design.

OOP places encapsulation boundaries around individual objects, creating
tightly-coupled systems. Boundaries should be around **systems**
(physics, rendering, audio), not objects.

---

## 6. Switch Statements Over Virtual Dispatch

A switch statement is not inherently less polymorphic than a vtable —
they are two different implementations of the same concept. But:

- Switch statements can be optimized by the compiler (jump tables, binary
  search, direct branching)
- Virtual calls prevent inlining, constant folding, dead code
  elimination, and vectorization
- Polymorphic code forces heterogeneous pointer arrays, destroying cache
  locality

**Measured cost:** Virtual dispatch runs ~1.5x slower than a switch for
simple cases, and up to 15x slower when combined with other "clean code"
patterns. That is equivalent to erasing 14 years of hardware
advancement.

Prefer discriminated unions (tagged unions) over inheritance hierarchies.

---

## 7. Against "Clean Code" Performance Destruction

Five rules from Clean Code that harm performance:

1. **Prefer polymorphism over switch** — vtable indirection prevents
   optimization
2. **Hide object internals** — prevents data-layout optimization
3. **Keep functions small** — prevents inlining, creates call overhead
4. **Functions should do one thing** — prevents batch processing
5. **DRY** — can prevent specialization for hot paths (this one is
   mostly fine)

It cannot be the case that we are willing to give up a decade or more of
hardware performance just to make programmers' lives a little bit easier.

If the way you look at code is "messy or clean," that is a bad habit.
Code quality only matters insofar as it affects the end product.

---

## 8. Total Cost Is the Only Metric

Every coding decision must be evaluated by its **total lifetime cost**
across: writing, debugging, modifying, adapting, maintaining, and
running.

Abstract principles, philosophical purity, and categorical rules are
tools to be evaluated on cost, not principles to follow dogmatically.
If total cost is worse, it doesn't matter what you can say about the code
philosophically.

---

## 9. Platform Layer Architecture

The program is a service provider to the platform layer, not the other
way around.

**Rules:**

- Separate platform files with clear prefixes (`win32_`, `linux_`). A
  shared header defines the API boundary.
- Never scatter `#if` preprocessor directives through code. Different
  platforms may need conceptually different approaches.
- Platform provides: graphics buffer, sound buffer, input, timing.
- Program provides: an update function receiving those buffers.
- Keep the platform boundary surface area minimal.

**Unity builds:** Compile one translation unit per platform by
`#include`-ing all source files. Eliminates forward declarations,
accelerates compilation, simplifies the build.

---

## 10. Memory Management

Dynamic allocation (malloc/free) spreads management across code, makes
it opaque, and represents unnecessary trips through the platform layer.

**Arena allocators instead:**

- Single pre-allocated memory pool from the platform layer at startup
- Permanent storage: data persisting throughout the program's lifetime
- Transient storage: temporary data cleared between frames, rebuilt on
  demand
- Each allocation is a pointer bump — fast, deterministic, no
  bookkeeping
- Deallocation: free the entire block at once
- For multithreading: each task gets its own sub-arena

---

## 11. Zero-Is-Default Design

Design all structures so that memset-to-zero produces a valid initial
state.

```
some_type var = {};   // Always works. No constructors needed.
```

- Prevents forgotten initializations when struct fields are added later
- Structs obeying zero-is-default can be trivially copied, passed, and
  serialized
- Once you create a constructor, the compiler stops treating the struct
  as plain old data

---

## 12. API Design

From five years designing Granny 3D (shipped in 2,600+ products for 12
years with minor modifications):

1. **Granularity** — Break operations into controllable pieces. Coarse
   convenience functions must decompose into fine-grained operations.
2. **Redundancy** — Multiple ways to accomplish the same task
   (`SetOrientation3x3` OR `SetOrientationQ`).
3. **Coupling** — Always minimize. Unlike other characteristics, coupling
   has no benefits. Eliminate global state, implicit locks, type forcing.
4. **Retention** — Minimize retained state. Immediate-mode eliminates
   sync overhead. All retained-mode constructs should have
   immediate-mode equivalents.
5. **Flow Control** — The caller controls execution. Simple call-return
   is best. Deep callback chains requiring `void*` context are worst.

**The primary goal: eliminate API discontinuities** — sudden jumps in
integration effort. A good API provides closely-spaced options so
developers take minimal incremental steps.

**Rule of thumb:** Never supply a higher-level function that can't be
trivially replaced by a few lower-level functions that do the same thing.

---

## 13. Immediate Mode Over Retained Mode

Whether for GUIs or state management: minimize library-retained state.

- No data synchronization needed — all state lives in the application
- Procedural function calls serve as "widgets"
- Code-driven, centralized flow control
- All code relating to one widget instance is entirely localized — not
  scattered across event handlers, layout definitions, and callbacks

IMGUI does NOT require: continuous refresh loops, all-or-nothing
redraws, or actual immediate rendering.

---

## 14. Multithreading

Job-based, not thread-per-purpose.

- Dedicated threads for specific purposes (logic, render, audio) don't
  scale
- Work queue pattern: worker threads pull jobs until the queue is empty
- If the main thread waits for a job, it runs the worker loop itself
  rather than sitting idle
- Each task allocates its own sub-arena to avoid interlocking
- Thread management belongs in the platform layer

---

## 15. Error Handling

- No exceptions. They force error handling and cleanup to spread across
  the entire codebase.
- Use `goto` for complex error/transaction handling in C when
  appropriate.
- Limit the surface area of APIs that can raise error conditions.
- If total cost of exception safety is worse than the alternative, the
  philosophy doesn't matter.

---

## 16. Profiling and Measurement

- Measure before optimizing, but understand before measuring. Know what
  your benchmark actually tests.
- Calculate hardware's maximum throughput and design accordingly.
- Repetition test: run the same operation many times, track the
  **minimum** — the minimum represents true cost; everything above is
  noise.
- Use cycle-accurate measurement (RDTSC or equivalent).

**Three categories of "performance work":**

1. **Non-pessimization** — The bulk of your effort. Don't write
   inherently slow patterns. Portable, simple, future-proof.
2. **Actual optimization** — Rare, targeted, machine-specific. Profiling
   hotspots, SIMD, cache-line tuning.
3. **Fake optimization** — Categorical advice divorced from context.
   "Never use X!" "Always use arrays!" These are aphorisms that ignore
   the specifics of your problem. Avoid.

---

## 17. Data-Oriented Design

- Organize code by **operation**, not by type
- Struct of Arrays over Array of Structs when processing one field across
  many elements
- Contiguous memory for sequential access patterns
- Avoid pointer-based heterogeneous containers that scatter data across
  the heap
- Everything in a tight loop benefits from cache-friendly data layout

---

## 18. Build Systems

Extreme simplicity. A single build command that calls the compiler
directly. This approach works even on very large projects and is far
faster than anything automated build systems produce.

Never update your development tools mid-project.

---

## 19. Code Reuse

When NOT to reuse:

- Never before two real instances exist
- When abstraction would increase total cost
- When the "reusable" version would be harder to modify than two
  specialized copies

When libraries fail: "Because the libraries suck." Libraries add
non-zero integration cost. A significant proportion of a programmer's
career is spent fixing impedance mismatches between third-party systems.
Libraries change, update, break, and have edge-case bugs you cannot fix.

Build from scratch at least once. Not because it is always practical, but
because everyone should understand how systems work at a fundamental
level.

---

## 20. Coding Style

- Comment tags: `NOTE:`, `IMPORTANT:`, `STUDY:` — categorize by purpose
- Avoid comments that restate what code does
- All variables public — private variables only prevent bugs you don't
  have, while adding ceremony you don't need
- Enums always include a `_COUNT` sentinel for iteration
- Sequential enum values create same-sized arrays without manual counting
- Prefer centralized switch statements over logic distributed across
  derived classes

---

## 21. Conway's Law Is Inescapable

The structure of software inevitably reflects the structure of the
organizations that produce it. Organizational dysfunction manifests as
architectural dysfunction. This is the only truly unbreakable law of
software.

---

## 22. Your First Thought Should Be the User

Your first thought should not be how to make your job easier so you can
go home earlier. The thought should be how to make the best program for
your user. Slow code is dishonorable code.

Performance is not optional. Ignoring it inevitably leads to
extraordinarily costly ground-up rewrites. Every 100ms of latency costs
1% in sales. Page load increases from 1 to 3 seconds increase bounce
probability by 32%.

---

## Sources

- [Semantic Compression](https://caseymuratori.com/blog_0015)
- [Complexity and Granularity](https://caseymuratori.com/blog_0016)
- [Immediate-Mode GUIs](https://caseymuratori.com/blog_0001)
- [Designing and Evaluating Reusable Components](https://caseymuratori.com/blog_0024)
- [The Worst API Ever Made](https://caseymuratori.com/blog_0025)
- ["Clean" Code, Horrible Performance](https://www.computerenhance.com/p/clean-code-horrible-performance)
- [Performance Excuses Debunked](https://www.computerenhance.com/p/performance-excuses-debunked)
- [The Big OOPs (BSC 2025)](https://www.computerenhance.com/p/the-big-oops-anatomy-of-a-thirty)
- [Muratori / Uncle Bob Discussion](https://github.com/unclebob/cmuratori-discussion/blob/main/cleancodeqa.md)
- [The Thirty-Million-Line Problem](https://caseymuratori.com/blog_0031)
- [Computer, Enhance!](https://www.computerenhance.com/)
- [Handmade Hero](https://hero.handmade.network/)
- [Handmade Network Manifesto](https://handmade.network/manifesto)
- [refterm](https://github.com/cmuratori/refterm)
- [CoRecursive Podcast](https://corecursive.com/062-game-programming/)
- [SE Radio 577](https://se-radio.net/2023/08/se-radio-577-casey-muratori-on-clean-code-horrible-performance/)
