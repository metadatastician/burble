//! Variable interpolation for selur-compose.
//!
//! Resolves `${VAR}`, `${VAR:-default}`, `${VAR:?err}`, and `$$` escapes
//! over every string-typed field in a parsed [`selur_compose_schema::Compose`].
//!
//! This is a pure function over `(Compose, EnvMap)` — no I/O except `.env`
//! file loading (performed by the caller before calling [`interpolate`]).
//!
//! # Grammar
//!
//! See `src/grammar.md` for the full BNF and semantics.
//!
//! # Example
//!
//! ```no_run
//! use selur_compose_schema::parse_str;
//! use selur_compose_interp::{interpolate, env::EnvMap};
//!
//! let toml = std::fs::read_to_string("selur-compose.toml").unwrap();
//! let compose = parse_str(&toml, None).unwrap();
//!
//! let env = EnvMap::from_process();
//! let resolved = interpolate(compose, &env).unwrap();
//! println!("{} services", resolved.services.len());
//! ```

pub mod env;
pub mod error;
pub mod expander;
pub mod lexer;
pub mod visit;

pub use env::EnvMap;
pub use error::InterpError;

use selur_compose_schema::Compose;

/// Resolve all `${VAR}` references in `compose` against `env`.
///
/// Returns a new `Compose` with every string-typed field expanded.
/// Fields that contain no `${…}` references are returned unchanged.
///
/// # Errors
///
/// - [`InterpError::Undefined`] — a `${VAR}` reference where `VAR` is not
///   in `env`.
/// - [`InterpError::MissingRequired`] — a `${VAR:?msg}` or `${VAR?msg}`
///   reference where `VAR` is absent (or empty for the `:` form).
/// - [`InterpError::Unterminated`] — a `${` with no closing `}`.
pub fn interpolate(compose: Compose, env: &EnvMap) -> Result<Compose, InterpError> {
    visit::visit_compose(compose, env)
}
