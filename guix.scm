;; SPDX-License-Identifier: MPL-2.0
;; Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
;;
;; Guix package definition for Burble — voice-first communications platform.
;;
;; Usage:
;;   guix shell -D -f guix.scm     # Enter dev shell with full toolchain
;;   guix build -f guix.scm        # Build the package
;;   guix shell -CN -f guix.scm    # Container shell (isolated network)
;;
;; Per estate-wide policy this is the PRIMARY development environment;
;; flake.nix is the Nix fallback.
;;
;; Components served by this environment:
;;   * Elixir/Phoenix server (server/) — needs erlang + elixir + bcrypt build
;;   * Zig SIMD coprocessor NIFs (ffi/zig/) — needs zig + erlang headers
;;   * Deno web client + signaling relay (client/web/, signaling/) — needs deno
;;   * Bolt cert + DDNS scripts — need curl + jq + openssl
;;   * VeriSimDB Rust client (built via Cargo from the verisim_client dep)

(use-modules (guix packages)
             (guix gexp)
             (guix git-download)
             (guix build-system gnu)
             (guix licenses)
             (gnu packages)
             (gnu packages base)
             (gnu packages erlang)
             (gnu packages elixir)
             (gnu packages zig)
             (gnu packages rust)
             (gnu packages tls)
             (gnu packages curl)
             (gnu packages haskell-xyz) ; for jq
             (gnu packages version-control)
             (gnu packages bash)
             (gnu packages compression)
             (gnu packages pkg-config))

(define-public burble
  (package
    (name "burble")
    (version "1.0.0")
    (source (local-file "." "burble-source"
                        #:recursive? #t
                        #:select? (lambda (file stat)
                                    (not (or (string-contains file ".git")
                                             (string-contains file "_build")
                                             (string-contains file "node_modules")
                                             (string-contains file "deps/")
                                             (string-contains file "zig-cache")
                                             (string-contains file "zig-out"))))))
    (build-system gnu-build-system)
    (arguments
     '(#:phases
       (modify-phases %standard-phases
         (delete 'configure)
         ;; Burble's release build is driven by `mix release` from server/,
         ;; which calls into ffi/zig/ for the coprocessor NIF. Both happen
         ;; inside the standard build phase; the Justfile recipe `build`
         ;; orchestrates ffi-then-server.
         (replace 'build
           (lambda _
             ;; Build Zig NIFs first so they're on disk when mix compile
             ;; loads them.
             (with-directory-excursion "ffi/zig"
               (invoke "zig" "build" "-Doptimize=ReleaseFast"))
             (with-directory-excursion "server"
               (setenv "MIX_ENV" "prod")
               (invoke "mix" "deps.get")
               (invoke "mix" "compile")
               (invoke "mix" "release"))))
         (delete 'check) ; tests run via `just test`, not the package phase
         (replace 'install
           (lambda* (#:key outputs #:allow-other-keys)
             (let* ((out (assoc-ref outputs "out"))
                    (bin (string-append out "/bin"))
                    (lib (string-append out "/lib/burble"))
                    (doc (string-append out "/share/doc/burble")))
               (mkdir-p bin)
               (mkdir-p lib)
               (mkdir-p doc)
               ;; Copy the release tree
               (copy-recursively "server/_build/prod/rel/burble" lib)
               ;; Top-level docs
               (for-each (lambda (f)
                           (when (file-exists? f)
                             (install-file f doc)))
                         '("README.adoc" "EXPLAINME.adoc" "CHANGELOG.md"
                           "LICENSE" "SECURITY.md")))))))
       ;; The Phoenix release embeds Erlang in the artifact, so we don't
       ;; need erlang as a runtime input here — it's a build-time concern.
       ))
    (native-inputs
     (list
      erlang             ; OTP runtime for Elixir
      elixir             ; mix, mix compile, mix release
      zig                ; SIMD coprocessor NIF builder
      rust               ; for any host-side Rust scaffolding
      `(,rust "cargo")
      pkg-config
      openssl            ; bcrypt_elixir links against this at NIF build
      tar
      gzip
      git))
    (inputs
     (list
      ;; Runtime inputs — what the deployed Burble binary needs at runtime.
      openssl
      curl               ; for the cf-bolt-dns.sh / cf-ddns.sh helpers
      jq))               ; same
    ;; The native client (Tier 1, ADR-0003) will additionally need:
    ;;   deno  -- for the Deno-based signaling relay (signaling/relay.js)
    ;; Guix's package collection is moving fast on Deno; check
    ;;   guix search deno
    ;; before adding. As of this writing it may not be in guix-master.
    (home-page "https://github.com/hyperpolymath/burble")
    (synopsis "Voice-first self-hostable communications platform")
    (description
     "Burble is a self-hostable voice communications platform built for
people who care about latency, privacy, and control. WebRTC SFU with
SIMD-accelerated audio kernels (Zig NIFs), four topology modes from
single-server to fully distributed mesh, Bolt UDP magic-packet ringer
with NAPTR/SRV discovery, and PAKE+SAS tiered caller authentication
(per ADR-0003). Browser join with no install; native client with QUIC
datagrams for low-latency peer-to-peer.")
    (license (list
              ;; MPL-2.0 — extends MPL-2.0
              mpl2.0))))

;; Return the package as the default value so `guix build -f guix.scm`
;; works without arguments.
burble
