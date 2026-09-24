package main

import (
	"context"
	"database/sql"
	"database/sql/driver"
	"errors"
	"io"
	"testing"
)

type privilegeTestDriver struct{}

func (privilegeTestDriver) Open(name string) (driver.Conn, error) {
	return privilegeTestConn{deniedTable: name}, nil
}

type privilegeTestConn struct{ deniedTable string }

func (privilegeTestConn) Prepare(string) (driver.Stmt, error) {
	return nil, errors.New("unexpected prepare")
}
func (privilegeTestConn) Close() error              { return nil }
func (privilegeTestConn) Begin() (driver.Tx, error) { return nil, errors.New("unexpected begin") }
func (c privilegeTestConn) QueryContext(_ context.Context, _ string, args []driver.NamedValue) (driver.Rows, error) {
	if len(args) != 1 {
		return nil, errors.New("unexpected arguments")
	}
	table, ok := args[0].Value.(string)
	if !ok {
		return nil, errors.New("unexpected table")
	}
	return &privilegeTestRows{allowed: table != c.deniedTable}, nil
}

type privilegeTestRows struct {
	allowed bool
	done    bool
}

func (*privilegeTestRows) Columns() []string { return []string{"allowed"} }
func (*privilegeTestRows) Close() error      { return nil }
func (r *privilegeTestRows) Next(values []driver.Value) error {
	if r.done {
		return io.EOF
	}
	r.done = true
	values[0] = r.allowed
	return nil
}

func TestCapabilityPrivilegeCheckRejectsExistingButUnusableTable(t *testing.T) {
	const driverName = "dropmesh-account-privilege-test"
	sql.Register(driverName, privilegeTestDriver{})
	database, err := sql.Open(driverName, "public.account_groups")
	if err != nil {
		t.Fatal(err)
	}
	defer database.Close()

	err = checkTablePrivileges(context.Background(), database,
		[]string{"account_groups", "account_group_events", "account_group_pending"})
	if !errors.Is(err, errStartup) {
		t.Fatalf("missing feature-table privileges accepted: %v", err)
	}
}

func TestCapabilityPrivilegeCheckAcceptsRequiredDMLAccess(t *testing.T) {
	const driverName = "dropmesh-account-privilege-success-test"
	sql.Register(driverName, privilegeTestDriver{})
	database, err := sql.Open(driverName, "")
	if err != nil {
		t.Fatal(err)
	}
	defer database.Close()

	if err := checkTablePrivileges(context.Background(), database,
		[]string{"account_groups", "account_group_events", "account_group_pending"}); err != nil {
		t.Fatalf("valid feature-table privileges rejected: %v", err)
	}
}
