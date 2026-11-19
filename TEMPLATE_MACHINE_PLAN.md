# Template machine

## Goals

1. **No breaking changes.** `Addressable::Template` keeps its public
   API, return values and exceptions. The `Template` specs pass unchanged
   against the machine.
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
  search that never tries the same state at the same position twice,
  which keeps it linear. Its splits follow `Template`'s regexp, and
  `Template::Matching.match_data` turns captures into the same
  `MatchData` for both engines.
- **The machine builds a regexp only for `to_regexp` and `source`**, from
  its nodes, byte-for-byte what `Template`'s builder writes. It builds
  it once, on first use or in `freeze`.
- **The machine matches `Template` exactly, bugs included.** Fixing one is
  a `Template` change with its own changelog entry, and the machine
  follows it. The one exception is processor patterns; see "Where the
  machine differs from `Template`".

## Done

- **Phase 0, baseline:** the profile task, and a non-blocking CI job that
  runs the `Template` specs in machine mode.
- **Phase 1, structure and parsing:** the engine switch and delegation,
  shared errors and `MatchData`, a lexer that accepts and rejects exactly
  what `Template` does, and `variables`.
- **Phase 2, expansion:** `expand` and `partial_expand`, including
  processors, blocks, prefixes, pct-encoded triplets and non-ASCII
  literals.
- **Phase 3, matching:** the matcher, processors' `match` and `restore`,
  and an oracle that compares the machine's splits with `:regexp`'s.
- **Phase 4, regexp API:** `named_captures` from the nodes, and
  `to_regexp` and `source` rendered from the nodes. A generated spec
  checks about 46,000 patterns against `Template`'s builder.

Machine mode passes every `Template` spec (Ruby 3.3.1).

Performance (Ruby 3.3.1, compared with `:regexp`):

- `expand`: 0.5–0.9× the time, with fewer objects.
- A new template expanded once: about 0.9×. `Parser` notes each node's
  context while it parses, which adds about 2–8 µs to every template,
  even one that's only expanded (it was about 0.8× when that waited for
  the first match).
- `partial_expand`: 0.4–1.0× the time.
- `match` and `extract`: 1.2–2.0× on new templates and the simple one,
  but 2.2–2.8× on reused templates with query, exploded and reserved
  expressions, which is over the 2× target. Adversarial payloads grow
  linearly.

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

Processor patterns (a processor whose `match` gives a variable a
regexp). `Template` puts them in its regexp, which can then backtrack
across the whole template on Rubies without regex memoization, since it
drops its pruning for them. The machine checks each pattern against the
value alone, trying the pattern's first choice, then the ends nearest
it. So:

- Where a URI can be split more than one way, the split can differ from
  `Template`'s.
- A lookahead or lookbehind in a pattern stops at the value's ends:
  `{a}.{b}` with `\w+(?=\.)` doesn't match `x.y`.

The way back is `engine: :regexp`. Note both in the changelog when the
machine ships.

## What's left

### Review findings to fix

From a review of the branch (2026-11-18), on Ruby 3.3.1 only: nothing
was run on JRuby, TruffleRuby, a Ruby without regex memoization, or with
`IDNA_MODE=pure`.

Its verdict: behaviour parity is excellent, but the matcher doesn't meet
the performance and backtracking goals, and processor patterns were
catastrophically slow. Don't make `:machine` the default until 3 and 4
are decided on.

What it checked and found sound: `bundle exec rake spec` passes in both
modes (4442 and 4730 examples). A differential fuzz of 8,000 random
templates (about 116k operations) found no differences between master,
branch `:regexp` and branch `:machine`, so moving code into `Values` and
`Matching` and the new `LITERAL_TOKEN` didn't change `:regexp`. Line
coverage of the new files is complete except `matching.rb:142`, the
branch for Ruby 2.3 and earlier.

#### 1. Processor patterns were polynomial, even on URIs that match (resolved)

`Search#pattern_ends` listed every end of a processor's pattern before
the search tried the first, recompiling the pattern for each end with a
`(?!…|…)` that ruled out the ends found so far: roughly 15× the time
for each doubling of the URI.

| Template, processor pattern | URI | `:regexp` | `:machine` |
|---|---|---|---|
| `http://example.com/search/{query}/`, `[^/]+` | 227 chars, matches | 67 µs | 0.30 s |
| `/{first}/{second}`, `.*?` and `.*` | 202 chars, matches | 65 µs | 0.66 s |
| `{a}/{b}`, `.*` | `"a"*500`, no match | 0.05 ms | 10.1 s |
| `{a}/{b}`, `.*` | `"a"*1000`, no match | 0.11 ms | over 30 s |

Resolved by checking each candidate end directly (`ProcessorPattern`):
the pattern's first choice, then the ends nearest it, each only where
what follows can start, against `\A(?:pattern)\z` on the value. That
loosens parity for processors; see "Where the machine differs from
`Template`". After it, the rows above take 0.39 ms, 0.78 ms and
0.45 ms (the 1000-character row wasn't rerun). The worst case is a
pattern whose next state can start anywhere, which checks every end:
`{a}{b}` with `a*` on 2,001 characters that don't match takes 17.8 ms
(`:regexp`: 0.24 ms), and grows quadratically, which Goal 2 accepts.
An untried way to cut it: for a greedy pattern like `a*`, the first
choice is the longest end it reaches, so the ends past it needn't be
checked. That doesn't hold for every pattern (`a*?`, `a|ab`), so it
needs a way to tell when it's safe.

Rejected: putting the patterns in a regexp rendered from the nodes, as
`Template` does. Exact, but it needs a second regexp shape in every
node, and it backtracks across the template on Rubies without
memoization, since `Template` drops its pruning when a processor has
`match`. Finding the ends lazily kept exact parity, but stayed
polynomial for lazy patterns and URIs that don't match.

#### 2. Processor patterns raised `RegexpError` on long URIs (resolved)

`pattern_ends` wrote `.{N}` with N up to the URI's length, and Onigmo
caps a repeat at 100,000.
`Template.new("{a}/{+rest}", engine: :machine).match("ab/" + "x"*100_010, processor)`,
with a processor whose `match` returns `"ab?"`, raised
`RegexpError: too big number for repeat range`, where `:regexp` returns
`nil`. Resolved with 1: there are no ruled-out ends any more.

#### 3. Matching is linear but about 1000× slower on adversarial input

`matcher.rb:200-222` and `matcher/states.rb`. Growth is a clean 2× per
doubling, but at 10–45 µs a byte:

| Template | 16 KB URI that doesn't match | `:regexp` | `:machine` |
|---|---|---|---|
| `{a}` ×12, then `!` | `"a"*16000` | 0.4 ms | 712 ms |
| `{/a*,b*,c*}!` | `"/"*16000` | 0.2 ms | 428 ms |
| `{;a*}{;b*}{;c}!` | `";a=1"*4000` | 0.3 ms | 349 ms |

`{/a*,b*,c*}!` also allocates 1.5M objects and a 33 MB memo hash (608k
entries) for one 16 KB URI. Linear, but a practical CPU and memory
regression on MRI 3.2+. The "10–600×" under "Matcher speed" understates
it.

#### 4. The 2× target only holds for short URIs

The ratio grows with the values' length, and the profile's cases in
`tasks/template_machine_profile.rb` are all 27–69 characters:

| Template | URI length | Ratio to `:regexp` |
|---|---|---|
| `http://example.com/users/{id}` | 27 | 1.2× |
| `/repos/{owner}/{repo}/issues{/number}{?state,labels,page,per_page}` | 82 | 2.7× |
| `/q{?a,b,c}` | 911 | 11.7× |
| `/files{/path*}` | 488 | 13.9× |

For the 82-character URI the matcher alone takes 159 µs against 1.9 µs
for the raw regexp; the whole `#match` ratio looks modest only because
both engines share about 50 µs of `Matching.match_data` and URI
handling. Add longer URIs to the profile.

#### 5. Where the matcher's time goes

Besides the ideas under "Matcher speed":

- **Pruning is only in the regexp.** `Expression#regexp_source`
  (`machine/expression.rb`) uses `absorbs?` to write `(?!)`, and the
  `group_regexp_source` overrides prune further (`NOT_AFTER_VALUE`,
  empty groups after an exploded variable). `add_match_steps` ignores
  all of it and walks the naive shape: `{a}{b}{c}{d}{e}x` on `"a"*1000`
  makes 31 attempts a byte, 10k of them memo hits. Each operator's
  shape is also described twice.
- **Every state is memoized.** `Search#first_time?` does a hash insert
  for every attempt, including `Capture`, `Literal`, `MemberStart` and
  `MemberEnd`, which have one way on. Memoizing only `Choice` and the
  runs would keep it linear with about half the hash work and memory.
- **Per-attempt allocation.** Each step makes an `Attempt` and an array
  from `follow`, then `reverse_each` pushes them; `Unit#match_end`
  allocates a substring with `byteslice` per comparison.
- **Lazy and greedy runs step one character at a time** through the
  whole loop whenever the next state can start with a character of the
  set (`LazyRun#follow`). That's why `/q{?a,b,c}` costs 6.3 attempts a
  byte.
- **`FirstBytes#allow?`** indexes a 257-bit Integer: 44 ns, against
  19 ns for an Array lookup, on every `Choice` and `LazyRun`.
- **No whole-URI rejects.** A trailing literal that doesn't end the
  URI, or a required literal that never occurs in it, would reject every
  `…!` case in 3 at once.
- `matcher_for` rebuilt the whole matcher, first bytes included, on
  every call with a processor that has `match`. It still does; it's
  needed while the processor is asked for its patterns on every call.

#### 6. The comparison with `:regexp` never fails CI

`.github/workflows/test.yml` and `template_match_spec.rb`. The "matches
like the :regexp engine" examples only run with `TEMPLATE_MODE=machine`,
in a job that's `continue-on-error: true` and covers four spec files.
Its comment ("Most of them fail until the machine is finished") is
stale: they all pass. The linear-time specs in
`template_machine_spec.rb` use only `Timeout`, and have no shapes with
several expressions like those in 3.

#### 7. Changelog and docs

- `CHANGELOG.md` has no entry for the new public API (`Template.engine`,
  `Template.engine=`, `Template#engine`, `Template.new(pattern,
  engine:)`). This plan holds entries back until release N, but
  `CLAUDE.md` asks for one with the change; decide which.
- About 32 comments say "as 2.10.0 does" or "2.10.0's regexp". 2.10.0
  is unreleased and would ship this code; they mean the `:regexp`
  engine.
- This plan is committed at the repository's root.

#### 8. Minor

- `expand(mapping, processor, false)` where `transform` returns an array
  whose first member isn't a String (for example `[1, [2, :x], nil]`):
  `:regexp` raises `NoMethodError`, `:machine` returns
  `?a=1&a=[2, :x]&a=`. Only an accidental error becomes a value.
- An invalid processor pattern raises `RegexpError` in both engines,
  with different messages.
- A `Marshal` or YAML dump of a used machine template holds the private
  node and matcher graph (2630 bytes against 436). They round-trip, and
  a dump from master loads. See "Dumps" under "Before release N".
- `ParsedTemplate#initialize` sets `@matcher = nil` but not `@regexp`,
  against the "same shape" intent of "Set the template machine's cached
  state when it's created".
- `machine.rb`, `machine/*.rb` and `parser.rb` lack the
  `# frozen_string_literal: true` line and licence header the other
  files have.
- `Parser::RESERVED_OPERATOR` copies `RESERVED_OPERATORS` "because of
  load order", yet `parser.rb` uses `RESERVED_OPERATORS` at call time.
  `Machine::VARSPEC` likewise copies `Template`'s grammar.
- In `values.rb`, `private` sits above `def self.` methods, which it
  doesn't affect, so they read as private.

#### 9. Not reproduced

- **Subclass overrides.** `:machine` ignores overrides of `Template`'s
  private methods (confirmed for `normalize_value`: `"NV"` against
  `"x"`). "Releasing" accepts this, but it's a behaviour change under
  "no breaking changes" once `:machine` is the default.
- **Other runtimes.** The processor pattern check relies on `\A`, `\z`
  and `$~`; check it on JRuby and TruffleRuby.

### Matcher speed

Bring the reused-template cases under 2×, keeping only changes that
stay easy to read, and explaining each in plain words where it's used.

Where the time goes: the cost is per character. In `{?foo,bar}`, the
reference regexp lets `bar` start right after any character of `foo`'s
value, with no `&`, so each character of a query value tries about six
states, at about 500 ns each. `Matching.match_data`, which both engines
share, is the biggest single cost of a match (22–47 µs). Adversarial
payloads grow linearly, but take 10–600× `Template`'s absolute time on
Ruby 3.3, where regex memoization helps `Template`.

Ideas, with what each bought when it was tried in phase 3 (an earlier
step-interpreter matcher, so the numbers are a guide only):

- **States push their next attempts straight onto the stack**, last
  choice first, rather than returning an array. That saves an allocation
  per state. Estimated 10–15%; not tried.
- **Search for the literal after a run** with `String#index` (on a binary
  copy for non-ASCII URIs, so offsets are bytes), and only try where it
  occurs. With the next idea: reserved 41 → 33 µs, path 26 → 22 µs, for
  the matcher alone.
- **Fixed run patterns** (`(?:[set]|%HH|[^\x00-\x7F])*+`, one per
  character set, compiled at load) with `StringScanner#skip`, so a run's
  extent is found in C. They're possessive, so they can't backtrack.
  They could also define `CharacterSet` as small named regexps that read
  as what they mean.
- **End checks**, since a match must use the whole URI: a trailing literal
  must end it (tried; catches templates that end in a literal), the last
  byte must be one the template can end on, every byte must be one it
  can take, and a branch that leaves fewer bytes than the rest needs
  can't finish.
- **Look one run ahead rather than one character** (RE2's idea in
  miniature). In `{?foo,bar}`, `bar` can only start where `bar=` follows.
  Would likely bring the reused cases under 2×, at the cost of another
  concept to explain. Not tried.
- **Interpreter tricks**, measured on the step interpreter: symbols in
  `case`/`when` so it compiles to a jump table (15–25%), one step per run
  with a tight loop (reserved 51 → 41 µs), `while` rather than `loop`
  (about 12%), a bit-packed memo string, and joining literal units (a
  25-byte literal 5 µs → 0.08 µs; kept). First-byte sets as arrays
  rather than Integer bitmasks: lookups take 11 rather than 40 ns, but
  they're slow to build.
- **RE2's backward pass:** work out, for every state and position,
  whether the end is reachable, then walk forward without backtracking.
  Its cost is predictable, but it fills the whole states × positions
  table every time, and it's a second engine to read. Not tried.
- **Speed up `Matching.match_data`.** It helps both engines, so it
  doesn't close the gap between them.
- **Measure with YJIT**, which this Ruby build doesn't have. Rails 7.1+
  turns it on by default on Ruby 3.3, so measure the matcher with it in
  CI.

Ruled out: normalizing the URI before matching. `URI#normalize` does
handle pct-encoding, but it changes results (it lowercases the host, and
a literal `%41` stops matching once `%41` becomes `A`), and it costs
about 50 µs per URI.

Prefilters and shortcuts flatter the profile's adversarial payloads, so
each one needs payloads that get past it, so the profile can still show
linear growth. A run cache that only helped forward searches once made
`{;a,b}` quadratic; the linear-time checks in `template_machine_spec.rb`
catch that kind of mistake now.

### Expansion speed

- **Single-variable expressions**, the most common kind outside query
  strings: `Expression#expand` could expand the one variable and join it
  directly, without the `map`, `compact!` and `flat_map` arrays. Likely
  well under a microsecond per expression; measure with
  `profile:template_machine` before adding a branch.

### Simplification

The code grew piece by piece, and much of it mirrors `Template`'s
regexp shapes. Some ways to make it smaller and easier to read:

- **Code that exists only to copy a `Template` bug** (`variables` reading
  invalid expressions: `Parser#names_in_invalid_token`,
  `Machine::Invalid#names`) goes once `Template` fixes the bug.
- **`Matching.match_data`'s quirks**, which the specs pin (an
  unexploded `;`, `?` or `&` value goes under the name the URI gives,
  and a name's first non-nil value wins). Both engines share it, so its
  results can only change once `:regexp` is gone.
- **Don't mirror the regexp in the matcher.** Its shape (nothing first,
  optional joiners, the empty-member rule) is the reference regexp's. A
  matcher that splits at the template level could be simpler, but every
  shortcut has to give the regexp's split, which only the oracle checks.

### Before release N

- **Dumps:** a `Marshal` or YAML dump of a template currently includes
  its caches, which name private classes. Dump only the pattern and the
  engine, and rebuild the caches on first use. Dumps from earlier
  versions must still load. An earlier version can't load the new
  format, which matters for caches shared across a rolling deploy.
- Measure what building the regexp in `freeze` costs a frozen machine
  template.
- Run machine mode on every runtime (Ruby 2.3 to 4.0, JRuby,
  TruffleRuby) in both IDNA modes, make the CI job blocking, and add
  `profile:template_machine` to CI.

## Releasing

- **Release N (minor):** the machine ships opt-in, with `:regexp` as the
  default. Document `Template.engine = :machine` and the `engine:`
  keyword. Add changelog entries under `` ### `Addressable::Template` ``.
  Until then the branch adds no changelog entries.
- **Release N+1 (minor):** `:machine` becomes the default, and `:regexp`
  still works but warns that it's deprecated. The specs run on the
  machine by default, and `TEMPLATE_MODE=regexp` runs them on `:regexp`.
  Overrides of `Template`'s private methods have no effect on the
  machine; say so in the changelog, with `engine: :regexp` as the way
  back.
- **Next major:** remove the `:regexp` engine, its private methods and
  `TEMPLATE_MODE`. Each `engine == :machine` guard's branch becomes its
  method body.

## Working on it

```sh
bundle exec rake spec                    # full suite, native IDNA
IDNA_MODE=pure bundle exec rake spec     # full suite, pure-Ruby IDNA

# The Template specs on the machine
TEMPLATE_MODE=machine bundle exec rspec \
  spec/addressable/template_spec.rb \
  spec/addressable/template_match_spec.rb \
  spec/addressable/template_match_forms_spec.rb \
  spec/addressable/template_conformance_spec.rb

# :regexp vs :machine: time, objects, agreement, adversarial growth
ITERATIONS=5000 bundle exec rake profile:template_machine
```

- Machine specs: `spec/addressable/template_machine_spec.rb` (they
  compare each operation with `:regexp`), `template_engine_spec.rb` and
  `template_parser_spec.rb`.
- Follow `CLAUDE.md`: specs first, Ruby 2.2-compatible code, both IDNA
  modes. Any warning fails the suite.
- Work one piece at a time, and wait for review before committing.
- Run the profile twice before calling a slowdown real.
- Add new adversarial shapes to the linear-time checks in
  `template_machine_spec.rb`, which run in the default suite.
