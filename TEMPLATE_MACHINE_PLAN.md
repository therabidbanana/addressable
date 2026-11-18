# Template machine

## Goals

1. **No breaking changes.** `Addressable::Template` keeps its public
   API, return values and exceptions. The `Template` specs pass unchanged
   against the machine.
2. **No catastrophic backtracking.** Expanding, matching and building the
   regexp run in linear time on every supported runtime, including ones
   without regex memoization (Ruby < 3.2, JRuby, TruffleRuby), without
   relying on `Regexp.timeout`.
3. **Same or better performance** than today's `Template`. Matching
   (`match`, `extract`) may take up to 2× as long if that keeps the
   matcher readable, as long as adversarial input stays linear.

## Design

`Template` is still the only public class. It has two private engines
and hands each operation to one of them with an `if engine ==
:machine` guard:

- `:regexp`: today's code, left where it is.
- `:machine`: `Template::ParsedTemplate`, which lexes the pattern once
  into nodes (`Template::Lexer`, `Template::Machine`) and walks them.

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
  answer `expand`, `partial_expand`, `match_steps` and `regexp_source`.
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
  follows it.

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

## What's left

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

### Simplification

The code grew piece by piece, and much of it mirrors `Template`'s
regexp shapes. Some ways to make it smaller and easier to read:

- **Code that exists only to copy a `Template` bug** (`variables` reading
  invalid expressions: `Lexer#names_in_invalid_token`,
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
  `template_lexer_spec.rb`.
- Follow `CLAUDE.md`: specs first, Ruby 2.2-compatible code, both IDNA
  modes. Any warning fails the suite.
- Work one piece at a time, and wait for review before committing.
- Run the profile twice before calling a slowdown real.
- Add new adversarial shapes to the linear-time checks in
  `template_machine_spec.rb`, which run in the default suite.
