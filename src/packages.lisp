;;;; packages.lisp — package skeleton for clun's subsystems (PLAN.md §3.7).
;;;; Each subsystem gets a namespace home now so later phases have somewhere to
;;;; land; per §6 nothing :use-s beyond :cl. Sub-packages (engine lexer/parser/…)
;;;; are added when their phase arrives.

(in-package :cl-user)

(defpackage :clun
  (:use :cl)
  (:documentation "Toplevel: argv dispatch, version, condition->exit-code.")
  (:export #:main))

(defpackage :clun.sys
  (:use :cl)
  (:documentation "Path discipline, JSON, errors, sbcl-compat, platform."))

(defpackage :clun.cli
  (:use :cl)
  (:documentation "Per-command argument parsing, help/version, .env loader."))

(defpackage :clun.engine
  (:use :cl)
  (:documentation "From-scratch ECMAScript engine: lexer, parser, analyzer, emitter, objects, stdlib."))

(defpackage :clun.loop
  (:use :cl)
  (:documentation "Event loop: reactor, timers, mailbox, handles, signals, workers."))

(defpackage :clun.resolver
  (:use :cl)
  (:documentation "Pure-CL Node module resolution (no engine dependency)."))

(defpackage :clun.transpiler
  (:use :cl)
  (:documentation "TypeScript type-stripping (shares the engine lexer)."))

(defpackage :clun.runtime
  (:use :cl)
  (:documentation "Globals wiring: console/inspector, process, timers, Clun global, node/ modules."))

(defpackage :clun.net
  (:use :cl)
  (:documentation "Sockets, HTTP parser/server/client, fetch, TLS integration."))

(defpackage :clun.test-runner
  (:use :cl)
  (:documentation "clun test: discovery, scheduler, matchers, diff, reporter."))

(defpackage :clun.install
  (:use :cl)
  (:documentation "clun install: semver, registry, tarball, integrity, linker, lockfile, cache."))
