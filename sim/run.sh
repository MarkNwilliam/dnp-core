#!/usr/bin/env bash
# Run the cocotb suite with a consistent cocotb install.
#
# The machine has two cocotb installs: pyenv 3.11 (2.0.1, has working
# cocotb-config) and oss-cad-suite (2.1.0, cocotb-config is broken on this
# libpython). iverilog/vvp come from oss-cad-suite, but the VPI library and
# the embedded interpreter must use the SAME cocotb -> use pyenv's, by
# putting it on PYTHONPATH.  See doc/research.md.
set -euo pipefail

PYENV_PY="$HOME/.pyenv/versions/3.11.10/bin"
COCOTB_SP="$HOME/.pyenv/versions/3.11.10/lib/python3.11/site-packages"
OSS="/Users/imac/oss-cad-suite/bin"

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$HERE"

export PATH="$PYENV_PY:$OSS:$PATH"
export PYTHONPATH="$HERE:$COCOTB_SP${PYTHONPATH:+:$PYTHONPATH}"

make "$@"
