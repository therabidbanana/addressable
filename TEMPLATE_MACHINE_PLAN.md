# Template machine

A second engine for `Addressable::Template`, `:machine`, which parses a
pattern once into nodes and matches URIs with a small state machine
instead of a backtracking regexp. This file is the record of what it
does, where it differs from the `:regexp` engine, and what's left.

## Goals

1. **No breaking changes.** `Addressable::Template` keeps its public
   API, return values and exceptions. The `Template` specs pass against
   the machine; the only exceptions are the matching fixes below, which
   the specs pin per engine.
2. **No catastrophic backtracking.** Expanding, matching and building the
   regexp run in linear time on every supported runtime, including ones
   without regex memoization (Ruby < 3.2, JRuby, TruffleRuby), without
   relying on `Regexp.timeout`. The exception is a processor's pattern:
   it's the caller's regexp and costs what it costs, and the machine
   adds at most one check of it per place its value could end, so its
   time grows with the square of the value's length.
3. **Same or better performance** than today's `Template`. Matching
   (`match`, `extract`) may take up to 2× as long if that keeps the
   matcher readable, as long as adversarial input stays linear.

## Design

`Template` is still the only public class. It has two private engines
and hands each operation to one of them with an `if engine ==
:machine` guard:

- `:regexp`: today's code, left where it is.
- `:machine`: `Template::ParsedTemplate`, which parses the pattern once
  into nodes (`Template::Parser`, `Template::Machine`) and walks them.

Pick the engine for the whole app with `Template.engine = :machine`, or
for one template with `Template.new(pattern, engine: :machine)`.
`Template#engine` reads it.

Decisions that shape the code:

- **The machine never uses the regexp engine's code.** Code both engines
  need lives once (`Template::Values`, `Template::Matching`). `Template`
  keeps a private method that delegates to it only where 2.9.2 had that
  private method (`normalize_value`, `normalize_keys`), so overrides
  still apply to `:regexp`.
- **The nodes describe each operation.** Literal and expression nodes
  answer `expand`, `partial_expand`, `add_match_steps` and `regexp_source`.
  Each operator's `Expression` subclass supplies its leader, joiner,
  value shapes and regexp rewrites. `ParsedTemplate#render` joins nodes
  for expansion and for the regexp.
- **`Values` owns values and `Machine` owns syntax.** `Values` looks up,
  checks, transforms and encodes values. Expressions add leaders and
  separators and join the values.
- **Matching is a state graph** (`Template::Matcher`): a depth-first
  search that never tries the same branching state at the same position
  twice, which keeps it linear. The nodes add the states in the shape
  expansion writes (see "Matching rules").
- **The machine decides how each varspec matches before it adds any
  state, and reads its values itself** (`Machine::Slots`). One pass
  over the varspecs gives each a slot: its group, its processor
  pattern, whether it can never take anything, and the earlier value
  it has to repeat. The expressions add their states from the slots,
  and after a match `Slots#mapping` turns what each group captured into
  the mapping (`Expression#read`). `Matching.match_data` only serves
  `:regexp`; the engines share `Matching.restore`.
- **The machine builds the template's regexp only for `to_regexp` and
  `source`**, from its nodes, byte-for-byte what `Template`'s builder
  writes. It builds it once, on first use or in `freeze`. The matcher
  uses only small fixed patterns that can't backtrack across the
  template: a possessive run per character set, and one per literal.
- **The machine expands and builds regexps exactly as `Template` does,
  bugs included**, and fixing one is a `Template` change the machine
  follows. Matching is the exception: `:regexp`'s matching stays as it
  is, and the machine fixes the results listed under "Matching rules",
  documented there and pinned in the specs.

## Status (2026-11-20)

All of `expand`, `partial_expand`, `match`, `extract`, `variables`,
`named_captures`, `to_regexp` and `source` run on the machine. The
full suite passes in both IDNA modes (4,700 and 4,582 examples), and
the `Template` specs pass in machine mode (`TEMPLATE_MODE=machine`),
with the rows the matching rules change picked by engine. Line
coverage of the machine's files is complete except `matching.rb:143`,
the branch for Ruby 2.3 and earlier.

On 2026-11-19 (run 44642534313, commit `017e0a1`) the machine-mode CI
job passed on Ruby 2.3, 3.1, JRuby 10.0, TruffleRuby and current Ruby,
and the full suite on every runtime in the matrix. The `gemspec` job
fails by design until the branch merges.

Performance against `:regexp` (Ruby 3.3.1, `profile:template_machine`
at 3,000 iterations, two runs, 2026-11-20):

| Case | `expand` | `match`, reused template | `extract`, reused |
|---|---|---|---|
| simple | 0.58× | 1.35× | 1.30× |
| path, query, prefix | 0.61× | 1.40× | 1.34× |
| exploded | 0.52× | 1.48× | 1.71× |
| reserved, fragment | 0.64× | 2.10–2.49× | 1.77–2.03× |
| API path and query | 0.39× | 1.46× | 1.33× |
| long query | 0.88× | 0.51× | 0.51× |
| long path | 0.52× | 1.60× | 1.59× |

`partial_expand` is 0.39–0.78×. A new template matched once is
1.4–1.7× (reserved, fragment 2.1×). Every adversarial shape in the
profile and in `template_machine_spec.rb`'s linear-time checks grows
linearly, but the absolute cost is far above `:regexp`'s: at n=2,000,
`{;a*}{;b*}{;c}!` (ending `?!`) takes 72 ms and 3.3 MB, and `{a}`×12`!`
46 ms and 3.1 MB, against under 5 ms for `:regexp`.

## `Template` bugs the machine copies

- `variables` lists names from inside invalid expressions (`{{a}}`
  lists `a`).
- `variable_defaults` always returns `{}`. Document it, and consider
  deprecating it at the next major.
- A UTF-8 pattern that isn't valid raises `ArgumentError`, not
  `InvalidTemplateError`.
- `match(nil)` raises `NoMethodError`, where the docs say `nil`.
- Non-ASCII literals in a pattern that isn't UTF-8 make `match` raise
  `Encoding::CompatibilityError`.
- The machine doesn't copy this one: on Ruby 2.3, `named_captures`
  merges `{42}` with `{__42__}`.

## Where the machine differs from `Template`

### Processor patterns

A processor whose `match` gives a variable a regexp. `Template` puts
the pattern in its regexp, which can then backtrack across the whole
template on Rubies without regex memoization, since it drops its
pruning for them. The machine checks each pattern against the value
alone, trying the pattern's first choice, then the ends nearest it
(`ProcessorPattern`). So:

- Where a URI can be split more than one way, the split can differ from
  `Template`'s.
- A lookahead or lookbehind in a pattern stops at the value's ends:
  `{a}.{b}` with `\w+(?=\.)` doesn't match `x.y`.
- A variable with a pattern is optional like any other, so the earlier
  variable can take text the pattern could match: `{a}{b}` with
  `[0-9]+` for `b` gives `x12` to `a`.

### Matching rules

RFC 6570 only defines expansion, so how a URI matches a template is
Addressable's own contract, and `Template` matches some templates in
ways that are hard to defend: results that don't expand back to the
URI. The machine fixes them; `:regexp` keeps its results, and
`engine: :regexp` is the way back. List each one in the changelog when
the machine ships.

The machine's rules:

- **A match expands back to the URI.** For every URI written by
  expanding some values, expanding what `match` gives back writes that
  URI again (not always the same values: a list and a hash can write
  the same text). A property spec over generated templates and values
  checks it (`template_machine_spec.rb`, "round trip"), and in machine
  mode `template_match_spec.rb`'s generated strings check that every
  match is sound and that the machine matches whatever `:regexp`
  matches correctly. With a `+` or `#` expression the round trip
  compares URIs decoded: a `+` or `#` value can take text a later
  expression pct-encoded, and the match decodes it (as `:regexp` does).
- **Every expression has one shape.** Each variable may be left out.
  The first value present takes the expression's leader and each later
  one the joiner, which is required: `{/a,b}` matches like `{/a}{/b}`,
  and `{?a,b}` like `?` then `a=…`, `&b=…`. A variable the URI leaves
  out is `nil`, never `""`, `[]` or `{}`; an empty value the URI holds
  keeps it (`{/a*}` on `/` gives `[""]`).
- **Names in `;`, `?` and `&` are matched as written.** A `;` value
  written `k=` doesn't match, since expansion writes `;k` for an empty
  value. Inside an exploded `;`, `?` or `&` value an empty member is a
  `""` key.
- **The earlier variable wins** wherever two variables could take the
  same text, with four exceptions, tried in this order:
  1. A variable a `;`, `?` or `&` expression names, outside an exploded
     one, takes its own pair: the exploded value stops before the first
     place the name follows it where the rest can match.
     `{?a*,b}` on `?x=1&b=2` gives `{"x" => "1"}` and `"2"`.
  2. A `+` or `#` value stops at the **first** `?` or `#` where the
     rest can match, whatever comes next, since the first `?` starts a
     URI's query and the first `#` its fragment:
     `/files/{+path}{?q}` on `/files/a/b?q=c` gives `path` `a/b`, and
     `{+a}{+b}` on `x?y` gives `x` and `?y`.
  3. Any value stops before the **last** place the next expression's
     leader follows it where the rest can match, so the next expression
     isn't left empty when the URI has its text: `/{name}{.ext}` on
     `/archive.tar.gz` gives `archive.tar` and `gz`, `{/dirs*}{/file}`
     on `/a/b/c.txt` gives `["a", "b"]` and `c.txt`, and `{+a}{/b}` on
     `x/y/z` gives `x/y` and `z`. Where 2 also applies, it comes first:
     `{+a}{#b}` on `x#y#z` gives `x` and `y#z`, not `x#y` and `z`.
  4. A `+` or `#` value before its expression's last stops at a comma.
- **An exploded variable right after another in its expression takes
  nothing** (`{;foo*,bar*}` matches like `{;foo*}`), so the matcher adds
  no steps for it.
- **A name written again matches the earlier value,** where that
  value's place in the URI is decided: it and every variable before it
  end at their run's end, as what follows each is a character it can't
  hold, and no other value comes between the two (`Machine::Slots`). The
  later varspec matches the value written as the earlier one is, or as
  expansion writes it, and is left out only where the earlier one is.
  A prefix is the start of the value: `{/var:1,var}` on `/v/value`
  gives `"value"`. Elsewhere (`{a}{a}`, `{a}{b}{a}`) the name matches as
  if written once, the first value winning: comparing at every place
  the earlier value could end was quadratic (`{a}{a}` 1.0 s at 16 KB)
  and, with a value between, close to cubic. The search remembers the
  states between the two once for each place the earlier value took
  (`Matcher#note_dependencies`).

Examples of where the machine's results differ from `:regexp`'s
(2.9.2 gives the same as `:regexp`), generated from both engines on
2026-11-20:

| Template | URI | `:regexp` | `:machine` | Rule |
|---|---|---|---|---|
| `{a}{b}` | `xyz` | `"a" => nil, "b" => "xyz"` | `"a" => "xyz", "b" => nil` | Earlier wins |
| `{/a*,b*}` | `/x/y` | `"a" => [], "b" => ["x", "y"]` | `"a" => ["x", "y"], "b" => nil` | Earlier wins |
| `{/dirs*}{/file}` | `/a/b/c.txt` | `"dirs" => ["a", "b", "c.txt"], "file" => nil` | `"dirs" => ["a", "b"], "file" => "c.txt"` | Next leader (3) |
| `{a,b}` | `y` | `"a" => "", "b" => "y"` (writes `,y`) | `"a" => "y", "b" => nil` | Left out is `nil` |
| `{+a*,b*}` | `x,y` | `"a" => ["x", "y"], "b" => []` | `"a" => ["x", "y"], "b" => nil` | Left out is `nil` |
| `{?a,b}` | `?a=1b=2` | `"a" => "", "b" => nil, "1b" => "2"` | no match | Joiners required |
| `{?a}` | `?x=1` | `"a" => nil, "x" => "1"` | no match | Names as written |
| `{;a,b*}` | `;x=1;y=2` | `"a" => nil, "x" => "", "b" => {"1" => "", "y" => "2"}` | `"a" => nil, "b" => {"x" => "1", "y" => "2"}` | Names as written |
| `{;hash*,first}` | `;a=1;b=2;c=3;first=foo` | `"hash" => {…, "first" => "foo"}, "first" => nil, nil => ""` | `"hash" => {"a" => "1", "b" => "2", "c" => "3"}, "first" => "foo"` | Named pair (1) |
| `{;a*,b}` | `;x=1;y=2;b=3` | `"a" => {…, "b" => "3"}, "b" => nil, nil => ""` | `"a" => {"x" => "1", "y" => "2"}, "b" => "3"` | Named pair (1) |
| `{+a*}!` | `y!` | no match (the members took the `!`) | `"a" => ["y"]` | Expands back |
| `{#a*}x` | `#x` | `"a" => nil` (writes `x`) | `"a" => [""]` | Expands back |
| `{;a*}` | `;x=;` | `"a" => {"x" => ""}` (writes `;x`) | no match | Names as written |
| `{a}/{a}` | `x/y` | `"a" => "x"` (writes `x/x`) | no match | Name written again |
| `/{lang}/page{?lang}` | `/en/page?lang=fr` | `"lang" => "en"` | no match | Name written again |
| `{/var:1,var}` | `/v/value` | `"var" => "v"` (writes `/v/v`) | `"var" => "value"` | Name written again |

`template_spec.rb`'s own note on the `{;hash*,first}` example calls a
separate key the more likely reading.

The specs pin each difference: `MACHINE_SPLITS` in
`template_match_spec.rb`, and `machine_differences`,
`processor_differences` and the "matching fixes" examples in
`template_machine_spec.rb`.

`to_regexp` and `source` stay byte-for-byte `Template`'s, so on a
machine template, matching `to_regexp` can split a URI differently from
`match`, or match a URI `match` rejects (see "Next work", 10).

## Next work

Each item stands alone and can be built as described; items 1–4 and
12 record decisions made on 2026-11-20. Work one piece at a time, with
specs first, and get each reviewed before committing (see "Working on
it").

### Matching results

1. **Cap a prefix at its length (decided).** `{a:3}` matches `abcdef`
   as `{"a" => "abcdef"}`, though expanding `{a:3}` never writes more
   than three characters. A prefix varspec takes at most its length in
   characters, counting a pct-encoded triplet as one, as
   `Values.prefix` does for `+` and `#`; then `{a:3}` on `abcdef`
   doesn't match. That bounds the run, and fixes a known wrong result:
   `{a:1}{a:2}` on `xy` gives `"xy"`, which writes `xxy` (pinned in
   `template_machine_spec.rb` with a "Known wrong" note). With bounded
   prefixes, two prefixes of one name can be compared (the shorter is
   the start of the longer, and the same if the value is shorter than
   both), so it won't match; and a prefix's end is near enough to
   decided that `Machine::Slots` can accept shapes like `{a:1}{a}`.
2. **Reject repeated names whose values disagree (decided; worth more
   exploration).** `{a}{a}`, `{a}{b}{a}`, `{a}.{a}` and a name
   exploded in one varspec and not another (`{/a}{/a*}`) aren't
   converted by `Machine::Slots`, and give the first value, which can
   fail to expand back. For now, once the search finds a match, check
   each such name's varspecs (decoded values equal, a prefix the start
   of the whole, left out only where it writes nothing) and give `nil`
   if they disagree. That's linear and never gives a wrong value, but
   it can miss a split that agrees: `{a}{a}` on `xx` finds `"xx"` and
   `nil` first, and gives `nil` rather than `"x"`. Keep the open
   question in the plan: a check that finds the agreeing split and
   stays linear would replace this. Leave the round trip's generator
   out of these shapes until then.
3. **Match a list in an unexploded variable (decided).** `{/a}` with
   `["x", "y"]` writes `/x,y`, but `{/a}` on `/x,y` gives `nil`.
   Outside `+` and `#` a string's comma is written `%2C`, so a raw
   comma in an unexploded value can only come from a list. Where the
   joiner isn't a comma (`/`, `.`, `;`, `?`, `&`), let the value hold
   raw commas and give it as a list: `{/a}` on `/x,y` gives
   `["x", "y"]`, `{?a}` on `?a=x,y` the same. Not for the default
   operator, whose joiner is the comma, nor `+` and `#`, whose values
   hold raw commas. An unexploded hash writes the same text
   (`{"k" => "v"}` writes `/k,v`), so those URIs give a list: the two
   can't be told apart. A new result where there was none, so it
   belongs in a minor release.
4. **Match exploded hashes outside `;`, `?` and `&` (decided).**
   Expanding `{/a*}` with `{"k" => "v"}` writes `/k=v`, which doesn't
   match today. Expansion writes the `=` between key and value as it
   is, and pct-encodes an `=` inside a key, a value or a list member
   (`["k=v"]` writes `/k%3Dv`, `{"k=x" => "v=y"}` writes
   `/k%3Dx=v%3Dy`; checked on both engines). So for the default, `/`
   and `.` operators, a member with a raw `=` is a pair: if every
   member has one, the value is a hash; if none does, a list; mixed
   members don't match. Not for `+` and `#`, which write `k=v` for both
   the hash and the list `["k=v"]`.

### Memory

On a URI that doesn't match, the search tries every state at every
position it can reach, and remembers each branching one, so memory
grows with the URI's length times the template's branching states.
Measured at 16 KB (memo only, `ObjectSpace.memsize_of`): `{a}`×12`!`
16.8 MB, `{;a*}{;b*}{;c}!` and `{a}{b}{c}` 4.2 MB, the rest under
1 MB. `:regexp` allocates well under 0.1 MB for each.

5. **Prune variables that can never take anything.** Under earlier-wins,
   a variable with no leader right after another whose value can hold
   everything it can (`{a}{b}`, `{a}{b}{c}`, and `{a}`×12, whose
   repeats aren't converted) never gets a value: checked on 100,000
   generated URIs over `{a}{b}`, `{a}{b}x`, `{.a}{b}`, `{a}{.b}` and
   `{a}{b}{c}`. Marking such a variable's slot absorbed, as
   `Machine::Slots` does for an exploded variable after another, would
   shrink these to one variable's states. `Slots` only looks at the
   slot before in the same expression today; this needs the one before
   in the template. It depends on item 1: a capped prefix
   (`{a:3}{b}`) leaves text for the next variable.
6. **Shrink the memo and the capture lists.** Notes from reading
   `Search` and `Matcher#match` (2026-11-20, not yet measured; measure
   each with `ObjectSpace.memsize_of` or `memory_profiler`, which runs
   on 2.3, before deciding). Neither changes a result.
   - *The memo is a Hash of Integers.* `Search#first_time?` already
     computes a dense key (`state.index * (@size + 1) + position`), so
     the only cost left is the Hash: about 30–40 bytes an entry on 3.3,
     plus the spare space a Hash keeps as it grows. A bit-packed memo
     is a handful of lines: a binary String of
     `(states * (size + 1) + 7) / 8` zero bytes, read and set with
     `getbyte` and `setbyte` (Ruby 1.9+). That's one bit an entry,
     about 1/250th of the Hash. To keep it small on long URIs, number
     only the states that branch (`State#branches?`) and use that
     number in the key. A state with `depends_on` also keys on
     captures, so it can't use a bit; keep the Hash for those states
     only. A template with no repeated name has none of them.
   - *A `CaptureList` for every capture state reached.* Each is a
     Struct, so an object on the heap, and `Capture` isn't memoized, so
     one is made every time the search reaches it, including on paths
     that fail. The other way to give each attempt its captures without
     copying is an undo log on the stack the search already has. Keep
     one mutable `slots` Array. When `Capture#follow` sets a slot, it
     first pushes a restore entry (the slot and its old value, as three
     flat entries like the others) and then the next attempt. When
     `Matcher#match` pops a restore entry, the attempts above it have
     all failed, so it puts the old value back. Attempts pushed earlier
     then see the captures as they were when they were pushed. `Done`
     copies `slots`. That allocates nothing per capture.
     `LeaveOutIfEmpty`'s `captures.rest` becomes clearing the slot's
     start (with its own restore entry), and `Search#captured` and
     `Search#span` (used by `SameValue`, `LeftOut`, `StartsWith` and
     the memo key) read `slots`.
   - *Already covered:* states as flat records (the stack's three
     entries, no `Attempt` objects), character classes as one run
     pattern per set rather than per-character edges, no DFA, and
     building the matcher once per template (except with a processor
     that has `match`; see item 8).

### Speed

7. **Reserved, fragment is over 2×** (2.1–2.5× for `match`). Its query
   value steps through every character, since `{#section}`'s `#` can be
   written `%23`, which a query value can hold. Making
   `State#bytes_after_run` carry texts too ("followed by `=`, or where
   `%23` occurs") would likely fix it, at the cost of a harder idea to
   explain. `{+a}/{b}` over 50 directories is 2.9×, as the value can
   stop at every `/`.

   Two gaps the printed graphs show (2026-11-20, not yet measured). A
   run only skips to where the text after it occurs
   (`State#leading_text`) when a literal follows it directly, or
   through a `Capture`. `Jump`, `LeaveOutIfEmpty` and `FollowedBy`
   don't pass the text on, so:
   - A value with no leader before a literal it could hold steps
     through every character: `{a}.json` and `x{a}y` list a plain
     `GreedyRun unreserved`, where `{/a}.json` lists `stopping before
     ".json"`.
   - The first pass of rule 3 (`/{name}{.ext}`) could stop only where
     the leader occurs, but its run is followed by a `FollowedBy`.
8. **Processor patterns.** A pattern whose next state can start
   anywhere checks every end: `{a}{b}` with `a*` on 2,001 characters
   that don't match takes 17.8 ms (`:regexp` 0.24 ms), and grows
   quadratically, which Goal 2 accepts. Untried: for a greedy pattern
   like `a*`, the first choice is the longest end it reaches, so the
   ends past it needn't be checked; that doesn't hold for every pattern
   (`a*?`, `a|ab`), so it needs a way to tell when it's safe. Also,
   `matcher_for` rebuilds the whole matcher on every call with a
   processor that has `match`, since the processor is asked for its
   patterns each time.
9. **Smaller ideas**, each to measure with `profile:template_machine`
   before keeping: an Array for `FirstBytes` (lookups 11 rather than
   40 ns, but slower to build); a shortcut in `Expression#expand` for
   one-variable expressions (no `map`, `compact!`, `flat_map`); and
   measuring with YJIT, which Rails 7.1+ turns on by default on 3.3.

### Docs, CI and release

10. **Document `to_regexp` on the machine.** Its matches can differ
    from `match`'s (see "Matching rules"); say so in its doc comment,
    and revisit when `:regexp` is removed.
11. **CI.** Make the machine-mode job (`.github/workflows/test.yml`,
    `template-machine`, now `continue-on-error: true`) blocking; run it
    on every runtime (2.3 to 4.0, JRuby, TruffleRuby) in both IDNA
    modes; add `profile:template_machine` to CI. Check that the
    processor pattern check (`\A`, `\z`, `$~`) behaves on JRuby and
    TruffleRuby.
12. **Before release N.**
    - Dumps: a `Marshal` or YAML dump of a used machine template holds
      its caches, which name private classes (2,630 bytes against
      436). Dump only the pattern and the engine and rebuild the caches
      on first use. Dumps from earlier versions must still load; an
      earlier version can't load the new format, which matters for
      caches shared across a rolling deploy.
    - Measure what building the regexp in `freeze` costs a frozen
      machine template.
    - Changelog entries all go in at release N (decided 2026-11-20),
      not with each change as `CLAUDE.md` asks: the machine is opt-in
      and still changing, so entries written now would be rewritten.
      List the new API (`Template.engine`, `Template.engine=`,
      `Template#engine`, `engine:`), the processor differences and the
      matching rules table.
    - Overrides of `Template`'s private methods (`normalize_value`)
      have no effect on the machine. That's a behaviour change once
      `:machine` is the default; say so in the changelog, with
      `engine: :regexp` as the way back.

### Small differences and cleanup

13. **Small behaviour differences.** `expand(mapping, processor,
    false)` where `transform` returns an array whose first member isn't
    a String (`[1, [2, :x], nil]`): `:regexp` raises `NoMethodError`,
    the machine returns `?a=1&a=[2, :x]&a=`. An invalid processor
    pattern raises `RegexpError` in both engines, with different
    messages.
14. **Simplification.** Code that only copies a `Template` bug
    (`Parser#names_in_invalid_token`, `Machine::Invalid#names`) goes
    once `Template` fixes it. `Matching.match_data` only serves
    `:regexp`, and goes with it. `Expression#read` still copies one of
    its quirks: an unexploded `;`, `?` or `&` value goes under the name
    its text has, cut at the next `=`, which only a processor's pattern
    can make differ from the variable's (`{?n}` capturing `12` gives
    `"12" => ""`).
15. **Round-trip coverage of repeated names.** The round-trip spec's
    generator gives each name one use, and `template_match_spec.rb`'s
    soundness check skips patterns that reuse a name. Both could now
    include the repeated shapes `Machine::Slots` converts.

## Tried and ruled out

- **Comparing repeated names at every place the earlier value could
  end:** quadratic to cubic (see "Matching rules").
- **Normalizing the URI before matching.** `URI#normalize` changes
  results (it lowercases the host, and a literal `%41` stops matching
  once `%41` becomes `A`), and costs about 50 µs per URI.
- **A run's next character with a one-unit pattern:**
  `CharacterSet#character_end` is 2–9% of matcher time, and a scanner's
  `pos=` and `skip` cost about as much as the byte checks they'd
  replace.
- **`pop(3)` for the search's stack:** reads better, but makes an array
  per attempt (3–7% slower).

## Considered, not built

None of these was built or measured; each was set aside on paper, for
the reason given. Revisit one if the measurements change the picture.

- **Porting `:regexp`'s pruning rules** (`absorbs?`, the
  `group_regexp_source` rules) into the matcher. The matching rules
  took their place: they give the matcher fewer ways to split a URI,
  and change results where the pruning rules only copied them.
- **A byte or bit memo as the first fix for memory** (2026-11-19):
  shelved as too fiddly while states could still be trimmed. Item 6
  revisits it as a small, separate change.
- **A thread list (Pike VM)**, as RE2 and Rust's regex use: memory
  proportional to the template rather than to the URI. Against it: it
  reads every byte in Ruby, which the run skips avoid, so it would
  likely be slower on typical URIs; it needs processor patterns handled
  apart; and it's a second matcher core. It wouldn't help repeated
  names: two threads with different captures that reach the same state
  collapse into one, which misses splits as an unkeyed memo does. Worth
  a prototype in a scratch file against the profile if memory stays a
  problem after items 5 and 6.
- **RE2's backward pass** (work out, for every state and position,
  whether the end is reachable, then walk forward without
  backtracking). Its cost is predictable, but it fills the whole
  states × positions table on every match, and it's a second engine to
  read.

Prefilters and shortcuts flatter the profile's adversarial payloads, so
each one needs payloads that get past it, so the profile can still show
linear growth. A run cache that only helped forward searches once made
`{;a,b}` quadratic; the linear-time checks in `template_machine_spec.rb`
catch that kind of mistake now.

## Releasing

- **Release N (minor):** the machine ships opt-in, with `:regexp` as the
  default. Document `Template.engine = :machine` and the `engine:`
  keyword. Add changelog entries under `` ### `Addressable::Template` ``.
- **Release N+1 (minor):** `:machine` becomes the default, and `:regexp`
  still works but warns that it's deprecated. The specs run on the
  machine by default, and `TEMPLATE_MODE=regexp` runs them on `:regexp`.
- **Next major:** remove the `:regexp` engine, its private methods and
  `TEMPLATE_MODE`. Each `engine == :machine` guard's branch becomes its
  method body.

## Working on it

```sh
bundle exec rake spec                    # full suite, native IDNA
IDNA_MODE=pure bundle exec rake spec     # full suite, pure-Ruby IDNA

# The Template specs on the machine
TEMPLATE_MODE=machine bundle exec rspec spec/addressable/template*_spec.rb

# :regexp vs :machine: time, objects, agreement, adversarial growth
ITERATIONS=3000 bundle exec rake profile:template_machine

# The states the machine matches a template with
PATTERN='/{name}{.ext}' bundle exec rake template:graph
```

- `TEMPLATE_MODE` only switches the engine inside the specs. In a
  script or `ruby -e`, set `Addressable::Template.engine = :machine` or
  pass `engine: :machine`; otherwise you're looking at `:regexp`.
- Machine specs: `template_machine_spec.rb` (each operation against
  `:regexp`, the matching fixes, the round trip and the linear-time
  checks), `template_engine_spec.rb`, `template_parser_spec.rb`,
  `template_slots_spec.rb` and `template_matcher_spec.rb`, which pins
  the printed graph (`Matcher#to_s`) of one small template per shape
  and tries the matcher's builder methods on hand-built matchers. A
  change that's meant to alter a graph updates its pinned lines; start
  an edge case there, as a hand-built matcher, before touching the
  operators.
- Where the code is: `lib/addressable/template/parsed_template.rb`
  (the engine), `machine/` (the nodes: `slots.rb` decides how each
  varspec matches before any steps are added, `expression.rb` builds
  each expression's match steps from its slots, `repeated_value.rb`
  matches a name written again),
  `matcher.rb` (the builder and the search loop) and `matcher/` (the
  states, the search, character sets and first bytes).
- Follow `CLAUDE.md`: specs first, Ruby 2.2-compatible code, both IDNA
  modes. Any warning fails the suite.
- Work one piece at a time, and wait for review before committing.
- Run the profile twice before calling a slowdown real.
- Add new adversarial shapes to the linear-time checks in
  `template_machine_spec.rb`, which run in the default suite.
