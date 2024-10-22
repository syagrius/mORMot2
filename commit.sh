#!/bin/bash


VERS=$(python3 - `git rev-list --count master` <<<'import sys; print(int(sys.argv[1])+1)')
#echo VERS=$VERS

echo -e "'2.3.$VERS'\r">src/mormot.commit.inc
cp src/mormot.commit.inc ~/dev/lib2/src/mormot.commit.inc

git add --all
git commit
git push

echo committed 2.3.$VERS as https://github.com/synopse/mORMot2/commit/`git rev-parse --short HEAD`
