---
title: I Want Process-Aware Types
header-includes: |
  <style>
  p, aside {
    text-align: justify;
  }
  .right {
    display: flex;
    flex-direction: column;
  }
  aside {
    align-self: flex-end;
    max-width: 65%;
    background-color: #eeeeee;
    margin-block: 0.5rem;
    margin-left: auto;
    margin-right: -1.25rem;
    padding-inline: 0.75rem 1.25rem;
    padding-block: 0.5rem;
    border-left: double black medium;
  }
  aside p:first-of-type {
    margin-top: 0;
  }
  </style>
...

# tl;dr
I've always wanted a type system that would keep me from exposing sensitive data with minimal developer effort, so I took a crack at designing it for Go.
It requires two new container types (`inproc[T]` and `xproc[T]`) and a global function that are all removed at compile-time, but results in a nearly zero-cost data privacy setup.
Besides reflection-based checks, no runtime changes are required.

This is somewhere between a thought experiment and a proper proposal for inclusion in a language.
It's certainly not ready for an RFC anywhere, but there's perhaps a kernel of value here.

<div class="right">
  <aside>
  This was written in bursts between January and September 2024 before it was finally published.
  It's not as polished as I'd like, but I'd rather publish something a bit messy than never publish.
  </aside>
</div>

# Background
There's a class of data in many applications that's sensitive and/or secret, but must still be accessible in plain-text for the application to work.
The space is unbounded so a few examples help:

* In a server application:
  * Users' password hashes
  * External system credentials (e.g. your database auth certificate or log/metrics sink tokens)
  * The last four digits of a user's credit card
  * A user's mailing address (as in an e-commerce environment)
* In a client application:
  * A user's auth token after logging in
  * Any personally-identifying information from a user (e.g. their billing address)
* In an offline-only CLI:
  * The passphrase used to decrypt a password manager's vault
  * A user's SSH key passphrase

In any scenario, this information is required for the application to function.
Clearly, users can't log in if we make password hashes unreadable on the server, and we can't display a user's shipping address if their addresses aren't readable.
Users can't perform any actions after logging in if we make auth tokens unreadable on the client.
And we can't decrypt the user's password store without accepting their passphrase.

The trouble comes in with the handling of these values.
It's incredibly easy to include one in a log line that gets shipped off to a separate machine, where it's indexed, replicated, and archived.
Whether that machine is in your control or not is irrelevant: sensitive data has just leaked.

<div class="right">
<aside>
This isn't limited to logging!
Serializing objects for server response, producing crash reports, making requests to external systems, and even writing internal state files can all lead to this kind of exposure.
</aside>
</div>

Just how easy that is depends on the languages and frameworks involved, but `printf` debugging
remains relevant because it's so dang effective.
And sometimes you just need to log values in production to see why a bug doesn't reproduce in a pre-prod environment.

<aside>
We'll be talking about a lot of languages here, all of which have their own names for similar concepts.
Structs in C and Go are roughly equivalent to Java classes, for example.
Unless otherwise noted, I'll be using Go's names as a middle-ground.
</aside>

For a contrived example, consider a user session object in Go:

```go
type UserSession struct {
  Username string
  pwHash string
  expires time.Time
}
```

By default, you're one `fmt.(Sp|P)rintf("%v\n", session)` away from including a user's password hash in your logs, writing it to a file, or returning it in a server response.

Type systems as they exist today are unable to prevent this kind of bug.
A `string` containing a user's name is indistinguishable from the `string` containing their salted+hashed password at compile-time.
While some tools and techniques exist to mitigate these issues, they're at-best difficult to set up and at-worst (and most commonly) not attempted at all.

Languages have recently taken to adding compile-time guarantees for concurrency-related bugs.
Like the concurrency-awareness baked into Rust and Swift (among others), I'd argue there's significant benefits to be realized if type systems were aware of process boundaries and could prevent values from being exfiltrated from processes.

# Why is this needed at all?
<div class="right">
<aside>
If you're already sold, feel free to skip ahead to [the proposal](#proposed-the-inproc-and-xproc-type-modifiers).
</aside>
</div>

First, a brief detour for justification.

The "Internet commenter"-obvious solution is to tell developers to just… not do these kinds of things.
Don't log structures that contain sensitive values; don't log values you don't fully understand; don't rely on `printf` debugging; don't deploy code without reading through responses.

And they're right!
Those are _of course_ valid solutions.
That same advice applies to other forms of safety that we as developers have come to rely on:

* Without being able to test before deploying, we remind each other "Just don't forget to test manually"
* Without access modifiers, we warn "Just don't read/write values prefixed with `_`"
* Without strongly-typed languages, we tell ourselves "Just don't access properties without making type assertions"
* Without linters, we try to remember to "Just close that file descriptor before returning"
* Without ownership guarantees, we say "Just don't modify that pointer if you don't control it"

At some point in time, developers have agreed that a subset of these "Just don't (…)" techniques weren't enough.
We wrote tools to protect our users from our own forgetfulness and made those tools available by default in many cases.
We've been able to spend our newfound attention on more complicated problems as a result.

Protecting sensitive values --- both "our" values and our users' data --- is due for this kind of
tooling.

# Existing Techniques
<div class="right">
<aside>
If you're already sold, feel free to skip ahead to [the proposal](#proposed-the-inproc-and-xproc-type-modifiers).
</aside>
</div>

This is by no means an unsolvable problem using current techniques, but each of those have at least
one significant drawback.

I recognize that I'm likely missing some approaches here.
[Please let me know](#contact).

## Access Modifiers / Design Around It
By far the most common approach is to structure an application such that it's harder to accidentally leak this kind of information.
Access modifiers can allow only the database module to access database credentials and DB session info.
This, naturally, limits the space for accidental disclosures of those credentials to the database module as well.
Wrong code certainly looks "more wrong" during review, but a revision that logs credentials still builds, still passes test cases, etc.
This especially breaks down when dealing with credentials passed via environment variable.
Once read via `os.Getenv`{.go}, sensitive environment variables are still just loggable strings.

## Custom Serialization
A similar option is to control how structures are serialized.
Go's `MarshalJSON` function can be implemented for any struct that's serialized with `encoding/json`, allowing developers to exclude fields that shouldn't be logged.
Ditto adding `toJSON()` for a JavaScript class, implementing the `ToString` and `Debug` traits in Rust, etc.
Logger-specific functions, like `MarshalZerologObject` from Go's `github.com/rs/zerolog`, allow fields to be excluded with specific logging libraries as well.
And for more general data-dumping purposes, the `fmt.Formatter` and `fmt.GoStringer` interfaces can interface can be implemented on a struct for additional control.
These unfortunately must be implemented manually for each type containing sensitive data, and they have no influence over non-logging contexts.

Combined, implementing `MarshalJSON`, `MarshalZerologObject`, `Format`, `ToString`, and `GoStringer` (or their equivalents in other languages) cover most cases.
Go's `fmt.Sprintf("%s", some.StructField)` remains vulnerable however, and the resulting string can be freely logged, written to files, combined with other values, etc.
Developers must manually know not to call that.
We've shrunk the vulnerable surface, but it's still possible to leak data.

## Domain Types & Custom Wrappers
Following access modifiers and custom serialization is the approach of building domain-specific types.
In our `UserLogin` example above, we'd replace `pwHash: string` with `pwHash: PasswordHash` --- that is, we'd use a type that wraps a `string` serializes to a static string (or nothing):

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

This combines both the benefits and limitations of its source techniques though, so it's vulnerable to the same issues.

## Haskell's `IO` Monad
Having read about Haskell's `IO` Monad for the first time just a few days ago, I'm quite clearly an expert when it comes to its limitations.
As such an monadic sage --- with _minutes_ of research and zero experience --- I can confidently say:

> The `IO` Monad appears to be solving a different yet mildly related problem and probably wouldn't make an impact.
> I think.
> Probably.

An `IO String` in Haskell is needed to solve compile-time and lazy-evaluation constraints with externally-provided bits of text, but doesn't limit what actions can be taken with such a value once it's been obtained.
`IO String`s can still be printed, logged, sent in network requests, etc.

There may be another related technique from Haskell and its relatives, but I haven't found it yet.
Do let me know if you find one :)

## Linting via Denylist
A naive linter can pretty easily detect calls to `fmt.Print*` (and its wrappers) that reference variables and fields of known name, e.g.:

```go
fmt.Printf("Auth token: %q", sess.AuthToken)
//                           ~~~~~~~~~~~~~~
// Lint error: cannot print field named "AuthToken"
```

This is quite easy to accidentally bypass.
If that auth token is used for Bearer authentication, it's reasonable to prefix it with `"Bearer "` early:

```go
bt := "Bearer " + sess.AuthToken
fmt.Printf("Auth token: %q", bt)
//                           ~~
// No error. "bt" isn't in the denylist, and string concatenation
// hides the presence of sess.AuthToken.
```

Besides the list of names being unbounded and easily gamed, a denylist linter is unlikely to be effective beyond a trivial program.
And once folks are used to relying on it to catch this case, bypassing the denylist becomes trivial.
In other words, a "the linter didn't catch this, it's probably fine" mentality.

## Linting via Taint Tracking
[Taint tracking](https://en.wikipedia.org/wiki/Taint_checking) is not a new concept in programming and often comes up when I ask about this topic.
Bugs for Perl's [perlsec](https://perldoc.perl.org/perlsec) pod date back to [at least September 2000](https://rt-archive.perl.org/perl5/Ticket/Display.html?id=4240), Ruby had a taint-tracking mechanism [until version 2.7](https://bugs.ruby-lang.org/issues/16131), and some Googlers released the experimental (and unfortunately seemingly-defunct) [go-flow-levee](https://github.com/google/go-flow-levee).
This seems to be the closest I've found to process-aware types, but it's unfortunately not flexible enough for our "don't log sensitive values" use-case.

Taint tracking tools --- whether provided by default in a language or in external libraries/binaries --- are all security-focused.
They deal in the domain of trusted and untrusted values, and strive to prevent the use of externally-provided values in privileged ways.
Attacks like SQL Injection, poison-pilled requests, and missing input validation are all well within-scope for a taint tracker.
None of the available tools prevent the exposure of values before or after sanitization, possibly because printing or writing to files are considered low-risk.
In fact many values we'd like to avoid exposing have known and trusted sources.
For example, hashed passwords in our databases or customer fraud risk scores are inherently trustworthy but should absolutely not be logged anywhere.
Taint tracking as it exists today is largely unable to help.
Where they're flexible enough to be helpful (e.g. Semgrep's [pattern-based taint tracking](https://semgrep.dev/docs/writing-rules/data-flow/taint-mode/#sinks)), they tend to be complicated to set up, easy to ignore (due to being run in a separate build pass), or difficult to tune as desired.

# Proposed: the `inproc` and `xproc` type modifiers
On a POSIX system, there's surprisingly few ways to leak data outside the bounds of a process:

1. Write to a file descriptor (unix domain socket, named pipe, raw file, `stdout`/`stderr`, etc.)
2. Write to a network socket (e.g. the result of `connect`)
3. Write to a memory-mapped file descriptor (via `mmap`; overlaps with 1, but looks like raw memory manipulation)
4. Write to a shared memory region (via `shmat` or similar)

At any higher level beyond C(ish), developers typically see:

1. Mechanisms for writing to output streams
2. Wrappers around that mechanism

Go has `io.Writer`, `node` has `fs.WriteStream` and `net.Stream`, etc. that cover almost everything.

What if we could limit Go's `fmt.Printf` to only values we know _at compile time_ are safe to write to `stdout`?
How would we approach `MarshalJSON`, given that it produces new values (a byte slice) based on existing ones?

Let's consider a pair of new type modifiers, `inproc` and `xproc`, and feel out the impacts they'd have.

`inproc[T]`
  ~ A value of type `T` that should not be allowed to cross process boundaries without manual intervention.
  ~ Values with this type should only be used **in-proc**ess.

`xproc[T]`
  ~ A value of type `T` that can cross process boundaries with no additional effort.
  ~ Values with this type are not limited to a single process.

For now, we'll model these as Go generics.
As will become clear below, these don't qualify as proper Go generics and have some special compile-time properties.
The syntax is convenient for demonstration purposes though.

## Variance: `T`, `inproc[T]`, and `xproc[T]`
The proposed `inproc` and `xproc` container types are generic, with no notable additional contraints.
They can be thought of as cost-free containers (costs consisdered below) or simply tagged subtypes of `T`.

They do however have unique variance rules, to ensure an `inproc[T]` can't easily be smuggled out via a regular `T`.
To ensure backwards-compatibility with existing Go code, `T` is equivalent to `xproc[T]`.
I do appreciate the clarity that an explicit `xproc[T]` provides, so it remains in this proposal.

### Binary Expressions
Binary expressions between `T`, `inproc[T]`, and `xproc[T]` should be allowed as a convenience for developers, but the result must preserve the most specific and restrictive of the two types.

Consider the type of `c` for the statement `c := a + b`, given certain types for `a` and `b`:

 | a | b | c |
 | --- | --- | --- |
 | `inproc[T]` | `inproc[T]` | `inproc[T]` |
 | `inproc[T]` | `T` | `inproc[T]` |
 | `inproc[T]` | `xproc[T]` | `inproc[T]` |
 | `xproc[T]`  | `T[T]` | `xproc[T]` |

Similar to [taint tracking](#linting-via-taint-tracking) above, the `inproc` container type "poisons" the result of any binary expression its involved it.
The validity of `inproc[T] + inproc[U]` (that is, the addition of two different types wrapped in `inproc`) is unchanged here.
If they were `+`able before, they still are; if they weren't before, they still aren't.

Since `inproc[T]` is more specific than `xproc[T]`, binary expressions have covariant arguments of type `T`.
The same applies for `xproc[T]` and bare `T`.

### Assignments
Basically the same rules apply to assignments.
For example, `x = y` for various declarations of `x` and types of `y`:

| Declaration | Type of `y` | `x = y` Allowed? |
| --- | --- | --- |
| `var x inproc[T]` | `inproc[T]` | Yes |
| `var x inproc[T]` | `xproc[T]` | Yes |
| `var x inproc[T]` | `T` | Yes |
| `var x xproc[T]` | `inproc[T]` | No - leaks `y` |
| `var x xproc[T]` | `xproc[T]` | Yes |
| `var x xproc[T]` | `T` | Yes |
| `var x T` | `inproc[T]` | No - leaks `y` |
| `var x T` | `xproc[T]` | Yes |
| `var x T` | `T` | Yes |

### Function Arguments
And the same for function arguments.
For various signatures of a function `f` and the types of input parameters passed to it, we get roughly the same table.
For simplicity, the placeholder type `T` is reified to `string` in this example.

| Signature | Type of `b` | `f(b)` Allowed? |
| --- | --- | --- |
| `func f(a inproc[string])` | `inproc[string]` | Yes |
| `func f(a inproc[string])` | `xproc[string]` | Yes |
| `func f(a inproc[string])` | `string` | Yes |
| `func f(a xproc[string])` | `inproc[string]` | No - `f` can leak `b` |
| `func f(a xproc[string])` | `xproc[string]` | Yes |
| `func f(a xproc[string])` | `string` | Yes |
| `func f(a string)` | `inproc[string]` | No - `f` can leak `b` |
| `func f(a string)` | `xproc[string]` | Yes |
| `func f(a string)` | `string` | Yes |

Already, the power of this pattern is beginning to show through.
Function `f` can declare that it _won't_ cause an argument to leak outside the current process.
This is spiritually similar to using an argument of type `const char* a` in C to declare that the `char` array pointed to by `a` won't be modified.

### Returned Values
Likely unsurprising, we see these same rules in a function's return type.
A function that claims it returns `inproc[string]` can `return x` where `x` has the type `xproc[string]`, but not the inverse.
The truth table here is left as an exercise to the reader.

<div class="right">
<aside>
I've always wanted to say that.
</aside>
</div>

### Container Types (Structs)
There's nothing special about structs in this arrangement.
Structs can be marked `inproc` or `xproc` separately from their fields.

### Collection Types (Slices & Maps)
So far, these are all pretty trivial rules.
Where taint tracking tends to get complicated is when collection types are introduced.
Without careful static analysis, a `map[string]string` could be used to "juggle" a sensitive value and erase its taint marker.

Go already rejects slices of heterogeneous types without an interface wrapping them.
It follows then that `[](inproc[string] | xproc[string])` would also be invalid.
To optimize for developer simplicity --- and in the interests of side-stepping a Known Hard Problem --- this restriction should likely be maintained outside of Go.
There's few cases where sensitive and non-sensitive values of the same type should be colocated in a single slice or map.
Cases that do so are already at risk of accidental disclosure, but are unchanged from a backwards-compatibility perspective.

There's one notable restriction applied to the `inproc` and `xproc` containers: **collection types cannot themselves be marked `inproc` or `xproc`**.

#### Why No `inproc`/`xproc` Collections
This seems initially restrictive, but the motivation is minimizing confusion and false-negatives.
There are, in-effect, two ways to handle `inproc[[]T]` and `xproc[[]T]`:

1. The `inproc` modifier _propagates to its children_.
An `inproc` slice implicitly contains `inproc` elements.
For example, `inproc[[]T]` is implicitly `inproc[[]inproc[T]]`.
An explicit `inproc[[]xproc[T]]` (an `inproc` slice of `xproc` elements) would also be valid.

    * Advantages:
      * Less Typing
      * More likely what a developer wants
    * Disadvantages:
      * Controlling visibility separately is very verbose
      * This behavior isn't terribly intuitable

2. The `inproc` modifier _never propagates to its children_.
In this approach, `inproc[[]T]` from the previous example is explicitly an `inproc` slice of bare `T` elements.
This forces developers to read and write `inproc[[]inproc[T]]` to represent an `inproc` slice of `inproc` values.
That's difficult to parse visually, so broken down:

    ```
              inproc[T]   - the element type
            []inproc[T]   - a slice of the element type
    inproc[ []inproc[T] ] - an inproc slice of the element type
    ```

    * Advantages
      * No magic behavior
      * Provides complete control over visibility
    * Disadvantages
      * Awful to read and write
      * Often redundant

In practice, **a collection type itself isn't sensitive**.
The length of a slice is rarely sensitive without also having the contents.
Since `[]inproc[T]` (e.g. `[]inproc[byte]` for a slice of inproc bytes) already covers the contents of such a slice, wrapping the collection provides near-zero value.
Disallowing `inproc` on collections is a bit of an arbitrary decision, but it does serve to simplify things significantly.

<div class="aside">
<aside>
Password logins are a difficult counter-example.
Exposing a password's byte length is still a significant disclosure, and this restriction would allow `len(pw_bytes)` (where `pw_bytes` is of type `[]byte`) to escape the process boundary via logging, etc.

Since Go's slices must have homogeneous types, there's perhaps a workaround possible at the compiler level.
If `len(x)` is called where `x` is a collection of an `inproc` type, perhaps it returns an `inproc[int]`?
</aside>
</div>

## Explicit Conversions
It must still be possible to convert from an `inproc[T]` to an `xproc[T]`.
A generated auth token needs to be shown to users once for it to be useful, and a customer's shipping address must be displayed on invoices.
It's recommended that these both be `inproc[T]` values to prevent accidental logging, but these at some level _do_ need to be serialized and sent over the wire.

Like Go's `len` or `new`, a new global function `larry()` is included here as well.

<div class="aside">
<aside>
I genuinely haven't found a good name for this function yet.
It almost certainly won't be accepted as-is, but it'd be Very Funny if it does.
To avoid bikeshedding over the name for now, I'm calling it "Larry" in honor of my neighborhood cat who recently passed away.

Miss you, buddy. </3
</aside>
</div>

This function returns whatever it's provided. It's a no-op, implemented roughly as:

```go
func larry[V any](sensitive inproc[V]) xproc[V] {
    return any(sensitive)
}
```

This provides the necessary escape-hatch to allow sensitive values to be intentionally exposed for inclusion in user-facing function calls. (Assume `fmt.Printf` has been modified to accept only `xproc[T]` values).

```go
type UserSession struct {
  Username xproc[string]
  pwHash inproc[string]
  expires time.Time
}

// ...
fmt.Printf("Session created: %q/%q", sess.Username, sess.pwHash)
//                                                  ~~~~~~~~~~~
// Compile error: 'inproc[string]' is not assignable to 'xproc[string]'.
// To print this value, use larry().


// Debugging incident 717
fmt.Printf("Session created: %q/%q", sess.Username, larry(sess.pwHash))
//                                                  ~~~~~~~~~~~~~~~~~~
// No compile error.
```

This helps to highlight where sensitive values are intentionally being exposed, and [makes wrong code look wrong](https://www.joelonsoftware.com/2005/05/11/making-wrong-code-look-wrong/).

## Runtime Cost
Remember, `inproc[T]` and `xproc[T]` are not actually generic containers, even though they're typed like generics.
To avoid unnecessary allocations or pointer dereferences, these container types are _erased_ during Go's [IR construction ("noding") phase](https://github.com/golang/go/blob/2bffb8b3fb2d9137ccfa87fc35137371b86a2e96/src/cmd/compile/README.md#3-ir-construction-noding).
This is the first possible point after type checking, and ensures no changes are needed to the Go IR or any emit phases.

Similarly, the `larry` function above also gets completely optimized away at compile-time.

The result is a nearly zero-cost data privacy setup.

## JSON Marshalling
Go's `encoding/json.Marshal` function would need some small modifications to ensure that `inproc[T]` values can be marshalled properly.
The critical behavior change is that `Marshal(v inproc[any])` must produce a slice of inproc bytes (`[]inproc[byte]`), to ensure JSON marshalling can't sneak past these restrictions.

The default implementation of `encoding/json.Marshal` would continue to require reflection.
There is some runtime cost to checking field tags, but this is in-line with the current implementation of `encoding/json`.

Unfortunately, the erasure of `inproc[T]` and `xproc[T]` at compile-time render the `reflect` package unable to determine the `inproc`ness of struct fields automatically.
Struct tags _are_ accessible via the `reflect` package, so this may be solveable via a matching `json` struct tag.
This would require extra work for third-party serializers to integrate, as well a compile-time check guaranteeing that the struct tag and type agree on `inproc`-ness.

<div class="right">
<aside>
I don't have a great solution here.
Suggestions welcome!
</aside>
</div>

# Example Use
By putting this all together into a reasonably realistic(ish) example, we can get a better sense of what it feels like to build something with `inproc` available.

```go
// InvoiceBuilder provides a builder pattern for serialized,
// externally-facing invoices.
type InvoiceBuilder struct {
    // ...
    destAddr string
    memo string
}

// WithDestAddr adds the provided destination address to the invoice.
func (ib *InvoiceBuilder) WithDestAddr(a *Address) *InvoiceBuilder {
    if a == nil {
      return ib
    }
    ib.destAddr = "Ships to:\n" + a.String()
    return ib
}

func (ib *InvoiceBuilder) WithMemo(m string) *InvoiceBuilder {
    if m == nil || m == "" {
        return ib
    }
}

// -----

type AddressBook interface {
    // Lookup retrieves an address from the database by its ID.
    Lookup(id inproc[string]) inproc[Address];
}

type Order struct {
    isPhysical bool
    destAddrId inproc[string]
    customerMemo string
    // The ID of the corresponding transaction in Stripe.
    stripeTxId inproc[string]
}

// GetInvoice builds a plain-text representation of a purchase
// invoice for the provided order, looking up additional order
// metadata as needed.
func GetInvoice(ctx context.Contextx, order *Order) string {
    span := tracing.Span(ctx, "GetInvoice")
        Str("orderID", order.id).
        Str("stripeTxId", larry(order.stripeTxId))
//                        ~~~~~
//      ① Converts inproc[string] to xproc[string], and allows
//      the Stripe transaction ID to be included in a span's
//      metadata. We know it's safe to send to our controlled
//      tracing infrastructure, but it shouldn't ever be sent
//      to users.
    defer span.End()

    ib := new(InvoiceBuilder).
        WithNumber(order.seqNum).
        WithMemo(order.stripeTxId)
//               ~~~~~~~~~~~~~~~~
// ② Compile error: 'inproc[string]' is not assignable to 'string'.
//
// Without inproc support, this would accidentally include the
// Stripe transaction ID instead of the customer's order memo.

    /* ... */

    if (order.isPhysical && order.destAddrId) {
        if dst, err := addrBook.Lookup(destAddrId); err != nil {
            ib.WithDestAddr(larry(dst))
//                          ~~~~~
//          ③ Converts inproc[Address] to xproc[Address], and 
//          allows the destination address to be passed to
//          InvoiceBuilder.WithDestAddr
        }
    }

    return ib.String()
}
```

This is of course a contrived example, but there's three locations worth calling out:

* At ① and ③, we see that it's quite easy to expose sensitive information when desired.
The explicit call to `larry` makes the intention clear, and requires no runtime overhead. 
* At ②, we've been stopped from accidentally misusing an `inproc` value in a cross-process context.
The compile-time error is a lightweight prompt to the author: should that variable be exposed?

# Next Steps
Goodness I sure wish I had a highly-motivating closing section!
To reiterate, this is somewhere between a thought experiment and an actual proposal.

I'd love to hear your thoughts --- consider this a pre-RFC request for comments.
Perhaps I'm over-indexing on the risks, and this just isn't that big of a deal.
Maybe I've overlooked something major that makes this approach a non-starter.
Am I a big dumdum? (Generally, yeah).
Am I a big dumdum _who should have realized this is already built into `$popular_language`_?

## Contact
Feel free to get in touch by:

* Emailing <a href="mailto:inproc@barag.org">inproc@barag.org</a>
* Commenting on Hacker News/lobste.rs/wherever else you may have found this post
* DMing me at <a href="https://hachyderm.io/@sjbarag"/>@sjbarag@hachyderm.io</a>
* Shouting really loud out your window (I might not hear it)
