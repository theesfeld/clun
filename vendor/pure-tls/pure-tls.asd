;;; pure-tls.asd
;;;
;;; SPDX-License-Identifier: MIT
;;;
;;; Copyright (C) 2026 Anthony Green <green@moxielogic.com>

(asdf:defsystem "pure-tls"
  :description "Pure Common Lisp TLS 1.3 implementation"
  :author "Anthony Green <green@moxielogic.com>"
  :license "MIT"
  :version "1.12.1"
  :defsystem-depends-on ("trivial-features")
  :depends-on ("ironclad"
               "trivial-gray-streams"
               "flexi-streams"
               "alexandria"
               "cl-base64"
               "trivial-features"
               "idna"
               "bordeaux-threads"
               "usocket"
               "cl-cancel")
  ;; clun purity patch (Phase 19): the win/mac native-cert-validation foreign-lib deps
  ;; (two :feature-guarded entries) + the macos-verify/windows-verify source files are
  ;; stripped — Windows/macOS are non-goals and the literal token trips the §1.1 scan.
  :serial t
  :components ((:file "src/package")
               (:file "src/constants")
               (:file "src/conditions")
               (:file "src/context-support")
               (:file "src/utils")
               (:file "src/buffer-pool")
               (:module "src/crypto"
                :serial t
                :components ((:file "hkdf")
                             (:file "aead")
                             (:file "key-exchange")
                             (:file "ml-kem")
                             (:file "ml-dsa")
                             (:file "hpke")))
               (:module "src/record"
                :serial t
                :components ((:file "record-layer")))
               (:module "src/handshake"
                :serial t
                :components ((:file "messages")
                             (:file "key-schedule")
                             (:file "ech")
                             (:file "extensions")
                             (:file "resumption")
                             (:file "client")
                             (:file "server")))
               (:module "src/x509"
                :serial t
                :components ((:file "asn1")
                             (:file "certificate")
                             (:file "crl")
                             ;; clun purity patch (Phase 19): win/mac native-cert-validation
                             ;; source files removed (foreign-lib; non-goal platforms, §1.1).
                             (:file "verify")))
               (:file "src/context")
               (:file "src/streams")))

(asdf:defsystem "pure-tls/cl+ssl-compat"
  :description "cl+ssl API compatibility layer for pure-tls"
  :author "Anthony Green <green@moxielogic.com>"
  :license "MIT"
  :version "1.12.1"
  :depends-on ("pure-tls"
               "usocket")
  :serial t
  :components ((:file "compat/package")
               (:file "compat/api")))

(asdf:defsystem "pure-tls/acme"
  :description "ACME client for automatic certificate management (Let's Encrypt)"
  :author "Anthony Green <green@moxielogic.com>"
  :license "MIT"
  :version "2.0.0"
  :depends-on ("pure-tls"
               "drakma"
               "cl-json"
               "cl-base64"
               "ironclad"
               "flexi-streams"
               "bordeaux-threads"
               "usocket"
               "alexandria")
  :serial t
  :components ((:module "acme"
                :serial t
                :components ((:file "package")
                             (:file "asn1")
                             (:file "client")
                             (:file "store")
                             (:file "acme-client")
                             (:file "challenges")
                             (:file "csr")))))

(asdf:defsystem "pure-tls/acme+hunchentoot"
  :description "Hunchentoot integration for pure-tls/acme"
  :author "Anthony Green <green@moxielogic.com>"
  :license "MIT"
  :version "2.0.0"
  :depends-on ("pure-tls/acme"
               "hunchentoot")
  :serial t
  :components ((:module "acme"
                :components ((:file "hunchentoot")))))

(asdf:defsystem "pure-tls/test"
  :description "Tests for pure-tls"
  :author "Anthony Green <green@moxielogic.com>"
  :license "MIT"
  :depends-on ("pure-tls"
               "fiveam"
               "usocket"
               "iparse"
               "cl-ppcre"
               "bordeaux-threads"
               "drakma")
  :serial t
  :components ((:module "test"
                :serial t
                :components ((:file "package")
                             (:file "crypto-tests")
                             (:file "ml-dsa-tests")
                             (:file "record-tests")
                             (:file "handshake-tests")
                             (:file "certificate-tests")
                             (:file "trust-store-tests")
                             (:file "cancel-tests")
                             (:file "cancel-integration-tests")
                             (:file "network-tests")
                             (:file "openssl-tests")
                             (:file "boringssl-tests")
                             (:file "x509test-tests")
                             (:file "security-regression-tests")
                             (:file "resumption-interop-tests")
                             (:file "runner")))))

(asdf:defsystem "pure-tls/acme/test"
  :description "Tests for the pure-tls ACME client retry/restart handling"
  :author "Anthony Green <green@moxielogic.com>"
  :license "MIT"
  :depends-on ("pure-tls/acme"
               "fiveam")
  :serial t
  :components ((:module "test/acme"
                :serial t
                :components ((:file "client-retry-tests")))))
