#!/bin/sh
# clang wrapper for this container: LLVM 19 lives in ~/opt without a GCC
# toolchain, so link with lld and LLVM's own runtime libraries.
L="$HOME/opt/LLVM-19.1.7-Linux-X64"
case " $* " in
  *" --version "*|*" -v "*) exec "$L/bin/clang" "$@" ;;
esac
exec "$L/bin/clang" -fuse-ld=lld --rtlib=compiler-rt --unwindlib=none "$@"
