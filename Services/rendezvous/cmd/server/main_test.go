package main

import (
	"testing"
	"time"
)

func TestConfiguredStoresFailClosedWithoutDatabase(t *testing.T) {
	t.Setenv("DATABASE_URL", "")
	t.Setenv("MACCHANNEL_DEV_IN_MEMORY", "")
	_, _, _, closeStores, err := configuredStores(time.Now)
	if closeStores != nil {
		closeStores()
	}
	if err == nil {
		t.Fatal("production startup accepted an implicit in-memory store")
	}
}

func TestConfiguredStoresPermitExplicitDevelopmentMemoryMode(t *testing.T) {
	t.Setenv("DATABASE_URL", "")
	t.Setenv("MACCHANNEL_DEV_IN_MEMORY", "true")
	pairings, registry, verifier, closeStores, err := configuredStores(time.Now)
	if err != nil {
		t.Fatal(err)
	}
	defer closeStores()
	if pairings == nil || registry == nil || verifier == nil {
		t.Fatal("development memory mode returned incomplete stores")
	}
}
