#!/bin/bash 

VERBOSE_LOG=${HOME}/dramhit-verbose.log

echo "Logging to ${VERBOSE_LOG}"
/local/repository/dramhit-setup.sh |& tee -a ${VERBOSE_LOG}
