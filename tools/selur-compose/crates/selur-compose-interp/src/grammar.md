# Interpolation Grammar

This document defines the grammar implemented by `lexer.rs` and `expander.rs`.
It is deliberately minimal — we support the subset of POSIX parameter expansion
that docker-compose and podman-compose honour, and nothing else.

## BNF

```
template  ::= fragment*
fragment  ::= literal | escape | expansion
literal   ::= <any character except '$'>+
escape    ::= "$$"
expansion ::= "${" name modifier? "}"
name      ::= [A-Za-z_][A-Za-z0-9_]*
modifier  ::= colon_default
            | plain_default
            | colon_required
            | plain_required
colon_default  ::= ":-" value_text
plain_default  ::= "-"  value_text
colon_required ::= ":?" value_text
plain_required ::= "?"  value_text
value_text ::= <any character except '}'>*
```

## Semantics

| Syntax              | Expansion rule |
|---------------------|----------------|
| `${VAR}`            | Value of VAR. If VAR is unset → `InterpError::Undefined`. |
| `${VAR:-default}`   | Value of VAR if set **and non-empty**; otherwise `default`. |
| `${VAR-default}`    | Value of VAR if set (even if empty); otherwise `default`. |
| `${VAR:?msg}`       | Value of VAR if set and non-empty; otherwise `InterpError::MissingRequired { name, msg }`. |
| `${VAR?msg}`        | Value of VAR if set; otherwise `InterpError::MissingRequired { name, msg }`. |
| `$$`                | A literal `$` character. |

## Bare `$` policy

A bare `$` that is **not** followed by `{` is left unchanged.  This is the
key design decision that makes the coturn `command` string safe:

```
args='--config /etc/coturn/turnserver.conf'; args="$args --static-auth-secret=…"
```

The `$args`, `$TURN_SECRET`, `$TURN_REALM`, and `$TURN_EXTERNAL_IP` literals
all lack `{…}` braces, so the interpolator treats the `$` as a plain character
and the entire shell fragment is emitted verbatim.  The shell (invoked via
`entrypoint = ["/bin/sh", "-c"]`) then performs its own expansion at runtime.

This is intentional: selur-compose interpolates only `${…}` form variables
(compose-level configuration), while leaving unbraced `$var` intact for the
container's shell to expand at runtime.

## Error positions

The `span` on `InterpError::MissingRequired` is a byte-offset range
`(start, end)` into the original input string, pointing at the opening `$`.
This is reserved for future `miette` integration (v0.2).

## Non-recursive

The `value_text` inside a modifier is treated as a literal — it is **not**
recursively expanded.  `${VAR:-${OTHER}}` is not valid in our grammar.
