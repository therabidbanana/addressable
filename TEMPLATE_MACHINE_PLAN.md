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

The end state is that `Addressable::Template` uses the machine internally.
`Addressable::UriTemplate` is the working name while the two run side by side.

## Where the branch stands

The 2020 commits rebased cleanly. They add:

- `lib/addressable/template_lexer.rb`: a `StringScanner` lexer that turns a
  pattern into literal strings and `Expression` nodes
- `lib/addressable/template_machine.rb`: `Variable`, one `Expression`
  subclass per operator (`OpPlain`, `OpReserved`, `OpFragment`, `OpPath`,
  `OpLabel`, `OpPathParams`, `OpForm`, `OpFormContinuation`), and tagged
  values that join expansions
- `lib/addressable/uri_template.rb`: `UriTemplate` with `#expand` and a
  rough `#match`
- `spec/addressable/template_machine_spec.rb`: unit specs. The 5 `OpPath`
  ones fail because `let(:var)` and `subject(:op)` refer to each other, and
  they call `extract_values` with 3 arguments where it takes 2.
- `tasks/profile.rake`: `profile:template_machine` (expand only) and
  `profile:template_machine_match` (machine only, memory only)

Uncommitted, since the rebase:

- `TEMPLATE_MODE=machine` in `spec/spec_helper.rb` puts `UriTemplate` in
  `Template`'s place before the specs load, like `IDNA_MODE=pure`.
- `TestHelper.regexp_template` always returns the regexp-based class. The
  reference oracle in `template_match_spec.rb` and the
  `GROUP_NAME_CAN_START_WITH_DOT` checks in `template_spec.rb` use it.
  It's temporary: it exists only while two implementations run side by
  side, and phase 5 removes it.
- `UriTemplate` defines `Template`'s four error classes.
- Removed `spec/addressable/uri_template_spec.rb` (a 2020 copy of
  `template_spec.rb`) and `profiling/*.txt` (generated output).

### Baseline

`template_spec.rb`, `template_match_spec.rb`, `template_match_forms_spec.rb`,
and `template_conformance_spec.rb`:

| Mode | Examples | Failures |
|---|---:|---:|
| regexp (`Template`) | 1,908 | 0 |
| `TEMPLATE_MODE=machine` | 1,908 | 1,413 |

Largest groups of machine failures:

| Count | Cause |
|---:|---|
| 275 | Mapping assumed to be a `Hash` (`inject`); lambdas and other lookups fail |
| 267 | No `#extract` |
| 240 | No `#parse_template_pattern` (reference oracle, see below) |
| 156 | Wrong expansion or match result |
| 100 | Lexer raises `RuntimeError: Incomplete varspec` on valid varspecs |
| 76 | No `#partial_expand` |
| 74 | Expected no error, but expectations failed inside |
| 33 | No `#variables` |
| 22 | `#match` returned `nil` where a match was expected |
| 24 | `InvalidTemplateError` / `InvalidTemplateValueError` not raised |
| 13 | `ArgumentError: invalid byte sequence in UTF-8` |

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

- Class: `Template.new(pattern)`
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
- Run `TEMPLATE_MODE=machine` in CI as a non-blocking job, so the count is
  tracked on every runtime.
- Last: add a "Starting phase 1" section to this plan with enough for a
  fresh agent to pick up phase 1 with no other context: the commands to
  run, the current failure counts and their causes, the files involved,
  the conventions to follow (CLAUDE.md, the review-each-piece workflow),
  and phase 1's first concrete step.

### 1. Parsing

- Lexer accepts everything `Template` accepts (pct-encoded names, names
  that start with a digit, dots, `:` prefixes up to 9999) and raises
  `InvalidTemplateError` / `InvalidTemplateOperatorError` for the rest,
  with `Template`'s messages.
- Handle text that isn't valid UTF-8 the way `Template` does.
- `pattern`, `variables`, `keys`, `names`, `variable_defaults`, `==`,
  `eql?`, `hash`, `inspect`, `freeze`.
- Check lexer regexes for backtracking on every runtime (CLAUDE.md).

### 2. Expansion

- Mapping lookup through the same path as `Template` (`MappingLookup`), so
  lambdas and non-`Hash` mappings work.
- Value conversion, normalization with `String#unicode_normalize(:nfkc)`,
  and processors (`validate`, `transform`).
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
- `MatchData` and `extract`.
- Match only when the whole URI is consumed. `UriTemplate#match` ignores
  whatever follows the last node, so it matches every adversarial payload
  in the profile (e.g. `{/foo*}` matches `/a/a/…/a/!`), where `Template`
  returns `nil`.
- Target: `template_match_spec.rb` "with adversarial input" passes on every
  runtime, and match and extract are at least as fast as `Template`.

### 4. Regexp API and the reference oracle

- `to_regexp`, `source`, `named_captures`: keep the existing regexp builder
  for these (decision 1), producing exactly what `Template` produces now.
- Keep the grammar constants.
- Rework the 240 reference examples to compare `#match` results with the
  reference regexp's matches, so they test the behaviour and run in both
  modes. Build the reference regexp from the public grammar constants and
  stop calling the private `#parse_template_pattern`, so the examples no
  longer need `TestHelper.regexp_template`.

### 5. Switch over

- Make `Addressable::Template` use the machine, and remove `UriTemplate`,
  `TEMPLATE_MODE`, and `TestHelper.regexp_template`. The specs go back to
  reading everything, including `GROUP_NAME_CAN_START_WITH_DOT` and the
  grammar constants, from `Addressable::Template`, with no spec that
  reaches around it.
- Full suite in both IDNA modes on Ruby 2.3 to 4.0, JRuby, and TruffleRuby.
- Benchmarks meet goal 3 on each runtime.
- `CHANGELOG.md` entry under `` ### `Addressable::Template` ``, following
  the format in CLAUDE.md.

## Open decisions

1. **Regexp builder.** `#to_regexp` is public, so some regexp builder has
   to stay. Either keep the current one only for `to_regexp`, `source`,
   and `named_captures`, or generate the regexp from the machine's nodes.
   Keeping the current one is less work and guarantees identical output.
2. **Error classes.** `UriTemplate` currently defines its own copies. Once
   phase 5 merges the classes this goes away, but until then a caller that
   rescues `Addressable::Template::InvalidTemplateError` won't catch
   `UriTemplate`'s errors.
3. **Release.** Keeping all output identical makes this a patch or minor
   release. Any output change found along the way needs its own decision
   (CLAUDE.md: changed return values go in the next minor release).

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
