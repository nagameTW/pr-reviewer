Correctness — bugs, broken logic, unhandled realistic inputs, concurrency issues; regressions in the callers of anything whose signature or semantics the diff changed.

Concurrency issues, spelled out: two threads, tasks or processes touching the same state without a lock or atomic operation (a data race); checking a condition and acting on it in two steps while something else can change it in between (check-then-act, also called time-of-check to time-of-use, CWE-367); locks taken in different orders on different paths (deadlock); an async call whose result is used without being awaited; a shared file or temporary path two runs can write at once.

Null and contract, spelled out: report a missing null check only when you can point to the line that returns null, None, nil or an empty value, or to a type that allows it (Optional, @Nullable, T | None). That is a null dereference (CWE-476). A changed signature that a caller or an implementer did not follow also belongs here, as does a fixed error return or a stub where the contract promises a real result. Set the area to contract.

Call target, spelled out: a wrapper, cache or delegate that calls a method of the same name must call the wrapped object, not itself or a sibling. Before you report a route parameter name or an HTTP method as wrong, open the route definition with Read or Grep and confirm it.
