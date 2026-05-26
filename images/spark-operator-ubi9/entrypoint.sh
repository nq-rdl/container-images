#!/bin/bash
#
# Blueprint: kubeflow/spark-operator entrypoint.sh (verbatim from upstream)
# Handles OpenShift random UID case via libnss_wrapper
#

set -ex

myuid="$(id -u)"
if ! getent passwd "$myuid" &> /dev/null; then
    for wrapper in {/usr,}/lib{/*,}/libnss_wrapper.so; do
      if [ -s "$wrapper" ]; then
        NSS_WRAPPER_PASSWD="$(mktemp)"
        NSS_WRAPPER_GROUP="$(mktemp)"
        export LD_PRELOAD="$wrapper" NSS_WRAPPER_PASSWD NSS_WRAPPER_GROUP
        mygid="$(id -g)"
        printf 'spark:x:%s:%s:%s:%s:/bin/false\n' "$myuid" "$mygid" "${SPARK_USER_NAME:-anonymous uid}" "$SPARK_HOME" > "$NSS_WRAPPER_PASSWD"
        printf 'spark:x:%s:\n' "$mygid" > "$NSS_WRAPPER_GROUP"
        break
      fi
    done
fi

exec /usr/bin/tini -s -- /usr/bin/spark-operator "$@"
