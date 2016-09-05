#!/bin/bash

set -e

if [[ "$TRAVIS_OS_NAME" == "linux" ]]; then
  sudo apt-get install --yes libssl-dev opam libgmp-dev libsqlite3-dev g++-5 gcc-5;
  sudo update-alternatives --install /usr/bin/gcc gcc /usr/bin/gcc-5 200;
  sudo update-alternatives --install /usr/bin/g++ g++ /usr/bin/g++-5 200;
  tar xJvf clang+llvm-*
fi

export OPAMYES=true
opam init
eval $(opam config env)
opam install batteries sqlite3 fileutils stdint zarith yojson pprint \
  ppx_deriving_yojson menhir ulex process fix

if [[ "$TRAVIS_OS_NAME" == "linux" ]]; then
  export Z3=z3-4.4.1-x64-ubuntu-14.04;
  wget https://github.com/Z3Prover/z3/releases/download/z3-4.4.1/$Z3.zip;
  unzip $Z3.zip;
  export PATH=/home/travis/build/FStarLang/FStar/$Z3/bin:/home/travis/build/FStarLang/FStar/bin:$PATH;
fi

git clone https://github.com/FStarLang/FStar.git fstar
make -C fstar/src/ocaml-output
