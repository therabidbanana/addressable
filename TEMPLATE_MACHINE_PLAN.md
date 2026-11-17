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
   templates, in both time and allocations. Decided in phase 3: matching
   (`match`, `extract`) may take up to 2× `Template`'s time if that keeps
   the matcher readable, as long as adversarial input stays linear (goal
   2). Readability wins over the last factor of speed there.

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

## Starting the next phase

This section is for an agent picking up the next phase (phase 4, the
regexp API: `named_captures`, `to_regexp`, `source`) with no other
context. Read `CLAUDE.md`, then this plan's Goals (goal 3 was loosened
for matching in phase 3), the "Decided" list under "Open decisions",
"Phase 1, piece by piece", phases 2 and 3 under "Build phases" (what was
built and why), "`Template` bugs found along the way", "Risks and
constraints", and phase 4.

**Ask the user first: the matcher optimizations.** Phase 3 ended with a
list, "To come back to at the end of phase 3: matcher optimizations",
saved to weigh once processors were done. Matching is within the 2×
target for the simple template and new templates, but over it on reused
templates with query, exploded and reserved expressions (2.1–2.9×). Ask
whether to work through that list before phase 4, after it, or not at
all. The user prefers a readable matcher to a fast one (goal 3), so each
optimization has to earn its place.

### The branch

`template-machine`, 42 commits ahead of `master` at the end of phase 3
(abac08a). It's local only. `origin/template-machine` is still the 2020
branch from before the rebase, so pushing needs a force push. Don't push
without asking.

### Commands

```sh
bundle install
bundle exec rake spec                    # full suite, native IDNA
IDNA_MODE=pure bundle exec rake spec     # full suite, pure-Ruby IDNA
bundle exec rspec spec/addressable/template_machine_spec.rb \
  spec/addressable/template_engine_spec.rb \
  spec/addressable/template_lexer_spec.rb

# The Template specs against the machine
TEMPLATE_MODE=machine bundle exec rspec \
  spec/addressable/template_spec.rb \
  spec/addressable/template_match_spec.rb \
  spec/addressable/template_match_forms_spec.rb \
  spec/addressable/template_conformance_spec.rb

# :regexp vs :machine: time, allocations, output agreement, adversarial
ITERATIONS=5000 bundle exec rake profile:template_machine
```

What they give at the end of phase 3 (Ruby 3.3.1):

| Run | Result |
|---|---|
| Full suite, native IDNA | 4,355 examples, 0 failures, 5 pending (all from `master`) |
| Full suite, pure IDNA | 4,241 examples, 0 failures, 5 pending |
| Machine, engine and lexer specs | 793 examples, 0 failures |
| Machine mode, the four `Template` spec files | 2,198 examples, 47 failures (see "Baseline") |

The 47 are all `named_captures`, which `ParsedTemplate` still answers
with `NotImplementedError`: 40 where a spec expects
`InvalidTemplateError` or `InvalidTemplateOperatorError` from
`named_captures` for a malformed pattern (with `to_regexp` and `source`,
which already pass), and 7 that check its names, including names that
start with a digit or hold a dot or a triplet. Group them with `-f json
-o tmp/machine.json` as described under "Baseline". Machine mode takes
about 80 s; the 288 oracle examples are most of it.

The full suite must stay at 0 failures, and no piece should increase the
machine-mode failures. Each phase lowers them; record the count in
"Baseline" when a phase ends.

### Where things are

- `lib/addressable/template.rb` (about 1,775 lines). Search for these:
  `class << self` (`Template.engine`), `MappingLookup` (a private
  constant), `class MatchData`, `def initialize(pattern, engine: nil)`
  (it never raises for an invalid pattern), `def freeze`, `def ==` and
  `def hash` (pattern only), the operations (`def extract`, `def match`,
  `def partial_expand`, `def expand`, `def variables`, `def
  variable_defaults`, `def to_regexp`, `def source`, `def
  named_captures`), most starting with an `if engine == :machine` guard.
  For phase 4: `def to_regexp` and `def source` have no guard; both
  engines use the builder, `def parse_template_pattern`, which caches in
  `@cached_template_parse` (see "Found at the end of phase 3" under
  phase 4). `def named_captures` maps the regexp's group names back to
  variable names with `def capture_name` and `def variable_name` (a
  name that starts with a digit gets a leading "." as a group name, or
  `__name__` on Ruby 2.3).
- `lib/addressable/template/values.rb`: `Template::Values`. Its class
  methods are the helpers both engines share (`normalize_value`,
  `utf8_value`, `normalize_keys`, `defined_value`, `mapping_or_block`,
  `prefix`, `encode_later_number_signs`); `Template`'s private methods of
  the same names delegate to them. An instance is one machine expansion.
  Matching doesn't use an instance.
- `lib/addressable/template/parsed_template.rb`, `machine.rb`,
  `lexer.rb`, and `matcher.rb`: the machine (see "Where the branch
  stands", phase 2, and phase 3). Each node adds its steps to a
  `Template::Matcher` (`#match_steps`), and `ParsedTemplate#match` runs
  them. `ParsedTemplate#named_captures` is the one operation still
  raising `NotImplementedError`. Literals are `Machine::Literal` nodes,
  which keep the text as written and its pct-encoded expansion;
  `Machine::Expression#variables` lists an expression's varspecs, and
  each `Variable` has `name`. `lib/addressable/template/matching.rb`:
  what both engines' `#match` share.
- `spec/addressable/template_lexer_spec.rb`: compares the machine's
  errors and `variables` with the `:regexp` engine's.
- `spec/addressable/template_machine_spec.rb`: unit specs for `Values`
  and the nodes, and the specs that compare expansion, partial
  expansion and matching (with and without processors) with the
  `:regexp` engine. Phase 4's specs can follow the same pattern.
- `spec/addressable/template_match_spec.rb`: the reference oracle
  (`TemplateMatchSpec`), the split examples, and the adversarial
  payloads.
- `spec/spec_helper.rb`: `TestHelper.template_engine` and the
  `TEMPLATE_MODE` block that sets `Template.engine`.
- `spec/addressable/template_engine_spec.rb`: the engine switch.
- `tasks/template_machine_profile.rb`: `ENGINES` names the two engines
  being compared.
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
- **Never fall back to the regexp engine.** An operation or argument the
  machine doesn't handle yet raises `NotImplementedError` naming it, so
  machine-mode failures list what's left. Code both engines need lives
  once, and `Template`'s private method of the same name delegates to
  it. `Template` uses `ParsedTemplate` only to hand an operation to it
  (the `engine == :machine` guards, `#parsed_template` and `#freeze`),
  never for shared code, and never uses `Machine` or `Lexer`. So far
  that code has been about parsing and normalizing values, so it's
  `Values` class methods. Shared code of another kind belongs wherever
  fits it, not in `Values` by default.
- **`Values` owns values and `Machine` owns syntax** (decided in phase
  2). `Values` looks values up and applies the value modifiers and
  encoding; `Machine` expressions own leaders, separators and joining.
- **Compare with the `:regexp` engine.** Phase 2's specs build the same
  call on both engines and expect the same result or the same error
  class and message, over generated mixes of inputs. When a spec and
  `Template` disagree, check `Template` first: twice in phase 2 the
  spec's assumption was wrong, not the machine.
- **Edit files with the Edit tool**, not scripts, and read them with
  Read, so each change can be reviewed.
- **Measure with the profile** after each piece, and run it twice before
  calling a slowdown real; one run can be off by 30%.
- **Readable over fast** (decided in phase 3). The user would rather
  have a matcher that's far easier to read than one that's faster, up to
  2× `Template`'s time on matching, as long as adversarial input stays
  linear. Keep an optimization only if a bound needs it, and explain it
  in plain words where it's used; avoid unexplained jargon.
- **Check linear time on the machine in the default suite.** The
  `TEMPLATE_MODE=machine` specs catch slow matching, but only in machine
  mode; a run cache that only helped forward queries went quadratic in
  phase 3, and `template_machine_spec.rb` now times ten patterns on
  50,000-character URIs with `engine: :machine`. Add new shapes there.

### Phase 1, piece by piece

1. **Done: the switch, no delegation yet.** Decided: a public
   `Template#engine` reader. `Template.engine` is shared with subclasses
   (setting it on a subclass sets it for `Template`), only the symbols
   `:regexp` and `:machine` are accepted, and `engine: nil` means the
   default. Until piece 2, a template picks its engine only through
   `#engine`, `freeze`, or `partial_expand`.
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
2. **Done: delegation, with pieces 4 and 5 folded in.** Removing
   `UriTemplate` broke the `TEMPLATE_MODE` swap and the profile task, so
   the spec helper and the profile moved to the switch in the same piece.
   - **Guards.** The `:regexp` engine is `Template`'s own code, left where
     it is. `expand`, `partial_expand`, `match`, `variables`,
     `variable_defaults`, `named_captures`, and `freeze` each start with
     `if engine == :machine`, which hands off to the template's
     `Template::ParsedTemplate`. The default path costs one symbol
     comparison and runs the same code as before. At the next major, each
     guard's branch becomes the method body; grep for `engine ==
     :machine`. `extract` stays `match(...).mapping`, and `to_regexp` and
     `source` stay shared (decided for phase 4). Considered and dropped: a
     stateless `RegexpEngine` that called private `regexp_*` methods with
     `send` (three hops and three places to edit per operation, for no
     behaviour), and a `ParsedTemplate` that wrapped `UriTemplate`.
   - **`ParsedTemplate`** (`lib/addressable/template/parsed_template.rb`,
     moved from `uri_template.rb` with `git mv`) is marked `@api private`
     (it began as a `private_constant`; see nesting, below).
     `ParsedTemplate.new(template)` is made the first time a machine
     template needs it and lexes the pattern then. A parse error is kept
     and raised by the first operation, so `new` and `freeze` never raise
     for an invalid pattern, and `freeze` freezes the `ParsedTemplate`
     too. (Piece 6 replaced its `rescue StandardError` with
     `Machine::Invalid` nodes.) The public `UriTemplate` is
     gone, and so is its `require` in `lib/addressable.rb`.
   - **The machine never falls back to the regexp code.** An operation
     it lacks (`partial_expand`, `variables` and its aliases,
     `variable_defaults`, `named_captures`) or an argument it would ignore
     (a processor, a block lookup, `normalize_values` false) raises
     `NotImplementedError` naming it, so machine-mode failures list
     exactly what's left. `freeze` works on a machine template and
     computes nothing. `NotImplementedError` isn't a `StandardError`, so
     the profile rescues it by name.
   - **Specs.** `TEMPLATE_MODE=machine` sets `Template.engine = :machine`
     (`TestHelper.template_engine` says which). The constant swap and
     `TestHelper.regexp_template` are gone. The 240 reference-oracle
     examples in `template_match_spec.rb` test `Template`'s regexp
     builder, not the machine, so machine mode skips them until phase 4
     (`REGEXP_BUILDER_ONLY`); they show as pending.
     `template_engine_spec.rb` starts each example from `:regexp`.
   - **Profile.** `profile:template_machine` compares `engine: :regexp`
     with `engine: :machine`. The adversarial parse case moves to piece 6.
   - **Done, as its own commit after piece 2: nesting.**
     `Addressable::TemplateMachine` is now `Template::Machine` (the
     nodes), and `Addressable::TemplateLexer` is `Template::Lexer`, in
     `lib/addressable/template/machine.rb` and `lexer.rb`. Neither had been
     released. Decided: they're public constants marked `@api private`,
     so YARD documents them as internal; not `private_constant`. The same
     commit does this for `ParsedTemplate`. Both
     files open `class Addressable::Template` rather than nesting, so the
     bodies kept their indentation through the move. Inside `Template`, a
     bare `VARSPEC` is `Template`'s, so the lexer says `Machine::VARSPEC`.
   - **Decided: dumps hold the pattern and engine, not caches.** Today a
     `Marshal` or YAML dump includes every cache (`@variables`,
     `@cached_template_parse`, and now `@parsed_template` with its nodes),
     so a dump names private classes that will change. Before release N,
     as its own piece: dump only `@pattern` and `@engine`, and rebuild the
     caches on first use after loading. To check then:
     - Dumps from earlier versions must still load. Ruby restores their
       instance variables without calling any hook, so their old caches
       come back too; decide whether to drop them on first use.
     - Defining `marshal_dump` / `marshal_load` changes the dump format,
       so an earlier version can't load a new dump. That matters for apps
       sharing a cache across a rolling deploy.
     - YAML (`encode_with` / `init_with`) needs the same treatment.
3. **Shared pieces.** The machine uses `Template`'s error classes,
   `MatchData`, `MappingLookup`, `normalize_value`, and `utf8_value`.
   Remove its copies.
   - **Done: error classes and `MatchData`.** `ParsedTemplate`'s copies
     are gone, and constant lookup finds `Template`'s. It keeps `NoMatch`,
     which `#match` raises and rescues internally. A machine match is now
     a full `Template::MatchData` (machine mode: 1,027 failures, from
     1,037), though `values`, `to_a` and `captures` need `variables`
     (piece 6).
   - **Done: `normalize_value`, `utf8_value`, and `normalize_keys`.** Their
     bodies moved to `Template::Values` (`lib/addressable/template/values.rb`,
     `@api private`, module functions; a class with class methods since
     phase 2). `Template`'s private methods of the
     same names stay as one-line delegators, so subclasses that call them
     keep working. `Machine::Variable` and `ParsedTemplate` call `Values`,
     and their copies are gone. `normalize_keys` gives the machine
     `MappingLookup`, so lambdas and other non-`Hash` mappings expand
     (machine mode: 799 failures, from 1,027). The regexp `expand` showed
     no measurable cost from the extra call. `resolve_mapping`, which
     picks the block or the mapping, was shared in phase 2 (blocks).
4. **Done with piece 2:** specs on the switch.
5. **Done with piece 2:** profile on the switch.
6. **Parsing.** The rest of phase 1: the lexer, invalid UTF-8,
   `variables` and `variable_defaults`, each as its own piece. Add a
   parse case to the profile's adversarial section.
   - **Done: the lexer.** It splits a pattern into `Template`'s tokens
     (literal text, `{...}` up to the next `}` or the end, an unmatched
     `}`) and checks each expression against `Template`'s grammar
     (`Machine::VARSPEC` now has atomic name characters and prefixes of 1
     to 9999). It never raises: a token that isn't valid becomes a
     `Machine::Invalid` holding `Template`'s error class and message, and
     `ParsedTemplate` raises the first one from `expand` and `match`. The
     broad `rescue` is gone. `variables` will skip `Invalid` nodes, as
     `Template#variables` leaves out invalid expressions. Positions count
     characters by adding token lengths; `StringScanner#charpos` was
     quadratic on non-ASCII patterns, which the new parse table in the
     profile showed and a spec now checks. `partial_expand` and
     `named_captures` still raise `NotImplementedError` before looking at
     the pattern. A pattern that isn't valid UTF-8 raises `ArgumentError`
     from the lexer, from `freeze` too, as `Template` does today (next
     part). Specs: `spec/addressable/template_lexer_spec.rb`. The machine
     builds every node before reaching a late error, so on long invalid
     patterns it's up to 9× slower than `Template`'s check, though linear.
     On normal patterns, "expand, new" is 0.44–0.74× `Template`'s time.
   - **Done: text that isn't valid UTF-8, for parsing.** No lexer change
     was needed. Both engines already behave the same:
     - A pattern in an ASCII-compatible encoding (binary, ISO-8859-1,
       Shift_JIS, US-ASCII) lexes, with its literal bytes kept as they are.
     - A UTF-8 pattern that isn't valid raises `ArgumentError` ("invalid
       byte sequence") from `freeze` and every operation.
     - A UTF-16 pattern raises `Encoding::CompatibilityError` the same way.
     - A Shift_JIS pattern that isn't valid gives the same tokens and
       positions as `Template`.

     `template_lexer_spec.rb` now pins all of this against the `:regexp`
     engine. The `ArgumentError` is `Template`'s own behaviour; see
     "`Template` bugs found along the way".

     What does differ is how literals are used. The machine copies literal
     text into an expansion as it is, and matches it only as written.
     Phases 2 and 3 now list both.
   - **Done: `variables`, `keys`, `names`, and `variable_defaults`.**
     `ParsedTemplate#variables` lists each expression node's names, in
     order, once each, worked out from the nodes on each call. It's rarely
     called, so keeping the list would cost every template for little, and
     a frozen `ParsedTemplate` couldn't save it later anyway.
     Like `Template`'s, it doesn't raise for an invalid pattern. To match
     `Template` exactly, it also includes names from a valid expression
     nested inside an invalid token. `Template` scans the whole pattern for
     `EXPRESSION`, so `{{a}}` lists `a`. The lexer finds these with
     `names_in_invalid_token` and keeps them on `Machine::Invalid#names`. Trying
     each `{` in the token stops at the next `{` at the latest, so this is
     linear, and the lexer spec checks it.
     `variable_defaults` returns `{}`, as `Template`'s always does.
     `MatchData#values`, `#to_a` and `#captures` now work on the machine.
     The lexer spec compares `variables` with the `:regexp` engine for
     every valid and invalid pattern it has. Machine mode: 674 failures,
     from 721. This finishes phase 1; phase 2 (expansion) is next.

## `Template` bugs found along the way

The machine matches `Template` exactly, bugs included, so each of these
has a spec that compares the two engines. Fixing one is a `Template`
change, with its own `CHANGELOG.md` entry and, where it changes output,
the compatibility rules in `CLAUDE.md`. The machine then follows the fix.

- **`variables` lists names from inside invalid expressions.** It scans
  the pattern for `EXPRESSION` anywhere instead of using the tokens that
  `check_expressions` validates. So it lists `a` for `{{a}}`, `b` for
  `{a{b}`, and `b` for `{?a){&b*}`, although `expand` and `match` raise
  `InvalidTemplateError` for each. Invalid varspecs themselves aren't
  listed (`{a b}`, `{a:0}` and `{a,}` give `[]`). Fixing this deletes the
  lexer's `names_in_invalid_token` and `Machine::Invalid#names`.
- **`variable_defaults` always returns `{}`.** Its doc says it maps
  variables to their defaults. It came with the pre-RFC `{var=default}`
  syntax (7411808, 2009), which `expand` used. The RFC 6570 rewrite
  (9268509, 2012) dropped that syntax, since RFC 6570 has no defaults,
  but kept the method. `ordered_variable_defaults` now returns only
  names, so `reject { |k, v| v.nil? }` drops everything. It isn't a
  hook either: nothing in the library reads it (`freeze` computes it and
  throws it away), and `expand` ignores defaults. It's public API and
  pinned by `template_spec.rb`, so keep it, document it as always empty,
  and consider deprecating it at the next major.
- **A UTF-8 pattern that isn't valid raises `ArgumentError`** ("invalid
  byte sequence in UTF-8") from `freeze` and every operation, including
  `variables`, rather than `InvalidTemplateError`. A UTF-16 pattern raises
  `Encoding::CompatibilityError` the same way.
- **`match(nil)` raises `NoMethodError`** (`undefined method 'to_str'
  for nil`), where the docs say `match` returns `nil` for anything that
  doesn't match. `template_match_spec.rb` pins it in both modes.
- **Non-ASCII literals in a pattern that isn't UTF-8 make `match`
  raise.** `Template`'s regexp holds the literals' non-ASCII characters,
  so it takes their encoding: a pattern with a Latin-1, Shift_JIS or
  binary non-ASCII literal raises `Encoding::CompatibilityError`
  ("incompatible encoding regexp match (ISO-8859-1 regexp with UTF-8
  string)") for any URI with non-ASCII text, and one whose literals mix
  such a character with pct-encoded UTF-8 (`\xE9%C3%A9`) raises
  ("incompatible character encodings: ISO-8859-1 and UTF-8") from every
  `match`, and from `freeze`. `Matcher#literal` and `#match` raise the
  same errors.
- **On Ruby 2.3, `named_captures` merges `{42}` with `{__42__}`.** There
  a group name can't start with a digit, so `{42}`'s group is `__42__`,
  the same as `{__42__}`'s, and `{42}{__42__}` gives `{"42" => [1, 2]}`.
  The machine gives `{"42" => [1], "__42__" => [2]}`, and doesn't follow
  this one, since it merges two different variables; no spec covers it.
  Ruby 2.4 and later name the group `.42`, which no variable can have.

## Where the branch stands

The machine's code, from 2020 (rebased cleanly):

- `lib/addressable/template/lexer.rb` (was `template_lexer.rb`):
  `Template::Lexer`, a `StringScanner` lexer that turns a pattern into
  literal strings, `Expression` nodes, and `Machine::Invalid` nodes
  (rewritten in phase 1, piece 6)
- `lib/addressable/template/machine.rb` (was `template_machine.rb`):
  `Template::Machine`, with `Variable`, one `Expression`
  subclass per operator (`OpPlain`, `OpReserved`, `OpFragment`, `OpPath`,
  `OpLabel`, `OpPathParams`, `OpForm`, `OpFormContinuation`), and tagged
  values that join expansions
- `lib/addressable/template/parsed_template.rb` (was `uri_template.rb`):
  `Template::ParsedTemplate`, the `:machine` engine, with `#expand` and a
  rough `#match`. It uses `Template`'s error classes, `MatchData`, and
  `Template::Values` (phase 1, piece 3).
- `spec/addressable/template_machine_spec.rb`: unit specs for the nodes

Added since the rebase (002aecc onwards):

- `TEMPLATE_MODE=machine` in `spec/spec_helper.rb` runs the specs with
  `Template.engine = :machine`, like `IDNA_MODE=pure`. (Until phase 1 it
  swapped the `Template` constant for `UriTemplate`.)
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
| `:regexp` (default) | 1,909 | 0 |
| `TEMPLATE_MODE=machine`, end of phase 0 (constant swap) | 1,909 | 1,388 |
| `TEMPLATE_MODE=machine`, after piece 2 (engine switch) | 1,909 | 1,037, plus 240 pending |
| `TEMPLATE_MODE=machine`, after piece 3 (shared pieces) | 1,909 | 799, plus 240 pending |
| `TEMPLATE_MODE=machine`, after piece 6's lexer | 1,909 | 721, plus 240 pending |
| `TEMPLATE_MODE=machine`, end of phase 1 | 1,909 | 674, plus 240 pending |
| `TEMPLATE_MODE=machine`, end of phase 2 | 1,909 | 363, plus 240 pending |
| `TEMPLATE_MODE=machine`, after the oracle rework | 2,197 | 651 (363, plus the 288 new oracle examples) |
| `TEMPLATE_MODE=machine`, after the matcher | 2,198 | 60 (`named_captures` 47, processors 13) |
| `TEMPLATE_MODE=machine`, end of phase 3 (processors) | 2,198 | 47 (all `named_captures`) |
| `TEMPLATE_MODE=machine`, after `named_captures` | 2,198 | 0 |

Until the oracle rework, the 240 pending were the reference-oracle
examples, skipped in machine mode because they test the regexp builder
(see "Spec inventory"). They now run in both modes, and 288 machine-only
examples compare `#match` with the `:regexp` engine. The rest of
the drop from 1,388 is `#extract`, which now goes through the machine's
`#match` instead of not existing. `#to_regexp` and `#source` use the
shared builder by design (phase 4).

Largest groups of machine failures after piece 2:

| Count | Cause |
|---:|---|
| 291 | Wrong expansion or match result |
| 274 | Mapping assumed to be a `Hash` (`inject`); lambdas and other lookups fail |
| 79 | `InvalidTemplateError` / `InvalidTemplateOperatorError` / `InvalidTemplateValueError` not raised, or a different error |
| 76 | `NotImplementedError`: `partial_expand` |
| 74 | Expected no error, but expectations failed inside |
| 66 | Lexer raises `RuntimeError: Incomplete varspec` on valid varspecs |
| 32 | `NotImplementedError`: `variables` |
| 25 | `NotImplementedError`: a processor, a block, or `named_captures` |
| 22 | `#match` returned `nil` where a match was expected |

Rerun these with `TEMPLATE_MODE=machine bundle exec rspec <the four
files> -f json -o tmp/machine.json` and group the failures by exception
and the first non-empty line of the message.

### Performance today

`rake profile:template_machine` (`tasks/template_machine_profile.rb`)
compares the two engines. For four templates (simple; path,
query and prefix; exploded; reserved and fragment), it runs `expand`,
`partial_expand`, `match`, and `extract` on new and reused templates and
reports µs and objects per call. It also checks each pair of outputs:
`same`, `differs` (the machine's numbers don't count), or `missing` (the
machine raises, so it isn't timed). Then it times `match` on adversarial
payloads at two sizes and reports how the time grows, and does the same
for the first `expand` of long invalid patterns (the parse table). `ITERATIONS=n`
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
| 240 | Regexp from the private `#parse_template_pattern` versus a reference regexp | Runs in both modes, but tests only the regexp builder |
| 288 | `#match` with `engine: :machine` versus `engine: :regexp` (machine mode only) | Yes; the machine's oracle |

The 240 reference examples define which way `#match` splits a URI that
can be split more than one way: the end positions it tries and the values
it captures. That is observable behaviour, so the machine must match the
same splits. It just can't be tested through a private regexp, so the 288
compare the machine's `#match` with the `:regexp` engine's (see phase 3).

## Public API to keep

- Class: `Template.new(pattern)`. The plan adds `Template.engine`,
  `Template.engine=`, an optional `engine:` keyword on `new`, and
  `Template#engine`; all four are additions, so existing calls are
  unaffected.
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
- Done: add `Template.engine` and the `engine:` keyword. A template picks
  its engine the first time it needs one, not in `new`, so `new` stays as
  cheap as today and a template loaded with `Marshal` or YAML from an
  earlier version still works. `freeze` picks it first.
- Done: the `:regexp` engine is today's code, left where it is, so
  subclasses and monkey patches of `Template`'s private methods keep
  working with `:regexp`. Each operation starts with a guard that hands
  off to the `:machine` engine.
- Done: the `:machine` engine is `UriTemplate`'s code, moved behind
  `Template` as `Template::ParsedTemplate` (`@api private`). The public
  `UriTemplate` class is gone.
- Done (piece 3, except `resolve_mapping`): everything that isn't an
  operation lives once, in `Template`, and the
  machine uses it instead of copies: the error classes (they keep their
  public `Addressable::Template::` names), `MatchData`, `MappingLookup`,
  `normalize_value` and `utf8_value` (removing the copy made in
  e2eb19a), `pattern`, `==`, `eql?`, `hash`, `inspect`, and `freeze`.
- Done: specs: `TEMPLATE_MODE=machine` sets `Template.engine = :machine`
  instead of swapping the constant. `TestHelper.regexp_template` is gone,
  and the three lookups that used it read `Addressable::Template`.
- Done: `profile:template_machine` compares `engine: :regexp` with
  `engine: :machine`, which also shows what delegating costs.

Then parsing:

- Done (piece 6): lexer accepts everything `Template` accepts (pct-encoded names, names
  that start with a digit, dots, `:` prefixes up to 9999) and raises
  `InvalidTemplateError` / `InvalidTemplateOperatorError` for the rest,
  with `Template`'s messages. Like `Template`, `new` never raises for an
  invalid pattern; the error comes from the first operation that needs a
  valid one.
- Done (piece 6): handle text that isn't valid UTF-8 the way `Template`
  does, for parsing. Values were already shared through
  `Template::Values`. Literals in expansion are phase 2, and URIs in
  matching are phase 3.
- Done (piece 6): `variables`, `keys`, `names`, `variable_defaults`.
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

- **Done: one value lookup, for the machine only.** `Values` is now a
  class (`lib/addressable/template/values.rb`): `Values.new(mapping,
  normalize_values)` holds one expansion's values, and the shared
  helpers (`normalize_value`, `utf8_value`, `normalize_keys`,
  `defined_value`) are its class methods. It takes the mapping as
  `expand` does and runs it through `normalize_keys` (a `Hash` or a
  `MappingLookup`), so the block piece can pass a block straight in. `#[]`
  gives a name's value. The value for a name
  comes out defined (`Values.defined_value`: nil members dropped, `[]`
  and `{}` undefined), converted (numbers, symbols, and booleans to
  strings), type-checked (`TypeError` as now), and normalized (unless
  `normalize_values` is false), and it's remembered per name. A variable
  used more than once (`{a}{+a}`) is converted and normalized once.
  Values are still looked up when an expression needs them, in template
  order, so errors come in the same order as now. What depends on the
  expression stays per expression: the prefix-on-a-list check and
  processors. `Variable#expand_with` now only encodes the prepared value.
  The machine accepts `normalize_values` false.
  - Decided: the `:regexp` engine doesn't use the lookup. It stays
    today's code, so overrides of `normalize_value` and `defined_value`
    still apply to it, `partial_expand` raises `TypeError` where it does
    now, and `{a}{+a}` doesn't share one value object between the two
    expressions, which a processor that changes its argument would
    notice. `Template#defined_value` became a delegator to
    `Values.defined_value`, as piece 3 did for `normalize_value`.
  - Machine mode: 613 failures, from 674. Expand is 0.51–0.80×
    `Template`'s time.
- **Done: blocks.** `resolve_mapping`'s argument checks moved to
  `Values.mapping_or_block`, which returns the mapping or the block and
  raises `Template`'s `ArgumentError`s for both or neither.
  `Template#resolve_mapping` is now `normalize_keys` of it, which behaves
  the same and can still be overridden. The machine's `expand` takes a block, and
  `expand()` with neither raises `ArgumentError` instead of `TypeError`.
  Machine mode: 611 failures. Most of `Template`'s block and lambda specs
  also call `partial_expand`, so they wait for that piece.
- **Done: processors in `expand`** (`validate`, `transform`), called with
  the same values, as often, and in the same order as `Template`:
  `validate` gets the normalized value after the prefix check, and a
  `transform` result replaces the pct-encoded value and is normalized
  again unless `normalize_values` is false.
  - Decided: `Values` owns values, and `Machine` owns syntax.
    `Values.new(mapping, normalize_values, processor)` calls the processor:
    `Values#validate` (raises `Template`'s error), `#transforms?`
    (decided once per expansion), and `#transform` (normalizes the
    result). `Variable#expand_with(values)` keeps the prefix check, which
    `Template` runs before `validate`, the pct-encoding, and the tagging.
    The processor is called for each occurrence of a variable, as
    `Template` calls it (`{a}{+a}` validates `a` twice), so its calls
    aren't cached.
  - As in `Template`'s `join_values`, a transformed array whose first
    member has an `=` joins as pairs, and `TaggedValue#to_str` leaves
    members to `Array#join`, so nested arrays and non-strings join as
    they do in `Template`.
  - The specs in `template_machine_spec.rb` compare each case (every
    operator, array, pair, nested and non-string results, validation
    errors, call order) with the `:regexp` engine. Machine mode: 604
    failures; the processor failures left are all `match` (phase 3).
- **Done: a prefix on a list or hash** (`{x:3}` with `["a", "b"]`) raises
  `InvalidTemplateValueError` with `Template`'s message, from
  `Variable#expand_with`, after `Values` type-checks the value and before
  the next varspec is looked up, as in `Template`. The machine had
  truncated each member instead, and that code is gone. Machine mode: 609
  failures. The `template_spec.rb` examples for it also call
  `partial_expand`, so they pass only once that's done.
- **Done: pct-encoded triplets in `+` and `#` expansions.** `{+x}` with
  `%41` gives `%41`, where the machine gave `%2541`. The machine encodes
  reserved values with `Template::RESERVED_ENCODE` (public; its own
  `WITH_RESERVED` is gone), and a prefix counts a triplet as one
  character (`{+x:2}` with `%41bc` gives `%41b`). `Template#prefix`'s
  body moved to `Values.prefix`, with `Template#prefix` delegating, so
  both engines share it, including its path for values that aren't valid
  UTF-8. The specs compare every operator, lists, hashes, prefixes, and
  broken triplets (`%`, `%4`, `%zz`, `%%41`) with the `:regexp` engine.
  Machine mode: 543 failures, from 604.
- **Done: `Values` expands each varspec.** RFC 6570 section 2.4 calls
  prefix and explode *value modifiers*, so `Values` owns them along with
  the pct-encoding, and `Machine` owns the expressions.
  `Values#expand(variable)` looks the value up, checks a prefix against a
  list or hash, validates, then transforms or encodes with the varspec's
  modifiers (`Values.prefix`, `RESERVED_ENCODE` or its private
  `UNRESERVED_ENCODE`). `Machine::Variable` is just the varspec: `name`,
  `prefix`, `explode`, `allows_reserved?` from its operator, and `tag`,
  which wraps the result in its operator's `TaggedValue`, so `Values`
  doesn't know about operators. `Variable#expand_with` and
  `Machine::WITHOUT_RESERVED` are gone. Joining (leaders, separators,
  names) stays in the `Expression` subclasses and `TaggedValue`s. No
  behaviour change: machine mode is still 543 failures, the same ones,
  and expand's time and objects are unchanged.
- **Done: non-ASCII literals and later number signs.** `é/{a}` expands
  to `%C3%A9/v`, where the machine gave `é/v`, and a pattern that isn't
  UTF-8 has its bytes encoded as they are (ISO-8859-1 `a b\xE9/{a}`
  gives `a b%E9/v`). `ParsedTemplate.new` encodes each literal that
  isn't `ascii_only?` once, with `LITERAL_ENCODE`, into a second node
  list for expansion. It keeps the lexer's raw literals for `match`,
  which must accept a literal written either way (phase 3). Every `#`
  after the first is encoded as `%23`, through
  `Values.encode_later_number_signs`, which `Template` now delegates to
  as well. It now returns early when there's no second `#`, which saves
  both engines about 6 objects per expand of a URI with a fragment;
  output is unchanged. The specs compare literals in UTF-8, ISO-8859-1,
  Shift_JIS, binary and US-ASCII, invalid UTF-8, and number signs from
  literals and values, with the `:regexp` engine, and check both in
  linear time. Machine mode: 521 failures, from 543.
- **Done: empty values in `;`.** `{;a*}` with `{"k" => ""}` gives `;k`,
  where the machine gave `;k=`, and `{;a}` with `[""]` gives `;a=`, where
  it gave `;a`. `TaggedValue` has a `composite` member, set by `Values`
  from the value before any transform, and `PathParamTaggedValue`
  follows `Template`'s `;` join (pairs lose a trailing `=`; a composite
  value keeps its `=` even when empty; a `nil` or empty value doesn't).
  The specs compare empty strings, lists and hashes in every operator,
  with and without `*`, plus transform results, with the `:regexp`
  engine. Machine mode: 516 failures, from 521. The conformance suite
  passes, and the only expansion failures left are `partial_expand`.
- **Done: `partial_expand`**, including fragments and undefined
  variables. `ParsedTemplate`'s `expand` and `partial_expand` mirror each
  other: each builds the `Values` and renders the nodes, literals as they
  are and each expression through `Machine::Expression#expand` or
  `#partial_expand`. `expand` renders the encoded literals into a URI;
  `partial_expand` renders the lexer's raw nodes, so literals stay as
  written, into a template with the same engine and the pattern's
  encoding. (`Expression#join_expansions`, which returned `nil` for
  nothing, is now `#expand`, which returns `""`.) `Machine::Expression#partial_expand`
  follows `Template#transform_partial_capture` step by step: all given,
  expanded; none given, kept; otherwise runs of given and missing
  variables, a `?` expression's first defined variable moved to the
  front, and the comma operators' separators and fragments.
  `Values#key?` and `#defined_value?` answer "given" and "defined" from
  the raw mapping, without type-checking, so errors and processor calls
  come in `Template`'s order. `Variable#varspec` and each class's
  `operator` write kept expressions back as text. Switching `?` to `&`
  or `#` to `+` only changes the leader, since each pair allows the same
  characters and tags values the same way. The specs compare about
  12,000 partial expansions (every operator, three varspec lists, every
  mix of eight kinds of value) and the edge cases with the `:regexp`
  engine. Machine mode: 363 failures, from 516. `partial_expand` is
  0.40–0.55× `Template`'s time on reused templates and 0.70–0.97× on new
  ones.
- **Target met.** All expansion specs and the conformance suite pass in
  machine mode. Expand is 0.54–0.81× `Template`'s time and
  `partial_expand` 0.40–0.97× (Ruby 3.3.1), with fewer objects. The 363
  failures left are matching (299, including expand-then-match round
  trips), `named_captures` (47), and `match` with a processor (13).

Phase 2 is complete.

### 3. Matching and extraction

- **Done: the reference oracle, moved from phase 4.** Decided (option
  A): chain two checks rather than copy `Template#match`'s
  capture-to-mapping code into the spec. The 240 examples that compare
  `Template`'s regexp builder with the reference regexp run in both
  modes; `REGEXP_BUILDER_ONLY` is gone. In machine mode only, 288
  examples compare `#match` mappings (or `nil`) from `engine: :machine`
  and `engine: :regexp` over the same generated strings: the 224
  capture patterns, and each of the 16 single expressions followed by
  nothing, `x`, `{b}` and `{+b}` (`CONTEXTS`), so a different order of
  end positions shows as a different split. Together they pin the
  machine to the reference's splits, including `Template`'s quirks
  (`{;a,b}` with `;a=1` gives `{"a" => "", "b" => nil, "1" => ""}`).
  They aren't defined in the default mode, where they'd compare
  `:regexp` with itself and fail the full suite until the matcher
  passes them; once it does, consider defining them in both modes.
  When `:regexp` is removed (next major), they need another oracle:
  the reference regexp's captures turned into mappings, or stored
  expected mappings. Machine mode: 651 failures, all 288 new examples
  included (12 of them `TypeError`s from the 2020 matcher).
- The rest of phase 3, piece by piece: share `#match`'s URI handling and
  capture-to-mapping code; the matcher; processors; performance.
- **Done: shared URI handling and captures.** `Template#match` turns the
  regexp's captures into a mapping with about 90 lines of post-processing
  (splitting exploded values, dropping trailing empty members that are
  joiners, `;` / `?` / `&` pairs, unencoding, the first value of a
  repeated name winning), with quirks the specs pin. The machine must give
  the same mappings, so that code moved, unchanged, to
  `Template::Matching` (`lib/addressable/template/matching.rb`, `@api
  private`): `Matching.parse_uri` (the UTF-8 check and parse, or `nil`),
  `Matching.match_data(template, uri, expansions, matched, processor)`,
  which takes anything that answers `captures`, `begin(n)` and `end(n)` as
  a regexp `MatchData` does, and `Matching.valid_utf8?`, which
  `Template#valid_utf8?` delegates to. `Template#match` keeps
  `check_expressions`, the regexp, and the call to `match`. The machine
  will hand its own captures to `match_data`. No behaviour change: the
  full suite passes in both IDNA modes, `matching.rb` is fully covered,
  and `:regexp` `#match` time is unchanged (about 30, 45 and 53 µs on
  three templates, before and after).
- **Decided: the nodes describe how they match.** Rather than a matcher
  that switches on the operator, each node gives its part of the search
  as steps (a literal written either way; a run of a character class,
  shortest first, longest first or possessive; an optional joiner; a
  capture), and `Expression`'s subclasses supply the operator's parts
  (character class, value shape, exploded member, required joiner) as
  class methods, as they supply `leader` and `joiner`. A small
  `Template::Matcher`, which knows nothing about operators, runs the
  steps for the whole template. It searches the choices in order and
  remembers each (step, position) that failed, so nothing is searched
  twice, and it ends an exploded value's repeat that matched nothing
  rather than failing it, as Onigmo does (that order gives `{/a*}` on
  `/a/a` the oracle's end positions 0, 1, 3, 4, 2). `label_takes_dots?`
  moves to `Matching` for both engines. The matcher piece is split in
  two: literal nodes first, then the steps and the matcher.
- **Done: literal nodes.** Literals are `Machine::Literal` nodes rather
  than `String`s. A literal keeps its text as written, for
  `partial_expand` and matching, and its expansion with non-ASCII
  characters pct-encoded, worked out once. Literals and expressions both
  answer `expand` and `partial_expand`, so `ParsedTemplate` renders every
  node the same way, and its second node list (`@expansion_nodes`) is
  gone. No behaviour change: the full suite passes in both IDNA modes,
  and machine mode is still 651. Objects per call are unchanged, a new
  template makes at most one more object (one per literal, less the
  second list), and over two profile runs each, expand and
  `partial_expand` times are within the runs' noise.
- **Done: the steps and the matcher.** `Template::Matcher`
  (`lib/addressable/template/matcher.rb`): the nodes call its builder
  (`literal`, `exact`, `lazy_run`, `greedy_run`, `possessive_run`,
  `optional`, `nothing_or`, `capture`, `repeat`), which adds states to a
  small graph, one class per kind (`Literal`, `LazyRun`, `GreedyRun`,
  `PossessiveRun`, `Choice`, `Capture`, `MemberStart`, `MemberEnd`,
  `Done`). Each state's `follow` returns what to try next, in order.
  `#match` is a depth-first search with an explicit stack of `Attempt`s
  (no recursion, so long URIs can't overflow it), skipping any state and
  position it has tried before; that's what keeps it linear. Captures
  are an immutable list carried by each attempt, so going back needs no
  undoing. One lookahead, `FirstBytes` (the bytes a match from a state
  can start with, worked out once per template), lets a choice or a
  run's stop skip what can't start with the next byte, and lets a run
  take its whole extent at once when what follows can't start with any
  of its characters. Character sets (`CharacterSet`) treat a non-ASCII
  character or a pct-encoded triplet as one character, as `Template`'s
  classes do. `Literal#match_steps` follows `literal_regexp`;
  `Expression#match_steps` follows the reference regexp, with the
  operator's value, member and required joiner from class methods
  (`value_steps`, `member_steps`, `joiner_required?`), and
  `Expression#text` gives the expression as written for `match_data`.
  `ParsedTemplate#match` reads the URI with `Matching.parse_uri`, runs the
  matcher, and hands its `Captures` to `Matching.match_data`. The matcher
  is built on the first match, or by `freeze`, as `Template#freeze` builds
  its regexp. `label_takes_dots?` moved to `Matching`, with `Template`
  delegating. The 2020 matcher is gone (`extract_values`,
  `Variable#unencode`, `UNRESERVED_SCAN`, `UNRESERVED_SET`,
  `Machine::RESERVED`, `NoMatch`), and so are its `OpPath` unit specs,
  whose cases are now comparisons with `:regexp`.
  - Specs: `template_machine_spec.rb` compares `#match` with `:regexp`
    for every operator, literals in either form and in other encodings,
    number signs, dotted labels, `Addressable::URI` arguments, text that
    isn't a valid URI or valid UTF-8, `nil`, invalid templates, frozen
    templates, and names that start with a digit, and checks no regexp
    is built. With the 288 oracle examples, machine mode is down to the
    60 expected failures: `named_captures` (47, phase 4) and processors
    (13, next piece).
  - Fixed on the way: piece 1 made `match(nil)` return `nil` where it
    raised `NoMethodError` (`URI.parse(nil)` is `nil`). `parse_uri` now
    returns `false` for a URI that can't match, and a spec pins the
    `NoMethodError` in both modes (see "`Template` bugs").
  - The oracle examples build each template once and match every string
    with it; built per string, they took 184 s in machine mode, and now
    67 s.
  - How it got here: the first matcher was a step interpreter, at
    1.2–1.9× on new templates and 1.4–3.7× on reused ones. A round of
    optimizations (below) brought reused templates to 1.15–1.7×, but
    left the class near unreadable, so it was rewritten as the state
    graph above, keeping only the lookahead. Along the way, a run cache
    that only helped forward queries made `{;a,b}` quadratic (a greedy
    run's ends are tried longest first); `template_match_forms_spec.rb`
    caught it, and `template_machine_spec.rb` now checks ten patterns in
    linear time on 50,000-character URIs in the default suite.
  - Performance now (Ruby 3.3.1, two profile runs, noisy machine): match
    and extract are 1.25–1.5× `Template`'s time for the simple template,
    and 1.3–2.1× on new and 1.8–3.2× on reused templates with query,
    exploded and reserved expressions; path and reserved are over the 2×
    target on reused templates. The cost left is per character: in
    `{?foo,bar}` the reference lets `bar` start right after any
    character of `foo`'s value with no `&`, so each character of a
    query value tries about six states, each about 500 ns. Every
    adversarial payload grows about 4× for 4× the input (linear), at
    10–600× `Template`'s absolute time on Ruby 3.3.
- **Done: processors in `match`.** As in `Template`, a processor's
  `match(name)` is asked for every varspec of an expression, in template
  order, before that expression's states are built, and a pattern it
  gives replaces the value's states with a required capture of a
  `ProcessorPattern` state (`Template` writes `(?<name>pattern)`, with no
  `?`). The pattern is the caller's regexp, so a regexp matches it,
  compiled when the matcher is built (an invalid one raises
  `RegexpError` before any matching, as from `Template`'s regexp). Its
  ends are tried in the order Ruby's engine prefers them, found as
  `template_match_spec.rb`'s `end_positions` does: match with `\G` at
  the position, then again with each end found so far ruled out by a
  lookahead on the characters left. Patterns can differ per call, so
  `ParsedTemplate#match` builds a matcher for each call with a processor
  that answers `match`, as `Template` doesn't cache its regexp then; a
  processor that only restores uses the cached matcher. `restore`, and
  not unencoding values, were already shared in `Matching.match_data`.
  With a processor's pattern, matching is only as linear as the pattern,
  as with `Template`. Specs compare 13 templates and patterns (lazy,
  greedy, lookaheads, lookbehinds, non-ASCII, empty), the call order,
  invalid patterns and URIs, and restore-only processors with the
  `:regexp` engine; `template_engine_spec.rb`'s "doesn't match with a
  processor yet" now checks that it does. Machine mode: 47 failures, all
  `named_captures` (phase 4). With `ExampleTwoProcessor`'s patterns,
  `match` is about 1.8× `Template`'s time.
- **To come back to at the end of phase 3: matcher optimizations.**
  Options seen so far, with what each bought when it was measured, to
  weigh against readability (goal 3) once processors are done:
  1. **States push their attempts straight onto the to-try stack**, last
     choice first, rather than returning an array. Saves an allocation
     per state; estimated 10–15%. Not tried.
  2. **Look one run ahead, not one character** (RE2's idea in
     miniature): in `{?foo,bar}`, `bar`'s name must be followed by `=`,
     so the rest can't start at most positions of `foo`'s value. Would
     likely bring path and reserved under 2×; another concept to
     explain. Not tried.
  3. **RE2's backward pass:** work out, for every state and position,
     whether the end is reachable, then walk forward without ever
     backtracking. Predictable cost, but it always fills the whole
     states × positions table (RE2 makes that cheap with a cached DFA in
     C), and it's a second engine to read. Not tried.
  4. **Don't mirror the regexp's structure.** Most of the shape
     (nothing first, every varspec optional, optional joiners between
     varspecs, the empty-member rule) is the reference regexp's. A
     matcher that reasons at the template level (split `?` values at
     `&`, names at `=`) could decide unambiguous URIs directly and
     search only where a split is ambiguous. Each shortcut must give
     the regexp's split, which only the oracle checks.
  5. **Search for the literal that follows a run** with `String#index`
     (on a binary copy for non-ASCII URIs, so offsets are bytes) and try
     only where it occurs. Tried: reserved 41 → 33 µs, path 26 → 22 µs
     for the matcher alone, with 4 and 6.
  6. **Fixed run patterns** (`(?:[set]|%HH|[^\x00-\x7F])*+`, one per
     set, compiled at load) with `StringScanner#skip`, so a run's extent
     is found in C. Possessive, so they can't backtrack. Tried, with 5.
     They could also define `CharacterSet` itself, as small named
     regexps that read as what they mean. They don't give
     `#to_regexp` for free, though: its source has to stay what
     `Template`'s builder writes (phase 4, decided), and that differs
     from the reference's shape (possessive members, lookbehinds, `(?!)`
     leaders, group names like `.42`). Composing it from the nodes means
     either porting those rewrites into the nodes or changing `#source`'s
     output, which callers can see.
  7. **End checks**, since a match must use the whole URI: a trailing
     literal must end it (tried; catches templates that end in a
     literal), the last byte must be one the template can end on, every
     byte must be one the template can take, and a branch that leaves
     fewer bytes than the rest needs can't finish. Prefilters flatter
     the profile's adversarial payloads, so add payloads that get past
     them.
  8. **Interpreter tricks:** literal `when`s (symbols) so `case`
     compiles to a jump table (15–25%), one step per run with a tight
     loop (reserved 51 → 41 µs), `while` rather than `loop` (about 12%),
     a bit-packed memo string, joining literal units (5 µs → 0.08 µs for
     a 25-byte literal; kept). First sets as arrays rather than Integer
     bitmasks: lookups 11 rather than 40 ns, but slow to build.
  9. **`Matching.match_data`**, shared by both engines, is the largest
     single cost of `#match` (22–47 µs). Speeding it up helps both
     engines and doesn't change the gap between them.
  10. **YJIT** isn't in this Ruby build; measure the matcher with it in
      CI (Rails 7.1+ turns it on by default on Ruby 3.3).
  - Ruled out: normalizing the URI first. `URI#normalize` does handle
    pct-encoding (uppercases hex digits, decodes unreserved characters,
    encodes non-ASCII), but it changes results (it lowercases the host,
    and a literal `%41` stops matching once `%41` becomes `A`) and costs
    about 50 µs per URI.
- Done, by the pieces above: the 2020 matcher (`extract_values`) is
  replaced by one that never backtracks exponentially and splits as the
  reference regexp does; exploded lists and hashes, the named operators,
  prefixes, and processors' `match` and `restore`; `extract` and
  `MatchData` (phase 1); non-ASCII literals and `#` in either form, and
  no match for text that isn't valid UTF-8; and only whole-URI matches.
- Target: `template_match_spec.rb` "with adversarial input" passes on
  every runtime (in machine mode in CI), and match and extract are
  within 2× `Template`'s time (goal 3, as decided in phase 3). Met for
  new templates and the simple one; reused templates with query,
  exploded and reserved expressions are at 2.1–2.9×, which the
  optimization list above is for.

Phase 3 is complete, apart from weighing the optimization list.

### 4. Regexp API

- Decided at the start of phase 4: the matcher optimizations wait until
  after it, and a frozen machine template's `to_regexp` is fixed by
  building the regexp in `freeze`, as `:regexp` does.
- **Done: `named_captures` from the nodes, with no regexp.** It maps
  each variable name to the 1-based positions of its occurrences, in
  template order (`{/a,b*}{?c,a}` gives `{"a" => [1, 4], "b" => [2],
  "c" => [3]}`), since `Template`'s regexp has one named group per
  varspec, in order. It uses variable names as written, so `{42}` gives
  `{"42" => [1]}`, not the group name `.42`. For a malformed pattern it
  raises `Template`'s error (`ParsedTemplate#nodes`). With it,
  `ParsedTemplate` has no `NotImplementedError` left, and `unsupported`
  is gone. Specs in `template_machine_spec.rb` compare 31 patterns and
  invalid ones with `:regexp`. Machine mode: 0 failures, from 47.
- `to_regexp` and `source`: build the regexp only when one of them is
  called, once per template, with the existing builder, so the result is
  exactly what `Template` gives now. `expand`, `match`, and `extract`
  never build one with the machine engine.
- **Found at the end of phase 3:** a frozen machine template's
  `to_regexp` (and so `source`) raises `FrozenError`, where `:regexp`
  works. `parse_template_pattern` caches in `@cached_template_parse`,
  and `Template#freeze` only fills that cache for `:regexp`, since the
  machine's `freeze` computes nothing it doesn't need. Decide how to
  keep both: build the regexp in `freeze` for the machine too (about
  40 µs per frozen template, used or not), build it without caching
  once frozen (each call rebuilds it), or keep the cache somewhere that
  isn't frozen. Ask the user. Add a spec that compares a frozen machine
  template's `to_regexp`, `source` and `named_captures` with
  `:regexp`'s.
- Keep the grammar constants.
- Done in phase 3: the reference-oracle rework.
- Then: once the regexp API is done, machine mode should have 0
  failures, which phase 5 (release N) requires on every runtime.

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
  silently change `#match` results. The reworked oracle (done at the start
  of phase 3) pins every split the reference examples cover.
