#!/bin/bash
SCRIPT_PATH=`dirname $0`
source $SCRIPT_PATH/config.inc
exec $GRAAL_GRAAL_BASIC_CMD "$@"
