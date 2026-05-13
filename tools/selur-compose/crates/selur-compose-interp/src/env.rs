//! `EnvMap` — ordered environment variable store and `.env` file loader.
//!
//! ## Lookup order
//!
//! When `interpolate` is called, variables are resolved by searching these
//! sources in priority order (highest first):
//!
//! 1. **Explicit overrides** — passed directly to [`EnvMap::with_overrides`].
//! 2. **Process environment** — captured at startup via [`std::env::vars`].
//! 3. **`--env-file` files** — loaded left-to-right; later files win over
//!    earlier ones for the same key (but both lose to the process env).
//!
//! This matches docker-compose v2 semantics: the process env always wins over
//! file-based values, so you can always override a file-set value by setting
//! the variable in your shell.
//!
//! The internal representation is a `Vec<(String, String)>` of key-value pairs
//! built in order of *decreasing* priority, so the first match in a linear
//! scan is always the highest-priority value.

use std::{
    collections::HashMap,
    path::Path,
};

use crate::error::InterpError;

/// A flat, ordered map of environment variable name → value.
///
/// Constructed via [`EnvMap::from_process`], [`EnvMap::from_env_files`], or
/// [`EnvMap::default`].  Once built it is immutable — all lookups go through
/// [`EnvMap::get`].
#[derive(Debug, Clone, Default)]
pub struct EnvMap {
    /// Ordered storage: earlier entries have higher priority.
    entries: Vec<(String, String)>,
    /// Fast-path index into `entries` (first occurrence = highest priority).
    index: HashMap<String, usize>,
}

impl EnvMap {
    /// Build an `EnvMap` from an iterator of `(key, value)` pairs.
    ///
    /// The first occurrence of any key wins (higher priority).
    pub fn from_iter<I>(iter: I) -> Self
    where
        I: IntoIterator<Item = (String, String)>,
    {
        let mut entries = Vec::new();
        let mut index = HashMap::new();
        for (k, v) in iter {
            if !index.contains_key(&k) {
                index.insert(k.clone(), entries.len());
                entries.push((k, v));
            }
        }
        EnvMap { entries, index }
    }

    /// Capture the current process environment.
    pub fn from_process() -> Self {
        Self::from_iter(std::env::vars())
    }

    /// Look up a variable by name.
    pub fn get(&self, name: &str) -> Option<&str> {
        self.index
            .get(name)
            .map(|&idx| self.entries[idx].1.as_str())
    }

    /// Return a new `EnvMap` with `overrides` layered on top (highest
    /// priority).
    pub fn with_overrides<I>(mut self, overrides: I) -> Self
    where
        I: IntoIterator<Item = (String, String)>,
    {
        // Build overrides first, then append existing entries that aren't
        // shadowed.
        let mut new_entries: Vec<(String, String)> = Vec::new();
        let mut new_index: HashMap<String, usize> = HashMap::new();

        for (k, v) in overrides {
            if !new_index.contains_key(&k) {
                new_index.insert(k.clone(), new_entries.len());
                new_entries.push((k, v));
            }
        }

        for (k, v) in self.entries.drain(..) {
            if !new_index.contains_key(&k) {
                new_index.insert(k.clone(), new_entries.len());
                new_entries.push((k, v));
            }
        }

        EnvMap { entries: new_entries, index: new_index }
    }

    /// Load one or more `.env`-format files and merge them **below** the
    /// current entries (i.e. existing keys win).
    pub fn with_env_files<P>(self, paths: &[P]) -> Result<Self, InterpError>
    where
        P: AsRef<Path>,
    {
        let mut file_pairs: Vec<(String, String)> = Vec::new();
        for path in paths {
            let pairs = load_env_file(path.as_ref())?;
            for (k, v) in pairs {
                // Later files in the list win over earlier ones for the same
                // key.  We insert unconditionally and deduplicate by scanning
                // for existing keys.
                if !file_pairs.iter().any(|(ek, _)| ek == &k) {
                    file_pairs.push((k, v));
                }
            }
        }

        // Existing entries (process env / overrides) win over file values.
        let mut new_entries: Vec<(String, String)> = Vec::new();
        let mut new_index: HashMap<String, usize> = HashMap::new();

        // Existing entries first (highest priority).
        for (k, v) in &self.entries {
            if !new_index.contains_key(k) {
                new_index.insert(k.clone(), new_entries.len());
                new_entries.push((k.clone(), v.clone()));
            }
        }

        // File entries second (lower priority).
        for (k, v) in file_pairs {
            if !new_index.contains_key(&k) {
                new_index.insert(k.clone(), new_entries.len());
                new_entries.push((k, v));
            }
        }

        Ok(EnvMap { entries: new_entries, index: new_index })
    }

    /// Number of entries in the map.
    pub fn len(&self) -> usize {
        self.entries.len()
    }

    /// Returns `true` if the map contains no entries.
    pub fn is_empty(&self) -> bool {
        self.entries.is_empty()
    }
}

// ---------------------------------------------------------------------------
// .env file parser
// ---------------------------------------------------------------------------

/// Parse a `.env`-format file from disk.
///
/// Format rules:
/// - Lines starting with `#` (ignoring leading whitespace) are comments.
/// - Blank lines are ignored.
/// - `KEY=VALUE` — value is everything after the first `=` on the line.
/// - `KEY="VALUE"` / `KEY='VALUE'` — quoted forms; quotes stripped, no escape
///   sequences processed (this is intentional: the values land verbatim in
///   `podman run --env`).
/// - `KEY` with no `=` is silently skipped (not a "pass-through" form; we
///   don't inherit from the process env at load time).
/// - Leading and trailing whitespace around the key is stripped.
/// - Trailing whitespace in an unquoted value is stripped.
pub fn load_env_file(path: &Path) -> Result<Vec<(String, String)>, InterpError> {
    let content = std::fs::read_to_string(path).map_err(|e| InterpError::EnvFile {
        path: path.display().to_string(),
        reason: e.to_string(),
    })?;
    parse_env_str(&content, path)
}

/// Parse `.env` content from a string (testable without touching the FS).
pub fn parse_env_str(content: &str, path: &Path) -> Result<Vec<(String, String)>, InterpError> {
    let mut pairs = Vec::new();

    for (line_no, raw) in content.lines().enumerate() {
        let line = raw.trim();

        // Skip comments and blank lines.
        if line.is_empty() || line.starts_with('#') {
            continue;
        }

        // Find the `=` separator.
        let Some(eq) = line.find('=') else {
            // `KEY` with no `=` — skip silently.
            continue;
        };

        let key = line[..eq].trim().to_string();
        let raw_val = &line[eq + 1..];

        if key.is_empty() {
            return Err(InterpError::EnvFile {
                path: path.display().to_string(),
                reason: format!("line {}: empty key", line_no + 1),
            });
        }

        // Strip optional surrounding quotes.
        let value = strip_quotes(raw_val).to_string();

        pairs.push((key, value));
    }

    Ok(pairs)
}

/// Strip a matching pair of `"…"` or `'…'` from a value string.
///
/// If the string is not properly quoted (no matching open/close quote) it is
/// returned as-is with trailing whitespace removed.
fn strip_quotes(s: &str) -> &str {
    let s = s.trim_end();
    if s.len() >= 2 {
        if (s.starts_with('"') && s.ends_with('"'))
            || (s.starts_with('\'') && s.ends_with('\''))
        {
            return &s[1..s.len() - 1];
        }
    }
    s
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

#[cfg(test)]
mod tests {
    use super::*;
    use std::path::PathBuf;

    fn dummy_path() -> PathBuf {
        PathBuf::from(".env")
    }

    #[test]
    fn basic_key_value() {
        let pairs = parse_env_str("FOO=bar\nBAZ=qux\n", &dummy_path()).unwrap();
        assert_eq!(pairs, vec![("FOO".into(), "bar".into()), ("BAZ".into(), "qux".into())]);
    }

    #[test]
    fn comments_and_blanks_skipped() {
        let content = "# this is a comment\n\nFOO=bar\n";
        let pairs = parse_env_str(content, &dummy_path()).unwrap();
        assert_eq!(pairs, vec![("FOO".into(), "bar".into())]);
    }

    #[test]
    fn double_quoted_value() {
        let pairs = parse_env_str("FOO=\"hello world\"\n", &dummy_path()).unwrap();
        assert_eq!(pairs[0].1, "hello world");
    }

    #[test]
    fn single_quoted_value() {
        let pairs = parse_env_str("FOO='hello world'\n", &dummy_path()).unwrap();
        assert_eq!(pairs[0].1, "hello world");
    }

    #[test]
    fn unquoted_value_trimmed() {
        let pairs = parse_env_str("FOO=bar   \n", &dummy_path()).unwrap();
        assert_eq!(pairs[0].1, "bar");
    }

    #[test]
    fn value_with_equals_sign() {
        // VALUE may contain `=`; only the first `=` is the separator.
        let pairs = parse_env_str("URL=http://example.com?a=1&b=2\n", &dummy_path()).unwrap();
        assert_eq!(pairs[0].1, "http://example.com?a=1&b=2");
    }

    #[test]
    fn no_equals_skipped() {
        let pairs = parse_env_str("NOEQUALS\nFOO=bar\n", &dummy_path()).unwrap();
        assert_eq!(pairs, vec![("FOO".into(), "bar".into())]);
    }

    #[test]
    fn empty_value_allowed() {
        let pairs = parse_env_str("EMPTY=\n", &dummy_path()).unwrap();
        assert_eq!(pairs, vec![("EMPTY".into(), "".into())]);
    }

    #[test]
    fn lookup_first_wins() {
        let env = EnvMap::from_iter(vec![
            ("A".into(), "first".into()),
            ("A".into(), "second".into()),
        ]);
        assert_eq!(env.get("A"), Some("first"));
    }

    #[test]
    fn with_overrides_higher_priority() {
        let base = EnvMap::from_iter(vec![("KEY".into(), "base".into())]);
        let overridden = base.with_overrides(vec![("KEY".into(), "override".into())]);
        assert_eq!(overridden.get("KEY"), Some("override"));
    }

    #[test]
    fn missing_key_returns_none() {
        assert_eq!(EnvMap::default().get("MISSING"), None);
    }
}
