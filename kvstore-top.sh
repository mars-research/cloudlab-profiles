#!/bin/bash 

VERBOSE_LOG=${HOME}/kvstore-verbose.log

echo "Logging to ${VERBOSE_LOG}"
/local/repository/kvstore-setup.sh |& tee -a ${VERBOSE_LOG}
