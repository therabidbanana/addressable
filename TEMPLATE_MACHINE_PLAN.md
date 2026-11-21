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
full suite passes in both IDNA modes (5,191 and 5,077 examples), and
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
linearly, but the absolute cost can be far above `:regexp`'s: at
n=2,000, `{;a*}{;b*}{;c}!` (ending `?!`) takes 52 ms and 0.46 MB
(3.3 MB before item 6), against 3 ms for `:regexp`. `{a}`×12`!` took 46 ms and 3.1 MB until its
later variables lost their states (`Slots`, `empty_only`); it now takes
0.06 ms, as `:regexp` does.

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
- **Names in `;`, `?` and `&` are matched as written.** Expansion
  writes `;k` for an empty string, so a `;` value written `k=` isn't
  one: with a prefix, or as an exploded value's member, it doesn't
  match, and otherwise it's a list of one empty member (below). Inside
  an exploded `;`, `?` or `&` value an empty member is a `""` key.
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
- **An exploded `;`, `?`, `&`, `+` or `#` variable right after another
  in its expression takes nothing** (`{;foo*,bar*}` matches like
  `{;foo*}`), so the matcher adds no steps for it. In a default, `/`
  or `.` expression it can take the kind of member the earlier one
  didn't (see the associative arrays below).
- **A value that isn't exploded can be a list.** Expansion writes a
  list's members with commas between them, and a comma inside a string
  as `%2C`, so a comma as it is separates members: `{/a}` on `/x,y`
  gives `["x", "y"]`, and `{?a}` on `?a=x,y` the same. An associative
  array writes the same text, so it comes back as a list too. In the
  default operator the comma is the joiner as well, so only an
  expression's last variable can be a list, as only a `+` or `#`
  expression's last holds commas: `{a,b}` on `x,y,w` gives `"x"` and
  `["y", "w"]`. A `;` value written `a=` is a list of one empty
  member, which is what writes it. Not `+` and `#`, whose values hold
  commas; nor with a prefix, which expansion refuses for a list; nor
  a value a processor's pattern matched.
- **An exploded default, `/` or `.` value can be an associative
  array.** Expansion writes each pair as its key, `=` and its value,
  and an `=` inside a key, a value or a list's member as `%3D`, so an
  `=` as it is makes a member a pair: `{/a*}` on `/k=v/j=w` gives
  `{"k" => "v", "j" => "w"}`. Its members are all pairs or all values,
  and no key comes twice; `/k=v/x` and `/k=v/k=w` don't match. Not `+`
  and `#`, whose members hold `=` as it is, so `{+a*}` on `k=v` is the
  list `["k=v"]`.
- **A prefix takes at most its length,** counted in decoded
  characters, since expansion cuts the value before it pct-encodes it:
  a character as it is, or the triplets of one UTF-8 character
  (`{a:1}` writes `é` as `%C3%A9`), is one. A triplet that isn't part
  of a character is one too, as `+` and `#` expansion count it, so
  `{+a:1}` takes `%C3%A9`, which it writes for `é` but not for the text
  `%C3%A9`; the URI can't tell them apart. What a prefix leaves goes to
  the next variable. Of 20,000 generated prefix expansions, the cap
  rejects none.
- **A name written again matches the earlier value,** where that
  value's place in the URI is decided: it and every variable before it
  end at their run's end, as what follows each is a character it can't
  hold, and no other value comes between the two (`Machine::Slots`). The
  later varspec matches the value written as the earlier one is, or as
  expansion writes it, and is left out only where the earlier one is.
  A prefix is the start of the value: `{/var:1,var}` on `/v/value`
  gives `"value"`, and a longer prefix gives more of it than a shorter
  one (`{a:1}{a:2}` on `xxy` gives `"xy"`). The search remembers the
  states between the two once for each place the earlier value took
  (`Matcher#note_dependencies`). Elsewhere (`{a}.{a}`, `{a}/{b}/{a}`,
  a name exploded in one place and not another) the values are
  compared once a split is found: equal when decoded, a prefix the
  start of the whole, an exploded list of one member the same as the
  member, and left out only where it would write nothing. If they
  disagree the search goes on to the next split, up to eight of them:
  comparing at every place the earlier value could end was quadratic
  (`{a}{a}` 1.0 s at 16 KB) and, with a value between, close to cubic.
  So a URI can go unmatched though some split of it agrees (see "Next
  work", item 2).

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
| `{/a}` | `/x,y` | no match | `"a" => ["x", "y"]` | List in a value |
| `{a,b}` | `x,y,w` | no match | `"a" => "x", "b" => ["y", "w"]` | List in a value |
| `{;a}` | `;a=` | `"a" => ""` (writes `;a`) | `"a" => [""]` | List in a value |
| `{?a,b}` | `?a=x,y&b=w` | no match | `"a" => ["x", "y"], "b" => "w"` | List in a value |
| `{.a}{c*}` | `.x,y` | `"a" => nil, "c" => [".x", "y"]` | `"a" => ["x", "y"], "c" => nil` | List in a value |
| `{/a*}` | `/k=v/j=w` | no match | `"a" => {"k" => "v", "j" => "w"}` | Pairs in a value |
| `{/a*,b*}` | `/x/k=v` | no match | `"a" => ["x"], "b" => {"k" => "v"}` | Pairs in a value |
| `{?a*}{.c*}` | `?k=x.j=y` | `"a" => {"k" => "x.j=y"}, "c" => nil` | `"a" => {"k" => "x"}, "c" => {"j" => "y"}` | Pairs in a value |
| `{a:3}` | `abcdef` | `"a" => "abcdef"` (writes `abc`) | no match | Prefix length |
| `{a:2}{b}` | `xyz` | `"a" => nil, "b" => "xyz"` | `"a" => "xy", "b" => "z"` | Prefix length |
| `{a}/{a}` | `x/y` | `"a" => "x"` (writes `x/x`) | no match | Name written again |
| `/{lang}/page{?lang}` | `/en/page?lang=fr` | `"lang" => "en"` | no match | Name written again |
| `{/var:1,var}` | `/v/value` | `"var" => "v"` (writes `/v/v`) | `"var" => "value"` | Name written again |
| `{a}/{b}/{a}` | `x/y/z` | `"a" => "x", "b" => "y"` (writes `x/y/x`) | no match | Name written again |
| `{a}.{a}` | `x.x.x.x` | `"a" => "x"` (writes `x.x`) | `"a" => "x.x"` | Name written again |
| `{a:1}{a:2}` | `xy` | `"a" => "xy"` (writes `xxy`) | no match | Name written again |
| `{a}{a}` | `xx` | `"a" => "xx"` (writes `xxxx`) | no match (`"x"` would write it) | Name written again |

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

Each item stands alone and can be built as described; items 1–4, 12,
16 and 17 record decisions made on 2026-11-20. Work one piece at a time, with
specs first, and get each reviewed before committing (see "Working on
it").

### Matching results

1. **Compare a prefix as the search goes (the rest is built).** A
   prefix varspec takes at most its length (`Matcher::CappedRun`; see
   "Matching rules"), so `{a:3}` on `abcdef` doesn't match, and two
   prefixes of one name are compared once a split is found (item 2):
   `{a:1}{a:2}` doesn't match `xy`. What's left: a prefix's end is near
   enough to decided that `Machine::Slots` could give shapes like
   `{a:1}{a}` a `RepeatedValue`, which compares during the search and
   so finds splits the check after it can miss.
2. **Find more of the splits where repeated names agree (the check is
   built).** A split where a name's varspecs took values that disagree
   isn't a match now (`Slots#read`; see "Matching rules"), and
   `ParsedTemplate#match` asks the search for the next split, up to
   `SPLITS_TO_TRY` (8) of them. On 12,196 generated templates that
   write a name more than once, matched against their own expansions:

   | | Right | Wrong values | Mapping that can't expand | No match |
   |---|---|---|---|---|
   | Before | 7,643 | 2,210 | 2,084 | 259 |
   | Rejecting at the first split | 7,133 | 20 | 1,091 | 3,952 |
   | Trying up to 8 (built) | 7,734 | 22 | 1,268 | 3,172 |

   Trying every split finds one more than 8 does. What's left:
   - A quarter of these expansions still don't match, since the search
     can't reach the split that agrees: a state it passed on the way
     to a split turned down isn't tried again with other captures (the
     memo), and `{a}{a}` gives its second `a` no states (item 18).
     These are generated worst cases; a shape like
     `/{lang}/docs{?lang}` is compared as the search goes
     (`RepeatedValue`).
   - 22 still match with values that don't write the URI, and 1,268
     with a mapping `expand` raises for. Not looked into.
   - The round trip's generator still gives each name one use.
3. **Match a list in an unexploded variable (built).** A value that
   isn't exploded holds raw commas and comes back as a list
   (`Expression#holds_list?`; see "Matching rules"): any `/`, `.`,
   `;`, `?` or `&` value, and the last of a default expression. On
   20,000 generated templates with strings, lists and hashes in
   unexploded variables, each name used once, every expansion now
   matches and writes the URI back: 14,911 with a list or hash, where
   4,541 did, and the same 5,089 with strings only. A new result where
   there was none, so it belongs in a minor release. What it costs:
   - A literal comma, or an expression with no leader, right after
     such a value no longer decides where it ends, so a name written
     again there isn't compared as the search goes
     (`Expression#end_decided?`), only once a split is found (item 2).
     On item 2's 12,196 repeated-name templates, 45 fewer expansions
     match (7,734 to 7,689).
   - Where two variables could take a comma, the earlier one wins:
     `{.a}{c*}` on `.x,y` gives `a` `["x", "y"]`, where `c` took
     `["", "y"]`, and `{a,b}{c*}` on `x,y,z` gives `b` `["y", "z"]`,
     where `c` took `["", "z"]`.
   - The values aren't always the ones expanded, only ones that write
     the same URI: `{a,b}` with `["x", "y"]` and `"w"` writes `x,y,w`,
     which gives `"x"` and `["y", "w"]`; an associative array comes
     back as a list; and a list of one member as a string.
4. **Match exploded hashes outside `;`, `?` and `&` (built).** An
   exploded default, `/` or `.` value whose members are all pairs is an
   associative array (`Expression#members_can_be_pairs?`; see
   "Matching rules"). The round trip spec now generates strings, lists
   and associative arrays in every kind of variable, and all 2,000 of
   its templates match their expansions and write them back. Three
   things that took:
   - *The same key twice isn't a match.* An associative array has each
     key once, so `{/a*}` doesn't match `/k=v/k=w`
     (`Expression#read`).
   - *A later exploded variable isn't absorbed there.* The earlier one
     takes all of one kind, and the later can take the other:
     `{/a*,b*}` gives `/x/k=v` `["x"]` and `{"k" => "v"}`. It costs
     states: rejecting 16 KB of `/` with `{/a*,b*,c*}!` went from 25 ms
     to 164 ms. With more ways to split, a name exploded twice in one
     expression can use up item 2's eight tries sooner.
   - *An exploded `?` or `&` member keeps the fewest `=` it can.* Its
     value can hold an `=` as it is, for URIs expansion didn't write
     (a token that ends `==`). It tried the most first, and so took
     the pairs of an expression after it: `{?a*}{.c*}` gave `?k=x.j=y`
     all to `a`.

   What it leaves, which the round trip spec's generator avoids:
   - A list or an associative array in a default expression's variable
     that isn't its last and isn't exploded (`{a,b*}` with `a`
     `{"k" => "v"}`, which writes `k,v,…`): there the comma is the
     joiner. It could be tried after the usual reading fails.
   - An exploded `;`, `?` or `&` value with the same name twice
     (`{?a*}` on `?k=1&k=2` gives `{"k" => "2"}`), as before.

16. **A processor's pattern covers only the value in `;`, `?` and `&`
    (decided 2026-11-20; build later).** In both engines the pattern
    replaces the whole `name=value` text, so `{?n}` with `[0-9]+` for
    `n` doesn't match `?n=12`, and matches `?12` as
    `{"n" => nil, "12" => ""}`; only a pattern that writes the name
    (`n=[0-9]+`) gives `{"n" => "12"}`. The machine should match the
    name as written, then the pattern against the value alone: `{?n}`
    with `[0-9]+` on `?n=12` gives `{"n" => "12"}`, and `?12` doesn't
    match. `:regexp` keeps its results, so this is a new row for the
    processor differences. Notes for building it:
    - For `;`, the value is left out with its `=` (`;n`) only where the
      pattern matches an empty value, and `;n=` never matches, so the
      pattern state needs a way to refuse an empty value.
    - `Expression#read` can then take the variable's name off the
      front of the text, where it now splits at every `=` and gives
      the value under whatever name the text has.
    - A variable with a pattern becomes one an exploded value stops
      before (`Expression#named_texts` leaves those out today), so
      `{?a*,n}` gives `n` its own pair.
    - An exploded variable's pattern still covers all its members'
      text, names included; decide that with this.
    - It breaks a caller who wrote the name into the pattern as a
      workaround (`n=[0-9]+`). Say so in the changelog.

17. **A long prefix is slow where its run starts in many places
    (revisit; accepted for now, 2026-11-20).** `CappedRun` has to know
    where its value started, so it hands over every end from each
    start, and the time grows with the URI's length times the
    prefix's. That's linear in the URI and small for a short prefix
    (`{x}.{a:3}!` rejects 16 KB in 38 ms, `{x}.{a:100}!` in 0.24 s), but
    not for the longest (Ruby 3.3.1, 16 KB that doesn't match):

    | Template | URI | Time |
    |---|---|---|
    | `{a:9999}{b:9999}!` | `aaa…?!` | 21 s |
    | `{a:9999}{b:9999}{c:9999}!` | `aaa…?!` | 116 s |
    | `{x}.{a:9999}!` | `a.a.a.…?!` | 12 s |
    | `{+x}/{+a:9999}!` | `a/a/a/… !` | 13 s |
    | `{a:9999}{x}!`, `{/x}{/a:9999}!`, `{x}/{a:9999}!` | | under 25 ms |

    The linear-time specs run the short prefixes, not these. Item 5
    removed `{x}{a:9999}!` (25 s): `x` can hold everything `a` can, so
    `a` never takes a character. Ways in for the rest:
    - The same argument thins `{a:N}{b:N}`: if `a` stops short of its
      length and `b` then takes a character, `a` could have taken it,
      and the earlier variable wins. So `b` only needs to start where
      `a` is full, or took its whole run.
    - That leaves a value that stops in many places before a literal
      it could hold (`{x}.{a:9999}`). There the ends from one start
      overlap those from the last, and only the new ones need trying:
      a running count of decoded characters gives each start's last end
      without walking to it, and the run can skip ends it already
      handed over. Skipping is only sound where no later state reads a
      capture (a name written again does), as with the memo.

### Memory

On a URI that doesn't match, the search tries every state at every
position it can reach, and remembers each branching one, so memory
grows with the URI's length times the template's branching states: a
byte for each position, for each state reached.
What one match allocates at 16 KB (`memory_profiler`, 2026-11-20):
`{;a*}{;b*}{;c}!` 0.90 MB, of which the memo is 0.43 MB, and under
0.4 MB for the other shapes measured. `:regexp` allocates well under
0.1 MB. Before items 5 and 6, the memo alone was 16.8 MB for
`{a}`×12`!` and 4.2 MB for `{;a*}{;b*}{;c}!`.

5. **Prune variables that can never take a character (built).** The
   first variable of a default expression right after a default or `+`
   expression has no states for a value (`Slot#empty_only`; the
   conditions are in `Slots`' comment). It changes no result: 43,202
   generated templates and texts give the same output with and without
   it. At 16 KB, `{a}`×12`!` went from 399 ms and 16.8 MB to 0.6 ms,
   and `{x}{a:9999}!` from 25 s to 0.5 ms. Item 18 lists the cases it
   leaves.
18. **More variables that can never take a character.** What item 5
    left, each to check the same way (the same output on generated
    templates and texts, unless it's meant to change):
    - In `{a}{b,c}`, `c` can't be the expression's first value with a
      character either: it only takes one after its joiner. It still
      has the states for it (`{a}{b,c}!` remembers 64,000 places at
      16 KB, where `{a}{b}{c}!` remembers two).
    - An `empty_only` variable still counts as a value between two
      varspecs with the same name, so `{a}{b}/{a}` isn't compared with
      its earlier value. Not counting it changes results, for the
      better, so decide it with item 2.
    - `{a:N}{b:N}`: `b` only needs to start where `a` is full. That
      isn't known from the text alone, so it needs a state that reads
      `a`'s capture, or a second copy of the states after `a`. Item
      17's general fix may cover it; decide there.
6. **Shrink the memo and the capture lists (built).** Neither changes
   a result: 43,202 generated templates and texts give the same output.
   What one match allocates rejecting 16 KB went from 6.55 MB to
   0.90 MB for `{;a*}{;b*}{;c}!`, 3.52 to 0.23 MB for `{a}{b,c}!`,
   1.83 to 0.37 MB for `{+a}/{b}!` and 1.06 to 0.21 MB for
   `{/a*,b*,c*}!`.
   - *The memo was one Hash of every state and position.*
     `Matcher::Memo` keeps a row for each state that branches
     (`State#memo_row`): a String with one byte for each position, 0
     until it's tried and 1 after. `Memo#positions` and `#to_s` list
     what a search tried, and `Matcher#match` takes a `Search` so a
     caller can read its memo afterwards. A state with `depends_on`
     also keys on captures, so those stay in a Hash. Measured apart
     from the search (16 KB, 40 rows, every position asked twice):

     | Memo | Memory | Time |
     |---|---|---|
     | Hash | 33.6 MB | 123 ms |
     | Array of `true` for each row | 5.1 MB | 74 ms |
     | a byte for each position (built) | 0.64 MB | 87 ms |
     | a bit for each position | 0.08 MB | 138 ms |

     The Array reads best, but saves nothing where a state is tried
     at a few positions in each stretch: 3.9 MB against the Hash's
     4.2 MB for `{;a*}{;b*}{;c}!`, where the bytes take 0.43 MB. The
     bits were built first and replaced: they need shifts and masks,
     and are the slowest. If memory matters more later, they're a
     change inside `Memo` alone.
   - *A `CaptureList` was made for every capture state reached*
     (16,000 to 32,000 a match in the shapes above). The captures are
     now one array of slots in `Search`, and a capture is undone, not
     copied: setting a slot first adds an entry under the attempts
     that follow, which puts the old value back when the search comes
     down to it (`Search#run`). Only `Search` numbers the slots; the
     states name a group (`start_capture`, `end_capture`, `leave_out`,
     `start_of`, `span`). A search that fails leaves every slot nil,
     which a spec checks.
   - *What it costs.* The search alone (`Matcher#match`) is about 5 to
     10% slower than before this item on typical URIs, measured best
     of seven on a noisy machine (simple 6.9 to 7.6 µs, API 23.1 to
     25.6 µs). The search is about a quarter of a match, so the
     profile's match ratios don't show it. Accepted for the memory
     (2026-11-20), and not tracked down; the memo alone is faster than
     the Hash was.
   - `FollowedBy` also stopped making a String each time it looks
     (28,000 of them in one match).
   - *Already covered:* states as flat records (the stack's two
     entries for an attempt, no `Attempt` objects), character classes as one run
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

   *Built (2026-11-20):* a run skips to where the text after it
   occurs (`State#leading_text`) through a `Jump`, a `LeaveOutIfEmpty`
   whose two ways on start with the same text, and a `FollowedBy` with
   one text. Before, only a literal right after the run, or after a
   `Capture`, counted, so a value with no leader before a literal it
   could hold stepped through every character (`{a}.json`), as did the
   first pass of rule 3 (`/{name}{.ext}`). The search alone, best of
   seven:

   | Template | URI | Before | After |
   |---|---|---|---|
   | `…/articles/{id}.json` | 62 bytes | 17.3 µs | 6.1 µs |
   | `/{name}{.ext}` | 30 bytes | 19.6 µs | 9.9 µs |
   | `/{year}/{month}/{day}/{title}.html` | 39 bytes | 22.2 µs | 13.0 µs |

   The profile's own cases don't have these shapes, and are
   unchanged. Results are the same for every template that writes
   each name once (43,202 generated pairs). With a repeated name,
   which splits the search reaches depends on what it has already
   tried (item 2), so 40 of those results moved, and 65 more of item
   2's expansions match (7,711 to 7,776).

   Still stepping a character at a time: the second pass of rule 3,
   and a value before a `#` leader that may be written `%23`.
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
    its quirks, until item 16: an unexploded `;`, `?` or `&` value goes
    under the name its text has, cut at the next `=`.
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
