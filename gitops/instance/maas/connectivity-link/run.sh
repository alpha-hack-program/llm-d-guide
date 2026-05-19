#!/bin/sh
APP_NAME=maas-connectivity-link
set -x
helm template . --name-template ${APP_NAME}
