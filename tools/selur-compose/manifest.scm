;;; SPDX-License-Identifier: MPL-2.0
;;; manifest.scm — Generic Guix manifest for RSR-compliant projects
;;;
;;; Usage:
;;;   guix shell -m manifest.scm
;;;

(specifications->manifest
  '(;; Core development tools
    "git"
    "just"
    "nickel"
    "curl"
    "bash"
    "coreutils"

    ;; Documentation
    "asciidoctor"
    "pandoc"

    ;; Common build dependencies
    "openssl"
    "zlib"
    "pkg-config"))
