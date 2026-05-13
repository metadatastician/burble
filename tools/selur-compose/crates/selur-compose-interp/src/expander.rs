//! Expander — turns a lexed token stream into a `String` given an env lookup.
//!
//! This is a pure function: no I/O, no global state.

use crate::{
    env::EnvMap,
    error::InterpError,
    lexer::{self, Token},
};

/// Expand `input` against `env`.
///
/// - `${VAR}` — value of VAR; error if unset.
/// - `${VAR:-default}` — value or `default` if unset/empty.
/// - `${VAR-default}` — value or `default` if unset; empty-string is kept.
/// - `${VAR:?msg}` — value or `MissingRequired` if unset/empty.
/// - `${VAR?msg}` — value or `MissingRequired` if unset.
/// - `$$` — literal `$`.
/// - bare `$X` — left unchanged (passed through by lexer as Literal).
pub fn expand(input: &str, env: &EnvMap) -> Result<String, InterpError> {
    let tokens = lexer::lex(input).map_err(|(pos, _msg)| InterpError::Unterminated {
        input: input.to_string(),
        pos,
    })?;

    if tokens.is_empty() {
        return Ok(String::new());
    }

    // Fast path: single literal token — avoid any allocation for the common
    // case where a string field has no interpolation at all.
    if tokens.len() == 1 {
        if let Token::Literal(s) = tokens[0] {
            return Ok(s.to_string());
        }
    }

    let mut out = String::with_capacity(input.len());

    for token in &tokens {
        match token {
            Token::Literal(s) => out.push_str(s),

            Token::Escape => out.push('$'),

            Token::VarPlain { name, offset: _ } => {
                match env.get(name) {
                    Some(val) => out.push_str(val),
                    None => {
                        return Err(InterpError::Undefined {
                            name: name.to_string(),
                            input: input.to_string(),
                        });
                    }
                }
            }

            Token::VarDefault { name, default, colon, offset: _ } => {
                let resolved = env.get(name);
                let use_default = match resolved {
                    None => true,
                    Some(v) if *colon && v.is_empty() => true,
                    _ => false,
                };
                if use_default {
                    out.push_str(default);
                } else {
                    out.push_str(resolved.unwrap());
                }
            }

            Token::VarRequired { name, msg, colon, offset } => {
                match env.get(name) {
                    Some(v) if !(*colon && v.is_empty()) => out.push_str(v),
                    _ => {
                        return Err(InterpError::MissingRequired {
                            name: name.to_string(),
                            msg: msg.to_string(),
                            span: (*offset, *offset + name.len() + 3),
                        });
                    }
                }
            }
        }
    }

    Ok(out)
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

#[cfg(test)]
mod tests {
    use super::*;
    use crate::env::EnvMap;

    fn map(pairs: &[(&str, &str)]) -> EnvMap {
        EnvMap::from_iter(pairs.iter().map(|(k, v)| (k.to_string(), v.to_string())))
    }

    fn empty() -> EnvMap {
        EnvMap::default()
    }

    // --- Literal passthrough ---

    #[test]
    fn plain_literal() {
        assert_eq!(expand("hello world", &empty()).unwrap(), "hello world");
    }

    #[test]
    fn empty_string() {
        assert_eq!(expand("", &empty()).unwrap(), "");
    }

    // --- $$ escape ---

    #[test]
    fn dollar_escape() {
        assert_eq!(expand("$$VAR", &empty()).unwrap(), "$VAR");
        assert_eq!(expand("cost: $$5", &empty()).unwrap(), "cost: $5");
    }

    // --- ${VAR} plain ---

    #[test]
    fn plain_var_set() {
        let env = map(&[("FOO", "bar")]);
        assert_eq!(expand("${FOO}", &env).unwrap(), "bar");
    }

    #[test]
    fn plain_var_unset_error() {
        let err = expand("${FOO}", &empty()).unwrap_err();
        assert!(matches!(err, InterpError::Undefined { name, .. } if name == "FOO"));
    }

    // --- ${VAR:-default} ---

    #[test]
    fn default_colon_var_set_nonempty() {
        let env = map(&[("REALM", "example.com")]);
        assert_eq!(expand("${REALM:-burble.local}", &env).unwrap(), "example.com");
    }

    #[test]
    fn default_colon_var_unset() {
        assert_eq!(
            expand("${REALM:-burble.local}", &empty()).unwrap(),
            "burble.local"
        );
    }

    #[test]
    fn default_colon_var_empty_uses_default() {
        // `:-` treats empty the same as unset.
        let env = map(&[("REALM", "")]);
        assert_eq!(expand("${REALM:-burble.local}", &env).unwrap(), "burble.local");
    }

    #[test]
    fn default_empty_string() {
        // ${VAR:-} with no text after `:-` → empty string as default.
        let env = map(&[("X", "")]);
        assert_eq!(expand("${X:-}", &env).unwrap(), "");
    }

    // --- ${VAR-default} (no colon) ---

    #[test]
    fn default_no_colon_var_unset() {
        assert_eq!(expand("${REALM-burble.local}", &empty()).unwrap(), "burble.local");
    }

    #[test]
    fn default_no_colon_var_empty_preserved() {
        // `-` without colon: empty string is kept.
        let env = map(&[("REALM", "")]);
        assert_eq!(expand("${REALM-burble.local}", &env).unwrap(), "");
    }

    // --- ${VAR:?msg} ---

    #[test]
    fn required_colon_var_set_nonempty() {
        let env = map(&[("SECRET", "abc")]);
        assert_eq!(expand("${SECRET:?must set SECRET}", &env).unwrap(), "abc");
    }

    #[test]
    fn required_colon_var_unset_errors() {
        let err = expand("${SECRET:?must set SECRET}", &empty()).unwrap_err();
        assert!(
            matches!(err, InterpError::MissingRequired { ref name, ref msg, .. }
                if name == "SECRET" && msg == "must set SECRET")
        );
    }

    #[test]
    fn required_colon_var_empty_errors() {
        let env = map(&[("SECRET", "")]);
        let err = expand("${SECRET:?must set SECRET}", &env).unwrap_err();
        assert!(matches!(err, InterpError::MissingRequired { .. }));
    }

    // --- ${VAR?msg} (no colon) ---

    #[test]
    fn required_no_colon_var_unset_errors() {
        let err = expand("${SECRET?oops}", &empty()).unwrap_err();
        assert!(matches!(err, InterpError::MissingRequired { ref name, .. } if name == "SECRET"));
    }

    #[test]
    fn required_no_colon_var_empty_ok() {
        // `?` without colon: empty string is allowed.
        let env = map(&[("SECRET", "")]);
        assert_eq!(expand("${SECRET?oops}", &env).unwrap(), "");
    }

    // --- Mixed templates ---

    #[test]
    fn turn_url_expansion() {
        let env = map(&[("TURN_REALM", "example.com")]);
        assert_eq!(
            expand("turn:${TURN_REALM:-burble.local}:3478", &env).unwrap(),
            "turn:example.com:3478"
        );
    }

    #[test]
    fn turn_url_default_realm() {
        assert_eq!(
            expand("turn:${TURN_REALM:-burble.local}:3478", &empty()).unwrap(),
            "turn:burble.local:3478"
        );
    }

    #[test]
    fn external_ip_empty_default() {
        // ${TURN_EXTERNAL_IP:-} → empty when TURN_EXTERNAL_IP is unset.
        assert_eq!(expand("${TURN_EXTERNAL_IP:-}", &empty()).unwrap(), "");
    }

    // --- Bare $VAR passthrough (the coturn case) ---

    #[test]
    fn bare_dollar_passthrough() {
        // $args has no braces → interpolator must leave it verbatim.
        let cmd = r#"args="$args --secret=$TURN_SECRET"; exec turnserver $args"#;
        assert_eq!(expand(cmd, &empty()).unwrap(), cmd);
    }

    #[test]
    fn coturn_command_passthrough() {
        let cmd = r#"args='--config /etc/coturn/turnserver.conf'; args="$args --static-auth-secret=$TURN_SECRET --realm=$TURN_REALM"; [ -n "$TURN_EXTERNAL_IP" ] && args="$args --external-ip=$TURN_EXTERNAL_IP"; exec turnserver $args"#;
        // Even with an empty env map the string must come through unchanged.
        assert_eq!(expand(cmd, &empty()).unwrap(), cmd);
    }

    // --- Unterminated brace ---

    #[test]
    fn unterminated_error() {
        let err = expand("${FOO", &empty()).unwrap_err();
        assert!(matches!(err, InterpError::Unterminated { .. }));
    }
}
