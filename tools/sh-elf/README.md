# sh-elf binutils

GNU binutils built for the `sh-elf` target, for the SH7604's upstream tests
(`rtl/cpu/sh7604/tests/*/sim.sh` assemble their programs with `sh-elf-as` and `sh-elf-objcopy`).
Only this README is committed; `src/`, `bin/`, `lib/`, `share/`, `sh-elf/` and the logs are
ignored.

Built under MSYS2 MinGW64 (`E:/msys64`):

```
curl -fsSL -o src/binutils-2.45.tar.xz https://ftp.gnu.org/gnu/binutils/binutils-2.45.tar.xz
tar xf src/binutils-2.45.tar.xz -C src
mkdir src/build && cd src/build
../binutils-2.45/configure --target=sh-elf --prefix=<this directory> \
    --disable-gdb --disable-gdbserver --disable-sim --disable-libdecnumber \
    --disable-readline --disable-gprofng --disable-werror --disable-nls
make -j8 && make install
```

`scripts/sh7604_tests.sh` puts `bin/` on the PATH before running the tests.
