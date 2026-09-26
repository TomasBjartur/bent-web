#!/bin/sh
# clang wrapper for this container: LLVM 19 lives in ~/opt without a GCC
# toolchain, so link with lld and LLVM's own runtime libraries. Sanitizer
# and fuzzer builds also need LLVM's libunwind and libc++.
L="$HOME/opt/LLVM-19.1.7-Linux-X64"
LIB="$L/lib/x86_64-unknown-linux-gnu"
case " $* " in
  *" --version "*|*" -v "*|*" -E "*) exec "$L/bin/clang" "$@" ;;
esac
case " $* " in
  *" -c "*) exec "$L/bin/clang" "$@" ;;
  *-fsanitize=*)
    exec "$L/bin/clang" -fuse-ld=lld --rtlib=compiler-rt --unwindlib=none \
      -L"$HOME/opt/fakestd" "$@" "$LIB/libc++.a" "$LIB/libc++abi.a" "$LIB/libunwind.a" -lpthread -ldl ;;
esac
exec "$L/bin/clang" -fuse-ld=lld --rtlib=compiler-rt --unwindlib=none "$@"
