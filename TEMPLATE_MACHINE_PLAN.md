# Template machine build plan

Branch: `template-machine`, rebased onto `master` (a7924ec) on 2026-11-16.

## Goals

1. **No breaking changes.** `Addressable::Template` keeps its public API,
   its return values, and the exceptions it raises. The existing spec suite
   passes unmodified against the machine, except for specs that only test
   the regexp implementation's internals (see "Spec inventory").
2. **No catastrophic backtracking.** Expanding, matching, and extracting run
   in linear (or at worst polynomial, bounded) time on every supported
   runtime, including ones without regex memoization (Ruby < 3.2, JRuby,
   TruffleRuby). It must not depend on `Regexp.timeout`.
3. **Same or better performance** than the current `Template` for `expand`,
   `match`, `extract`, and `partial_expand`, for both new and reused
   templates, in both time and allocations.

`Addressable::Template` stays the only public class. It gets two private
engines, `:regexp` (today's code) and `:machine`, and delegates the
template operations to one of them. Everything outside the operations is
shared: the class, the pattern, `==` and `hash`, value lookup and
normalization, the error classes, and `MatchData`. Code that rescues,
compares, or checks templates works the same with either engine.

The engine is chosen app-wide with `Addressable::Template.engine =
:machine`, or for one template with `Template.new(pattern, engine:
:machine)`. It ships in two minor releases (see "Releases"):

- **Release N:** the default is `:regexp`, so nothing changes unless a
  caller opts in. `engine: :regexp` pins today's implementation ahead of
  the switch.
- **Release N+1:** the default is `:machine`. `:regexp` still works and is
  deprecated.
- **Next major:** the `:regexp` engine is removed.

## Starting phase 1

This section is for an agent picking up phase 1 with no other context.
Read `CLAUDE.md`, then this plan's Goals, the "Decided" list under
"Open decisions", and phase 1 under "Build phases".

### The branch

`template-machine`, 15 commits ahead of `master` at the end of phase 0.
It's local only. `origin/template-machine` is still the 2020 branch from
before the rebase, so pushing needs a force push. Don't push without
asking.

### Commands

```sh
bundle install
bundle exec rake spec                    # full suite, native IDNA
IDNA_MODE=pure bundle exec rake spec     # full suite, pure-Ruby IDNA
bundle exec rspec spec/addressable/template_machine_spec.rb

# The Template specs against the machine
TEMPLATE_MODE=machine bundle exec rspec \
  spec/addressable/template_spec.rb \
  spec/addressable/template_match_spec.rb \
  spec/addressable/template_match_forms_spec.rb \
  spec/addressable/template_conformance_spec.rb

# Template vs machine: time, allocations, output agreement, adversarial
ITERATIONS=5000 bundle exec rake profile:template_machine
```

What they give at the end of phase 0 (Ruby 3.3.1):

| Run | Result |
|---|---|
| Full suite, native and pure IDNA | 0 failures; 6 pending (5 from `master`, plus the `OpPath` one in `template_machine_spec.rb`) |
| `template_machine_spec.rb` | 11 examples, 1 pending |
| Machine mode, the four `Template` spec files | 1,909 examples, 1,388 failures (groups under "Baseline") |

Phase 1's structural pieces must leave the first two rows unchanged and
shouldn't increase the third.

### Where things are

- `lib/addressable/template.rb` (about 1,960 lines). Search for these:
  `MappingLookup` (a private constant), `class MatchData`, `def
  initialize(pattern)` (it never raises for an invalid pattern), `def
  freeze` (computes `variables`, `variable_defaults`, and the parse
  before freezing), `def ==` and `def hash` (pattern only), the operations
  (`def extract`, `def match`, `def partial_expand`, `def expand`, `def
  variables`, `def variable_defaults`, `def to_regexp`, `def source`, `def
  named_captures`), `def normalize_value`, and `def
  parse_template_pattern` (the regexp builder, cached in
  `@cached_template_parse`). `partial_expand` returns
  `Addressable::Template.new(result)`, so the new template has to get
  the original's engine.
- `lib/addressable/uri_template.rb`, `template_machine.rb`, and
  `template_lexer.rb`: the machine (see "Where the branch stands").
- `spec/spec_helper.rb`: the `TEMPLATE_MODE` block that swaps the
  constant, and `TestHelper.regexp_template`. The helper is used by two
  `GROUP_NAME_CAN_START_WITH_DOT` lookups in `template_spec.rb` and the
  `Reference` module in `template_match_spec.rb`.
- `tasks/template_machine_profile.rb`: `IMPLEMENTATIONS` names the two
  classes being compared. It becomes the two engines.
- `.github/workflows/test.yml`: the `template-machine` job.

### Conventions

- **`CLAUDE.md`:**
  - Write specs first for `lib/` code, covering every changed line and
    branch.
  - Add adversarial specs for parsing.
  - Check regexps for backtracking on every runtime.
  - Code must run on Ruby 2.2: no `&.`, no `<<~`, no
    `Hash#transform_values`, or guard them.
  - Run both IDNA modes.
- **Warnings fail the suite.** `spec_helper.rb` turns any warning from
  `lib/` or `spec/` into a failure.
- **The changelog waits for release N.** Nothing on this branch ships
  before release N (phase 5), so don't add `CHANGELOG.md` entries piece by
  piece. If the branch is going to be merged to `master` earlier, ask.
- **One piece at a time.** Make one change, show the diff and the test
  results in both modes, and wait for review before committing. Each
  commit message says what changed and why. Follow `git log` for the
  style, and end it with the Co-Authored-By trailer.
- **Keep this plan current.** Mark items done as they land, record the
  counts at the end of each phase, and add anything learned to the
  phase it affects.

### Phase 1, piece by piece

1. **The switch, no delegation yet.**
   - Specs first, in a new `spec/addressable/template_engine_spec.rb`:
     - `Template.engine` defaults to `:regexp`, and `Template.engine =`
       accepts `:regexp` and `:machine`.
     - `Template.new(pattern, engine: :machine)` overrides the default
       for one template.
     - An unknown engine raises `ArgumentError`, from the setter and from
       the keyword.
     - A template that has picked its engine keeps it when
       `Template.engine` changes.
     - `partial_expand` returns a template with the same engine.
     - A template survives a `Marshal` round trip.
     - `freeze` picks the engine.
     - The engine doesn't affect `==` or `hash`.
   - Restore `Template.engine` after each example so specs don't leak
     into each other.
   - Then the code, with every operation still running today's code
     whichever engine is chosen.
   - Ask the user first whether to add a public `Template#engine` reader
     to test against: it's useful for debugging, but it's more public
     API. The alternative is testing through a private method.
2. **Delegation.** The `:regexp` adapter calls today's private methods.
   The `:machine` adapter wraps `UriTemplate`'s code, moved behind
   `Template` as a private constant. Remove the public `UriTemplate`.
3. **Shared pieces.** The machine uses `Template`'s error classes,
   `MatchData`, `MappingLookup`, `normalize_value`, and `utf8_value`.
   Remove its copies.
4. **Specs on the switch.** `TEMPLATE_MODE=machine` sets
   `Template.engine = :machine`. Remove the constant swap and
   `TestHelper.regexp_template`, and point its three call sites back at
   `Addressable::Template`.
5. **Profile on the switch.** `profile:template_machine` compares the two
   engines, and its adversarial section gets a parse case.
6. **Parsing.** The rest of phase 1: the lexer, invalid UTF-8,
   `variables` and `variable_defaults`, each as its own piece.

## Where the branch stands

The machine's code, from 2020 (rebased cleanly):

- `lib/addressable/template_lexer.rb`: a `StringScanner` lexer that turns a
  pattern into literal strings and `Expression` nodes
- `lib/addressable/template_machine.rb`: `Variable`, one `Expression`
  subclass per operator (`OpPlain`, `OpReserved`, `OpFragment`, `OpPath`,
  `OpLabel`, `OpPathParams`, `OpForm`, `OpFormContinuation`), and tagged
  values that join expansions
- `lib/addressable/uri_template.rb`: `Addressable::UriTemplate`, a
  separate class with `#expand`, a rough `#match`, and its own copies of
  `Template`'s error classes and `MatchData`. Phase 1 turns it into the
  `:machine` engine behind `Template`.
- `spec/addressable/template_machine_spec.rb`: unit specs for the nodes

Added since the rebase (002aecc onwards):

- `TEMPLATE_MODE=machine` in `spec/spec_helper.rb` runs the specs against
  the machine by swapping the `Template` constant for `UriTemplate`, like
  `IDNA_MODE=pure`. Phase 1 replaces the swap with
  `Template.engine = :machine`.
- `TestHelper.regexp_template` returns the regexp class whatever the mode.
  The reference oracle in `template_match_spec.rb` and the
  `GROUP_NAME_CAN_START_WITH_DOT` checks in `template_spec.rb` use it.
  Once `Template` is one class with two engines, those specs can read
  `Addressable::Template` again, so phase 1 removes the helper.
- The machine normalizes values to NFC, with logic copied from
  `Template#normalize_value` (e2eb19a).
- The `OpPath` unit specs run; one is pending until phase 3 (3c50c4c).
- `rake profile:template_machine` compares the two (6cdc5d5; see
  "Performance today").
- CI's non-blocking `template-machine` job runs the `Template` specs in
  machine mode on Ruby 2.3, 3.1, the latest Ruby, JRuby 10, and
  TruffleRuby, and reports the counts in each job's summary (a82f41a).

### Baseline

`template_spec.rb`, `template_match_spec.rb`, `template_match_forms_spec.rb`,
and `template_conformance_spec.rb`, on Ruby 3.3.1:

| Mode | Examples | Failures |
|---|---:|---:|
| regexp (`Template`) | 1,909 | 0 |
| `TEMPLATE_MODE=machine` | 1,909 | 1,388 |

Largest groups of machine failures:

| Count | Cause |
|---:|---|
| 275 | Mapping assumed to be a `Hash` (`inject`); lambdas and other lookups fail |
| 267 | No `#extract` |
| 240 | No `#parse_template_pattern` (reference oracle, see below) |
| 154 | Wrong expansion or match result |
| 100 | Lexer raises `RuntimeError: Incomplete varspec` on valid varspecs |
| 76 | No `#partial_expand` |
| 74 | Expected no error, but expectations failed inside |
| 33 | No `#variables` |
| 24 | `InvalidTemplateError` / `InvalidTemplateValueError` not raised |
| 22 | `#match` returned `nil` where a match was expected |

Rerun these with `TEMPLATE_MODE=machine bundle exec rspec <the four
files> -f json -o tmp/machine.json` and group the failures by exception.

### Performance today

`rake profile:template_machine` (`tasks/template_machine_profile.rb`)
compares the two implementations. For four templates (simple; path,
query and prefix; exploded; reserved and fragment), it runs `expand`,
`partial_expand`, `match`, and `extract` on new and reused templates and
reports µs and objects per call. It also checks each pair of outputs:
`same`, `differs` (the machine's numbers don't count), or `missing` (the
machine raises, so it isn't timed). Then it times `match` on adversarial
payloads at two sizes and reports how the time grows. `ITERATIONS=n`
sets the calls per timing (default 20,000, about a minute). MemoryProfiler
reports go to `tmp/template_machine/`.

Results on Ruby 3.3.1 at the end of phase 0, reused templates:

| Operation | Output | Machine time vs `Template` | Machine objects vs `Template` |
|---|---|---:|---:|
| expand | same in all 4 cases | 0.47–0.52× | 44–99 vs 92–231 |
| partial_expand | missing | – | – |
| match | same in 2 cases, differs in 2 | 0.20–0.27× (where same) | 46–115 vs 196–355 |
| extract | missing | – | – |
| adversarial match | the machine matches payloads it should reject | – | – |

`Template`'s adversarial match time grows about 3–4× for 4× the input
(linear), helped by Ruby 3.3's regex memoization.

These ratios only cover what the machine already does. Its `expand` still
skips work `Template`'s does on every call (`MappingLookup`, processors,
value validation, keeping pct-encoded triplets), so the comparison means
something only once phase 2 makes the outputs agree across the specs.
Check goal 3 then, and on every runtime.

History: in 2020 the machine's `expand` was about 10× faster than
`Template`'s. At the start of this plan it was about 4× slower and used
3× the memory, almost all of it from calling the deprecated
`Addressable::IDNA.unicode_normalize_kc` once per value. Copying
`Template`'s NFC normalization into the machine removed that.

## Spec inventory

The conformance suite only covers expansion. Matching and extraction are
covered by `template_spec.rb`, `template_match_spec.rb`, and
`template_match_forms_spec.rb`.

| Examples | What they test | Machine applies? |
|---:|---|---|
| 1,606 | Behaviour through `expand`, `match`, `extract`, `partial_expand`, `variables`, `==`, … | Yes, unmodified |
| 53 | `#to_regexp`, `#source`, `#named_captures` (public) | Yes, unmodified |
| 9 | Grammar constants `EXPRESSION`, `VARNAME`, `VARIABLE_LIST`, `VARSPEC` (public) | Yes, unmodified |
| 240 | Regexp from the private `#parse_template_pattern` versus a reference regexp | Rework (phase 4) |

The 240 reference examples define which way `#match` splits a URI that
can be split more than one way: the end positions it tries and the values
it captures. That is observable behaviour, so the machine must match the
same splits. It just can't be tested through a private regexp.

## Public API to keep

- Class: `Template.new(pattern)`. The plan adds `Template.engine`,
  `Template.engine=`, and an optional `engine:` keyword on `new`; all
  three are additions, so existing calls are unaffected.
- Instance methods: `==`, `eql?`, `hash`, `freeze`, `inspect`, `pattern`,
  `variables`, `keys`, `names`, `variable_defaults`, `expand`,
  `partial_expand`, `match`, `extract`, `to_regexp`, `source`,
  `named_captures`
- Mappings: `Hash` with string or symbol keys, and anything else
  `Template` accepts (e.g. lambdas through `MappingLookup`)
- Processors: `#validate`, `#transform`, `#restore`, `#match`, called as
  often and in the order they are now
- `MatchData` and its methods (`mapping`, `variables`, `captures`,
  `values_at`, `[]`, `to_a`, `pre_match`, `post_match`, …)
- Errors: `InvalidTemplateError`, `InvalidTemplateOperatorError`,
  `InvalidTemplateValueError`, `TemplateOperatorAbortedError`, raised for
  the same inputs with the same messages where specs check them
- Public constants: `EXPRESSION`, `VARSPEC`, `VARNAME`, `VARIABLE_LIST`,
  `LEADERS`, `JOINERS`, `RESERVED`, `RESERVED_NO_COMMA`, `RESERVED_ENCODE`,
  `UNRESERVED`, `PCT_ENCODED_OR_CHARACTER`

## Build phases

Each phase ends with both modes run and the failure count recorded here.

### 0. Baseline

- Done: commit the uncommitted changes above.
- Done: fix the 5 broken `template_machine_spec.rb` examples (one is
  pending until phase 3).
- Done: extend `tasks/profile.rake` so the same harness compares both
  implementations on `expand`, `partial_expand`, `match`, and `extract`
  (new and reused templates, time and allocations), and drop the
  machine-only `template_machine_match` task. Write reports to `tmp/`, not
  `profiling/`. Include an adversarial `match` case to track backtracking.
- Done: run `TEMPLATE_MODE=machine` in CI as a non-blocking job, so the
  count is tracked on every runtime (`template-machine` in
  `.github/workflows/test.yml`; the count is in each job's summary).
- Done: add a "Starting phase 1" section to this plan with enough for a
  fresh agent to pick up phase 1 with no other context.

Phase 0 is complete.

### 1. Structure and parsing

Structure first, with no change in behaviour: the full suite passes with
the default engine at every step.

- Specs first for the engine switch: `:regexp` by default,
  `Template.engine = :machine` app-wide, `Template.new(pattern, engine:
  :machine)` for one template, an `ArgumentError` for an unknown engine,
  and a template keeping its engine when `Template.engine` changes later.
- Add `Template.engine` and the `engine:` keyword. A template picks its
  engine the first time it needs one, not in `new`, so `new` stays as
  cheap as today and a template loaded with `Marshal` or YAML from an
  earlier version still works. `freeze` picks it first.
- The `:regexp` engine is today's code. Leave it where it is, as
  `Template`'s private methods, and give it a thin adapter, so subclasses
  and monkey patches of those methods keep working with `:regexp`.
- The `:machine` engine is `UriTemplate`'s code, moved behind `Template`
  as a private constant. Remove the public `UriTemplate` class.
- Everything that isn't an operation lives once, in `Template`, and the
  machine uses it instead of copies: the error classes (they keep their
  public `Addressable::Template::` names), `MatchData`, `MappingLookup`,
  `normalize_value` and `utf8_value` (removing the copy made in
  e2eb19a), `pattern`, `==`, `eql?`, `hash`, `inspect`, and `freeze`.
- Specs: `TEMPLATE_MODE=machine` sets `Template.engine = :machine` instead
  of swapping the constant. Remove `TestHelper.regexp_template` and point
  the three lookups that use it back at `Addressable::Template`.
- `profile:template_machine` compares `engine: :regexp` with `engine:
  :machine`, which also shows what delegating costs.

Then parsing:

- Lexer accepts everything `Template` accepts (pct-encoded names, names
  that start with a digit, dots, `:` prefixes up to 9999) and raises
  `InvalidTemplateError` / `InvalidTemplateOperatorError` for the rest,
  with `Template`'s messages. Like `Template`, `new` never raises for an
  invalid pattern; the error comes from the first operation that needs a
  valid one.
- Handle text that isn't valid UTF-8 the way `Template` does.
- `variables`, `keys`, `names`, `variable_defaults`.
- Parsing must stay linear: templates can come from untrusted input, such
  as the URI templates in hypermedia API responses that Octokit and Sawyer
  expand. `template_spec.rb` already covers this for `Template`: "checks
  long templates in linear time" parses 9 invalid patterns of 100,000
  characters with a 10 s timeout, and "expands long templates with
  non-ASCII literals in linear time" covers a long valid one. They run in
  machine mode in CI on every runtime there. Add a parse case to the
  profile's adversarial section, so growth shows as a number and not only
  as a timeout.

### 2. Expansion

- One value lookup for both engines: wrap `MappingLookup` so that the
  value for a name comes out converted (numbers, symbols, and booleans
  to strings), type-checked (`TypeError` as now), and normalized (unless
  `normalize_values` is false), and remember it per name. A variable used
  more than once (`{a}{+a}`) is then converted and normalized once, and
  lambdas and non-`Hash` mappings work in the machine. Values are still
  looked up when an expression needs them, in template order, so errors
  come in the same order as now. What depends on the expression stays
  per expression: the prefix-on-a-list check and processors.
- Processors (`validate`, `transform`), called with the same values as
  now: `validate` gets the normalized value, and a `transform` result is
  normalized again.
- `InvalidTemplateValueError` cases, such as a prefix on a list or hash
  (`{x:3}` with `["a", "b"]`; the machine truncates instead of raising).
- Keep pct-encoded triplets in `+` and `#` expansions: `{+x}` with `%41`
  gives `%41`, but the machine gives `%2541`.
- `partial_expand`, including fragments and undefined variables.
- Target: all expansion specs and the conformance suite pass. Expand is at
  least as fast as `Template`.

### 3. Matching and extraction

- Replace `extract_values` with a matcher that never backtracks
  exponentially. Each expression's possible end positions come from the
  literal that follows and the operator's character set. Search the
  positions in the same order as the reference regexp, and memoize on
  (node, position) so the work stays polynomial.
- Exploded lists and hashes, named operators (`;`, `?`, `&`), prefixes,
  processors' `match` and `restore`.
- `extract`, and `match` returning `Addressable::Template::MatchData`, the
  same class `Template` returns, instead of the machine's own copy.
- Match only when the whole URI is consumed. `UriTemplate#match` ignores
  whatever follows the last node, so it matches every adversarial payload
  in the profile (e.g. `{/foo*}` matches `/a/a/…/a/!`), where `Template`
  returns `nil`.
- Target: `template_match_spec.rb` "with adversarial input" passes on every
  runtime, and match and extract are at least as fast as `Template`.

### 4. Regexp API and the reference oracle

- `named_captures` from the nodes, with no regexp: it maps each variable
  name to the 1-based positions of its occurrences, in template order
  (`{/a,b*}{?c,a}` gives `{"a" => [1, 4], "b" => [2], "c" => [3]}`).
- `to_regexp` and `source`: build the regexp only when one of them is
  called, once per template, with the existing builder, so the result is
  exactly what `Template` gives now. `expand`, `match`, and `extract`
  never build one with the machine engine.
- Keep the grammar constants.
- Rework the 240 reference examples to compare `#match` results with the
  reference regexp's matches, so they test the behaviour and run in both
  modes. Today they compare the regexp builder with a reference regexp,
  which says nothing about the machine's `match`. After phase 1 they run
  in machine mode too, because the builder is still `Template`'s private
  method, but they still only test the builder.

## Releases

### 5. Release N: the machine, opt-in

Requirements before release:

- The full `Template` suite passes in `TEMPLATE_MODE=machine`, in both
  IDNA modes, on Ruby 2.3 to 4.0, JRuby, and TruffleRuby. The
  `template-machine` CI job becomes blocking and covers the full test
  matrix.
- Benchmarks meet goal 3 on each runtime (add `profile:template_machine`
  to the CI `profile` job).

Changes:

- Document `Template.engine = :machine` (app-wide, so code that reaches
  `Addressable::Template` through other gems such as Octokit and Sawyer
  runs on the machine too) and `Template.new(pattern, engine: :machine)`.
  `:regexp` is the default.
- `CHANGELOG.md` entries under `` ### `Addressable::Template` ``,
  following CLAUDE.md.

### 6. Release N+1: the machine by default

- Change the default of `Template.engine` to `:machine`. `:regexp` keeps
  working and is deprecated, with a warning when it's chosen.
- Flip the specs: the suite runs with `:machine` by default, and
  `TEMPLATE_MODE=regexp` runs it with `:regexp`.
- Outputs stay identical, but callers could notice that `:machine` doesn't
  use `Template`'s private methods, so subclasses and monkey patches that
  override them have no effect with it. List that in the changelog, with
  `engine: :regexp` as the way back.

### Next major

- Remove the `:regexp` engine, its private methods, and `TEMPLATE_MODE`.
  `to_regexp` keeps its builder.

## Open decisions

1. **Output changes.** Any output change found along the way needs its own
   decision (CLAUDE.md: changed return values go in the next minor
   release). The goal is none.

Decided:

- **One public class with two private engines.** `Template` delegates the
  operations (`expand`, `partial_expand`, `match`, `extract`,
  `variables`, `variable_defaults`, `to_regexp`, `source`,
  `named_captures`) to its engine and keeps everything else. Compared
  with the alternatives:
  - *Separate public classes* (`UriTemplate`, `RegexpTemplate`) with the
    constant swapped app-wide: `is_a?`, `rescue`, and `MatchData` differ
    between them unless everything is shared through a base class,
    swapping a constant depends on load order, and each class is more
    public API to document, deprecate, and remove.
  - *Subclasses of `Template`, with `Template.new` returning one of them*:
    keeps `is_a?`, but overriding `new` is surprising, and it interferes
    with callers' own subclasses of `Template`.
  - The cost of one class: a method call per operation (measured by the
    profile task), and with `:machine`, overrides of `Template`'s private
    methods have no effect (listed for N+1). `UriTemplate` and
    `RegexpTemplate` are dropped, so `==` across implementations doesn't
    come up.
- **The switch** is `Addressable::Template.engine = :machine`, or
  `engine:` on `Template.new` for one template. `:regexp` is the default
  in release N and `:machine` in N+1. `Template.engine` is process-wide
  and meant to be set once at boot; changing it affects templates that
  haven't picked an engine yet, not ones that have. Anyone who doesn't set
  it sees no change in release N.
- **Shared, not copied:** the error classes, `MatchData`, value lookup and
  normalization, and the rest of `Template` outside the operations.
- **Regexps only on request:** `named_captures` comes from the nodes, and
  `to_regexp` and `source` build a regexp once per template, only when
  called, with the existing builder.

## Risks and constraints

- Ruby 2.2 is still allowed by the gemspec. Avoid newer syntax and methods,
  or guard them (`String#unicode_normalize` is 2.2+; `&.` is 2.3+).
- The specs fail on any warning from `lib/` or `spec/`, so deprecated calls
  and unused variables must go.
- Regex memoization in Ruby 3.2+ hides backtracking, so measure it on
  2.x, JRuby, and TruffleRuby too.
- A matcher that prefers a different split than the regexp's order would
  silently change `#match` results. The reworked oracle in phase 4 must be
  in place before the old `#match` is replaced.
