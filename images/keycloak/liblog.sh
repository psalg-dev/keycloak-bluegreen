# Stub for the Bitnami chart's init container, which sources this file for its log helpers.
info() { echo "INFO  $*"; }
warn() { echo "WARN  $*" >&2; }
error() { echo "ERROR $*" >&2; }
debug() { :; }
