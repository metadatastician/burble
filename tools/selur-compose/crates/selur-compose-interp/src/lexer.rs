//! Lexer for the interpolation template grammar.
//!
//! Turns a raw string into a sequence of [`Token`]s.  The lexer is a simple
//! byte-at-a-time state machine — no regex, no allocations until tokens are
//! collected.

/// A single lexed token from the template string.
#[derive(Debug, Clone, PartialEq)]
pub enum Token<'a> {
    /// A run of literal characters (no `$` inside).
    Literal(&'a str),
    /// `$$` — represents a literal `$`.
    Escape,
    /// `${name}` — plain variable reference.
    VarPlain {
        name: &'a str,
        /// Byte offset of the opening `$` in the source.
        offset: usize,
    },
    /// `${name:-default}` or `${name-default}` — default-value modifier.
    VarDefault {
        name: &'a str,
        default: &'a str,
        /// If `true`, the default applies when the variable is unset **or**
        /// empty (`:-`).  If `false`, only when unset (`-`).
        colon: bool,
        offset: usize,
    },
    /// `${name:?msg}` or `${name?msg}` — required-value modifier.
    VarRequired {
        name: &'a str,
        msg: &'a str,
        /// If `true`, the error fires when the variable is unset **or** empty.
        colon: bool,
        offset: usize,
    },
}

/// Lex `input` into a sequence of tokens.
///
/// Returns an `Err` when a `${` is opened but never closed with `}`, or when
/// the content inside `${…}` does not match the grammar (e.g. empty name,
/// invalid name character).
///
/// A bare `$` not followed by `{` is emitted as part of the surrounding
/// [`Token::Literal`] — it is **not** expanded.
pub fn lex(input: &str) -> Result<Vec<Token<'_>>, (usize, String)> {
    let bytes = input.as_bytes();
    let mut tokens: Vec<Token<'_>> = Vec::new();
    let mut i = 0usize;
    let mut lit_start = 0usize;

    macro_rules! flush_literal {
        ($end:expr) => {
            if lit_start < $end {
                tokens.push(Token::Literal(&input[lit_start..$end]));
            }
        };
    }

    while i < bytes.len() {
        if bytes[i] != b'$' {
            i += 1;
            continue;
        }

        // We are at a `$`.
        let dollar_pos = i;

        if i + 1 >= bytes.len() {
            // Trailing bare `$` — treat as literal.
            i += 1;
            continue;
        }

        match bytes[i + 1] {
            b'$' => {
                // `$$` escape.
                flush_literal!(dollar_pos);
                tokens.push(Token::Escape);
                i += 2;
                lit_start = i;
            }
            b'{' => {
                // Start of `${…}`.
                flush_literal!(dollar_pos);
                let brace_start = i + 2; // byte after `{`

                // Find the matching `}`.
                let Some(rel) = memchr_byte(b'}', &bytes[brace_start..]) else {
                    return Err((dollar_pos, format!("unterminated `${{` at byte {dollar_pos} in `{input}`")));
                };
                let brace_end = brace_start + rel; // index of `}`

                let inner = &input[brace_start..brace_end];

                // Parse `inner` = name + optional modifier.
                let token = parse_expansion(inner, dollar_pos)
                    .map_err(|msg| (dollar_pos, msg))?;

                tokens.push(token);
                i = brace_end + 1; // skip past `}`
                lit_start = i;
            }
            _ => {
                // Bare `$X` — not a brace expansion; leave as literal.
                i += 1;
            }
        }
    }

    // Flush any trailing literal.
    flush_literal!(bytes.len());

    Ok(tokens)
}

/// Find the first occurrence of `needle` in `haystack`, returning the index.
fn memchr_byte(needle: u8, haystack: &[u8]) -> Option<usize> {
    haystack.iter().position(|&b| b == needle)
}

/// Parse the content inside `${…}` (i.e. `inner` does not include the braces).
fn parse_expansion(inner: &str, offset: usize) -> Result<Token<'_>, String> {
    if inner.is_empty() {
        return Err(format!("`${{}}` — empty variable name at byte {offset}"));
    }

    // Scan for modifier characters `:-`, `-`, `:?`, `?`.
    // We scan byte-by-byte to keep things simple.
    let bytes = inner.as_bytes();

    // Determine the end of the name.
    // Valid name chars: [A-Za-z_][A-Za-z0-9_]*
    let name_end = bytes
        .iter()
        .position(|&b| !is_name_char(b))
        .unwrap_or(bytes.len());

    if name_end == 0 {
        return Err(format!(
            "invalid variable name in `${{{inner}}}` at byte {offset}: \
             names must start with [A-Za-z_]"
        ));
    }

    let name = &inner[..name_end];
    let rest = &inner[name_end..];

    if rest.is_empty() {
        return Ok(Token::VarPlain { name, offset });
    }

    // Modifier parsing.
    match rest.as_bytes() {
        [b':', b'-', ..] => {
            let default = &rest[2..];
            Ok(Token::VarDefault { name, default, colon: true, offset })
        }
        [b'-', ..] => {
            let default = &rest[1..];
            Ok(Token::VarDefault { name, default, colon: false, offset })
        }
        [b':', b'?', ..] => {
            let msg = &rest[2..];
            Ok(Token::VarRequired { name, msg, colon: true, offset })
        }
        [b'?', ..] => {
            let msg = &rest[1..];
            Ok(Token::VarRequired { name, msg, colon: false, offset })
        }
        _ => Err(format!(
            "unrecognised modifier `{rest}` in `${{{inner}}}` at byte {offset}"
        )),
    }
}

/// Returns `true` for characters that can appear in a variable name.
#[inline]
fn is_name_char(b: u8) -> bool {
    b.is_ascii_alphanumeric() || b == b'_'
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

#[cfg(test)]
mod tests {
    use super::*;

    fn lit(s: &str) -> Token<'_> {
        Token::Literal(s)
    }

    #[test]
    fn plain_literal() {
        assert_eq!(lex("hello world").unwrap(), vec![lit("hello world")]);
    }

    #[test]
    fn empty_string() {
        assert_eq!(lex("").unwrap(), vec![]);
    }

    #[test]
    fn escape_double_dollar() {
        let tokens = lex("$$").unwrap();
        assert_eq!(tokens, vec![Token::Escape]);
    }

    #[test]
    fn escape_in_context() {
        let tokens = lex("cost $$5").unwrap();
        assert_eq!(tokens, vec![lit("cost "), Token::Escape, lit("5")]);
    }

    #[test]
    fn plain_var() {
        let tokens = lex("${FOO}").unwrap();
        assert_eq!(tokens, vec![Token::VarPlain { name: "FOO", offset: 0 }]);
    }

    #[test]
    fn var_default_colon() {
        let tokens = lex("${REALM:-burble.local}").unwrap();
        assert_eq!(
            tokens,
            vec![Token::VarDefault {
                name: "REALM",
                default: "burble.local",
                colon: true,
                offset: 0,
            }]
        );
    }

    #[test]
    fn var_default_no_colon() {
        let tokens = lex("${REALM-burble.local}").unwrap();
        assert_eq!(
            tokens,
            vec![Token::VarDefault {
                name: "REALM",
                default: "burble.local",
                colon: false,
                offset: 0,
            }]
        );
    }

    #[test]
    fn var_required_colon() {
        let tokens = lex("${SECRET:?must set SECRET}").unwrap();
        assert_eq!(
            tokens,
            vec![Token::VarRequired {
                name: "SECRET",
                msg: "must set SECRET",
                colon: true,
                offset: 0,
            }]
        );
    }

    #[test]
    fn var_required_no_colon() {
        let tokens = lex("${SECRET?must set SECRET}").unwrap();
        assert_eq!(
            tokens,
            vec![Token::VarRequired {
                name: "SECRET",
                msg: "must set SECRET",
                colon: false,
                offset: 0,
            }]
        );
    }

    #[test]
    fn bare_dollar_not_expanded() {
        // $args has no braces — must come through as a literal `$args`.
        let tokens = lex("exec $args now").unwrap();
        assert_eq!(tokens, vec![lit("exec $args now")]);
    }

    #[test]
    fn trailing_dollar() {
        let tokens = lex("end$").unwrap();
        assert_eq!(tokens, vec![lit("end$")]);
    }

    #[test]
    fn mixed_template() {
        // "turn:${REALM:-burble.local}:3478"
        let tokens = lex("turn:${REALM:-burble.local}:3478").unwrap();
        assert_eq!(
            tokens,
            vec![
                lit("turn:"),
                Token::VarDefault {
                    name: "REALM",
                    default: "burble.local",
                    colon: true,
                    offset: 5,
                },
                lit(":3478"),
            ]
        );
    }

    #[test]
    fn unterminated_brace() {
        let err = lex("${FOO").unwrap_err();
        assert_eq!(err.0, 0);
        assert!(err.1.contains("unterminated"));
    }

    #[test]
    fn empty_name_error() {
        let err = lex("${}").unwrap_err();
        assert!(err.1.contains("empty variable name"));
    }

    #[test]
    fn multiple_expansions() {
        let tokens = lex("${A} and ${B:-default}").unwrap();
        assert_eq!(
            tokens,
            vec![
                Token::VarPlain { name: "A", offset: 0 },
                lit(" and "),
                Token::VarDefault {
                    name: "B",
                    default: "default",
                    colon: true,
                    offset: 9,
                },
            ]
        );
    }

    #[test]
    fn coturn_command_passthrough() {
        // The load-bearing case from burble's selur-compose.toml.
        // None of $args, $TURN_SECRET, $TURN_REALM, $TURN_EXTERNAL_IP have
        // braces → the whole string should lex to a single Literal.
        let cmd = r#"args='--config /etc/coturn/turnserver.conf'; args="$args --static-auth-secret=$TURN_SECRET --realm=$TURN_REALM"; [ -n "$TURN_EXTERNAL_IP" ] && args="$args --external-ip=$TURN_EXTERNAL_IP"; exec turnserver $args"#;
        let tokens = lex(cmd).unwrap();
        assert_eq!(tokens, vec![lit(cmd)]);
    }
}
