// Unit tests (no live database) that exercise the *Postgres query-method BODIES —
// List*/Get*/Upsert*/Delete*/AppendAudit and the WithTx begin/commit/rollback
// seam — through a fake database/sql/driver built on the STANDARD LIBRARY only
// (database/sql/driver). NO third-party mock library is added (go.mod/go.sum stay
// untouched, §11.4.84). The fake driver lets a test script exactly what the
// underlying pool returns — real rows, a query error, a scan-conversion failure,
// a rows.Err() failure, sql.ErrNoRows — so the wrapped-error paths (§11.4.1: a
// FAIL must be a real product path, never a script bug) and the ErrNotFound
// fail-closed branches are asserted as genuine behaviour, not padding.
package store

import (
	"context"
	"database/sql"
	"database/sql/driver"
	"errors"
	"io"
	"strings"
	"testing"
	"time"
)

// =============================================================================
// fake database/sql/driver — stdlib only, scriptable per test.
// =============================================================================

type fakeConnector struct {
	queryFn   func(query string, args []driver.Value) (driver.Rows, error)
	execFn    func(query string, args []driver.Value) (driver.Result, error)
	beginErr  error
	commitErr error
}

func (c *fakeConnector) Connect(context.Context) (driver.Conn, error) {
	return &fakeConn{queryFn: c.queryFn, execFn: c.execFn, beginErr: c.beginErr, commitErr: c.commitErr}, nil
}
func (c *fakeConnector) Driver() driver.Driver { return fakeDriver{} }

type fakeDriver struct{}

func (fakeDriver) Open(string) (driver.Conn, error) { return nil, errors.New("use OpenDB") }

type fakeConn struct {
	queryFn   func(query string, args []driver.Value) (driver.Rows, error)
	execFn    func(query string, args []driver.Value) (driver.Result, error)
	beginErr  error
	commitErr error
}

func namedToValue(named []driver.NamedValue) []driver.Value {
	vals := make([]driver.Value, len(named))
	for i, n := range named {
		vals[i] = n.Value
	}
	return vals
}

func (c *fakeConn) QueryContext(_ context.Context, query string, args []driver.NamedValue) (driver.Rows, error) {
	if c.queryFn == nil {
		return nil, errors.New("fake: unexpected QueryContext: " + query)
	}
	return c.queryFn(query, namedToValue(args))
}

func (c *fakeConn) ExecContext(_ context.Context, query string, args []driver.NamedValue) (driver.Result, error) {
	if c.execFn == nil {
		return nil, errors.New("fake: unexpected ExecContext: " + query)
	}
	return c.execFn(query, namedToValue(args))
}

func (c *fakeConn) Prepare(string) (driver.Stmt, error) {
	return nil, errors.New("prepare unsupported")
}
func (c *fakeConn) Close() error { return nil }
func (c *fakeConn) Begin() (driver.Tx, error) {
	return c.BeginTx(context.Background(), driver.TxOptions{})
}
func (c *fakeConn) BeginTx(context.Context, driver.TxOptions) (driver.Tx, error) {
	if c.beginErr != nil {
		return nil, c.beginErr
	}
	return &fakeTx{c: c}, nil
}

type fakeTx struct{ c *fakeConn }

func (t *fakeTx) Commit() error {
	if t.c.commitErr != nil {
		return t.c.commitErr
	}
	return nil
}
func (t *fakeTx) Rollback() error { return nil }

type fakeResult struct{}

func (fakeResult) LastInsertId() (int64, error) { return 0, nil }
func (fakeResult) RowsAffected() (int64, error) { return 1, nil }

type fakeRows struct {
	cols     []string
	data     [][]driver.Value
	idx      int
	finalErr error // returned in place of io.EOF once data is exhausted (rows.Err path)
}

func (r *fakeRows) Columns() []string { return r.cols }
func (r *fakeRows) Close() error      { return nil }
func (r *fakeRows) Next(dest []driver.Value) error {
	if r.idx >= len(r.data) {
		if r.finalErr != nil {
			return r.finalErr
		}
		return io.EOF
	}
	row := r.data[r.idx]
	r.idx++
	for i := range dest {
		if i < len(row) {
			dest[i] = row[i]
		}
	}
	return nil
}

// openFake wires a *Postgres over a *sql.DB backed by the fake driver so the SAME
// production query bodies run against scripted rows/errors.
func openFake(t *testing.T, c *fakeConnector) *Postgres {
	t.Helper()
	db := sql.OpenDB(c)
	t.Cleanup(func() { _ = db.Close() })
	return New(db)
}

// column-name helpers (count is what matters to database/sql scanning).
var (
	profileCols = []string{"id", "name", "type", "config", "secret_ref", "enabled", "created_at", "updated_at"}
	targetCols  = []string{"id", "public_alias", "private_ip", "port", "protocol", "vpn_profile_id", "health_check", "enabled", "created_at", "updated_at"}
	ruleCols    = []string{"id", "priority", "match_host", "match_path", "target_host_id", "enabled", "created_at", "updated_at"}
	tierCols    = []string{"target_host_id", "vpn_profile_id", "tier", "created_at"}
	userCols    = []string{"id", "username", "secret_ref", "role", "enabled", "created_at", "updated_at"}
)

var errBoom = errors.New("boom")

func now() time.Time { return time.Unix(1700000000, 0).UTC() }

// =============================================================================
// List* — success, query error, scan error, rows.Err() error.
// =============================================================================

func TestListProfiles_Paths(t *testing.T) {
	t.Parallel()
	ctx := context.Background()

	// success: two rows scanned.
	ok := openFake(t, &fakeConnector{queryFn: func(string, []driver.Value) (driver.Rows, error) {
		return &fakeRows{cols: profileCols, data: [][]driver.Value{
			{"p1", "eu", "wireguard", []byte("{}"), "ref", true, now(), now()},
			{"p2", "us", "openvpn", []byte("{}"), "", false, now(), now()},
		}}, nil
	}})
	got, err := ok.ListProfiles(ctx)
	if err != nil || len(got) != 2 || got[0].Name != "eu" || got[1].Type != "openvpn" {
		t.Fatalf("success: got %+v err=%v", got, err)
	}

	// query error → wrapped "list profiles".
	qe := openFake(t, &fakeConnector{queryFn: func(string, []driver.Value) (driver.Rows, error) { return nil, errBoom }})
	if _, err := qe.ListProfiles(ctx); err == nil || !strings.Contains(err.Error(), "list profiles") {
		t.Fatalf("query error: want wrapped list-profiles error, got %v", err)
	}

	// scan error: enabled column is a non-bool string → convert failure → "scan profile".
	se := openFake(t, &fakeConnector{queryFn: func(string, []driver.Value) (driver.Rows, error) {
		return &fakeRows{cols: profileCols, data: [][]driver.Value{
			{"p1", "eu", "wireguard", []byte("{}"), "ref", "not-a-bool", now(), now()},
		}}, nil
	}})
	if _, err := se.ListProfiles(ctx); err == nil || !strings.Contains(err.Error(), "scan profile") {
		t.Fatalf("scan error: want wrapped scan-profile error, got %v", err)
	}

	// rows.Err() error after zero rows → propagated verbatim.
	re := openFake(t, &fakeConnector{queryFn: func(string, []driver.Value) (driver.Rows, error) {
		return &fakeRows{cols: profileCols, finalErr: errBoom}, nil
	}})
	if _, err := re.ListProfiles(ctx); !errors.Is(err, errBoom) {
		t.Fatalf("rows.Err path: want errBoom, got %v", err)
	}
}

func TestListTargets_Paths(t *testing.T) {
	t.Parallel()
	ctx := context.Background()
	ok := openFake(t, &fakeConnector{queryFn: func(string, []driver.Value) (driver.Rows, error) {
		return &fakeRows{cols: targetCols, data: [][]driver.Value{
			{"t1", "api.internal", "10.8.0.5", int64(8443), "https", "prof-1", "", true, now(), now()},
		}}, nil
	}})
	got, err := ok.ListTargets(ctx)
	if err != nil || len(got) != 1 || got[0].PublicAlias != "api.internal" || got[0].Port != 8443 {
		t.Fatalf("success: got %+v err=%v", got, err)
	}
	qe := openFake(t, &fakeConnector{queryFn: func(string, []driver.Value) (driver.Rows, error) { return nil, errBoom }})
	if _, err := qe.ListTargets(ctx); err == nil || !strings.Contains(err.Error(), "list targets") {
		t.Fatalf("query error: got %v", err)
	}
	se := openFake(t, &fakeConnector{queryFn: func(string, []driver.Value) (driver.Rows, error) {
		return &fakeRows{cols: targetCols, data: [][]driver.Value{
			{"t1", "a", "10.0.0.1", int64(1), "http", "", "", "nope", now(), now()},
		}}, nil
	}})
	if _, err := se.ListTargets(ctx); err == nil || !strings.Contains(err.Error(), "scan target") {
		t.Fatalf("scan error: got %v", err)
	}
}

func TestListRules_Paths(t *testing.T) {
	t.Parallel()
	ctx := context.Background()
	ok := openFake(t, &fakeConnector{queryFn: func(string, []driver.Value) (driver.Rows, error) {
		return &fakeRows{cols: ruleCols, data: [][]driver.Value{
			{"r1", int64(100), "api.internal", "", "t1", true, now(), now()},
		}}, nil
	}})
	got, err := ok.ListRules(ctx)
	if err != nil || len(got) != 1 || got[0].Priority != 100 || got[0].MatchHost != "api.internal" {
		t.Fatalf("success: got %+v err=%v", got, err)
	}
	qe := openFake(t, &fakeConnector{queryFn: func(string, []driver.Value) (driver.Rows, error) { return nil, errBoom }})
	if _, err := qe.ListRules(ctx); err == nil || !strings.Contains(err.Error(), "list rules") {
		t.Fatalf("query error: got %v", err)
	}
	se := openFake(t, &fakeConnector{queryFn: func(string, []driver.Value) (driver.Rows, error) {
		return &fakeRows{cols: ruleCols, data: [][]driver.Value{
			{"r1", "not-an-int", "h", "", "t1", true, now(), now()},
		}}, nil
	}})
	if _, err := se.ListRules(ctx); err == nil || !strings.Contains(err.Error(), "scan rule") {
		t.Fatalf("scan error: got %v", err)
	}
}

func TestListTiers_Paths(t *testing.T) {
	t.Parallel()
	ctx := context.Background()
	ok := openFake(t, &fakeConnector{queryFn: func(string, []driver.Value) (driver.Rows, error) {
		return &fakeRows{cols: tierCols, data: [][]driver.Value{
			{"t1", "prof-1", int64(0), now()},
			{"t1", "prof-2", int64(1), now()},
		}}, nil
	}})
	got, err := ok.ListTiers(ctx, "t1")
	if err != nil || len(got) != 2 || got[0].Tier != 0 || got[1].VPNProfileID != "prof-2" {
		t.Fatalf("success: got %+v err=%v", got, err)
	}
	qe := openFake(t, &fakeConnector{queryFn: func(string, []driver.Value) (driver.Rows, error) { return nil, errBoom }})
	if _, err := qe.ListTiers(ctx, "t1"); err == nil || !strings.Contains(err.Error(), "list tiers") {
		t.Fatalf("query error: got %v", err)
	}
	se := openFake(t, &fakeConnector{queryFn: func(string, []driver.Value) (driver.Rows, error) {
		return &fakeRows{cols: tierCols, data: [][]driver.Value{{"t1", "p", "not-int", now()}}}, nil
	}})
	if _, err := se.ListTiers(ctx, "t1"); err == nil || !strings.Contains(err.Error(), "scan tier") {
		t.Fatalf("scan error: got %v", err)
	}
}

func TestListUsers_Paths(t *testing.T) {
	t.Parallel()
	ctx := context.Background()
	ok := openFake(t, &fakeConnector{queryFn: func(string, []driver.Value) (driver.Rows, error) {
		return &fakeRows{cols: userCols, data: [][]driver.Value{
			{"u1", "alice", "htpw", "admin", true, now(), now()},
		}}, nil
	}})
	got, err := ok.ListUsers(ctx)
	if err != nil || len(got) != 1 || got[0].Username != "alice" || got[0].Role != "admin" {
		t.Fatalf("success: got %+v err=%v", got, err)
	}
	qe := openFake(t, &fakeConnector{queryFn: func(string, []driver.Value) (driver.Rows, error) { return nil, errBoom }})
	if _, err := qe.ListUsers(ctx); err == nil || !strings.Contains(err.Error(), "list users") {
		t.Fatalf("query error: got %v", err)
	}
	se := openFake(t, &fakeConnector{queryFn: func(string, []driver.Value) (driver.Rows, error) {
		return &fakeRows{cols: userCols, data: [][]driver.Value{{"u1", "a", "s", "r", "not-bool", now(), now()}}}, nil
	}})
	if _, err := se.ListUsers(ctx); err == nil || !strings.Contains(err.Error(), "scan user") {
		t.Fatalf("scan error: got %v", err)
	}
}

// =============================================================================
// Get* — success, ErrNotFound (sql.ErrNoRows), generic wrapped error.
// =============================================================================

func TestGetProfile_Paths(t *testing.T) {
	t.Parallel()
	ctx := context.Background()
	ok := openFake(t, &fakeConnector{queryFn: func(string, []driver.Value) (driver.Rows, error) {
		return &fakeRows{cols: profileCols, data: [][]driver.Value{
			{"p1", "eu", "wireguard", []byte("{}"), "ref", true, now(), now()},
		}}, nil
	}})
	got, err := ok.GetProfile(ctx, "p1")
	if err != nil || got.ID != "p1" || got.Name != "eu" {
		t.Fatalf("success: got %+v err=%v", got, err)
	}
	nf := openFake(t, &fakeConnector{queryFn: func(string, []driver.Value) (driver.Rows, error) {
		return &fakeRows{cols: profileCols}, nil // zero rows → sql.ErrNoRows
	}})
	if _, err := nf.GetProfile(ctx, "missing"); !errors.Is(err, ErrNotFound) {
		t.Fatalf("no rows: want ErrNotFound, got %v", err)
	}
	ge := openFake(t, &fakeConnector{queryFn: func(string, []driver.Value) (driver.Rows, error) { return nil, errBoom }})
	if _, err := ge.GetProfile(ctx, "x"); err == nil || errors.Is(err, ErrNotFound) || !strings.Contains(err.Error(), "get profile") {
		t.Fatalf("generic error: want wrapped get-profile (not ErrNotFound), got %v", err)
	}
}

func TestGetTargetHost_Paths(t *testing.T) {
	t.Parallel()
	ctx := context.Background()
	ok := openFake(t, &fakeConnector{queryFn: func(string, []driver.Value) (driver.Rows, error) {
		return &fakeRows{cols: targetCols, data: [][]driver.Value{
			{"t1", "api.internal", "10.8.0.5", int64(8443), "https", "prof-1", "hc", true, now(), now()},
		}}, nil
	}})
	got, err := ok.GetTargetHost(ctx, "api.internal")
	if err != nil || got.PublicAlias != "api.internal" || got.Protocol != "https" {
		t.Fatalf("success: got %+v err=%v", got, err)
	}
	nf := openFake(t, &fakeConnector{queryFn: func(string, []driver.Value) (driver.Rows, error) {
		return &fakeRows{cols: targetCols}, nil
	}})
	if _, err := nf.GetTargetHost(ctx, "missing"); !errors.Is(err, ErrNotFound) {
		t.Fatalf("no rows: want ErrNotFound, got %v", err)
	}
	ge := openFake(t, &fakeConnector{queryFn: func(string, []driver.Value) (driver.Rows, error) { return nil, errBoom }})
	if _, err := ge.GetTargetHost(ctx, "x"); err == nil || errors.Is(err, ErrNotFound) || !strings.Contains(err.Error(), "get target") {
		t.Fatalf("generic error: got %v", err)
	}
}

func TestGetRuleByHost_Paths(t *testing.T) {
	t.Parallel()
	ctx := context.Background()
	ok := openFake(t, &fakeConnector{queryFn: func(string, []driver.Value) (driver.Rows, error) {
		return &fakeRows{cols: ruleCols, data: [][]driver.Value{
			{"r1", int64(50), "api.internal", "/x", "t1", true, now(), now()},
		}}, nil
	}})
	got, err := ok.GetRuleByHost(ctx, "api.internal")
	if err != nil || got.ID != "r1" || got.MatchPath != "/x" {
		t.Fatalf("success: got %+v err=%v", got, err)
	}
	nf := openFake(t, &fakeConnector{queryFn: func(string, []driver.Value) (driver.Rows, error) {
		return &fakeRows{cols: ruleCols}, nil
	}})
	if _, err := nf.GetRuleByHost(ctx, "none"); !errors.Is(err, ErrNotFound) {
		t.Fatalf("no rows: want ErrNotFound, got %v", err)
	}
	ge := openFake(t, &fakeConnector{queryFn: func(string, []driver.Value) (driver.Rows, error) { return nil, errBoom }})
	if _, err := ge.GetRuleByHost(ctx, "x"); err == nil || errors.Is(err, ErrNotFound) || !strings.Contains(err.Error(), "get rule by host") {
		t.Fatalf("generic error: got %v", err)
	}
}

// =============================================================================
// Upsert* (RETURNING id) — success, error; UpsertRule update-path ErrNotFound.
// =============================================================================

func idRows(id string) *fakeRows {
	return &fakeRows{cols: []string{"id"}, data: [][]driver.Value{{id}}}
}

func TestUpsertProfile_Paths(t *testing.T) {
	t.Parallel()
	ctx := context.Background()
	// success: also drives the config-default ("{}") and type-default (wireguard) branches.
	ok := openFake(t, &fakeConnector{queryFn: func(_ string, args []driver.Value) (driver.Rows, error) {
		return idRows("new-id"), nil
	}})
	id, err := ok.UpsertProfile(ctx, VPNProfile{Name: "eu"}) // empty Config + empty Type
	if err != nil || id != "new-id" {
		t.Fatalf("success: id=%q err=%v", id, err)
	}
	er := openFake(t, &fakeConnector{queryFn: func(string, []driver.Value) (driver.Rows, error) { return nil, errBoom }})
	if _, err := er.UpsertProfile(ctx, VPNProfile{Name: "eu", Config: []byte(`{"a":1}`), Type: VPNTypeOpenVPN}); err == nil || !strings.Contains(err.Error(), "upsert profile") {
		t.Fatalf("error: got %v", err)
	}
}

func TestUpsertTarget_Paths(t *testing.T) {
	t.Parallel()
	ctx := context.Background()
	// success drives port-default (80) and protocol-default ("http") branches.
	ok := openFake(t, &fakeConnector{queryFn: func(string, []driver.Value) (driver.Rows, error) { return idRows("tid"), nil }})
	id, err := ok.UpsertTarget(ctx, TargetHost{PublicAlias: "a", PrivateIP: "10.0.0.1"})
	if err != nil || id != "tid" {
		t.Fatalf("success: id=%q err=%v", id, err)
	}
	er := openFake(t, &fakeConnector{queryFn: func(string, []driver.Value) (driver.Rows, error) { return nil, errBoom }})
	if _, err := er.UpsertTarget(ctx, TargetHost{PublicAlias: "a", PrivateIP: "10.0.0.1", Port: 8443, Protocol: "https"}); err == nil || !strings.Contains(err.Error(), "upsert target") {
		t.Fatalf("error: got %v", err)
	}
}

func TestUpsertRule_Paths(t *testing.T) {
	t.Parallel()
	ctx := context.Background()
	// insert path (ID == "").
	ins := openFake(t, &fakeConnector{queryFn: func(string, []driver.Value) (driver.Rows, error) { return idRows("r-new"), nil }})
	id, err := ins.UpsertRule(ctx, ProxyRule{MatchHost: "h", Enabled: true})
	if err != nil || id != "r-new" {
		t.Fatalf("insert: id=%q err=%v", id, err)
	}
	// update path (ID != "") success.
	upd := openFake(t, &fakeConnector{queryFn: func(string, []driver.Value) (driver.Rows, error) { return idRows("r1"), nil }})
	id, err = upd.UpsertRule(ctx, ProxyRule{ID: "r1", Priority: 9})
	if err != nil || id != "r1" {
		t.Fatalf("update: id=%q err=%v", id, err)
	}
	// update path, no row matched → ErrNotFound.
	miss := openFake(t, &fakeConnector{queryFn: func(string, []driver.Value) (driver.Rows, error) {
		return &fakeRows{cols: []string{"id"}}, nil // zero rows → sql.ErrNoRows
	}})
	if _, err := miss.UpsertRule(ctx, ProxyRule{ID: "gone"}); !errors.Is(err, ErrNotFound) {
		t.Fatalf("update-miss: want ErrNotFound, got %v", err)
	}
	// insert path generic error.
	er := openFake(t, &fakeConnector{queryFn: func(string, []driver.Value) (driver.Rows, error) { return nil, errBoom }})
	if _, err := er.UpsertRule(ctx, ProxyRule{MatchHost: "h"}); err == nil || !strings.Contains(err.Error(), "upsert rule") {
		t.Fatalf("insert-error: got %v", err)
	}
}

func TestUpsertUser_Paths(t *testing.T) {
	t.Parallel()
	ctx := context.Background()
	// success drives role-default ("user") branch.
	ok := openFake(t, &fakeConnector{queryFn: func(string, []driver.Value) (driver.Rows, error) { return idRows("uid"), nil }})
	id, err := ok.UpsertUser(ctx, ProxyUser{Username: "bob"})
	if err != nil || id != "uid" {
		t.Fatalf("success: id=%q err=%v", id, err)
	}
	er := openFake(t, &fakeConnector{queryFn: func(string, []driver.Value) (driver.Rows, error) { return nil, errBoom }})
	if _, err := er.UpsertUser(ctx, ProxyUser{Username: "bob", Role: "admin"}); err == nil || !strings.Contains(err.Error(), "upsert user") {
		t.Fatalf("error: got %v", err)
	}
}

// =============================================================================
// Delete*/UpsertTier/DeleteTier/AppendAudit (ExecContext) — success + error.
// =============================================================================

func TestExecMethods_Paths(t *testing.T) {
	t.Parallel()
	ctx := context.Background()

	okExec := func() *fakeConnector {
		return &fakeConnector{execFn: func(string, []driver.Value) (driver.Result, error) { return fakeResult{}, nil }}
	}
	errExec := func() *fakeConnector {
		return &fakeConnector{execFn: func(string, []driver.Value) (driver.Result, error) { return nil, errBoom }}
	}

	cases := []struct {
		name    string
		callOK  func(p *Postgres) error
		wrapStr string
	}{
		{"DeleteProfile", func(p *Postgres) error { return p.DeleteProfile(ctx, "id") }, "delete profile"},
		{"DeleteTarget", func(p *Postgres) error { return p.DeleteTarget(ctx, "id") }, "delete target"},
		{"DeleteRule", func(p *Postgres) error { return p.DeleteRule(ctx, "id") }, "delete rule"},
		{"UpsertTier", func(p *Postgres) error {
			return p.UpsertTier(ctx, TargetTunnelTier{TargetID: "t", VPNProfileID: "p", Tier: 0})
		}, "upsert tier"},
		{"DeleteTier", func(p *Postgres) error { return p.DeleteTier(ctx, "t", 1) }, "delete tier"},
		{"AppendAudit", func(p *Postgres) error {
			return p.AppendAudit(ctx, AuditLogEntry{Actor: "admin", Action: "x.y", Detail: ""})
		}, "append audit"},
	}
	for _, tc := range cases {
		t.Run(tc.name+"/ok", func(t *testing.T) {
			if err := tc.callOK(openFake(t, okExec())); err != nil {
				t.Fatalf("%s ok: unexpected err %v", tc.name, err)
			}
		})
		t.Run(tc.name+"/err", func(t *testing.T) {
			err := tc.callOK(openFake(t, errExec()))
			if err == nil || !strings.Contains(err.Error(), tc.wrapStr) {
				t.Fatalf("%s err: want wrapped %q, got %v", tc.name, tc.wrapStr, err)
			}
		})
	}
}

// =============================================================================
// WithTx — commit success, begin error, fn error (rollback), commit error.
// =============================================================================

func TestWithTx_Paths(t *testing.T) {
	t.Parallel()
	ctx := context.Background()

	// success: fn runs an exec on the tx-scoped store and commits.
	okc := &fakeConnector{execFn: func(string, []driver.Value) (driver.Result, error) { return fakeResult{}, nil }}
	p := openFake(t, okc)
	ran := false
	if err := p.WithTx(ctx, func(tx Queries) error {
		ran = true
		return tx.AppendAudit(ctx, AuditLogEntry{Actor: "a", Action: "b"})
	}); err != nil || !ran {
		t.Fatalf("commit-success: ran=%v err=%v", ran, err)
	}

	// begin error → wrapped "begin tx", fn never runs.
	be := openFake(t, &fakeConnector{beginErr: errBoom})
	called := false
	if err := be.WithTx(ctx, func(Queries) error { called = true; return nil }); err == nil || !strings.Contains(err.Error(), "begin tx") || called {
		t.Fatalf("begin-error: called=%v err=%v", called, err)
	}

	// fn error → rollback, fn error returned verbatim (authoritative).
	fe := openFake(t, &fakeConnector{execFn: func(string, []driver.Value) (driver.Result, error) { return fakeResult{}, nil }})
	if err := fe.WithTx(ctx, func(Queries) error { return errBoom }); !errors.Is(err, errBoom) {
		t.Fatalf("fn-error: want errBoom (rolled back), got %v", err)
	}

	// commit error → wrapped "commit tx".
	ce := openFake(t, &fakeConnector{
		execFn:    func(string, []driver.Value) (driver.Result, error) { return fakeResult{}, nil },
		commitErr: errBoom,
	})
	if err := ce.WithTx(ctx, func(Queries) error { return nil }); err == nil || !strings.Contains(err.Error(), "commit tx") {
		t.Fatalf("commit-error: got %v", err)
	}
}
