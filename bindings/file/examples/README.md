# A worked set in the file binding

Six tickets belonging to a fictional project `ex`, one in each of the five
lifecycle positions, written to be read rather than run: the commands in their
`verify` blocks name paths in that fictional project and will not pass here.

What is real is the shape. The set lints clean:

```
$ python3 reference/issues.py lint bindings/file/examples/

6 tickets, 0 errors, 0 warnings
```

Zero warnings as well as zero errors is the part that took arranging. `EX-001`
and `EX-002` both append to `CHANGELOG.md`, which would be reported as a small
expected merge if both were startable at once — `EX-002` is blocked by `EX-001`,
so it is not. The three tickets that are simultaneously startable own three
disjoint sets of paths, which is the property that makes running them in
parallel safe rather than merely attempted.

Read them alongside [`../BINDING.md`](../BINDING.md), which is where the rules
they follow are stated normatively.
