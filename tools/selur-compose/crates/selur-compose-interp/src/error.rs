//! Error types for the interpolation crate.

use thiserror::Error;

/// Errors produced during environment variable interpolation.
#[derive(Debug, Clone, PartialEq, Error)]
pub enum InterpError {
    /// A `${VAR}` reference where `VAR` is not present in the environment.
    #[error("undefined variable `{name}` in `{input}`")]
    Undefined {
        /// Variable name.
        name: String,
        /// The full input string containing the reference.
        input: String,
    },

    /// A `${VAR:?msg}` or `${VAR?msg}` reference where `VAR` is absent
    /// (or empty when the `:` colon form is used).
    #[error("required variable `{name}` is missing: {msg}")]
    MissingRequired {
        /// Variable name.
        name: String,
        /// The message from the `?msg` modifier.
        msg: String,
        /// Byte-offset span `(start, end)` into the original input, pointing
        /// at the `$` of the expansion.  Reserved for `miette` integration.
        span: (usize, usize),
    },

    /// A `${` was opened but never closed with `}`.
    #[error("unterminated `${{` in `{input}` at byte {pos}")]
    Unterminated {
        /// The full input string.
        input: String,
        /// Byte offset of the opening `$`.
        pos: usize,
    },

    /// Error reading or parsing a `.env` file.
    #[error("failed to load env file `{path}`: {reason}")]
    EnvFile {
        /// Path that could not be loaded.
        path: String,
        /// Human-readable reason.
        reason: String,
    },
}
