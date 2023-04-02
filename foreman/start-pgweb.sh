#!/bin/sh

while ! nc -z localhost 64444; do sleep 1; done

pgweb --host localhost --port 64444 --db hydra
