# Third-party notices

Clun is GPL-3.0-or-later. Its source distribution also contains vendored,
GPL-compatible Common Lisp components under `vendor/`; those components retain
their original copyrights and licenses. Release archives copy the available
license and copyright files into `licenses/vendor/`.

The native release archive also contains or incorporates these runtime pieces:

- SBCL. Most SBCL code is in the public domain; some portions use BSD-style
  licenses. The exact SBCL 2.6.4 source and notices are published by the SBCL
  project at
  <https://sourceforge.net/projects/sbcl/files/sbcl/2.6.4/sbcl-2.6.4-source.tar.bz2/download>.
- Zstandard. Copyright Meta Platforms, Inc. and contributors, BSD-3-Clause.
  Source: <https://github.com/facebook/zstd>.
- GNU C Library (Linux archives only), LGPL-2.1-or-later. Clun ships the shared
  loader and libraries so the same archive can run on distributions without a
  system glibc loader. Source for the Ubuntu 22.04 build is available from
  <https://packages.ubuntu.com/source/jammy/glibc>.

The corresponding Clun source for each binary release is the Git tag bearing
the same version. System-library and vendored-component terms apply in addition
to Clun's GPL terms where required.
