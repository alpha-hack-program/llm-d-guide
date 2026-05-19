#!/bin/sh
APP_NAME=maas-rbac
helm template . --name-template ${APP_NAME}
