There's a class of data in many applications that's sensitive and/or secret, but must still be
accessible in plain-text for the application to work. The space is unbounded so a few examples
help:

* In a server application:
  * Users' password hashes
  * External system credentials (e.g. your database auth certificate or log/metrics sink tokens)
  * The last four digits of a user's credit card
* In a client application:
  * A user's auth token after logging in
  * Any personally-identifying information from a user (e.g. their billing address)
* In an offline-only CLI:
  * The passphrase used to decrypt a password manager's vault
  * A user's SSH key passphrase

In any scenario, this information is required for the application to function. Clearly, users can't
log in if we make password hashes unreadable on the server. They can't perform any actions after
logging in if we make auth tokens unreadable on the client. And we can't decrypt the user's password
store without accepting their passphrase.

The trouble comes in with the handling of these values. It's incredibly easy to include one in a
log line that gets shipped off to a separate machine, where it's indexed, replicated, and archived.
Whether that machine is in your control or not is irrelevant: you've just leaked sensitive data.

Just how easy that is depends on the languages and frameworks involved, but `printf` debugging
remains relevant because it's so dang effective. And sometimes you just need to log values in
production to see why a bug doesn't reproduce in a pre-prod environment.

Aside: this isn't limited to logging! Serializing objects for server response, producing crash
reports (even if they're not sent anywhere), making requests to external systems, and even writing
internal state files can all lead to this kind of exposure.

For a contrived example, consider a user session object in TypeScript:

```typescript
interface UserSession {
	username: string,
	pwHash: string,
	mtime: Date,
}
```

At any time, you're one `JSON.stringify()` or `console.dir()` away from including a user's password
hash in your logs, writing it to a file, or returning it in a server response.

Type systems as they exist today are unable to prevent this kind of bug. A `string` containing
a user's name is indistinguishable from the `string` containing their salted+hashed password. While
some tools and techniques exist to mitigate these issues, they're at best difficult to set up and at
worst (and most commonly) not attempted at all.

Languages have recently taken to adding compile-time guarantees for concurrency-related bugs. Like
the awareness baked into Rust and Swift (among others), I'd argue there's significant benefits to be
realized if type systems were aware of process boundaries and could prevent values from being
exfiltrated from processes.

# Why is this Needed at all?
First, a brief detour for justification. The "Internet commenter"-obvious solution is to tell
developers to just not do these kinds of things. Don't log structures that contain sensitive values;
don't log values you don't fully understand; don't rely on `printf` debugging; don't deploy code
without reading through responses.

And they're right! Those are _of course_ valid solutions. That same advice applies to other forms of
safety that we as developers have come to rely on:

* Without being able to test before deploying, we remind each other "Just don't forget to test
  manually"
* Without access modifiers, we warn "Just don't read/write values prefixed with `_`"
* Without strongly-typed languages, we tell ourselves "Just don't access properties without making
  type assertions"
* Without linters, we try to remember to "Just close that file descriptor before returning"
* Without ownership guarantees, we say "Just don't modify that pointer if you don't control it"

At some point in time, developers have agreed that a subset of these "Just don't (…)" techniques
weren't enough. We wrote tools to protect our users from our own forgetfulness and made those tools
available by default in many cases. We've been able to spend our newfound attention on more
complicated problems as a result.

Protecting sensitive values --- both "our" values and our users' data --- is due for this kind of
tooling.

# Existing Techniques
This is by no means an unsolvable problem using current techniques, but each of those have at least
one significant drawback.

## Access Modifiers / Design Around It
By far the most common approach is to structure an application such that it's harder to accidentally
leak this kind of information. Access modifiers can allow only the database module to access
database credentials and DB session info. This, naturally, limits the space for accidental
disclosures of those credentials to the database module as well. Wrong code certainly looks
"more wrong" during review, but a revision that logs credentials still builds, still passes test
cases, etc.

## Custom Serialization
A similar option is to control how structures are serialized. Go's `MarshalJSON` function can be
implemented for any struct that's serialized with `encoding/json`, allowing developers to exclude
fields that shouldn't be logged. Ditto adding `toJSON()` for a JavaScript class, implementing the
`ToString` and `Debug` traits in Rust, etc. Logger-specific functions, like `MarshalZerologObject`
from Go's `github.com/rs/zerolog`, allow fields to be excluded with specific logging libraries as
well. These unfortunately must be implemented manually for each type containing sensitive data, and
have no influence over non-logging contexts.

Combined, implementing `MarshalJSON` and `MarshalZerologObject` (or their equivalents in other
languages) cover most cases. Go's `fmt.Sprintf("%v")` remains vulnerable however, and the resulting
string can be freely logged, written to files, combined with other values, etc. Developers must
manually know not to call that. We've shrunk the vulnerable surface, but it's still possible to leak
data.

## Domain Types & Custom Wrappers
Following access modifiers and custom serialization is the approach of building domain-specific
types. In our `UserLogin` example above, we'd replace `pwHash: string` with `pwHash: PasswordHash`
--- that is, we'd use a type that wraps a `string` serializes to a static string (or nothing):

```typescript
class PasswordHash {
  private readonly hash: string;
  constructor(hash: string) {
    this.hash = hash;
  }

  toJSON(): string {
    return "[redacted]";
  }
}
```

This combines both the benefits and limitations of its source techniques though, so it's vulnerable
to the same issues.

## Haskell's `IO` Monad
Having read about Haskell's `IO` Monad for the first time just a few days ago, I'm quite clearly an
expert when it comes to its limitations. As such an monadic sage --- with _minutes_ of research and
zero experience --- I can confidently say:

> The `IO` Monad appears to be solving a different yet slightly related problem and probably wouldn't
> make an impact. I think.

An `IO String` in Haskell is needed to solve compile-time and lazy-evaluation constraints with
externally-provided bits of text, but doesn't limit what actions can be taken with such a value once
it's been obtained. `IO String`s can still be printed, logged, sent in network requests, etc.

There may be another related technique from Haskell and its relatives, but I haven't found it yet.
Do let me know if you find one :)

## Linting via Taint Tracking
[Taint tracking](https://en.wikipedia.org/wiki/Taint_checking) is not a new concept in programming
and often comes up when I ask folks about this topic. Bugs for Perl's
[perlsec](https://perldoc.perl.org/perlsec) pod date back to
[at least September 2000](https://rt-archive.perl.org/perl5/Ticket/Display.html?id=4240), and Ruby
had a taint-tracking mechanism [until version 2.7](https://bugs.ruby-lang.org/issues/16131). This
seems to be the closest I've found to process-aware types, but it's unfortunately not flexible
enough for our "don't log sensitive values" use-case.

Taint tracking tools --- whether provided by default in a language or in external
libraries/binaries --- are all security-focused. They deal in the domain of trusted and untrusted
values, and strive to prevent the use of externally-provided values in privileged ways. Attacks like
SQL Injection, poison-pilled requests, and missing input validation are all well within-scope for a
taint tracker. None of the available tools prevent the exposure of values before or after
sanitization, possibly because printing or writing to files are considered low-risk. In fact many
values we'd like to avoid exposing have known and trusted sources. For example, hashed passwords in
our databases or customer fraud risk scores are inherently trustworthy but should absolutely not be
logged anywhere. Taint tracking as it exists today is largely unable to help. Where they're flexible
enough to be helpful (e.g. Semgrep's
[pattern-based taint tracking](https://semgrep.dev/docs/writing-rules/data-flow/taint-mode/#sinks)),
they tend to be complicated to set up, easy to ignore (due to being run in a separate build pass),
or difficult to tune as desired.

# Proposed: The `inproc` and `xproc` Keywords
On a POSIX system, there's surprisingly few ways to leak data outside the bounds of a process:

1. Write to a file descriptor (unix domain socket, a named pipe, a raw file, `stdout`/`stderr`, etc.)
2. Write to a network socket (e.g. the result of `connect`)
3. Write to a memory-mapped file descriptor (via `mmap`; overlaps with 1, but looks like raw memory manipulation)
4. Write to a shared memory region (via `shmat` or similar)

At any higher level beyond C(ish), developers typically see:

1. Mechanisms for writing to output streams
2. Wrappers around that mechanism

Go has `io.Writer`, `node` has `fs.WriteStream` and `net.Stream`, etc. but that covers almost
everything.

What if we could limit TypeScript's `console.log()` to only values we know _at compile time_ are
safe to write out to the JS console? How would we approach `JSON.stringify`, given that it produces
new values based on existing ones?

Let's consider a pair of new keywords, `inproc` and `xproc`, and feel out the impacts they'd have.
From this point forward, we'll focus on TypeScript. There isn't anything particularly special about
it that warrants choosing it over other languages, but it's helpful to have something concrete to
ground the discussion.

## `inproc` and `xproc`
The proposed `inproc` and `xproc` keywords are unary prefix operators, similar to the `unique`
keyword. While `unique` only applies to the `symbol` type (i.e. `unique string` is invalid, but
`unique symbol` is valid), `inproc` and `xproc` can precede any type expression. Additionally,
we'll define two new mapped type helpers `InProc<T>` and `XProc<T>`. They operate exactly like the
existing `Readonly<T>`, and mark all fields in type `T` as either `inproc` or `xproc`.

## Assignability
The type checker is updated such that `inproc T` is not assignable to `xproc T`. This is the core
that prevents data leaks. `xproc T` is assignable to `inproc T` however, as it's always possible to
upgrade a cross-process value to an in-process-only value. For backwards compatibility, `xproc T`
is assignable to `T` (and vice-versa). `inproc T[]` is
parsed as `(inproc T)[]` - that is, there's no such thing as an `inproc` array - just an array of
`inproc` elements.

Signatures that cause external writes accept `xproc T`, e.g. `console.log(...data: xproc any[])`.
This prevents directly passing an `inproc` value:

```ts
// Assignment allowed because `string` is assignable to `inproc string`.
const DB_PASSWORD: inproc string = process.env.DB_PASSWORD;
console.log("The database password is:", DB_PASSWORD);
//                                       ~~~~~~~~~~~
// Compile-time error: Argument of type 'inproc string' is not assignable to parameter of type 'xproc string'
```

## Expression Results
This highlights another major change necessary in the type-checker: expressions that produce values
must propagate the `inproc`ness of a value. For example:

```ts
const DB_USER = "app";
const DB_PASSWORD: inproc string = process.env.DB_PASSWORD;
const DB_AUTH = DB_USER + ":" + DB_PASSWORD;
//              ~~~~~~~ ~ ~~~ string + string => string
//              ~~~~~~~~~~~~~ ~ ~~~~~~~~~~~ string + inproc string => inproc string

// alternatively...
const DB_AUTH = `${DB_USER}:${DB_PASSWORD}`;
//              A template literal that include an `inproc string` must produce
//              `inproc string`
```

At runtime, there are no operational changes here: strings still combine to strings, and the
JavaScript engine needs no knowledge of the `inproc` modifier or its rules. This by extension means
no JS emit changes are required to support expression result type changes.

## Downgrading
Which brings us to the last change required in TypeScript: downcasting and code emission. There
needs to be some way to downcast an `inproc T` to `xproc T` or `T`, to that `DB_AUTH` value (of type
`inproc string`) to actually be used by a library that accepts `string`. Three options exist:

1. A global function `revealInprocValue` is implemented, i.e.:
  ```ts
  function revealInprocValue<T>(val: inproc T) T {
    return (val as any) as T;
  }

  const AUTH_TOKEN: inproc string = process.env.AUTH_TOKEN;
  console.log("Current auth token:", revealInprocValue(AUTH_TOKEN));
  ```

  This incurs a small performance loss, though most optimizers should be able to skip the call to
  `revealInprocValue`. Readability suffers --- having to write `revealInprocValue` (or whatever it
  ends up being called) is cumbersome and obscures critical behavior.
2. A global function `revealInprocValue` is declared but not implemented, and calls to it are
   excluded from code emission to avoid runtime performance issues:

  ```ts
  declare function revealInprocValue<T>(val: inproc T) T;

  const AUTH_TOKEN: inproc string = process.env.AUTH_TOKEN;
  console.log(revealInprocValue(AUTH_TOKEN));

  // Generated JS:
  const AUTH_TOKEN = process.env.AUTH_TOKEN;
  console.log("Current auth token:", AUTH_TOKEN);
  ```

  This has the same readability issues as (1) above, but without the performance impact. It does
  adds quite a bit of "magic" to the TypeScript compiler, in that entire function calls get removed,
  magic names are included, etc. While JSX _adds_ calls to `React.createObject` (or similar,
  depending on your `jsxFactory` setting in `tsconfig.json`), it's a separate file extension and has
  a 1:1 translation with JSX elements. Silently removing function calls from emitted TypeScript is a
  bad idea.
3. A magic comment allows a downgrade from `inproc T` to `xproc T` on the next line, similar to how
   the `@ts-expect-error` and `@ts-ignore` comment directive can be used to [granularly ignore known
   issues](https://www.typescriptlang.org/docs/handbook/release-notes/typescript-3-9.html#-ts-expect-error-comments):

  ```ts
  const AUTH_TOKEN: inproc string = process.env.AUTH_TOKEN;
  // @ts-expose-inproc -- Debugging unauthenticated requests (ISSUE-1234)
  console.log("Current auth token:", AUTH_TOKEN);
  ```

  The name `@ts-expose-inproc` could probably use some work, but this seems to be the best option.
  No magic is added to the TypeScript emit path, no extra function calls are required, and this
  matches behavior already present in the TypeScript compiler (via `@ts-expect-error` comments).

  An initial implementation may use `@ts-expect-error` of course. Narrowing the scope to
  `inproc` exposures means that fewer additional compile-time errors can sneak in on that line, and
  that developers must be explicit about when they plan to expose in-process values.

A magic comment appears to be the most idiomatic option, for better or worse.

## `JSON.stringify`
This, surprisingly, may be the hardest call to solve. `JSON.parse` can keep its existing signature:

```ts
function parse(text: string, reviver?: ((this: any, key: string, value: any) => any) | undefined): any;
```

but `JSON.stringify` --- the inverse --- must be aware of the `inproc`ness of its argument and all
fields of that argument recursively, e.g.:

```ts
// Current signature.
function stringify(value: any, replacer?: (this: any, key: string, value: any) => any, space?: string | number): string;
// New, additional signature.
function stringify(value: inproc any, replacer?: (this: any, key: string, value: inproc any) => inproc any, space?: string | number): inproc string;
```

This may also require changes to how TypeScript reduces type overloads, such that `inproc any`
doesn't reduce to `any` (which is the current behavior).

## Lib Changes
Most of the remaining changes are "draw the rest of the owl": a bunch of modifications to `lib.d.ts`
and every other one to accept `xproc T` in place of `T` in `console.log`, `fs.WriteStream`, even
in the global `Headers` type (accidentally sending sensitive data in a header map is still an
exposure, after all).

## Optional: A Compiler Option
All of these changes are quite invasive, so it's likely worth hiding these behind a compiler option
`--strictProcessBoundaries` or similar. When that flag isn't specified (or its value in
`tsconfig.json` is `false`), the `inproc` and `xproc` keywords are ignored and type-checker behavior
falls back to the existing logic.

# In Use
When applied to actual (not contrived) code, the `inproc` keyword becomes a critical safety
mechanism to prevent accidental exposure.

```ts

```
