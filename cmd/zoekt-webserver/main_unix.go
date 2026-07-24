//go:build linux || darwin || freebsd || netbsd

package main

import (
	"os"
	"os/signal"

	"golang.org/x/sys/unix"
)

func notifyShutdownSignals(c chan<- os.Signal) {
	signal.Notify(c, os.Interrupt, unix.SIGTERM)
}

func diskUsagePath(path string) (string, error) {
	return path, nil
}
