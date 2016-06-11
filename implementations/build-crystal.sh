#!/bin/bash
SCRIPT_PATH=`dirname $0`
source $SCRIPT_PATH/script.inc
source $SCRIPT_PATH/config.inc

INFO Build Crystal Benchmarks
pushd $SCRIPT_PATH/../benchmarks/Crystal
if [ "$1" = "style" ]
then
  exit 0
else
  $SCRIPT_PATH/build.sh
fi