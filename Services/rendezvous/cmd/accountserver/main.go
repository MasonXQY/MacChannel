package main

import (
	"context"
	"errors"
	"log"
	"net"
	"os"
	"os/signal"
	"syscall"
)

func main() {
	ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer stop()
	if err := run(ctx, os.Getenv, net.Listen); err != nil {
		log.Print("account service stopped: startup or runtime failure")
		os.Exit(1)
	}
}

func run(ctx context.Context, getenv func(string) string, listen func(string, string) (net.Listener, error)) error {
	cfg, err := loadConfig(getenv)
	if err != nil {
		return errStartup
	}
	if !cfg.enabled {
		return nil
	}
	handler, closeService, err := buildService(ctx, cfg)
	if err != nil {
		return errStartup
	}
	defer closeService()
	listener, err := listen("tcp", cfg.addr)
	if err != nil {
		return errStartup
	}
	if err := serveHTTP(ctx, listener, handler); err != nil && !errors.Is(err, context.Canceled) {
		return errStartup
	}
	return nil
}
