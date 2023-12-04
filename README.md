# libmem-build

Build script and pipeline to create pre-built binaries for [libmem].

[libmem]: https://github.com/rdbo/libmem

Artifacts structure:
```text
├── include/
│   └── libmem/
│       ├── libmem.h
│       └── libmem.hpp
├── lib/
│   ├── liblibmem.so|libmem.dll
│   ├── liblibmem.a|libmem.lib
│   ├── libcapstone.a|capstone.lib
│   ├── libinjector.a|injector.lib
│   ├── libkeystone.a|keystone.lib
│   ├── libLIEF.a|LIEF.lib
│   └── libllvm.a|llvm.lib
├── licenses/[...]
├── GLIBC_VERSION.txt   (if linux-gnu)
├── MUSL_VERSION.txt    (if linux-musl)
├── MSVC_VERSION.txt    (if windows-msvc)
└── WINSDK_VERSION.txt  (if windows-msvc)
```

Used by:
- [ts3-server-hook](https://github.com/nathan818fr/ts3-server-hook)
